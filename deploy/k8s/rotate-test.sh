#!/usr/bin/env bash
# Tests for the order of a change of credentials (deploy/k8s/rotate.sh) through deploy/k8s/secrets.sh, on the dev path
# and the GitOps path's staging, and for the glue of deploy/k8s/install.sh around it: fake kubectl, helmfile, helm and
# drill traffic log their calls in order; a fake .env made at run time, so no file of the repository holds a secret.
# macOS and Linux, no network, Docker or cluster: the services' restarts are checked by make drill-k8s-reloader.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
for tool in git jq openssl perl; do
  command -v "$tool" >/dev/null || {
    echo "FAIL  $tool is not installed" >&2
    exit 1
  }
done

# --- the fakes. FAKE_STATE is the folder of their log (calls) and of the state of the fake cluster: namespaces,
# statefulsets, reloader, release, live-<namespace>-<resource>-<name>, render-<name>...
# No Reloader annotation is ever on a command line: the scripts read a workload as JSON.
bin=$work/bin
mkdir -p "$bin"
cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
printf 'kubectl %s' "$*" | tr '\n' ' ' >>"$s/calls"
echo >>"$s/calls"
[ "${1:-}" = --context ] || { echo "fake kubectl: --context is not the first argument" >&2; exit 2; }
shift 2
ns=
if [ "${1:-}" = -n ]; then ns=$2; shift 2; fi
args="$*"
case $args in
  "get namespace "*) grep -qx "${args#get namespace }" "$s/namespaces" ;;
  "apply --server-side --field-manager=svp-secrets --force-conflicts -f -")
    tee -a "$s/applied.yaml" | awk '$1 == "name:" { n = $2 } $1 == "namespace:" { print "applied " $2 "/" n }' >>"$s/calls" ;;
  "create -f -") cat >/dev/null ;;
  "get secret glitchtip-runtime") exit 1 ;;
  "get pvc data-kafka-0") [ -f "$s/broker-pass" ] ;;
  # Kafka's svp-admin (kafka_admin): Secret kafka-admin holds the value of .env unless file kafka-secret says another;
  # the broker and svp-ops run unless broker-down; the broker takes svp-admin with the password of file broker-pass.
  "get secret kafka-admin -o jsonpath={.data.SVP_KAFKA_ADMIN_PASSWORD}")
    { cat "$s/kafka-secret" 2>/dev/null || sed -n 's/^SVP_KAFKA_ADMIN_PASSWORD=//p' "$FAKE_ENV"; } | tr -d '\n' | base64 ;;
  "get pod kafka-0 -o jsonpath={.status.containerStatuses[?(@.name==\"kafka\")].ready}") [ -f "$s/broker-down" ] || printf true ;;
  "get deployment svp-ops --ignore-not-found -o jsonpath={.status.availableReplicas}") [ -f "$s/broker-down" ] || printf 1 ;;
  "exec -i deploy/svp-ops -c kafka -- sh -c "*)
    IFS= read -r new; IFS= read -r secret
    have=$(cat "$s/broker-pass")
    [ "$new" != "$have" ] || exit 0
    [ "$secret" = "$have" ] || { echo "fake: SaslAuthenticationException" >&2; exit 3; }
    printf '%s' "$new" >"$s/broker-pass"
    exit 10 ;;
  # Valkey's users (valkey_barrier): refused for as many logins as file stale-valkey holds (never: always), then the
  # four passwords on stdin must be those of .env.
  "get deployment valkey --ignore-not-found -o name") ! grep -qx valkey "$s/deployments" 2>/dev/null || echo deployment.apps/valkey ;;
  "exec -i deploy/svp-ops -c valkey -- sh -c "*)
    got=$(cat)
    want=$(for v in GATEWAY FEED_SERVICE WEB OPS; do sed -n "s/^SVP_VALKEY_${v}_PASSWORD=//p" "$FAKE_ENV"; done)
    n=$(cat "$s/stale-valkey" 2>/dev/null || echo 0)
    case $n in
      never) exit 3 ;;
      0) [ "$got" = "$want" ] || exit 3 ;;
      *) echo $((n - 1)) >"$s/stale-valkey"; exit 3 ;;
    esac ;;
  "get nodes -o jsonpath="*) printf arm64 ;;
  "get clusters.postgresql.cnpg.io svp-pg --ignore-not-found -o name" | "get backups.postgresql.cnpg.io -o jsonpath="*) ;;
  "get statefulsets,deployments -o name")
    sed 's|^|statefulset.apps/|' "$s/statefulsets" 2>/dev/null || true
    sed 's|^|deployment.apps/|' "$s/deployments" 2>/dev/null || true ;;
  "get deployment reloader --ignore-not-found -o jsonpath={.status.availableReplicas}") cat "$s/reloader" 2>/dev/null || true ;;
  "get deployment reloader -o jsonpath={.spec.template.spec.serviceAccountName}") printf reloader ;;
  "get deployments.apps "*" --ignore-not-found -o json" | "get statefulsets.apps "*" --ignore-not-found -o json" | \
    "get rollouts.argoproj.io "*" --ignore-not-found -o json")
    set -- $args
    cat "$s/live-$ns-$2-$3" 2>/dev/null || true ;;
  "get statefulsets.apps "*" -o json" | "get deployments.apps "*" -o json")
    set -- $args
    cat "$s/live-$ns-$2-$3" 2>/dev/null || { echo "Error from server (NotFound): $2 \"$3\" not found" >&2; exit 1; } ;;
  "auth can-i patch "*" --as system:serviceaccount:reloader:reloader")
    set -- $args
    if grep -qx "$ns $4" "$s/cannot" 2>/dev/null; then echo no; exit 1; fi
    echo yes ;;
  "get statefulset "*" --ignore-not-found -o jsonpath={.spec.replicas}")
    sts=${args#get statefulset }
    sts=${sts%% *}
    if grep -qx "$sts" "$s/statefulsets" 2>/dev/null; then cat "$s/replicas-$sts" 2>/dev/null || printf 1; fi ;;
  "get pod "*" --ignore-not-found -o jsonpath="*)
    if [ -f "$s/pod-error" ]; then echo "Error from server (ServiceUnavailable): the server is currently unable to handle the request" >&2; exit 1; fi
    printf '2026-01-01T00:00:00Z True' ;;
  "exec -i "*" -c "*" -- sh -c "*)
    pod=${args#exec -i }
    pod=${pod%% *}
    IFS= read -r v
    case $args in
      *RUSTFS_SECRET_KEY*) want=$(sed -n 's/^SVP_S3_ROOT_PASSWORD=//p' "$FAKE_ENV") ;;
      *) exit 4 ;;
    esac
    n=$(cat "$s/stale-$pod" 2>/dev/null || echo 0)
    case $n in
      never) exit 3 ;;
      0) [ "$v" = "$want" ] || exit 3 ;;
      *) echo $((n - 1)) >"$s/stale-$pod"; exit 3 ;;
    esac ;;
  "get secrets -l owner=helm,name=svp-data -o name") [ ! -f "$s/release" ] || echo secret/sh.helm.release.v1.svp-data.v1 ;;
  "get crd externalsecrets.external-secrets.io --ignore-not-found -o name")
    [ ! -f "$s/eso" ] || echo customresourcedefinition.apiextensions.k8s.io/externalsecrets.external-secrets.io ;;
  "get externalsecrets.external-secrets.io -A -o json")
    for id in svp-data/pg-superuser svp-data/s3-root svp/user-service-env svp-obs/grafana-admin; do
      jq -n --arg id "$id" --arg n "$(cat "$s/es-${id%/*}-${id#*/}" 2>/dev/null || echo 0)" '{metadata: {namespace: ($id | split("/")[0]),
        name: ($id | split("/")[1]), generation: 1}, status: {syncedResourceVersion: "1-\($n)", conditions: [{type: "Ready", status: "True"}]}}'
    done | jq -s '{items: .}' ;;
  "annotate externalsecrets.external-secrets.io "*" --overwrite force-sync="*)
    name=$(printf '%s' "$args" | awk '{print $3}')
    f=$s/es-$ns-$name
    echo $(($(cat "$f" 2>/dev/null || echo 0) + 1)) >"$f" ;;
  "get crd applications.argoproj.io --ignore-not-found -o name")
    [ ! -f "$s/argo" ] || echo customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io ;;
  "get applications.argoproj.io svp-data --ignore-not-found -o name") [ ! -f "$s/argo-app" ] || echo application.argoproj.io/svp-data ;;
  "patch applications.argoproj.io/svp-data --type merge -p "*) jq -r .operation.initiatedBy.username <<<"${args#*-p }" >"$s/argo-op" ;;
  "get applications.argoproj.io/svp-data -o json")
    jq -n --arg u "$(cat "$s/argo-op" 2>/dev/null)" --arg p "$(cat "$s/argo-phase" 2>/dev/null || echo Succeeded)" \
      '{status: {operationState: {operation: {initiatedBy: {username: $u}}, phase: $p, message: "fake message"}}}' ;;
  "get rollouts.argoproj.io "*) [ -f "$s/rollout-${args#get rollouts.argoproj.io }" ] ;;
  # A migrate Job that fails (install.sh's hooks): the previous Job, the one running now, its last attempt's log.
  "get job video-service-migrate -o jsonpath={.metadata.uid}") printf uid-old ;;
  "get job video-service-migrate -o jsonpath={.metadata.uid} {.status.active}") printf 'uid-new 1' ;;
  "logs -l batch.kubernetes.io/controller-uid=uid-new --previous --tail=40") echo 'migrate: password authentication failed for user "svp_video_migrator"' ;;
  "get job video-service-migrate -o jsonpath={.status.conditions[?(@.type==\"Failed\")].status}") printf True ;;
  "get pods -o json") echo '{"items": []}' ;;
  "get rollout "*" -o jsonpath={.status.phase}") name=${args#get rollout }; cat "$s/phase-${name%% *}" 2>/dev/null || true ;;
  *) echo "fake kubectl: unexpected call: $args" >&2; exit 3 ;;
esac
EOF
cat >"$bin/helmfile" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
printf 'helmfile %s\n' "$*" >>"$s/calls"
case " $* " in
  *" template "*)
    for a; do
      case $a in
        name=*) cat "$s/render-${a#name=}" 2>/dev/null ;;
        'wave!=0,wave!=1') cat "$s/render-later" 2>/dev/null ;;
      esac
    done
    exit 0 ;;
esac
# helmfile-fail: the sync whose arguments hold this text fails.
if [ -s "$s/helmfile-fail" ]; then case " $* " in *"$(cat "$s/helmfile-fail")"*) exit 1 ;; esac; fi
# A sync of the later waves upgrades each Rollout's release to its render, which helm get manifest then prints, and
# installs what next-<file> says.
case " $* " in
  *" sync "*"wave!=0"*)
    for f in "$s"/render-*; do [ ! -e "$f" ] || [ "$f" = "$s/render-later" ] || cp "$f" "$s/manifest-${f##*/render-}"; done
    for f in "$s"/next-*; do [ ! -e "$f" ] || mv "$f" "$s/${f##*/next-}"; done ;;
esac
EOF
cat >"$bin/helm" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
printf 'helm %s\n' "$*" >>"$s/calls"
[ "$1 $2" = "--kube-context k3d-svp" ] || exit 2
case "$3 $4" in
  "get manifest") cat "$s/manifest-$5" 2>/dev/null ;;
  *) exit 3 ;;
esac
EOF
chmod 755 "$bin"/*

# --- the clone of svp-gitops (gitops_dir only checks it is one), with the two Rollouts of components.json.
gitops=$work/gitops
mkdir -p "$gitops/argocd/apps"
git -C "$gitops" init -q
git -C "$gitops" remote add origin https://github.com/anhnvcoder/svp-gitops.git
cat >"$gitops/argocd/apps/components.json" <<'EOF'
{"components": [
  {"name": "svp-cluster", "namespace": "cert-manager", "wave": 1, "path": "deploy/helm/svp-cluster"},
  {"name": "gateway", "namespace": "svp", "wave": 7, "path": "deploy/helm/svp-service", "values": "base/services/gateway.yaml", "canaryRoute": "api"},
  {"name": "web", "namespace": "svp", "wave": 7, "path": "deploy/helm/svp-service", "values": "base/services/web.yaml", "canaryRoute": "web"},
  {"name": "external-secrets", "namespace": "external-secrets", "wave": 0, "gitopsOnly": true, "canaryRoute": "x"}
]}
EOF

# --- the fake secrets, and the copy of deploy/ that reads them. install.sh's copy runs a fake secrets.sh and a fake
# drill traffic, which log their calls.
fake=$work/code
mkdir -p "$fake"
cp -R "$repo/deploy" "$fake/deploy"
names=(SVP_PG_SUPERUSER_PASSWORD
  SVP_USER_MIGRATOR_DB_PASSWORD SVP_USER_APP_DB_PASSWORD SVP_VIDEO_MIGRATOR_DB_PASSWORD SVP_VIDEO_APP_DB_PASSWORD
  SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD SVP_ENGAGEMENT_APP_DB_PASSWORD SVP_FEED_MIGRATOR_DB_PASSWORD
  SVP_FEED_APP_DB_PASSWORD SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD
  SVP_S3_ROOT_PASSWORD SVP_VIDEO_S3_SECRET_KEY SVP_MEDIA_WORKER_S3_SECRET_KEY SVP_PG_BACKUP_S3_SECRET_KEY
  SVP_KAFKA_ADMIN_PASSWORD SVP_KAFKA_KEDA_PASSWORD SVP_KAFKA_USER_SERVICE_PASSWORD SVP_KAFKA_VIDEO_SERVICE_PASSWORD
  SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_MEDIA_WORKER_PASSWORD
  SVP_KAFKA_OTELCOL_PASSWORD JWT_SIGNING_KID JWT_SIGNING_KEY JWT_VERIFY_KEYS SVP_GRAFANA_ADMIN_PASSWORD
  GLITCHTIP_SECRET_KEY GLITCHTIP_ADMIN_PASSWORD)
: >"$work/secrets"
{
  for n in "${names[@]}"; do
    v="fake-$(openssl rand -hex 12)"
    echo "$v" >>"$work/secrets"
    echo "$n=$v"
  done
  # Valkey's ACL file takes letters and digits only, as make env writes them.
  for n in GATEWAY FEED_SERVICE WEB OPS; do
    v="fake$(openssl rand -hex 12)"
    echo "$v" >>"$work/secrets"
    echo "SVP_VALKEY_${n}_PASSWORD=$v"
  done
  echo "GLITCHTIP_ADMIN_EMAIL=admin@svp.local"
  v=$(openssl rand -base64 32)
  echo "$v" >>"$work/secrets"
  echo "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=$v"
} >"$work/env"
FAKE_ENV=$fake/.env
export FAKE_ENV
env_of() { sed -n "s/^$1=//p" "$work/env"; }
# The local CA of make env: fake PEM files, the server key's body a secret of its own.
mkdir -p "$fake/.local/ca"
printf -- '-----BEGIN CERTIFICATE-----\nfakeca%s\n-----END CERTIFICATE-----\n' "$(openssl rand -hex 8)" >"$fake/.local/ca/ca.crt"
printf -- '-----BEGIN CERTIFICATE-----\nfakeserver%s\n-----END CERTIFICATE-----\n' "$(openssl rand -hex 8)" >"$fake/.local/ca/server.crt"
key_body="fakekey$(openssl rand -hex 16)"
echo "$key_body" >>"$work/secrets"
printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----\n' "$key_body" >"$fake/.local/ca/server.key"
printf -- '-----BEGIN CERTIFICATE-----\nfakepg%s\n-----END CERTIFICATE-----\n' "$(openssl rand -hex 8)" >"$fake/.local/ca/postgres.crt"
pg_key_body="fakepgkey$(openssl rand -hex 16)"
echo "$pg_key_body" >>"$work/secrets"
printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----\n' "$pg_key_body" >"$fake/.local/ca/postgres.key"

# leaks FILE...: the secrets (or their base64) the FILEs hold, one line each; nothing when none.
leaks() {
  local v
  while IFS= read -r v; do
    if cat "$@" | grep -qF -- "$v" || cat "$@" | grep -qF -- "$(b64 "$v")"; then echo "${v:0:8}..."; fi
  done <"$work/secrets"
}
# no_leak NAME FILE...: a case of its own, that the FILEs (output, log of the calls) of NAME hold no secret.
no_leak() {
  local found
  found=$(leaks "${@:2}")
  if [ -z "$found" ]; then ok "$1: no secret value in the output or in any argument"; else fail "$1: secrets in the output or arguments: $found"; fi
}

# new_state NAMESPACE...: a fresh folder of the fakes' log and state (the namespaces given), and a fresh .env.
new_state() {
  FAKE_STATE=$(mktemp -d "$work/state.XXXXXX")
  export FAKE_STATE
  : >"$FAKE_STATE/calls"
  : >"$FAKE_STATE/applied.yaml"
  printf '%s\n' "$@" >"$FAKE_STATE/namespaces"
  cp "$work/env" "$fake/.env"
}
# applied_keys NAMESPACE/NAME: the keys of the Secret applied last under that name, joined by a space.
applied_keys() {
  awk -v id="$1" '/^---/ { n = ""; d = 0 } $1 == "name:" { name = $2 } $1 == "namespace:" { n = $2 "/" name }
    /^data:/ { d = (n == id); if (d) keys = ""; next } d && /^  [^ ]/ { k = $1; sub(/:$/, "", k); keys = keys " " k }
    END { print substr(keys, 2) }' "$FAKE_STATE/applied.yaml"
}
# applied_value NAMESPACE/NAME KEY: the decoded value of KEY of the Secret applied last under that name.
applied_value() {
  awk -v id="$1" -v key="$2" '/^---/ { n = "" } $1 == "name:" { name = $2 } $1 == "namespace:" { n = $2 "/" name }
    n == id && $1 == key ":" { gsub(/"/, "", $2); v = $2 } END { print v }' "$FAKE_STATE/applied.yaml" | base64 -d
}
# set_state FILE [CONTENT]: writes CONTENT (empty) into the fake cluster's state file FILE.
set_state() { printf '%s' "${2:-}" >"$FAKE_STATE/$1"; }
# opt_in_doc KIND NAMESPACE NAME SECRETS [template]: a document of a render whose workload opts in to Reloader for
# SECRETS, on it or (template) on its pod template.
opt_in_doc() {
  printf -- '---\n# Source: fake/templates/workload.yaml\napiVersion: apps/v1\nkind: %s\nmetadata:\n  name: %s\n  namespace: %s\n' "$1" "$3" "$2"
  if [ "${5:-}" = template ]; then
    printf 'spec:\n  template:\n    metadata:\n      annotations:\n        secret.reloader.stakater.com/reload: %s\n' "$4"
  else
    printf '  annotations:\n    secret.reloader.stakater.com/reload: "%s"\nspec:\n  replicas: 1\n' "$4"
  fi
}
# workload FILE NAMESPACE RESOURCE NAME [SECRETS [template]]: writes into state file FILE-NAMESPACE-RESOURCE-NAME
# (FILE live, or next-live) the JSON of a workload that names SECRETS for Reloader, on it or (template) on its pod
# template; none when SECRETS is empty.
workload() {
  jq -n --arg k secret.reloader.stakater.com/reload --arg v "${5:-}" --arg w "${6:-}" --arg n "$4" '{metadata: {name: $n}}
    | if $v == "" then . elif $w == "template" then .spec.template.metadata.annotations[$k] = $v
      else .metadata.annotations[$k] = $v end' >"$FAKE_STATE/$1-$2-$3-$4"
}
# The workloads of a running cluster that opt in, as the later waves render them: the servers (valkey), the operations
# CLI, a client (on its pod template), and a Rollout not made yet (none is a gap). Kafka's broker does not opt in.
later_render() {
  opt_in_doc StatefulSet svp-data s3 s3-root
  opt_in_doc Deployment svp-data valkey valkey-acl
  opt_in_doc Deployment svp-data svp-ops svp-ops template
  opt_in_doc Deployment svp user-service user-service-env,sentry
  opt_in_doc Rollout svp web web-env,sentry
  printf -- '---\nkind: ConfigMap\nmetadata:\n  name: notes\n  namespace: svp\n  annotations:\n    secret.reloader.stakater.com/reload: not-a-workload\n'
}
# running_cluster: s3, kafka (its svp-admin on the value of .env) and valkey run with the values of .env, Reloader is
# available, release svp-data installed, and every workload that exists names the Secrets its render does.
running_cluster() {
  printf 's3\nkafka\n' >"$FAKE_STATE/statefulsets"
  printf 'svp-ops\nvalkey\n' >"$FAKE_STATE/deployments"
  env_of SVP_KAFKA_ADMIN_PASSWORD | tr -d '\n' >"$FAKE_STATE/broker-pass"
  set_state reloader 1
  set_state release
  later_render >"$FAKE_STATE/render-later"
  workload live svp-data statefulsets.apps s3 s3-root
  workload live svp-data deployments.apps valkey valkey-acl
  workload live svp-data deployments.apps svp-ops svp-ops template
  workload live svp deployments.apps user-service user-service-env,sentry
}
# secrets_run OUT: deploy/k8s/secrets.sh of the copy with the fakes, at most 120 s; exit status in $rc.
secrets_run() {
  rc=0
  mkdir -p "$FAKE_STATE/tmp"
  env PATH="$bin:$PATH" SVP_GITOPS_DIR="$gitops" TMPDIR="$FAKE_STATE/tmp" perl -e 'alarm 120; exec @ARGV' \
    "$fake/deploy/k8s/secrets.sh" >"$1" 2>&1 || rc=$?
}
# line PATTERN, last_line PATTERN: the number of the first (last) line of the log of calls matching PATTERN (grep -E),
# empty when none.
line() { grep -nE -- "$1" "$FAKE_STATE/calls" | head -n 1 | cut -d: -f1 || true; }
last_line() { grep -nE -- "$1" "$FAKE_STATE/calls" | tail -n 1 | cut -d: -f1 || true; }
# before A B: true when lines A and B are both set and A comes first.
before() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }
show() { sed 's/^/      /' "$@"; }
all_calls=$work/all-calls
: >"$all_calls"
keep_calls() { cat "$FAKE_STATE/calls" >>"$all_calls"; }

# --- 1. the dev path on a running cluster: the object store restarted by Reloader meanwhile (two reads still find the
# previous root password), Valkey for one login, Kafka's svp-admin already on the value of .env.
new_state svp-data svp svp-obs keda
running_cluster
set_state stale-s3-0 2
set_state stale-valkey 1
secrets_run "$work/dev.out"
server=$(line '^kubectl .* get pvc data-kafka-0$')
broker=$(line '^kubectl .* -n svp-data exec -i deploy/svp-ops -c kafka -- sh -c ')
data=$(last_line '^applied svp-data/')
s3=$(last_line '^kubectl .* exec -i s3-0 -c s3 ')
valkey=$(last_line '^kubectl .* -n svp-data exec -i deploy/svp-ops -c valkey -- sh -c ')
init=$(line '^helmfile .* sync -l name=svp-data --concurrency 1$')
client=$(line '^applied (svp|svp-obs|keda)/')
guard=$(last_line '^kubectl .* -n svp auth can-i patch rollouts.argoproj.io --as system:serviceaccount:reloader:reloader$')
if [ "$rc" = 0 ] && before "$(line '^helmfile .* template -l wave!=0,wave!=1 --skip-deps$')" "$guard" && before "$guard" "$server" &&
  before "$server" "$broker" && before "$broker" "$data" && before "$data" "$s3" && before "$s3" "$valkey" &&
  before "$valkey" "$init" && before "$init" "$client" && [ "$(grep -c '^kubectl .* exec -i s3-0 ' "$FAKE_STATE/calls")" = 3 ] &&
  [ "$(grep -c '^kubectl .* exec -i deploy/svp-ops -c valkey ' "$FAKE_STATE/calls")" = 2 ] &&
  [ "$(grep -c '^helmfile .* sync ' "$FAKE_STATE/calls")" = 1 ] &&
  [ "$(grep -c ' auth can-i patch ' "$FAKE_STATE/calls")" = 4 ] &&
  grep -qE "^helmfile --kube-context k3d-svp --file $fake/deploy/k8s/helmfile.yaml.gotmpl --state-values-set gitopsDir=[^ ]*/gitops --state-values-set nodeArch=arm64 sync " "$FAKE_STATE/calls" &&
  grep -qx 'applied keda/keda-kafka' "$FAKE_STATE/calls" && grep -qx 'applied svp-obs/grafana-admin' "$FAKE_STATE/calls" &&
  grep -q '^ok    StatefulSet s3: each of its 1 pod(s) runs with the RUSTFS_SECRET_KEY of .env and is Ready' "$work/dev.out" &&
  grep -q "^ok    Deployment valkey: takes every user's password of .env" "$work/dev.out" &&
  ! grep -q 'password of svp-admin set in Kafka' "$work/dev.out" &&
  grep -q '^ok    Reloader restarts each workload whose Secret changed' "$work/dev.out"; then
  ok "secrets.sh, dev path: Reloader may restart each workload the later waves render with its annotation (on it or its pod template; one not made yet is no gap), then svp-admin's password checked in Kafka (unchanged), the Secrets of svp-data, the barriers (s3, then Valkey, each until it runs the values of .env), helmfile sync of release svp-data alone, then the clients' Secrets"
else
  fail "secrets.sh, dev path: exit $rc; guard $guard, server $server, broker $broker, data $data, s3 $s3, valkey $valkey, init $init, client $client"$'\n'"$(show "$work/dev.out" "$FAKE_STATE/calls")"
fi
no_leak "secrets.sh, dev path" "$work/dev.out" "$FAKE_STATE/calls"

# The Secrets of Kafka, Valkey and the local CA the dev path applies: the names and keys of the GitOps path's
# ExternalSecrets (chart svp-cluster, files/external-secrets.yaml), with the values of .env and .local/ca/.
want_secrets='svp-data/kafka-admin=SVP_KAFKA_ADMIN_PASSWORD
svp-data/svp-ops=SVP_KAFKA_ADMIN_PASSWORD SVP_VALKEY_OPS_PASSWORD
svp-data/kafka-users=SVP_KAFKA_USER_SERVICE_PASSWORD SVP_KAFKA_VIDEO_SERVICE_PASSWORD SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_MEDIA_WORKER_PASSWORD SVP_KAFKA_KEDA_PASSWORD SVP_KAFKA_OTELCOL_PASSWORD
svp-data/valkey-acl=users.acl
svp-data/kafka-tls=kafka.pem
svp-data/valkey-tls=valkey.crt valkey.key
svp-data/local-ca=ca.crt
svp-data/pg-tls=tls.crt tls.key
svp/local-ca=ca.crt
svp-obs/otelcol-kafka=password
svp-obs/local-ca=ca.crt
keda/keda-kafka=sasl tls username password
keda/local-ca=ca.crt'
problems=
while IFS='=' read -r id keys; do
  [ "$(applied_keys "$id")" = "$keys" ] || problems="$problems; $id has keys '$(applied_keys "$id")'"
done <<<"$want_secrets"
for k in $(applied_keys svp-data/kafka-users); do
  [ "$(applied_value svp-data/kafka-users "$k")" = "$(env_of "$k")" ] || problems="$problems; kafka-users $k"
done
[ "$(applied_value svp-data/svp-ops SVP_VALKEY_OPS_PASSWORD)" = "$(env_of SVP_VALKEY_OPS_PASSWORD)" ] || problems="$problems; svp-ops"
"$fake/deploy/valkey/aclfile.sh" "$fake/.env" "$work/users.acl"
[ "$(applied_value svp-data/valkey-acl users.acl)" = "$(cat "$work/users.acl")" ] || problems="$problems; valkey-acl"
[ "$(applied_value svp-data/kafka-tls kafka.pem)" = "$(cat "$fake/.local/ca/server.key" "$fake/.local/ca/server.crt")" ] ||
  problems="$problems; kafka.pem"
[ "$(applied_value svp-data/valkey-tls valkey.key)" = "$(cat "$fake/.local/ca/server.key")" ] || problems="$problems; valkey.key"
{ [ "$(applied_value svp-data/pg-tls tls.crt)" = "$(cat "$fake/.local/ca/postgres.crt")" ] &&
  [ "$(applied_value svp-data/pg-tls tls.key)" = "$(cat "$fake/.local/ca/postgres.key")" ]; } || problems="$problems; pg-tls"
awk '/^---/ { n = "" } $1 == "name:" { name = $2 } $1 == "namespace:" { n = $2 "/" name }
  n == "svp-data/pg-tls" && $1 == "type:" { t = $2 } n == "svp-data/pg-tls" && $1 == "cnpg.io/reload:" { l = $2 }
  END { exit !(t == "kubernetes.io/tls" && l == "\"true\"") }' "$FAKE_STATE/applied.yaml" ||
  problems="$problems; pg-tls is not of type kubernetes.io/tls labelled cnpg.io/reload"
# Every connection string verify-full against the CA each client mounts, at the name svp-pg's certificate holds.
while read -r id key user var db; do
  [ "$(applied_value "$id" "$key")" = "postgres://$user:$(env_of "$var")@svp-pg-rw.svp-data:5432/$db?sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt" ] ||
    problems="$problems; $key of $id"
done <<'URLS'
svp/user-service-env DATABASE_URL svp_user_app SVP_USER_APP_DB_PASSWORD svp_user
svp/feed-service-migrate-env DATABASE_URL svp_feed_migrator SVP_FEED_MIGRATOR_DB_PASSWORD svp_feed
svp-obs/glitchtip-env MAINTENANCE_DATABASE_URL svp_glitchtip_migrator SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD svp_glitchtip
URLS
for ns in svp-data svp svp-obs keda; do
  [ "$(applied_value "$ns/local-ca" ca.crt)" = "$(cat "$fake/.local/ca/ca.crt")" ] || problems="$problems; $ns/local-ca"
done
[ "$(applied_value keda/keda-kafka sasl) $(applied_value keda/keda-kafka tls) $(applied_value keda/keda-kafka username)" = \
  "scram_sha512 enable svp-keda" ] || problems="$problems; keda-kafka"
while read -r svc user var db; do
  [ "$(applied_value "svp/$svc-env" REDIS_URL)" = "rediss://$user:$(env_of "SVP_VALKEY_${var}_PASSWORD")@valkey.svp-data.svc.cluster.local:6379/$db" ] ||
    problems="$problems; REDIS_URL of $svc-env"
done <<'EOF'
gateway svp-gateway GATEWAY 10
feed-service svp-feed-service FEED_SERVICE 14
web svp-web WEB 9
EOF
data_secrets=$(sed -n 's|^applied svp-data/||p' "$FAKE_STATE/calls" | LC_ALL=C sort -u | paste -sd ' ' -)
[ "$data_secrets" = "kafka-admin kafka-tls kafka-users local-ca pg-backup-s3 pg-roles pg-superuser pg-tls s3-root s3-users svp-ops valkey-acl valkey-tls" ] ||
  problems="$problems; svp-data gets $data_secrets"
if [ -z "$problems" ] && [ -z "$(ls -A "$FAKE_STATE/tmp")" ]; then
  ok "secrets.sh, dev path: the Secrets of Kafka, Valkey, Postgres's server certificate (pg-tls, kubernetes.io/tls, cnpg.io/reload) and the local CA with the names and keys of the ExternalSecrets, the values of .env and .local/ca/ (the ACL file as deploy/valkey/aclfile.sh writes it, REDIS_URL rediss:// per user, DATABASE_URL verify-full against /etc/svp-ca/ca.crt), exactly these Secrets in svp-data, nothing left in TMPDIR"
else
  fail "secrets.sh, dev path, the Secrets of Kafka and Valkey:${problems#;}"
fi
keep_calls

# --- 1b. a changed password of svp-admin: the broker still on the previous one, which Secret kafka-admin holds, takes
# the one of .env through svp-ops before any Secret is written.
new_state svp-data svp svp-obs keda
running_cluster
old_admin="old$(openssl rand -hex 12)"
echo "$old_admin" >>"$work/secrets"
set_state broker-pass "$old_admin"
set_state kafka-secret "$old_admin"
secrets_run "$work/admin.out"
if [ "$rc" = 0 ] && grep -q '^ok    password of svp-admin set in Kafka from .env (logged in with the previous one)' "$work/admin.out" &&
  [ "$(cat "$FAKE_STATE/broker-pass")" = "$(env_of SVP_KAFKA_ADMIN_PASSWORD)" ] &&
  before "$(line '^kubectl .* exec -i deploy/svp-ops -c kafka ')" "$(line '^applied ')"; then
  ok "secrets.sh, svp-admin's password changed: set in Kafka through svp-ops with the previous one, before any Secret"
else
  fail "secrets.sh, svp-admin's password changed: exit $rc"$'\n'"$(show "$work/admin.out" "$FAKE_STATE/calls")"
fi
no_leak "secrets.sh, svp-admin's password changed" "$work/admin.out" "$FAKE_STATE/calls"
keep_calls

# --- 1c. what stops the change of svp-admin's password before any Secret: the broker or svp-ops not running, and a
# broker that takes none of the passwords known.
for c in down unknown; do
  new_state svp-data svp svp-obs keda
  running_cluster
  set_state kafka-secret "$old_admin"
  if [ "$c" = down ]; then
    set_state broker-pass "$old_admin"
    set_state broker-down
    why="SVP_KAFKA_ADMIN_PASSWORD in .env differs from Secret svp-data/kafka-admin, and broker kafka-0 or Deployment svp-ops is not running to take it; no Secret was changed"
  else
    set_state broker-pass "other$(openssl rand -hex 8)"
    why="Kafka takes none of these passwords for svp-admin: the one in .env, the one of Secret svp-data/kafka-admin, the one svp-ops runs with; no Secret was changed"
  fi
  secrets_run "$work/admin-$c.out"
  if [ "$rc" != 0 ] && grep -qF "FAIL  $why" "$work/admin-$c.out" && ! grep -q '^applied ' "$FAKE_STATE/calls"; then
    ok "secrets.sh, svp-admin's password changed, $c: stops before any Secret ($why)"
  else
    fail "secrets.sh, svp-admin's password changed, $c: exit $rc"$'\n'"$(show "$work/admin-$c.out" "$FAKE_STATE/calls")"
  fi
  keep_calls
done

# --- 1d. make env not run yet: no local CA, nothing applied.
new_state svp-data svp svp-obs keda
mv "$fake/.local/ca/server.key" "$work/server.key"
secrets_run "$work/no-ca.out"
mv "$work/server.key" "$fake/.local/ca/server.key"
if [ "$rc" != 0 ] && grep -qF 'FAIL  the local CA is missing in .local/ca/ (server.key); run make env, then this again' "$work/no-ca.out" &&
  ! grep -q '^applied ' "$FAKE_STATE/calls"; then
  ok "secrets.sh without the local CA: stops naming make env, nothing applied"
else
  fail "secrets.sh without the local CA: exit $rc"$'\n'"$(show "$work/no-ca.out" "$FAKE_STATE/calls")"
fi
keep_calls

# --- 2. the dev path on a new cluster (install.sh, right after chart svp-cluster): no server, no release svp-data.
new_state svp-data svp svp-obs keda
secrets_run "$work/new.out"
if [ "$rc" = 0 ] && ! grep -q '^helmfile ' "$FAKE_STATE/calls" && ! grep -q ' exec -i ' "$FAKE_STATE/calls" &&
  grep -q '^skip  init Jobs of svp-data: release svp-data is not installed yet' "$work/new.out" &&
  before "$(line '^applied svp-data/')" "$(line '^applied svp/')" && grep -qx 'applied keda/keda-kafka' "$FAKE_STATE/calls"; then
  ok "secrets.sh, dev path on a new cluster: no server to wait for, the init skipped (release svp-data not installed yet), the clients' Secrets applied"
else
  fail "secrets.sh, dev path on a new cluster: exit $rc"$'\n'"$(show "$work/new.out" "$FAKE_STATE/calls")"
fi
keep_calls

# --- 3. a run that dies after the servers' step: only SVP_PG_BACKUP_S3_SECRET_KEY changed, the init fails (s3-init
# cannot set the new key of svp-pg-backup), so no client Secret is applied; the next run with the same .env applies
# the same Secrets, runs the init again, then the clients.
new_state svp-data svp svp-obs keda
running_cluster
sed "s/^SVP_PG_BACKUP_S3_SECRET_KEY=.*/SVP_PG_BACKUP_S3_SECRET_KEY=fake-$(openssl rand -hex 12)/" "$work/env" >"$fake/.env"
sed -n 's/^SVP_PG_BACKUP_S3_SECRET_KEY=//p' "$fake/.env" >>"$work/secrets"
set_state helmfile-fail name=svp-data
secrets_run "$work/died.out"
died_rc=$rc
died_client=$(line '^applied (svp|svp-obs|keda)/')
died_init=$(grep -c '^helmfile .* sync -l name=svp-data ' "$FAKE_STATE/calls" || true)
keep_calls
: >"$FAKE_STATE/calls"
set_state helmfile-fail
secrets_run "$work/again.out"
if [ "$died_rc" != 0 ] && [ -z "$died_client" ] && [ "$died_init" = 1 ] &&
  grep -qF 'FAIL  the init Jobs of svp-data (helmfile sync of release svp-data, above) did not set the new passwords; the clients'"'"' Secrets were not changed' "$work/died.out" &&
  [ "$rc" = 0 ] && grep -qx 'applied svp-data/pg-backup-s3' "$FAKE_STATE/calls" &&
  before "$(line '^helmfile .* sync -l name=svp-data ')" "$(line '^applied svp/')"; then
  ok "secrets.sh, a run that dies in the init (only SVP_PG_BACKUP_S3_SECRET_KEY changed): no client Secret applied; the next run with the same .env runs the init again, then the clients"
else
  fail "secrets.sh, a run that dies in the init: first exit $died_rc (client line '$died_client', inits $died_init), next exit $rc"$'\n'"$(show "$work/died.out" "$work/again.out" "$FAKE_STATE/calls")"
fi
no_leak "secrets.sh, a run that dies in the init" "$work/died.out" "$work/again.out" "$FAKE_STATE/calls"
keep_calls

# --- 4. the GitOps path's staging: sources, ExternalSecrets of svp-data, barrier, sync of Application svp-data, the
# other ExternalSecrets.
new_state svp-data svp svp-obs svp-secrets
running_cluster
set_state eso
set_state argo
set_state argo-app
secrets_run "$work/gitops.out"
sources=$(last_line '^applied svp-secrets/')
annotated=$(grep -E '^kubectl .* annotate externalsecrets' "$FAKE_STATE/calls" | awk '{print $5 "/" $8}' | paste -sd ' ' -)
first_client=$(line '^kubectl .* -n (svp|svp-obs) annotate externalsecrets')
last_server=$(last_line '^kubectl .* -n svp-data annotate externalsecrets')
admin=$(line '^kubectl .* exec -i deploy/svp-ops -c kafka ')
valkey=$(last_line '^kubectl .* exec -i deploy/svp-ops -c valkey ')
patch=$(line '^kubectl .* patch applications.argoproj.io/svp-data ')
synced=$(last_line '^kubectl .* get applications.argoproj.io/svp-data -o json$')
source_keys="$(applied_keys svp-secrets/kafka-users)|$(applied_keys svp-secrets/valkey-users)|$(applied_keys svp-secrets/local-ca)|$(applied_keys svp-secrets/local-tls)"
if [ "$rc" = 0 ] && [ "$annotated" = "svp-data/pg-superuser svp-data/s3-root svp-obs/grafana-admin svp/user-service-env" ] &&
  before "$admin" "$(line '^applied svp-secrets/')" && before "$sources" "$last_server" && before "$last_server" "$valkey" &&
  before "$valkey" "$patch" && before "$patch" "$synced" && before "$synced" "$first_client" &&
  [ "$source_keys" = "SVP_KAFKA_KEDA_PASSWORD SVP_KAFKA_USER_SERVICE_PASSWORD SVP_KAFKA_VIDEO_SERVICE_PASSWORD SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_MEDIA_WORKER_PASSWORD SVP_KAFKA_OTELCOL_PASSWORD|SVP_VALKEY_GATEWAY_PASSWORD SVP_VALKEY_FEED_SERVICE_PASSWORD SVP_VALKEY_WEB_PASSWORD SVP_VALKEY_OPS_PASSWORD|ca.crt|server.crt server.key postgres.crt postgres.key" ] &&
  [ "$(applied_value svp-secrets/local-tls server.key)" = "$(cat "$fake/.local/ca/server.key")" ] &&
  [ "$(applied_value svp-secrets/local-tls postgres.key)" = "$(cat "$fake/.local/ca/postgres.key")" ] &&
  grep -q '"operation":{"initiatedBy":{"username":"svp-rotate-' "$FAKE_STATE/calls" &&
  ! grep -qE '^applied (svp|svp-obs|svp-data|keda)/' "$FAKE_STATE/calls" && ! grep -q '^helmfile ' "$FAKE_STATE/calls" &&
  grep -q '^ok    init Jobs of svp-data done (sync of Application svp-data Succeeded)' "$work/gitops.out"; then
  ok "secrets.sh, GitOps path: svp-admin's password in Kafka, the sources (Kafka's and Valkey's users, the local CA in local-ca and local-tls), the ExternalSecrets of svp-data built again, the barriers, one sync of Application svp-data until it Succeeded, then the other ExternalSecrets: exactly two groups"
else
  fail "secrets.sh, GitOps path: exit $rc; annotated '$annotated', admin $admin, sources $sources, server $last_server, valkey $valkey, patch $patch, synced $synced, client $first_client, source keys '$source_keys'"$'\n'"$(show "$work/gitops.out" "$FAKE_STATE/calls")"
fi
no_leak "secrets.sh, GitOps path" "$work/gitops.out" "$FAKE_STATE/calls"
keep_calls

# --- 5. the same, the sync of svp-data Failed: no ExternalSecret of the clients built again.
new_state svp-data svp svp-obs svp-secrets
running_cluster
set_state eso
set_state argo
set_state argo-app
set_state argo-phase Failed
secrets_run "$work/gitops-failed.out"
if [ "$rc" != 0 ] && grep -qF 'FAIL  sync of Application argocd/svp-data ended Failed: fake message; the clients'"'"' Secrets were not changed' "$work/gitops-failed.out" &&
  ! grep -qE '^kubectl .* -n (svp|svp-obs) annotate externalsecrets' "$FAKE_STATE/calls" &&
  [ "$(grep -c '^kubectl .* -n svp-data annotate externalsecrets' "$FAKE_STATE/calls")" = 2 ]; then
  ok "secrets.sh, GitOps path, the sync of svp-data Failed: stops naming it, no ExternalSecret of the clients built again"
else
  fail "secrets.sh, GitOps path, the sync of svp-data Failed: exit $rc"$'\n'"$(show "$work/gitops-failed.out" "$FAKE_STATE/calls")"
fi
keep_calls

# --- 6. the GitOps path before Argo CD exists (deploy/k8s/gitops.sh): the sources alone.
new_state svp-data svp svp-obs svp-secrets
secrets_run "$work/bootstrap.out"
if [ "$rc" = 0 ] && grep -q '^skip  ExternalSecrets of the server: none yet' "$work/bootstrap.out" &&
  grep -q '^skip  init Jobs of svp-data: Application argocd/svp-data does not exist yet' "$work/bootstrap.out" &&
  grep -q '^skip  ExternalSecrets of the clients: none yet' "$work/bootstrap.out" &&
  grep -q '^applied svp-secrets/pg-superuser$' "$FAKE_STATE/calls" && ! grep -qE ' (annotate|patch) ' "$FAKE_STATE/calls"; then
  ok "secrets.sh, GitOps path before Argo CD: the sources written, no ExternalSecret or Application yet to sync"
else
  fail "secrets.sh, GitOps path before Argo CD: exit $rc"$'\n'"$(show "$work/bootstrap.out" "$FAKE_STATE/calls")"
fi
keep_calls

# --- 7. a cluster not ready for a change of credentials: refused before anything is written, on both paths. Made
# before Reloader; or s3 or valkey names no Secret for Reloader yet (make k8s-up stopped before svp-data; GitOps: no
# Argo CD yet); on the dev path also a client naming fewer Secrets than its chart, and a Reloader whose ServiceAccount
# may not patch the Rollouts (its chart rendered before their API was served).
for c in "dev no-reloader" "gitops no-reloader" "dev s3" "gitops s3" "gitops valkey" "dev client" "dev rbac"; do
  set -- $c
  if [ "$1" = dev ]; then new_state svp-data svp svp-obs keda; else new_state svp-data svp svp-obs svp-secrets; fi
  case $2 in
    no-reloader)
      printf 'kafka\n' >"$FAKE_STATE/statefulsets"
      why="runs the project's workloads but no Reloader" ;;
    valkey)
      running_cluster
      workload live svp-data deployments.apps valkey
      why="Deployment svp-data/valkey names no Secret in secret.reloader.stakater.com/reload yet" ;;
    s3)
      running_cluster
      workload live svp-data statefulsets.apps s3
      if [ "$1" = dev ]; then
        why="StatefulSet svp-data/s3 names no Secret in secret.reloader.stakater.com/reload, its chart s3-root"
      else
        why="StatefulSet svp-data/s3 names no Secret in secret.reloader.stakater.com/reload yet"
      fi ;;
    client)
      running_cluster
      workload live svp deployments.apps user-service user-service-env
      why="Deployment svp/user-service names user-service-env in secret.reloader.stakater.com/reload, its chart user-service-env,sentry" ;;
    rbac)
      running_cluster
      set_state cannot 'svp rollouts.argoproj.io'
      why="Reloader (ServiceAccount reloader/reloader) may not patch rollouts.argoproj.io in namespace svp" ;;
  esac
  [ "$1" = dev ] || set_state eso
  secrets_run "$work/old.out"
  want="make k8s-up installs them, Reloader and every workload's annotation"
  [ "$1" = dev ] || want="Argo CD installs them with component reloader and the charts of svp-gitops"
  if [ "$rc" != 0 ] && grep -qF "is not ready for a change of credentials: " "$work/old.out" && grep -qF "$why" "$work/old.out" &&
    grep -qF "$want" "$work/old.out" && ! grep -qE '^applied |get pvc |^helmfile .* sync ' "$FAKE_STATE/calls"; then
    ok "secrets.sh, $1 path, $2: refused before anything is written ($why; $want)"
  else
    fail "secrets.sh, $1 path, $2: exit $rc"$'\n'"$(show "$work/old.out" "$FAKE_STATE/calls")"
  fi
  keep_calls
done

# --- 8. the barriers themselves, sourced with sleep as a function that moves bash's clock: rotate_barrier over three
# pods of s3, valkey_barrier over Valkey.
# barrier_run OUT FUNCTION STATE...: FUNCTION (rotate_barrier of s3 with 3 replicas, or valkey_barrier) with the state
# files given; exit status in $rc, the sleeps taken in OUT.sleeps.
barrier_run() {
  local out=$1 fn=$2
  shift 2
  new_state svp-data
  printf 's3\n' >"$FAKE_STATE/statefulsets"
  printf 'valkey\n' >"$FAKE_STATE/deployments"
  set_state replicas-s3 3
  for st in "$@"; do set_state "${st%%=*}" "${st#*=}"; done
  rc=0
  (
    PATH=$bin:$PATH
    # shellcheck source=deploy/k8s/lib.sh
    . "$fake/deploy/k8s/lib.sh"
    # shellcheck source=deploy/k8s/rotate.sh
    . "$fake/deploy/k8s/rotate.sh"
    again="make k8s-secrets"
    sleep() {
      echo "$1" >>"$out.sleeps"
      SECONDS=$((SECONDS + $1))
    }
    for v in GATEWAY FEED_SERVICE WEB OPS; do eval "SVP_VALKEY_${v}_PASSWORD=\$(env_of SVP_VALKEY_${v}_PASSWORD)"; done
    if [ "$fn" = rotate_barrier ]; then
      rotate_barrier s3 s3 RUSTFS_SECRET_KEY "$(env_of SVP_S3_ROOT_PASSWORD)"
    else
      valkey_barrier
    fi
  ) >"$out" 2>&1 || rc=$?
  touch "$out.sleeps"
}
barrier_run "$work/b-current" rotate_barrier
if [ "$rc" = 0 ] && [ ! -s "$work/b-current.sleeps" ] && [ "$(grep -c ' exec -i s3-' "$FAKE_STATE/calls")" = 3 ]; then
  ok "rotate_barrier: every pod already on the value of .env: each compared once, no wait"
else
  fail "rotate_barrier, pods already current: exit $rc, $(grep -c . "$work/b-current.sleeps") sleeps"$'\n'"$(show "$work/b-current")"
fi
barrier_run "$work/b-later" rotate_barrier stale-s3-2=2 stale-s3-1=1
if [ "$rc" = 0 ] && [ "$(grep -c . "$work/b-later.sleeps")" = 3 ] &&
  grep -q '^ok    StatefulSet s3: each of its 3 pod(s) runs with the RUSTFS_SECRET_KEY of .env and is Ready' "$work/b-later"; then
  ok "rotate_barrier: pods on the previous password for a few reads (Reloader restarting them) are waited for, then it passes"
else
  fail "rotate_barrier, pods restarted meanwhile: exit $rc, $(grep -c . "$work/b-later.sleeps") sleeps"$'\n'"$(show "$work/b-later")"
fi
barrier_run "$work/b-never" rotate_barrier stale-s3-0=never
if [ "$rc" != 0 ] &&
  grep -qF 'FAIL  StatefulSet svp-data/s3: pod s3-0 runs with another RUSTFS_SECRET_KEY than .env 900s after its Secret changed: Reloader did not restart it' "$work/b-never" &&
  [ "$(awk '{ s += $1 } END { print s }' "$work/b-never.sleeps")" -ge 800 ] && [ "$(awk '{ s += $1 } END { print s }' "$work/b-never.sleeps")" -le 902 ]; then
  ok "rotate_barrier: a pod that never runs the value of .env fails naming its StatefulSet and Reloader, once 300 s a replica are over"
else
  fail "rotate_barrier, a pod never restarted: exit $rc"$'\n'"$(show "$work/b-never")"
fi
barrier_run "$work/b-error" rotate_barrier pod-error=
if [ "$rc" != 0 ] && grep -qF 'FAIL  read pod svp-data/s3-0 (above), to know whether it runs with the value of .env; run make k8s-secrets again' "$work/b-error" &&
  [ ! -s "$work/b-error.sleeps" ]; then
  ok "rotate_barrier: a pod that cannot be read stops it at once, naming the pod"
else
  fail "rotate_barrier, a pod that cannot be read: exit $rc"$'\n'"$(show "$work/b-error")"
fi
barrier_run "$work/v-current" valkey_barrier
if [ "$rc" = 0 ] && [ ! -s "$work/v-current.sleeps" ] && [ "$(grep -c ' exec -i deploy/svp-ops -c valkey ' "$FAKE_STATE/calls")" = 1 ] &&
  grep -q "^ok    Deployment valkey: takes every user's password of .env" "$work/v-current"; then
  ok "valkey_barrier: Valkey already on the passwords of .env: one login of each user, no wait"
else
  fail "valkey_barrier, Valkey already current: exit $rc"$'\n'"$(show "$work/v-current" "$FAKE_STATE/calls")"
fi
barrier_run "$work/v-later" valkey_barrier stale-valkey=2
if [ "$rc" = 0 ] && [ "$(grep -c . "$work/v-later.sleeps")" = 2 ]; then
  ok "valkey_barrier: Valkey on the previous ACL file for two reads (Reloader restarting it) is waited for, then it passes"
else
  fail "valkey_barrier, Valkey restarted meanwhile: exit $rc"$'\n'"$(show "$work/v-later")"
fi
barrier_run "$work/v-never" valkey_barrier stale-valkey=never
if [ "$rc" != 0 ] &&
  grep -qF "FAIL  Deployment svp-data/valkey refuses a user's password of .env 300s after Secret valkey-acl changed: Reloader did not restart it" "$work/v-never" &&
  [ "$(awk '{ s += $1 } END { print s }' "$work/v-never.sleeps")" -ge 290 ] && [ "$(awk '{ s += $1 } END { print s }' "$work/v-never.sleeps")" -le 302 ]; then
  ok "valkey_barrier: a Valkey that never takes the passwords of .env fails after 300 s naming valkey-acl and Reloader"
else
  fail "valkey_barrier, Valkey never restarted: exit $rc"$'\n'"$(show "$work/v-never")"
fi
barrier_run "$work/v-none" valkey_barrier deployments=
if [ "$rc" = 0 ] && ! grep -q ' exec ' "$FAKE_STATE/calls" && [ ! -s "$work/v-none" ]; then
  ok "valkey_barrier: no Deployment valkey (Valkey managed, or not installed yet): nothing to wait for"
else
  fail "valkey_barrier without Deployment valkey: exit $rc"$'\n'"$(show "$work/v-none" "$FAKE_STATE/calls")"
fi
no_leak "the barriers" "$work/b-current" "$work/b-later" "$work/b-never" "$work/b-error" "$work/v-current" "$work/v-later" \
  "$work/v-never" "$FAKE_STATE/calls"
keep_calls

# --- 9. install.sh: the order of its helmfile runs around secrets.sh, and the drill traffic of a canary. Sourced from
# the copy, whose secrets.sh and drills/traffic.sh are fakes that log their calls.
cat >"$fake/deploy/k8s/secrets.sh" <<'EOF'
#!/usr/bin/env bash
echo "secrets.sh" >>"$FAKE_STATE/calls"
EOF
cat >"$fake/deploy/k8s/drills/traffic.sh" <<'EOF'
#!/usr/bin/env bash
# status: "PID LOG" of the running traffic (state file traffic); start makes ours (pid 4242); stop ends it.
s=$FAKE_STATE
echo "traffic $*" >>"$s/calls"
case $1 in
  status) [ -f "$s/traffic" ] && cat "$s/traffic" ;;
  start) echo "4242 .k8s/drills/traffic-fake.log" >"$s/traffic" ;;
  stop) rm -f "$s/traffic" ;;
esac
EOF
chmod 755 "$fake/deploy/k8s/secrets.sh" "$fake/deploy/k8s/drills/traffic.sh"
rollout_render='---
# Source: svp-service/templates/service.yaml
kind: Service
---
# Source: svp-service/templates/deployment.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: gateway
spec:
  template:
    spec:
      image: k3d-svp-registry:5111/svp/gateway:dev-0123456789ab'
# install_run OUT CODE: CODE after sourcing install.sh of the copy with the fakes; exit status in $rc.
install_run() {
  local out=$1
  rc=0
  (
    PATH=$bin:$PATH
    SVP_GITOPS_DIR=$gitops
    # shellcheck source=deploy/k8s/install.sh
    . "$fake/deploy/k8s/install.sh"
    components=$gitops/argocd/apps/components.json
    eval "$2"
  ) >"$out" 2>&1 || rc=$?
}
# Rollout STATE: Rollouts gateway and web exist, Healthy; gateway's coming render is the one helm keeps.
rollouts() {
  for r in gateway web; do
    set_state "rollout-$r"
    set_state "phase-$r" Healthy
    printf '%s\n' "$rollout_render" | sed "s/gateway/$r/g" >"$FAKE_STATE/render-$r"
    cp "$FAKE_STATE/render-$r" "$FAKE_STATE/manifest-$r"
  done
}

# A new cluster: the later waves install the servers and Reloader; once they are in, the cluster must be ready for a
# change of credentials: every workload naming its Secrets, Reloader allowed to patch each kind of them, the Rollouts
# included (rbac: its ServiceAccount may not, as when its chart was rendered before their API existed).
for c in ready rbac; do
  new_state svp-data svp svp-obs keda
  printf 's3\nkafka\n' >"$FAKE_STATE/next-statefulsets"
  printf 'svp-ops\nvalkey\n' >"$FAKE_STATE/next-deployments"
  set_state next-reloader 1
  later_render >"$FAKE_STATE/render-later"
  workload next-live svp-data statefulsets.apps s3 s3-root
  workload next-live svp-data deployments.apps valkey valkey-acl
  workload next-live svp-data deployments.apps svp-ops svp-ops template
  workload next-live svp deployments.apps user-service user-service-env,sentry
  workload next-live svp rollouts.argoproj.io web web-env,sentry
  [ "$c" = ready ] || set_state cannot 'svp rollouts.argoproj.io'
  install_run "$work/i-new.out" install_releases
  order=$(grep -E '^(helmfile .* sync |secrets.sh)' "$FAKE_STATE/calls" | sed -E 's/^helmfile .* sync /sync /; s/ --concurrency 1$//' | paste -sd ';' -)
  checked=$(last_line '^kubectl .* -n svp auth can-i patch rollouts.argoproj.io ')
  if [ "$order" != "sync -l wave=0 -l wave=1;secrets.sh;sync -l wave!=0,wave!=1" ] || grep -q '^traffic start' "$FAKE_STATE/calls" ||
    ! before "$(last_line '^helmfile .* sync -l wave!=0,wave!=1 ')" "$checked"; then
    fail "install.sh on a new cluster ($c): exit $rc, order '$order'"$'\n'"$(show "$work/i-new.out" "$FAKE_STATE/calls")"
  elif [ "$c" = ready ] && [ "$rc" = 0 ] &&
    grep -qxF 'ok    Reloader runs and may restart each workload that opts in, each naming the Secrets its chart does' "$work/i-new.out"; then
    ok "install.sh on a new cluster: helmfile of waves 0 and 1, secrets.sh, helmfile of the later waves (no Rollout yet, no traffic), then Reloader may restart each workload that opts in"
  elif [ "$c" = rbac ] && [ "$rc" = 1 ] &&
    grep -qxF 'FAIL  every release installed, but cluster svp is not ready for a change of credentials: Reloader (ServiceAccount reloader/reloader) may not patch rollouts.argoproj.io in namespace svp; run make k8s-up again' "$work/i-new.out"; then
    ok "install.sh on a new cluster whose Reloader may not patch the Rollouts: fails once every release is in, naming it"
  else
    fail "install.sh on a new cluster ($c): exit $rc"$'\n'"$(show "$work/i-new.out" "$FAKE_STATE/calls")"
  fi
  keep_calls
done

# A cluster made before Reloader whose gateway gets a new image (a canary ahead): the first run of the later waves
# upgrades the gateway with the Secrets as they are, so drill traffic runs around it; the second finds the templates
# that run left, Healthy, and starts none. A first run that fails stops its traffic, and secrets.sh does not run.
for c in 0 1; do
  new_state svp-data svp svp-obs keda
  printf 's3\nkafka\n' >"$FAKE_STATE/statefulsets"
  set_state next-reloader 1
  rollouts
  printf '%s\n' "$rollout_render" | sed 's/dev-0123456789ab/dev-ba9876543210/' >"$FAKE_STATE/render-gateway"
  [ "$c" = 0 ] || set_state helmfile-fail 'wave!=0'
  install_run "$work/i-old.out" install_releases
  order=$(grep -E '^(helmfile .* sync |secrets.sh$|traffic (start|stop)$)' "$FAKE_STATE/calls" |
    sed -E 's/^helmfile .* sync /sync /; s/ --concurrency 1$//' | paste -sd ';' -)
  first="sync -l wave=0 -l wave=1;traffic start;sync -l wave!=0,wave!=1;traffic stop"
  if [ "$c" = 0 ]; then
    if [ "$rc" = 0 ] && [ "$order" = "$first;secrets.sh;sync -l wave!=0,wave!=1" ] &&
      grep -q "^note  cluster svp is not ready for a change of credentials: it runs the project's workloads but no Reloader" "$work/i-old.out"; then
      ok "install.sh on a cluster made before Reloader, a new gateway: the later waves first with the Secrets as they are (Reloader and every annotation) and drill traffic around them, then secrets.sh, then the later waves without traffic (nothing left to canary)"
    else
      fail "install.sh on a cluster made before Reloader: exit $rc, order '$order'"$'\n'"$(show "$work/i-old.out" "$FAKE_STATE/calls")"
    fi
  elif [ "$rc" = 1 ] && [ "$order" = "$first" ] && [ ! -f "$FAKE_STATE/traffic" ] &&
    grep -qxF 'FAIL  helmfile sync of waves 2 and later, with the Secrets as they are (the release above)' "$work/i-old.out"; then
    ok "install.sh on a cluster made before Reloader, its first run of the later waves fails: drill traffic stopped, secrets.sh not run, a failure naming that run"
  else
    fail "install.sh on a cluster made before Reloader, first run of the later waves fails: exit $rc, order '$order'"$'\n'"$(show "$work/i-old.out" "$FAKE_STATE/calls")"
  fi
  keep_calls
done

# A cluster whose Reloader runs but whose s3 does not name its Secret yet: a run of the later waves that stopped after
# release reloader and before svp-data. The later waves go first again, with the Secrets as they are, then secrets.sh,
# then the later waves; the end finds every workload ready.
new_state svp-data svp svp-obs keda
running_cluster
workload live svp-data statefulsets.apps s3
workload next-live svp-data statefulsets.apps s3 s3-root
install_run "$work/i-half.out" install_releases
order=$(grep -E '^(helmfile .* sync |secrets.sh$)' "$FAKE_STATE/calls" | sed -E 's/^helmfile .* sync /sync /; s/ --concurrency 1$//' | paste -sd ';' -)
if [ "$rc" = 0 ] && [ "$order" = "sync -l wave=0 -l wave=1;sync -l wave!=0,wave!=1;secrets.sh;sync -l wave!=0,wave!=1" ] &&
  grep -qF "note  cluster svp is not ready for a change of credentials: StatefulSet svp-data/s3 names no Secret in secret.reloader.stakater.com/reload, its chart s3-root. Every later wave first, with the Secrets as they are" "$work/i-half.out" &&
  grep -qxF 'ok    Reloader runs and may restart each workload that opts in, each naming the Secrets its chart does' "$work/i-half.out"; then
  ok "install.sh on a cluster whose Reloader runs but whose s3 does not opt in yet (a run stopped half way): the later waves first with the Secrets as they are, then secrets.sh, then the later waves"
else
  fail "install.sh on a cluster whose s3 does not opt in yet: exit $rc, order '$order'"$'\n'"$(show "$work/i-half.out" "$FAKE_STATE/calls")"
fi
keep_calls

# canary_ahead over the Rollout's phase and whether its render changes.
for c in "Healthy same 1" "Paused same 0" "Degraded same 0" "Healthy changed 0"; do
  set -- $c
  new_state svp
  rollouts
  set_state phase-gateway "$1"
  [ "$2" = same ] || printf '%s\n' "$rollout_render" | sed 's/dev-0123456789ab/dev-ba9876543210/' >"$FAKE_STATE/render-gateway"
  install_run "$work/canary.out" 'canary_ahead svp gateway'
  if [ "$rc" = "$3" ]; then
    if [ "$3" = 1 ]; then ok "canary_ahead: template $2, Rollout $1: no canary ahead, no traffic"; else ok "canary_ahead: template $2, Rollout $1: a canary ahead"; fi
  else
    fail "canary_ahead: template $2, Rollout $1: exit $rc, want $3"$'\n'"$(show "$work/canary.out" "$FAKE_STATE/calls")"
  fi
  keep_calls
done

# The traffic around the later waves: started before them, stopped after them, even when they fail; traffic already
# running is used and left running.
for c in "0 own" "1 own" "0 running"; do
  set -- $c
  new_state svp-data svp svp-obs keda
  set_state reloader 1
  rollouts
  set_state phase-web Paused
  [ "$2" = own ] || set_state traffic "777 .k8s/drills/traffic-earlier.log"
  [ "$1" = 0 ] || set_state helmfile-fail 'wave!=0'
  install_run "$work/traffic.out" install_releases
  start=$(line '^traffic start$')
  later_waves=$(last_line '^helmfile .* sync -l wave!=0,wave!=1 ')
  stop=$(line '^traffic stop$')
  if [ "$2" = own ]; then
    if [ "$1" = 0 ]; then want=0; else want=1; fi
    if [ "$rc" = "$want" ] && before "$(line '^secrets.sh$')" "$start" && before "$start" "$later_waves" && before "$later_waves" "$stop"; then
      ok "install.sh, a canary of web ahead, later waves exit $1: drill traffic started after secrets.sh and before them, stopped after them"
    else
      fail "install.sh, a canary ahead, later waves exit $1: exit $rc, start $start, later waves $later_waves, stop $stop"$'\n'"$(show "$work/traffic.out" "$FAKE_STATE/calls")"
    fi
  elif [ "$rc" = 0 ] && [ -z "$start" ] && [ -z "$stop" ] &&
    grep -q '^ok    drill traffic already running (pid 777); used for the canary of web and left running' "$work/traffic.out"; then
    ok "install.sh, a canary ahead and drill traffic already running: used, neither started nor stopped"
  else
    fail "install.sh, a canary ahead, traffic already running: exit $rc, start $start, stop $stop"$'\n'"$(show "$work/traffic.out" "$FAKE_STATE/calls")"
  fi
  keep_calls
done

# --- 10. install.sh's hooks around a release whose helm upgrade failed on its migrate Job: presync starts the watcher,
# postsync (helmfile passes failed) stops it, prints the log of its last failed attempt and fails naming the release.
# Both hooks are children of one process, as of helmfile (|| exit keeps bash from running the second in its own place,
# under another parent). postsync waits up to 30 s for the watcher's log in svp-helmfile-<that process>, for slow ones.
new_state svp
mkdir -p "$work/tmp"
rc=0
env PATH="$bin:$PATH" TMPDIR="$work/tmp" bash -c '"$1" hook presync video-service svp service "" "" &&
  for i in $(seq 300); do [ ! -s "$TMPDIR/svp-helmfile-$$/video-service.log" ] || break; sleep 0.1; done &&
  "$1" hook postsync video-service svp service "" failed || exit' _ "$fake/deploy/k8s/install.sh" >"$work/hook.out" 2>&1 || rc=$?
if [ "$rc" = 1 ] && grep -qxF '    [svp] migrate: password authentication failed for user "svp_video_migrator"' "$work/hook.out" &&
  grep -qx 'FAIL  install video-service' "$work/hook.out" && [ -z "$(ls -A "$work/tmp")" ] &&
  before "$(line ' logs -l batch.kubernetes.io/controller-uid=uid-new ')" "$(line ' get pods -o json$')"; then
  ok "install.sh's hooks, a release whose migrate Job failed: the log of its last failed attempt (marked as namespace svp), the containers not ready, a failure naming the release; no watcher or file left"
else
  fail "install.sh's hooks, a release whose migrate Job failed: exit $rc"$'\n'"$(show "$work/hook.out" "$FAKE_STATE/calls")"
fi
keep_calls

# --- 11. no command of any case restarts a workload or writes an annotation of Reloader: no kubectl rollout, no patch
# or annotation of a workload, no annotation of Reloader's.
restarts='^kubectl --context [^ ]+( -n [^ ]+)? (rollout |(patch|annotate) (deployments?|statefulsets?|rollouts?)[ ./])|reloader\.stakater\.com'
if ! grep -qE "$restarts" "$all_calls"; then
  ok "no command of any case restarts a workload (kubectl rollout, a patch or annotation of a workload) or writes an annotation of Reloader"
else
  fail "a command restarts a workload or writes Reloader's annotation: $(grep -E "$restarts" "$all_calls" | head -n 3 | paste -sd ';' -)"
fi

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures case(s) of deploy/k8s/rotate-test.sh" >&2
  exit 1
fi
echo "ok    deploy/k8s/rotate-test.sh: every case"
