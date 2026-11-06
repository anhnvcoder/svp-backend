#!/usr/bin/env bash
# Tests for the order of a change of credentials (deploy/k8s/rotate.sh) through deploy/k8s/secrets.sh, on the dev path
# and on the GitOps path's staging with External Secrets, and for the glue of deploy/k8s/install.sh around it (the
# order of its helmfile runs, the drill traffic of a canary). Fake kubectl, helmfile, helm and drill traffic first on
# PATH or in a throwaway copy of this checkout's deploy/, each appending what it was asked to one log in the order of
# the calls; a throwaway git repository stands for the clone of svp-gitops. A fake .env whose secrets are made at run
# time, so no file of the repository holds one. Runs on macOS and Linux: no network, no Docker, no cluster. Cases:
#   - the dev path: servers (Redpanda's password, the Secrets of svp-data) -> barrier -> init (helmfile, release
#     svp-data alone) -> clients (svp, svp-obs, keda), on a running cluster whose workloads name the Secrets their
#     render does (on the workload or its pod template; one not made yet is no gap) and that Reloader may patch; a new
#     cluster (no release svp-data, no server yet) skips the init and still applies the clients;
#   - a run that dies after the servers' step (the init fails: only SVP_PG_BACKUP_S3_SECRET_KEY changed) applies no
#     client Secret; the next run with the same .env runs the init again, then the clients;
#   - the GitOps path: the sources, the ExternalSecrets of svp-data built again, barrier, one sync of Application
#     svp-data (Succeeded), the other ExternalSecrets built again: exactly two groups; a sync that Failed stops it
#     before the clients' group; before Argo CD exists (deploy/k8s/gitops.sh), the sources alone;
#   - a cluster not ready for a change of credentials, refused before anything is written: without Reloader (both
#     paths); with s3 naming no Secret for Reloader (both paths); on the dev path, a client naming fewer Secrets than
#     its chart, and Reloader's ServiceAccount not allowed to patch Rollouts;
#   - the barrier: servers already on the value of .env (no wait), on it after a few reads (Reloader restarting), never
#     on it (fails naming the StatefulSet once 300 s a replica are over), a pod that cannot be read (fails at once);
#   - install.sh: helmfile's waves 0 and 1, secrets.sh, the later waves, then the cluster ready for a change of
#     credentials (a new cluster whose Reloader may not patch the Rollouts fails there); a cluster made before
#     Reloader, whose gateway gets a new image, gets the later waves once before secrets.sh with drill traffic around
#     that run (none around the second, whose templates the first left Healthy), and when that run fails, the traffic
#     stops and secrets.sh does not run; a cluster whose Reloader runs but whose s3 does not opt in yet (a run stopped
#     half way) gets the later waves once before secrets.sh too; canary_ahead (an unchanged template on a Healthy
#     Rollout: no canary; unchanged but paused or aborted, or a changed template: a canary ahead); drill traffic
#     started before the later waves and stopped after them, a failure included, and traffic already running left
#     running;
#   - install.sh's hooks on a release of chart svp-service whose helm upgrade failed: the log of the migrate Job's last
#     failed attempt, copied while it ran and marked as a log line of namespace svp, then a failure naming the release;
#   - no command of any case restarts a workload (kubectl rollout, a patch or an annotation of a Deployment, StatefulSet
#     or Rollout) or writes an annotation of Reloader, and no output or argument holds a secret value or its base64.
# The services' pods and their restarts are checked by the drill reloader on a real cluster (make drill-k8s-reloader).
#
# Usage, from anywhere: deploy/k8s/rotate-test.sh
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

# --- the fakes. FAKE_STATE is the folder of their log (calls) and of the state of the fake cluster:
#   namespaces        the namespaces that exist, one a line
#   statefulsets      the StatefulSets of svp-data (s3, redpanda), one a line; replicas-<name> their replicas (1)
#   stale-<pod>       how many compares of <pod> still find another value than .env (never: every one)
#   pod-error         every read of a pod fails as an unavailable API server would
#   reloader          the available replicas of Deployment reloader/reloader (missing: no such Deployment)
#   render-later      what helmfile template of waves 2 and later prints (the workloads that opt in to Reloader)
#   live-<namespace>-<resource>-<name>
#                     the JSON of workload <name> (resource deployments.apps, statefulsets.apps or
#                     rollouts.argoproj.io): it exists, with its annotations
#   cannot            "<namespace> <resource>" a line: what Reloader's ServiceAccount may not patch
#   next-<file>       moved over <file> by a helmfile sync of the later waves that succeeds (what it installs)
#   release           Helm release svp-data is installed
#   eso, argo         the CRD of ExternalSecrets, of Argo CD's Applications exists; argo-app: Application svp-data
#   argo-phase        the phase of its operation (default Succeeded)
#   helmfile-fail     a helmfile sync whose arguments hold this text fails
#   rollout-<name>, phase-<name>, render-<name>, manifest-<name>
#                     Rollout svp/<name> exists, its status.phase, what helmfile template and helm get manifest print
#                     (a helmfile sync of the later waves that succeeds copies each render-<name> to manifest-<name>)
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
    awk '$1 == "name:" { n = $2 } $1 == "namespace:" { print "applied " $2 "/" n }' >>"$s/calls" ;;
  "create -f -") cat >/dev/null ;;
  "get secret glitchtip-runtime" | "get pvc datadir-redpanda-0") exit 1 ;;
  "get nodes -o jsonpath="*) printf arm64 ;;
  "get clusters.postgresql.cnpg.io svp-pg --ignore-not-found -o name" | "get backups.postgresql.cnpg.io -o jsonpath="*) ;;
  "get statefulsets -o name") sed 's|^|statefulset.apps/|' "$s/statefulsets" 2>/dev/null || true ;;
  "get deployment reloader --ignore-not-found -o jsonpath={.status.availableReplicas}") cat "$s/reloader" 2>/dev/null || true ;;
  "get deployment reloader -o jsonpath={.spec.template.spec.serviceAccountName}") printf reloader ;;
  "get deployments.apps "*" --ignore-not-found -o json" | "get statefulsets.apps "*" --ignore-not-found -o json" | \
    "get rollouts.argoproj.io "*" --ignore-not-found -o json")
    set -- $args
    cat "$s/live-$ns-$2-$3" 2>/dev/null || true ;;
  "get statefulsets.apps "*" -o json")
    set -- $args
    cat "$s/live-$ns-statefulsets.apps-$3" 2>/dev/null || { echo "Error from server (NotFound): statefulsets.apps \"$3\" not found" >&2; exit 1; } ;;
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
      *RPK_PASS*) want=$(sed -n 's/^SVP_KAFKA_ADMIN_PASSWORD=//p' "$FAKE_ENV") ;;
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
  JWT_SIGNING_KID JWT_SIGNING_KEY JWT_VERIFY_KEYS SVP_GRAFANA_ADMIN_PASSWORD GLITCHTIP_SECRET_KEY
  GLITCHTIP_ADMIN_PASSWORD)
: >"$work/secrets"
{
  for n in "${names[@]}"; do
    v="fake-$(openssl rand -hex 12)"
    echo "$v" >>"$work/secrets"
    echo "$n=$v"
  done
  echo "GLITCHTIP_ADMIN_EMAIL=admin@svp.local"
  v=$(openssl rand -base64 32)
  echo "$v" >>"$work/secrets"
  echo "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=$v"
} >"$work/env"
FAKE_ENV=$fake/.env
export FAKE_ENV

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
  printf '%s\n' "$@" >"$FAKE_STATE/namespaces"
  cp "$work/env" "$fake/.env"
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
# The workloads of a running cluster that opt in, as the later waves render them: the servers (redpanda on its pod
# template), a client, and a Rollout not made yet (none is a gap).
later_render() {
  opt_in_doc StatefulSet svp-data s3 s3-root
  opt_in_doc StatefulSet svp-data redpanda redpanda-bootstrap,redpanda-superusers template
  opt_in_doc Deployment svp user-service user-service-env,sentry
  opt_in_doc Rollout svp web web-env,sentry
  printf -- '---\nkind: ConfigMap\nmetadata:\n  name: notes\n  namespace: svp\n  annotations:\n    secret.reloader.stakater.com/reload: not-a-workload\n'
}
# running_cluster: s3 and redpanda run with the value of .env, Reloader is available, release svp-data installed, and
# every workload that exists names the Secrets its render does.
running_cluster() {
  printf 's3\nredpanda\n' >"$FAKE_STATE/statefulsets"
  set_state reloader 1
  set_state release
  later_render >"$FAKE_STATE/render-later"
  workload live svp-data statefulsets.apps s3 s3-root
  workload live svp-data statefulsets.apps redpanda redpanda-bootstrap,redpanda-superusers template
  workload live svp deployments.apps user-service user-service-env,sentry
}
# secrets_run OUT: deploy/k8s/secrets.sh of the copy with the fakes, at most 120 s; exit status in $rc.
secrets_run() {
  rc=0
  env PATH="$bin:$PATH" SVP_GITOPS_DIR="$gitops" perl -e 'alarm 120; exec @ARGV' "$fake/deploy/k8s/secrets.sh" \
    >"$1" 2>&1 || rc=$?
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
# previous root password), Redpanda already on the value of .env.
new_state svp-data svp svp-obs keda
running_cluster
set_state stale-s3-0 2
secrets_run "$work/dev.out"
server=$(line '^kubectl .* get pvc datadir-redpanda-0$')
data=$(last_line '^applied svp-data/')
s3=$(last_line '^kubectl .* exec -i s3-0 -c s3 ')
broker=$(last_line '^kubectl .* exec -i redpanda-0 -c redpanda ')
init=$(line '^helmfile .* sync -l name=svp-data --concurrency 1$')
client=$(line '^applied (svp|svp-obs|keda)/')
guard=$(last_line '^kubectl .* -n svp auth can-i patch rollouts.argoproj.io --as system:serviceaccount:reloader:reloader$')
if [ "$rc" = 0 ] && before "$(line '^helmfile .* template -l wave!=0,wave!=1 --skip-deps$')" "$guard" && before "$guard" "$server" &&
  before "$server" "$data" && before "$data" "$s3" && before "$s3" "$broker" && before "$broker" "$init" &&
  before "$init" "$client" && [ "$(grep -c '^kubectl .* exec -i s3-0 ' "$FAKE_STATE/calls")" = 3 ] &&
  [ "$(grep -c '^helmfile .* sync ' "$FAKE_STATE/calls")" = 1 ] &&
  [ "$(grep -c ' auth can-i patch ' "$FAKE_STATE/calls")" = 3 ] &&
  grep -qE "^helmfile --kube-context k3d-svp --file $fake/deploy/k8s/helmfile.yaml.gotmpl --state-values-set gitopsDir=[^ ]*/gitops --state-values-set nodeArch=arm64 sync " "$FAKE_STATE/calls" &&
  grep -qx 'applied keda/keda-kafka' "$FAKE_STATE/calls" && grep -qx 'applied svp-obs/grafana-admin' "$FAKE_STATE/calls" &&
  grep -q '^ok    StatefulSet s3: each of its 1 pod(s) runs with the RUSTFS_SECRET_KEY of .env and is Ready' "$work/dev.out" &&
  grep -q '^ok    Reloader restarts each workload whose Secret changed' "$work/dev.out"; then
  ok "secrets.sh, dev path: Reloader may restart each workload the later waves render with its annotation (on it or its pod template; one not made yet is no gap), then Redpanda's password, the Secrets of svp-data, the barrier (s3 until it runs the value of .env, then redpanda), helmfile sync of release svp-data alone, then the clients' Secrets"
else
  fail "secrets.sh, dev path: exit $rc; guard $guard, server $server, data $data, s3 $s3, broker $broker, init $init, client $client"$'\n'"$(show "$work/dev.out" "$FAKE_STATE/calls")"
fi
no_leak "secrets.sh, dev path" "$work/dev.out" "$FAKE_STATE/calls"
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
broker=$(last_line '^kubectl .* exec -i redpanda-0 ')
patch=$(line '^kubectl .* patch applications.argoproj.io/svp-data ')
synced=$(last_line '^kubectl .* get applications.argoproj.io/svp-data -o json$')
if [ "$rc" = 0 ] && [ "$annotated" = "svp-data/pg-superuser svp-data/s3-root svp-obs/grafana-admin svp/user-service-env" ] &&
  before "$sources" "$last_server" && before "$last_server" "$broker" && before "$broker" "$patch" &&
  before "$patch" "$synced" && before "$synced" "$first_client" &&
  grep -q '"operation":{"initiatedBy":{"username":"svp-rotate-' "$FAKE_STATE/calls" &&
  ! grep -qE '^applied (svp|svp-obs|svp-data|keda)/' "$FAKE_STATE/calls" && ! grep -q '^helmfile ' "$FAKE_STATE/calls" &&
  grep -q '^ok    init Jobs of svp-data done (sync of Application svp-data Succeeded)' "$work/gitops.out"; then
  ok "secrets.sh, GitOps path: the sources, the ExternalSecrets of svp-data built again, the barrier, one sync of Application svp-data until it Succeeded, then the other ExternalSecrets: exactly two groups"
else
  fail "secrets.sh, GitOps path: exit $rc; annotated '$annotated', sources $sources, server $last_server, broker $broker, patch $patch, synced $synced, client $first_client"$'\n'"$(show "$work/gitops.out" "$FAKE_STATE/calls")"
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
# before Reloader (no Reloader); or Reloader runs, but s3 does not name its Secret for it yet (a run of make k8s-up
# that stopped before svp-data; on the GitOps path, Argo CD not there yet); on the dev path also a client that names
# fewer Secrets than its chart, and a Reloader whose ServiceAccount may not patch the Rollouts (its chart rendered
# before their API was served).
for c in "dev no-reloader" "gitops no-reloader" "dev s3" "gitops s3" "dev client" "dev rbac"; do
  set -- $c
  if [ "$1" = dev ]; then new_state svp-data svp svp-obs keda; else new_state svp-data svp svp-obs svp-secrets; fi
  case $2 in
    no-reloader)
      printf 'redpanda\n' >"$FAKE_STATE/statefulsets"
      why="runs the project's workloads but no Reloader" ;;
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

# --- 8. rotate_barrier itself, sourced with sleep as a function that moves bash's clock: three brokers.
# barrier_run OUT STATE...: rotate_barrier of redpanda (3 replicas) with the state files given; exit status in $rc,
# the sleeps taken in OUT.sleeps.
barrier_run() {
  local out=$1
  shift
  new_state svp-data
  printf 'redpanda\n' >"$FAKE_STATE/statefulsets"
  set_state replicas-redpanda 3
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
    rotate_barrier redpanda redpanda RPK_PASS "$(sed -n 's/^SVP_KAFKA_ADMIN_PASSWORD=//p' "$FAKE_ENV")"
  ) >"$out" 2>&1 || rc=$?
  touch "$out.sleeps"
}
barrier_run "$work/b-current"
if [ "$rc" = 0 ] && [ ! -s "$work/b-current.sleeps" ] && [ "$(grep -c ' exec -i redpanda-' "$FAKE_STATE/calls")" = 3 ]; then
  ok "rotate_barrier: every broker already on the value of .env: each compared once, no wait"
else
  fail "rotate_barrier, brokers already current: exit $rc, $(grep -c . "$work/b-current.sleeps") sleeps"$'\n'"$(show "$work/b-current")"
fi
barrier_run "$work/b-later" stale-redpanda-2=2 stale-redpanda-1=1
if [ "$rc" = 0 ] && [ "$(grep -c . "$work/b-later.sleeps")" = 3 ] &&
  grep -q '^ok    StatefulSet redpanda: each of its 3 pod(s) runs with the RPK_PASS of .env and is Ready' "$work/b-later"; then
  ok "rotate_barrier: brokers on the previous password for a few reads (Reloader restarting them) are waited for, then it passes"
else
  fail "rotate_barrier, brokers restarted meanwhile: exit $rc, $(grep -c . "$work/b-later.sleeps") sleeps"$'\n'"$(show "$work/b-later")"
fi
barrier_run "$work/b-never" stale-redpanda-0=never
if [ "$rc" != 0 ] &&
  grep -qF 'FAIL  StatefulSet svp-data/redpanda: pod redpanda-0 runs with another RPK_PASS than .env 900s after its Secret changed: Reloader did not restart it' "$work/b-never" &&
  [ "$(awk '{ s += $1 } END { print s }' "$work/b-never.sleeps")" -ge 800 ] && [ "$(awk '{ s += $1 } END { print s }' "$work/b-never.sleeps")" -le 902 ]; then
  ok "rotate_barrier: a broker that never runs the value of .env fails naming StatefulSet redpanda and Reloader, once 300 s a replica are over"
else
  fail "rotate_barrier, a broker never restarted: exit $rc"$'\n'"$(show "$work/b-never")"
fi
barrier_run "$work/b-error" pod-error=
if [ "$rc" != 0 ] && grep -qF 'FAIL  read pod svp-data/redpanda-0 (above), to know whether it runs with the value of .env; run make k8s-secrets again' "$work/b-error" &&
  [ ! -s "$work/b-error.sleeps" ]; then
  ok "rotate_barrier: a pod that cannot be read stops it at once, naming the pod"
else
  fail "rotate_barrier, a pod that cannot be read: exit $rc"$'\n'"$(show "$work/b-error")"
fi
no_leak "rotate_barrier" "$work/b-current" "$work/b-later" "$work/b-never" "$work/b-error" "$FAKE_STATE/calls"
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
  printf 's3\nredpanda\n' >"$FAKE_STATE/next-statefulsets"
  set_state next-reloader 1
  later_render >"$FAKE_STATE/render-later"
  workload next-live svp-data statefulsets.apps s3 s3-root
  workload next-live svp-data statefulsets.apps redpanda redpanda-bootstrap,redpanda-superusers template
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
  printf 's3\nredpanda\n' >"$FAKE_STATE/statefulsets"
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

# --- 10. install.sh's hooks around a release whose helm upgrade failed on its migrate Job: presync starts the watcher
# of the Job, postsync (helmfile passes failed) stops it, prints the log of its last failed attempt and fails naming the
# release. Both hooks are children of one process, as of helmfile (|| exit keeps bash from running the second in its
# own place, which would give it another parent). postsync runs once the watcher has copied the log into the hooks'
# folder (svp-helmfile-<that process>), whenever that is, or after 30 s, so a slow machine does not fail the case.
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
