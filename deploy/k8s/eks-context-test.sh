#!/usr/bin/env bash
# Tests for the guard of the cloud context and the scripts of the eks-* targets of deploy/k8s/k8s.mk that reach an EKS
# cluster, without a cluster, a network or AWS: fake kubectl, k3d, docker, aws, curl, ffmpeg and sleep first on PATH
# record their arguments, and a fake helm runs the real one for `helm template` and records every other call.

# Everything is a fixture in a temporary directory: a copy of this checkout's deploy/ with a fake .env, whose secrets
# are made at run time, so no file of the repository holds one. No output of a script may hold a secret value or its
# base64.
# The entries of AWS Secrets Manager have their own test, deploy/k8s/aws-secrets-test.sh.

# Usage, from anywhere: deploy/k8s/eks-context-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
for tool in helm jq openssl perl; do
  command -v "$tool" >/dev/null || {
    echo "FAIL  $tool is not installed" >&2
    exit 1
  }
done
real_helm=$(command -v helm)

# --- the fake tools. FAKE_STATE is the folder of their logs and answers.
bin=$work/bin
mkdir -p "$bin"
cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
# One line per call: an argument of several lines (the code of a python shell) on one.
printf '%s' "$*" | tr '\n' ' ' >>"$s/kubectl.log"
echo >>"$s/kubectl.log"
[ "${1:-}" = --context ] || { echo "fake kubectl: --context is not the first argument" >&2; exit 2; }
shift 2
[ "${1:-}" != -n ] || shift 2
args="$*"
case $args in
  "get --raw /readyz") ;;
  "get namespace "*) grep -qx "${args#get namespace }" "$s/namespaces" ;;
  "apply "* | "create -f -") { echo "---"; cat; echo; } >>"$s/applied.yaml" ;;
  "get pvc "* | "get secret glitchtip-runtime") exit 1 ;;
  # A cluster before Argo CD (deploy/k8s/gitops.sh): no workload, no CRD of External Secrets or Argo CD yet.
  "get statefulsets,deployments -o name" | "get statefulset "*" --ignore-not-found -o jsonpath={.spec.replicas}") ;;
  "get deployment "*" --ignore-not-found -o name") ;;
  "get crd "*" --ignore-not-found -o name") ;;
  "get pod "*) ;;
  # The operations CLI of svp-data: svp-valkey of Deployment svp-ops, logged in as svp-ops.
  "exec -i deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 10 --scan --pattern svp:gw:rl:register:*") printf 'svp:gw:rl:register:a\nsvp:gw:rl:register:b\n' ;;
  "exec -i deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 10 DEL svp:gw:rl:register:"[ab]) echo 1 ;;
  *) echo "fake kubectl: unexpected call: $args" >&2; exit 3 ;;
esac
EOF
cat >"$bin/helm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$FAKE_STATE/helm.log"
for a; do [ "\$a" != template ] || exec "$real_helm" "\$@"; done
EOF
for tool in k3d docker aws; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$FAKE_STATE/%s.log"\nexit 1\n' "$tool" >"$bin/$tool"
done
# sleep returns at once: the waits of the scripts poll fakes that answer the same every time.
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/sleep"
# ffmpeg: the last argument is the output file.
printf '#!/usr/bin/env bash\nfor a; do :; done\nprintf fake-video >"$a"\n' >"$bin/ffmpeg"
chmod 755 "$bin"/*

# new_state [NAMESPACE...]: an empty folder of logs; the namespaces that exist in the fake cluster.
new_state() {
  FAKE_STATE=$(mktemp -d "$work/state.XXXXXX")
  export FAKE_STATE
  : >"$FAKE_STATE/kubectl.log"
  : >"$FAKE_STATE/helm.log"
  : >"$FAKE_STATE/applied.yaml"
  : >"$FAKE_STATE/aws.log"
  printf '%s\n' "$@" >"$FAKE_STATE/namespaces"
}

# --- the fake secrets.
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
fake=$work/code
mkdir -p "$fake"
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
} >"$fake/.env"
env_pg_password=$(sed -n 's/^SVP_PG_SUPERUSER_PASSWORD=//p' "$fake/.env")
rds_password="rds-$(openssl rand -hex 12)"
echo "$rds_password" >>"$work/secrets"

# leaks FILE: the secrets (or their base64) FILE holds, one line each; nothing when none.
leaks() {
  local v
  while IFS= read -r v; do
    if grep -qF -- "$v" "$1" || grep -qF -- "$(b64 "$v")" "$1"; then echo "${v:0:8}..."; fi
  done <"$work/secrets"
}
# no_leak NAME FILE: a case of its own, that the output FILE of NAME holds no secret.
no_leak() {
  local found
  found=$(leaks "$2")
  if [ -z "$found" ]; then ok "$1: no secret value in the output"; else fail "$1: the output holds secrets: $found"; fi
}
# source_value NAME KEY: the decoded value of KEY of the Secret NAME applied last in $FAKE_STATE/applied.yaml.
source_value() {
  awk -v name="$1" -v key="$2" '/^---/ { n = "" } $1 == "name:" { n = $2 }
    n == name && $1 == key ":" { gsub(/"/, "", $2); print $2 }' "$FAKE_STATE/applied.yaml" | tail -n 1 | base64 -d
}

# --- the throwaway checkout: deploy/ of this one, and a fake local CA of make env.
cp -R "$repo/deploy" "$fake/deploy"
mkdir -p "$fake/.local/ca"
for f in ca.crt server.crt server.key postgres.crt postgres.key; do printf 'fake %s\n' "$f" >"$fake/.local/ca/$f"; done

# no_cluster_call NAME: kubectl was not run, nor helm but for templates, nor k3d, docker or aws.
no_cluster_call() {
  if [ -s "$FAKE_STATE/kubectl.log" ] || grep -vq '^template ' "$FAKE_STATE/helm.log" ||
    [ -s "$FAKE_STATE/k3d.log" ] || [ -s "$FAKE_STATE/docker.log" ] || [ -s "$FAKE_STATE/aws.log" ]; then
    fail "$1: a cluster or AWS was called: $(cat "$FAKE_STATE/kubectl.log" "$FAKE_STATE/helm.log" "$FAKE_STATE/aws.log" | head -n 3 | paste -sd ';' -)"
  else
    ok "$1: no kubectl, helm (but templates), k3d, docker or aws call"
  fi
}
# refused NAME OUT MESSAGE: the run failed with MESSAGE in its output.
refused() {
  if [ "$rc" != 0 ] && grep -qF -- "$3" "$2"; then
    ok "$1: refused ($3)"
  else
    fail "$1: exit $rc, want a failure with '$3':"$'\n'"$(sed 's/^/      /' "$2")"
  fi
}

# --- deploy/k8s/lib.sh: the context.
# lib_run OUT CODE: CODE after sourcing lib.sh of the throwaway checkout, with the fake tools; status in $rc.
lib_run() {
  local out=$1
  shift
  rc=0
  # shellcheck disable=SC2016 # expanded by the inner bash
  env PATH="$bin:$PATH" bash -c '. "$0/deploy/k8s/lib.sh" && eval "$1"' "$fake" "$1" >"$out" 2>&1 || rc=$?
}
for bad in arn:aws:eks:ap-southeast-1:000000000000:cluster/svp-stg k3d-other '' ' svp-stg ' svp-dev; do
  new_state
  SVP_KUBE_CONTEXT=$bad lib_run "$work/out" 'kc get nodes'
  if [ "$rc" != 0 ] && grep -qF "SVP_KUBE_CONTEXT is $(printf '%q' "$bad")" "$work/out" && [ ! -s "$FAKE_STATE/kubectl.log" ]; then
    ok "lib.sh: SVP_KUBE_CONTEXT=$(printf '%q' "$bad") refused as it is sourced, naming it, before kubectl"
  else
    fail "lib.sh: SVP_KUBE_CONTEXT=$(printf '%q' "$bad"): exit $rc, kubectl '$(cat "$FAKE_STATE/kubectl.log")': $(cat "$work/out")"
  fi
done
new_state
(
  unset SVP_KUBE_CONTEXT
  lib_run "$work/out" 'kc get --raw /readyz && hc template x /nonexistent >/dev/null 2>&1; true'
)
if grep -qx -- '--context k3d-svp get --raw /readyz' "$FAKE_STATE/kubectl.log" &&
  grep -q -- '--kube-context k3d-svp' "$FAKE_STATE/helm.log"; then
  ok "lib.sh: SVP_KUBE_CONTEXT unset, kc and hc name k3d-svp"
else
  fail "lib.sh: SVP_KUBE_CONTEXT unset: kubectl '$(cat "$FAKE_STATE/kubectl.log")', helm '$(cat "$FAKE_STATE/helm.log")'"
fi
new_state
SVP_KUBE_CONTEXT=svp-stg lib_run "$work/out" 'kube_cloud_ok=1; kc get --raw /readyz && hc template x /nonexistent >/dev/null 2>&1; true'
if grep -qx -- '--context svp-stg get --raw /readyz' "$FAKE_STATE/kubectl.log" &&
  grep -q -- '--kube-context svp-stg' "$FAKE_STATE/helm.log"; then
  ok "lib.sh: SVP_KUBE_CONTEXT=svp-stg in a script written for it, kc and hc name svp-stg"
else
  fail "lib.sh: SVP_KUBE_CONTEXT=svp-stg: kubectl '$(cat "$FAKE_STATE/kubectl.log")', helm '$(cat "$FAKE_STATE/helm.log")'"
fi
new_state
SVP_KUBE_CONTEXT=svp-prd lib_run "$work/out" 'kc get --raw /readyz'
refused "lib.sh: kc on svp-prd in a script not written for a cloud cluster (the dev path, a drill)" "$work/out" \
  "context svp-prd is an EKS cluster, which this script does not run against"
no_cluster_call "lib.sh: kc on svp-prd in a script not written for it"
for fn in ensure_registry ensure_cluster export_ca 'k3d_ cluster list'; do
  new_state
  SVP_KUBE_CONTEXT=svp-stg lib_run "$work/out" "kube_cloud_ok=1; $fn"
  refused "lib.sh: ${fn%% *} on svp-stg" "$work/out" "for the local cluster k3d-svp only, not context svp-stg"
  no_cluster_call "lib.sh: ${fn%% *} on svp-stg"
done

# --- the context of the scripts written for one kind of cluster alone.
# script_run SCRIPT OUT [VAR=VALUE...]: deploy/k8s/SCRIPT of the throwaway checkout with the fake tools; status in $rc.
script_run() {
  local script=$1 out=$2
  shift 2
  rc=0
  env "$@" PATH="$bin:$PATH" perl -e 'alarm 60; exec @ARGV' "$fake/deploy/k8s/$script" >"$out" 2>&1 </dev/null || rc=$?
}
for script in gitops.sh secrets.sh; do
  new_state svp-data svp svp-obs svp-secrets
  script_run "$script" "$work/out" SVP_KUBE_CONTEXT=svp-stg SVP_RDS_MASTER_PASSWORD="$rds_password"
  refused "$script on svp-stg (the local cluster alone)" "$work/out" "deploy/k8s/$script ("
  grep -qF "is for the local cluster k3d-svp only, not context svp-stg" "$work/out" ||
    fail "$script on svp-stg: refused for another reason: $(cat "$work/out")"
  no_cluster_call "$script on svp-stg"
done
for ctx in unset k3d-svp; do
  new_state
  if [ "$ctx" = unset ]; then
    script_run aws-secrets.sh "$work/out" -u SVP_KUBE_CONTEXT AWS_PROFILE=anhnv-stg SVP_RDS_MASTER_PASSWORD="$rds_password"
  else
    script_run aws-secrets.sh "$work/out" SVP_KUBE_CONTEXT=k3d-svp AWS_PROFILE=anhnv-stg SVP_RDS_MASTER_PASSWORD="$rds_password"
  fi
  refused "aws-secrets.sh with SVP_KUBE_CONTEXT $ctx (an EKS cluster alone)" "$work/out" "context k3d-svp is the local cluster"
  no_cluster_call "aws-secrets.sh with SVP_KUBE_CONTEXT $ctx"
done
new_state
script_run aws-secrets.sh "$work/out" SVP_KUBE_CONTEXT=arn:aws:eks:ap-southeast-1:000000000000:cluster/svp-stg AWS_PROFILE=anhnv-stg
refused "aws-secrets.sh with an ARN for context" "$work/out" "SVP_KUBE_CONTEXT is arn:aws:eks"
no_cluster_call "aws-secrets.sh with an ARN for context"

# --- deploy/k8s/secrets.sh on k3d-svp.
# secrets_run OUT [VAR=VALUE...]: deploy/k8s/secrets.sh of the throwaway checkout; status in $rc.
secrets_run() {
  local out=$1
  shift
  rc=0
  env PATH="$bin:$PATH" "$@" "$fake/deploy/k8s/secrets.sh" >"$out" 2>&1 || rc=$?
}
new_state svp-data svp svp-obs svp-secrets
secrets_run "$work/k3d.out" SVP_RDS_MASTER_PASSWORD="$rds_password"
if [ "$rc" = 0 ] && grep -qx 'ok    source Secrets of svp-secrets applied from .env: pg-superuser, pg-roles, s3-root, s3-users, kafka-admin, kafka-users, valkey-users, local-ca, local-tls, jwt-signing, jwt-verify, web, obs' "$work/k3d.out" &&
  [ "$(source_value pg-superuser SVP_PG_SUPERUSER_PASSWORD)" = "$env_pg_password" ] &&
  [ -z "$(grep -v '^--context k3d-svp ' "$FAKE_STATE/kubectl.log")" ]; then
  ok "secrets.sh on k3d-svp as before: pg-superuser from .env (SVP_RDS_MASTER_PASSWORD ignored), the store's sources, context k3d-svp"
else
  fail "secrets.sh on k3d-svp: exit $rc: $(cat "$work/k3d.out")"
fi
no_leak "secrets.sh on k3d-svp" "$work/k3d.out"

# --- reset_register_limit of deploy/compose/lib.sh.
# rl_run OUT [VAR=VALUE...]: sources deploy/compose/lib.sh of the throwaway checkout; status in $rc.
rl_run() {
  local out=$1
  shift
  rc=0
  env PATH="$bin:$PATH" "$@" bash -c '. "$0/deploy/compose/lib.sh"' "$fake" >"$out" 2>&1 || rc=$?
}
new_state
rl_run "$work/out" SVP_STACK=eks SVP_KUBE_CONTEXT=svp-stg
if [ "$rc" = 0 ] && grep -q '2 keys deleted in Valkey db 10 (eks)' "$work/out" &&
  [ "$(grep -c '^--context svp-stg -n svp-data exec -i deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 10 ' "$FAKE_STATE/kubectl.log")" = 3 ] &&
  [ "$(grep -c '' "$FAKE_STATE/kubectl.log")" = 3 ]; then
  ok "compose/lib.sh SVP_STACK=eks: SCAN and DEL through svp-valkey of Deployment svp-ops (logged in as svp-ops) in context svp-stg, nothing else"
else
  fail "compose/lib.sh SVP_STACK=eks: exit $rc, kubectl '$(cat "$FAKE_STATE/kubectl.log")': $(cat "$work/out")"
fi
for bad in k3d-svp '' svp-dev arn:aws:eks:ap-southeast-1:000000000000:cluster/svp-stg; do
  new_state
  rl_run "$work/out" SVP_STACK=eks SVP_KUBE_CONTEXT="$bad"
  refused "compose/lib.sh SVP_STACK=eks, SVP_KUBE_CONTEXT='$bad'" "$work/out" "got '$bad'"
  no_cluster_call "compose/lib.sh SVP_STACK=eks, SVP_KUBE_CONTEXT='$bad'"
done
new_state
rl_run "$work/out" SVP_STACK=k3d SVP_KUBE_CONTEXT=svp-stg
if [ "$rc" = 0 ] && [ -z "$(grep -v '^--context k3d-svp -n svp-data exec -i deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 10 ' "$FAKE_STATE/kubectl.log")" ] &&
  [ -s "$FAKE_STATE/kubectl.log" ]; then
  ok "compose/lib.sh SVP_STACK=k3d: still context k3d-svp, through svp-valkey of Deployment svp-ops"
else
  fail "compose/lib.sh SVP_STACK=k3d: kubectl '$(cat "$FAKE_STATE/kubectl.log")'"
fi

# --- deploy/k8s/eks-seed.sh against a fake API. FAKE_EXPLORE is how many items explore lists.
api_bin=$work/api-bin
mkdir -p "$api_bin"
cat >"$api_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/stdout fmt= method=GET url= cfg=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    -w) fmt=$2; shift ;;
    -X) method=$2; shift ;;
    -K) cfg=$2; method=POST; shift ;;
    -H | --data-binary | --max-time) shift ;;
    http*) url=$1 ;;
  esac
  shift
done
[ -z "$cfg" ] || url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
printf '%s %s\n' "$method" "$url" >>"$FAKE_STATE/curl.log"
code=200 body=
case "$method $url" in
  "GET "*/readyz) ;;
  "POST "*/auth/register) code=201 body="{\"user_id\":\"$(openssl rand -hex 8)\"}" ;;
  "POST "*/auth/login) body='{"access_token":"fake"}' ;;
  "POST "*/videos/*/complete) code=202 body='{"status":"PROCESSING"}' ;;
  "POST "*/videos) code=201 body="{\"video_id\":\"$(openssl rand -hex 8)\",\"upload_url\":\"https://uploads.stg.svp.example/\",\"form_fields\":{\"key\":\"uploads/x\",\"policy\":\"p\"}}" ;;
  "POST https://uploads.stg.svp.example/") code=204 ;;
  "GET "*/videos/*) body='{"status":"READY"}' ;;
  "GET "*/feed/explore*) body=$(jq -cn --argjson n "$FAKE_EXPLORE" '{items: [range($n) | {video_id: "v\(.)"}]}') ;;
  *) code=404 ;;
esac
printf '%s' "$body" >"$out"
fmt=${fmt//%\{http_code\}/$code}
printf '%s' "${fmt//%\{content_type\}/application/json}"
EOF
chmod 755 "$api_bin/curl"
# seed_run OUT EXPLORE: deploy/k8s/eks-seed.sh on context svp-stg, explore listing EXPLORE videos; status in $rc.
seed_run() {
  rc=0
  env PATH="$bin:$api_bin:$PATH" SVP_STACK=eks SVP_KUBE_CONTEXT=svp-stg FAKE_EXPLORE="$2" \
    perl -e 'alarm 120; exec @ARGV' "$fake/deploy/k8s/eks-seed.sh" https://api.stg.svp.example >"$1" 2>&1 || rc=$?
}
new_state
seed_run "$work/seed.out" 32
other=$(grep -v -e ' https://api\.stg\.svp\.example/' -e '^POST https://uploads\.stg\.svp\.example/$' "$FAKE_STATE/curl.log" || true)
if [ "$rc" = 0 ] && grep -q '32 videos READY' "$work/seed.out" && grep -q 'holds 32 READY videos' "$work/seed.out" &&
  [ "$(grep -c '^POST https://uploads' "$FAKE_STATE/curl.log")" = 32 ] && [ -z "$other" ]; then
  ok "eks-seed.sh: 4 users, 32 videos uploaded, completed and READY, explore 32, every request to https://api.stg.svp.example or the form"
else
  fail "eks-seed.sh: exit $rc, other requests '$other':"$'\n'"$(sed 's/^/      /' "$work/seed.out")"
fi
if [ -z "$(grep -v '^--context svp-stg ' "$FAKE_STATE/kubectl.log")" ] && grep -q 'register rate limit reset' "$work/seed.out"; then
  ok "eks-seed.sh: register rate limit reset in the Valkey of context svp-stg"
else
  fail "eks-seed.sh: kubectl '$(cat "$FAKE_STATE/kubectl.log")'"
fi
new_state
seed_run "$work/out" 29
refused "eks-seed.sh with 29 videos in explore" "$work/out" "GET /feed/explore holds at least 30 READY videos (status 200, 29)"
new_state
rc=0
env PATH="$bin:$api_bin:$PATH" SVP_KUBE_CONTEXT=svp-stg "$fake/deploy/k8s/eks-seed.sh" https://api.stg.svp.example \
  >"$work/out" 2>&1 || rc=$?
refused "eks-seed.sh without SVP_STACK=eks" "$work/out" "SVP_STACK=eks is not set"
no_cluster_call "eks-seed.sh without SVP_STACK=eks"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures case(s) of deploy/k8s/eks-context-test.sh" >&2
  exit 1
fi
echo "ok    deploy/k8s/eks-context-test.sh: every case"
