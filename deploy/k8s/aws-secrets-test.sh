#!/usr/bin/env bash
# Tests for the scripts that write the entries of AWS Secrets Manager of an EKS cluster (deploy/k8s/aws-secrets.sh of
# make eks-secrets, deploy/k8s/glitchtip-init.sh of make eks-glitchtip-init), without AWS, a cluster or a network:
# fake aws and kubectl first on PATH, each appending its arguments to one log in the order of the calls, the fake aws
# keeping a copy of each entry's JSON it was given as file://. helm is the real one, for helm template alone. Everything
# is a fixture in a temporary directory: a copy of this checkout's deploy/ with a fake .env, its secrets made at run
# time, so no file of the repository holds one. Cases:
#   - a first run on svp-stg (entry glitchtip-runtime without a version, no ExternalSecret): every entry of chart
#     svp-cluster's ExternalSecrets for EKS written once, with exactly its keys (pg-superuser from
#     SVP_RDS_MASTER_PASSWORD, the Telegram keys empty, none of the in-cluster object store), glitchtip-runtime with its
#     three keys empty, every aws call with the profile and the region on its command line, the account read first,
#     the files in a folder of mode 700 that is gone after, no kubectl call, no force-sync;
#   - a run again (glitchtip-runtime has a version): glitchtip-runtime not written, Redpanda's password set before the
#     first write, every ExternalSecret built again after the last one;
#   - svp-prd: entries svp/prd/*, the account of SVP_AWS_PRD_ACCOUNT_ID;
#   - stops before any write: AWS_PROFILE unset, another account, SVP_RDS_MASTER_PASSWORD unset, a variable missing
#     in .env, an entry the infrastructure has not made, a run again with the cluster out of reach;
#   - deploy/k8s/glitchtip-init.sh on svp-stg: GlitchTip's DSN and tokens written into entry glitchtip-runtime, then
#     its three ExternalSecrets built again; without AWS_PROFILE it stops before kubectl.
# No log, output or argument may hold a secret value or its base64.
#
# Usage, from anywhere: deploy/k8s/aws-secrets-test.sh
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
for tool in helm jq openssl; do
  command -v "$tool" >/dev/null || {
    echo "FAIL  $tool is not installed" >&2
    exit 1
  }
done

# --- the fake tools. FAKE_STATE is the folder of their log (calls) and answers.
bin=$work/bin
mkdir -p "$bin"
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
printf 'aws %s\n' "$*" | tr '\n' ' ' >>"$s/calls"
echo >>"$s/calls"
[ "$1 $2 $3 $4" = "--profile $FAKE_PROFILE --region ap-southeast-1" ] ||
  { echo "fake aws: --profile $FAKE_PROFILE --region ap-southeast-1 are not the first arguments" >&2; exit 2; }
[ -z "${AWS_PAGER:-}" ] || { echo "fake aws: AWS_PAGER is set" >&2; exit 2; }
shift 4
case "$1 $2 $3" in
  "sts get-caller-identity --query") printf '%s\n' "$FAKE_ACCOUNT" ;;
  "secretsmanager describe-secret --secret-id")
    if grep -qxF -- "$4" "$s/missing" 2>/dev/null; then echo "An error occurred (ResourceNotFoundException)" >&2; exit 254; fi
    printf '%s\n' "$4" ;;
  "secretsmanager list-secret-version-ids --secret-id") cat "$s/runtime-version" 2>/dev/null || echo ;;
  "secretsmanager put-secret-value --secret-id")
    [ "$5" = --secret-string ] && [ "${6#file://}" != "$6" ] || { echo "fake aws: no --secret-string file://" >&2; exit 2; }
    f=${6#file://}
    ls -ld "$(dirname "$f")" | cut -c1-10 >>"$s/modes"
    mkdir -p "$s/entries"
    cp "$f" "$s/entries/$(printf '%s' "$4" | tr / _).json"
    echo version-1 ;;
  *) echo "fake aws: unexpected call: $*" >&2; exit 3 ;;
esac
EOF
cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
# One line per call: an argument of several lines (the code of a shell) on one.
printf 'kubectl %s' "$*" | tr '\n' ' ' >>"$s/calls"
echo >>"$s/calls"
[ "${1:-}" = --context ] || { echo "fake kubectl: --context is not the first argument" >&2; exit 2; }
shift 2
[ "${1:-}" != -n ] || shift 2
args="$*"
es='[["svp-data", "pg-superuser"], ["svp", "sentry"], ["svp-obs", "glitchtip-api"], ["svp-obs", "glitchtip-sourcemaps"]]'
case $args in
  "get --raw /readyz") [ ! -f "$s/unreachable" ] ;;
  "get pvc datadir-redpanda-0" | "rollout status deployment/glitchtip --timeout=300s" | "get crd "*) ;;
  "get secret redpanda-bootstrap -o jsonpath={.data.password}") printf '%s' "$FAKE_KAFKA_B64" ;;
  "get pod redpanda-0 -o jsonpath="*) printf true ;;
  "exec -i redpanda-0 -c redpanda -- bash -c "*) cat >/dev/null ;;
  "exec deployment/glitchtip "*) printf 'svp-dsn=%s\nsvp-token=%s\nsvp-sourcemaps-token=%s\n' "$FAKE_DSN" "$FAKE_TOKEN" "$FAKE_SOURCEMAPS_TOKEN" ;;
  "get externalsecrets.external-secrets.io -A -o name") jq -r "$es[] | \"externalsecret.external-secrets.io/\(.[1])\"" <<<null ;;
  "get externalsecrets.external-secrets.io -A -o json")
    n=$(cat "$s/annotations" 2>/dev/null || echo 0)
    jq -n --arg rv "1-$n" "{items: $es | map({metadata: {namespace: .[0], name: .[1], generation: 1},
      status: {syncedResourceVersion: \$rv, conditions: [{type: \"Ready\", status: \"True\"}]}})}" ;;
  "annotate externalsecrets.external-secrets.io "*) echo $(($(cat "$s/annotations" 2>/dev/null || echo 0) + 1)) >"$s/annotations" ;;
  "get rollouts.argoproj.io "*) exit 1 ;;
  "get deployment "*) ;;
  *) echo "fake kubectl: unexpected call: $args" >&2; exit 3 ;;
esac
EOF
chmod 755 "$bin"/*

# --- the fake secrets, and the copy of deploy/ that reads them.
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
  echo "SVP_ARGOCD_NOTIFY_APP_ID=123456"
  echo "SVP_ARGOCD_NOTIFY_INSTALLATION_ID=7654321"
  v=$(openssl genpkey -algorithm ed25519 2>/dev/null | base64 | tr -d '\n')
  echo "$v" >>"$work/secrets"
  echo "SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64=$v"
  # Telegram unset: optional, its keys written empty.
  echo "SVP_ALERT_TELEGRAM_BOT_TOKEN="
} >"$work/env"
dotenv_of() { sed -n "s/^$1=//p" "$work/env"; }
rds_password="rds-$(openssl rand -hex 12)"
FAKE_DSN="http://$(openssl rand -hex 16)@127.0.0.1:8000/1"
FAKE_TOKEN="token-$(openssl rand -hex 16)"
FAKE_SOURCEMAPS_TOKEN="maps-$(openssl rand -hex 16)"
FAKE_KAFKA_B64=$(b64 "$(dotenv_of SVP_KAFKA_ADMIN_PASSWORD)")
export FAKE_DSN FAKE_TOKEN FAKE_SOURCEMAPS_TOKEN FAKE_KAFKA_B64
printf '%s\n' "$rds_password" "${FAKE_DSN%@*}" "$FAKE_TOKEN" "$FAKE_SOURCEMAPS_TOKEN" >>"$work/secrets"
stg_account=111111111111
prd_account=222222222222

# leaks FILE...: the secrets (or their base64) the FILEs hold, one line each; nothing when none.
leaks() {
  local v
  while IFS= read -r v; do
    if cat "$@" | grep -qF -- "$v" || cat "$@" | grep -qF -- "$(b64 "$v")"; then echo "${v:0:8}..."; fi
  done <"$work/secrets"
}
# no_leak NAME FILE...: a case of its own, that the FILEs (output, the log of the calls) of NAME hold no secret.
no_leak() {
  local found
  found=$(leaks "${@:2}")
  if [ -z "$found" ]; then ok "$1: no secret value in the output or in any argument"; else fail "$1: secrets in the output or arguments: $found"; fi
}

# new_state [RUNTIME_VERSION]: an empty folder of the fakes' log and answers, a fresh .env and TMPDIR; entry
# glitchtip-runtime has version RUNTIME_VERSION (none when not given).
new_state() {
  FAKE_STATE=$(mktemp -d "$work/state.XXXXXX")
  export FAKE_STATE
  : >"$FAKE_STATE/calls"
  mkdir -p "$FAKE_STATE/tmp"
  [ -z "${1:-}" ] || echo "$1" >"$FAKE_STATE/runtime-version"
  cp "$work/env" "$fake/.env"
}
# run SCRIPT OUT [VAR=VALUE...]: deploy/k8s/SCRIPT of the copy with the fake tools and the environment given (on top
# of profile anhnv-stg of the stg account, context svp-stg), at most 120 s; output in OUT, exit status in $rc.
run() {
  local script=$1 out=$2
  shift 2
  rc=0
  env -u AWS_PROFILE -u SVP_RDS_MASTER_PASSWORD PATH="$bin:$PATH" TMPDIR="$FAKE_STATE/tmp" \
    SVP_KUBE_CONTEXT=svp-stg AWS_PROFILE=anhnv-stg FAKE_PROFILE=anhnv-stg FAKE_ACCOUNT=$stg_account \
    SVP_AWS_STG_ACCOUNT_ID=$stg_account SVP_AWS_PRD_ACCOUNT_ID=$prd_account "$@" \
    perl -e 'alarm 120; exec @ARGV' "$fake/deploy/k8s/$script" >"$out" 2>&1 || rc=$?
}
# refused NAME OUT MESSAGE: the run failed with MESSAGE in its output, and nothing was written.
refused() {
  if [ "$rc" != 0 ] && grep -qF -- "$3" "$2" && ! grep -q 'put-secret-value' "$FAKE_STATE/calls"; then
    ok "$1: refused before any write ($3)"
  else
    fail "$1: exit $rc, want a failure with '$3' and no put-secret-value:"$'\n'"$(sed 's/^/      /' "$2" "$FAKE_STATE/calls")"
  fi
}
# line PATTERN: the number of the first line of the log of calls that matches PATTERN (grep -E), 0 when none.
line() { grep -nE -- "$1" "$FAKE_STATE/calls" | head -n 1 | cut -d: -f1 || true; }
last_line() { grep -nE -- "$1" "$FAKE_STATE/calls" | tail -n 1 | cut -d: -f1 || true; }
# entry ENV NAME: the JSON the fake aws was given for entry svp/ENV/NAME (empty when none).
entry() { cat "$FAKE_STATE/entries/svp_$1_$2.json" 2>/dev/null || true; }

# The entries and keys of the ExternalSecrets of chart svp-cluster on EKS (store aws, s3.mode external,
# argocdNotifications on), written out here so that the script's own reading of the chart is checked against them.
want_keys='{
  "argocd-notifications": ["SVP_ALERT_TELEGRAM_BOT_TOKEN", "SVP_ARGOCD_NOTIFY_APP_ID", "SVP_ARGOCD_NOTIFY_INSTALLATION_ID", "SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64"],
  "glitchtip-runtime": ["SENTRY_AUTH_TOKEN", "SENTRY_DSN", "SENTRY_SOURCEMAPS_TOKEN"],
  "jwt-signing": ["JWT_SIGNING_KEY", "JWT_SIGNING_KID"],
  "jwt-verify": ["JWT_VERIFY_KEYS"],
  "kafka-admin": ["SVP_KAFKA_ADMIN_PASSWORD"],
  "kafka-users": ["SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD", "SVP_KAFKA_FEED_SERVICE_PASSWORD", "SVP_KAFKA_KEDA_PASSWORD", "SVP_KAFKA_MEDIA_WORKER_PASSWORD", "SVP_KAFKA_USER_SERVICE_PASSWORD", "SVP_KAFKA_VIDEO_SERVICE_PASSWORD"],
  "obs": ["GLITCHTIP_ADMIN_EMAIL", "GLITCHTIP_ADMIN_PASSWORD", "GLITCHTIP_SECRET_KEY", "SVP_ALERT_TELEGRAM_BOT_TOKEN", "SVP_ALERT_TELEGRAM_CHAT_ID", "SVP_GRAFANA_ADMIN_PASSWORD"],
  "pg-roles": ["SVP_ENGAGEMENT_APP_DB_PASSWORD", "SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD", "SVP_FEED_APP_DB_PASSWORD", "SVP_FEED_MIGRATOR_DB_PASSWORD", "SVP_GLITCHTIP_APP_DB_PASSWORD", "SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD", "SVP_USER_APP_DB_PASSWORD", "SVP_USER_MIGRATOR_DB_PASSWORD", "SVP_VIDEO_APP_DB_PASSWORD", "SVP_VIDEO_MIGRATOR_DB_PASSWORD"],
  "pg-superuser": ["SVP_PG_SUPERUSER_PASSWORD"],
  "web": ["NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"]
}'

# written_ok ENV [no-runtime]: every entry of want_keys but glitchtip-runtime (and it too, empty, without no-runtime)
# was written for ENV with exactly its keys, each with the value it must have. Prints what is wrong, nothing when all is.
written_ok() {
  local env=$1 name key got want
  for name in $(jq -r 'keys[]' <<<"$want_keys"); do
    got=$(entry "$env" "$name")
    if [ "$name" = glitchtip-runtime ] && [ "${2:-}" = no-runtime ]; then
      [ -z "$got" ] || echo "$name written"
      continue
    fi
    [ -n "$got" ] || { echo "$name not written"; continue; }
    [ "$(jq -c 'keys' <<<"$got")" = "$(jq -c --arg n "$name" '.[$n]' <<<"$want_keys")" ] ||
      echo "$name has keys $(jq -c 'keys' <<<"$got")"
    for key in $(jq -r 'keys[]' <<<"$got"); do
      case $key in
        SVP_PG_SUPERUSER_PASSWORD) want=$rds_password ;;
        SENTRY_*) want= ;;
        *) want=$(dotenv_of "$key") ;;
      esac
      [ "$(jq -r --arg k "$key" '.[$k]' <<<"$got")" = "$want" ] || echo "$name.$key has another value"
    done
  done
  [ "$(find "$FAKE_STATE/entries" -type f | grep -c .)" = "$(jq -r 'keys | length' <<<"$want_keys")" ] ||
    [ "${2:-}" = no-runtime ] || echo "entries written: $(ls "$FAKE_STATE/entries" | paste -sd ' ' -)"
}
# aws_calls_ok: every aws call names the profile and the region (the fake refuses any other), the account is read
# before any other aws call, each file was in a folder of mode 700 that is gone now.
aws_calls_ok() {
  [ "$(line '^aws ')" = "$(line '^aws .* sts get-caller-identity ')" ] || echo "the account is not read first"
  [ -z "$(grep '^aws ' "$FAKE_STATE/calls" | grep -v '^aws --profile anhnv-[a-z]* --region ap-southeast-1 ')" ] ||
    echo "an aws call without the profile and region first"
  [ -z "$(sort -u "$FAKE_STATE/modes" | grep -vx 'drwx------')" ] || echo "a file in a folder of mode $(sort -u "$FAKE_STATE/modes" | paste -sd ' ' -)"
  [ -z "$(ls -A "$FAKE_STATE/tmp")" ] || echo "left in TMPDIR: $(ls -A "$FAKE_STATE/tmp")"
}

# --- 1. a first run on svp-stg.
new_state
run aws-secrets.sh "$work/first.out" SVP_RDS_MASTER_PASSWORD="$rds_password"
problems=$( (written_ok stg; aws_calls_ok) | paste -sd ';' -)
if [ "$rc" = 0 ] && [ -z "$problems" ]; then
  ok "aws-secrets.sh, a first run on svp-stg: the $(jq length <<<"$want_keys") entries of svp/stg/ with exactly their keys (pg-superuser from SVP_RDS_MASTER_PASSWORD, Telegram empty, glitchtip-runtime empty, no s3-root or s3-users), profile and region in every aws call, the account read first, files in a folder of mode 700, gone after"
else
  fail "aws-secrets.sh, a first run on svp-stg: exit $rc; $problems"$'\n'"$(sed 's/^/      /' "$work/first.out")"
fi
if ! grep -q '^kubectl ' "$FAKE_STATE/calls" && grep -q '^skip  ExternalSecrets: a new environment' "$work/first.out"; then
  ok "aws-secrets.sh, a first run: no kubectl call (no force-sync, no Redpanda)"
else
  fail "aws-secrets.sh, a first run: kubectl called: $(grep '^kubectl ' "$FAKE_STATE/calls" | head -n 3 | paste -sd ';' -)"
fi
no_leak "aws-secrets.sh, a first run" "$work/first.out" "$FAKE_STATE/calls"

# --- 2. a run again: glitchtip-runtime has a version.
new_state v-runtime
run aws-secrets.sh "$work/again.out" SVP_RDS_MASTER_PASSWORD="$rds_password"
problems=$( (written_ok stg no-runtime; aws_calls_ok) | paste -sd ';' -)
redpanda=$(line '^kubectl .* exec -i redpanda-0 ')
first_put=$(line 'put-secret-value')
last_put=$(last_line 'put-secret-value')
first_annotate=$(line '^kubectl .* annotate externalsecrets')
if [ "$rc" = 0 ] && [ -z "$problems" ] && [ -n "$redpanda" ] && [ "$redpanda" -lt "$first_put" ] &&
  [ -n "$first_annotate" ] && [ "$last_put" -lt "$first_annotate" ] &&
  [ "$(grep -c '^kubectl .* annotate externalsecrets' "$FAKE_STATE/calls")" = 4 ] &&
  grep -q '^skip  entry svp/stg/glitchtip-runtime: it has a value already' "$work/again.out"; then
  ok "aws-secrets.sh, a run again: glitchtip-runtime not written, Redpanda's password before the first write, every ExternalSecret (4) built again after the last one"
else
  fail "aws-secrets.sh, a run again: exit $rc; $problems; redpanda $redpanda, puts $first_put-$last_put, first annotate $first_annotate"$'\n'"$(sed 's/^/      /' "$work/again.out")"
fi
no_leak "aws-secrets.sh, a run again" "$work/again.out" "$FAKE_STATE/calls"

# --- 3. svp-prd.
new_state
run aws-secrets.sh "$work/prd.out" SVP_RDS_MASTER_PASSWORD="$rds_password" SVP_KUBE_CONTEXT=svp-prd \
  AWS_PROFILE=anhnv-prd FAKE_PROFILE=anhnv-prd FAKE_ACCOUNT=$prd_account
problems=$( (written_ok prd; aws_calls_ok) | paste -sd ';' -)
if [ "$rc" = 0 ] && [ -z "$problems" ] && ! grep -q 'svp/stg/' "$FAKE_STATE/calls"; then
  ok "aws-secrets.sh on svp-prd: entries svp/prd/*, the account of SVP_AWS_PRD_ACCOUNT_ID"
else
  fail "aws-secrets.sh on svp-prd: exit $rc; $problems"$'\n'"$(sed 's/^/      /' "$work/prd.out")"
fi

# --- 4. what stops it before any write.
new_state
run aws-secrets.sh "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password" AWS_PROFILE=
refused "aws-secrets.sh without AWS_PROFILE" "$work/out" "AWS_PROFILE is not set"
if ! grep -q '^aws ' "$FAKE_STATE/calls"; then ok "aws-secrets.sh without AWS_PROFILE: no aws call"; else fail "aws-secrets.sh without AWS_PROFILE: aws called"; fi
new_state
run aws-secrets.sh "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password" FAKE_ACCOUNT=$prd_account
refused "aws-secrets.sh, profile of another account" "$work/out" "is of account $prd_account, not of stg"
if [ "$(grep -c '^aws ' "$FAKE_STATE/calls")" = 1 ]; then ok "aws-secrets.sh, another account: no aws call after the account's"; else fail "aws-secrets.sh, another account: $(cat "$FAKE_STATE/calls")"; fi
new_state
run aws-secrets.sh "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password" SVP_AWS_STG_ACCOUNT_ID=
refused "aws-secrets.sh without SVP_AWS_STG_ACCOUNT_ID" "$work/out" "SVP_AWS_STG_ACCOUNT_ID is not the 12-digit id"
new_state
run aws-secrets.sh "$work/out"
refused "aws-secrets.sh without SVP_RDS_MASTER_PASSWORD" "$work/out" "SVP_RDS_MASTER_PASSWORD is not set or empty"
new_state
grep -v '^JWT_VERIFY_KEYS=' "$work/env" >"$fake/.env"
run aws-secrets.sh "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password"
refused "aws-secrets.sh, .env without JWT_VERIFY_KEYS" "$work/out" ".env lacks or has empty: JWT_VERIFY_KEYS"
new_state
grep -v '^SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64=' "$work/env" >"$fake/.env"
run aws-secrets.sh "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password"
refused "aws-secrets.sh, .env without the key of Argo CD Notifications" "$work/out" "lacks or has empty: SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64, which Argo CD Notifications needs"
new_state
echo svp/stg/web >"$FAKE_STATE/missing"
run aws-secrets.sh "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password"
refused "aws-secrets.sh, entry svp/stg/web not made" "$work/out" "entry svp/stg/web of AWS Secrets Manager not found"
new_state v-runtime
: >"$FAKE_STATE/unreachable"
run aws-secrets.sh "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password"
refused "aws-secrets.sh, a run again with the cluster out of reach" "$work/out" "cluster svp-stg is not reachable"

# --- 5. deploy/k8s/glitchtip-init.sh on svp-stg.
new_state v-runtime
run glitchtip-init.sh "$work/glitchtip.out"
got=$(entry stg glitchtip-runtime)
put=$(line 'put-secret-value --secret-id svp/stg/glitchtip-runtime ')
first_annotate=$(line '^kubectl .* annotate externalsecrets')
annotated=$(grep '^kubectl .* annotate externalsecrets' "$FAKE_STATE/calls" | awk '{print $5 "/" $8}' | sort | paste -sd ' ' -)
problems=$(aws_calls_ok | paste -sd ';' -)
if [ "$rc" = 0 ] && [ -z "$problems" ] &&
  [ "$(jq -r .SENTRY_DSN <<<"$got")" = "${FAKE_DSN/@127.0.0.1:8000\//@glitchtip.svp-obs:8000/}" ] &&
  [ "$(jq -r .SENTRY_AUTH_TOKEN <<<"$got")" = "$FAKE_TOKEN" ] &&
  [ "$(jq -r .SENTRY_SOURCEMAPS_TOKEN <<<"$got")" = "$FAKE_SOURCEMAPS_TOKEN" ] &&
  [ -n "$put" ] && [ -n "$first_annotate" ] && [ "$put" -lt "$first_annotate" ] &&
  [ "$annotated" = "svp-obs/glitchtip-api svp-obs/glitchtip-sourcemaps svp/sentry" ] &&
  [ "$(grep -c 'put-secret-value' "$FAKE_STATE/calls")" = 1 ]; then
  ok "glitchtip-init.sh on svp-stg: GlitchTip's DSN (the Service's host) and tokens in entry svp/stg/glitchtip-runtime, then its three ExternalSecrets built again"
else
  fail "glitchtip-init.sh on svp-stg: exit $rc; $problems; put $put, annotate $first_annotate ($annotated)"$'\n'"$(sed 's/^/      /' "$work/glitchtip.out")"
fi
no_leak "glitchtip-init.sh on svp-stg" "$work/glitchtip.out" "$FAKE_STATE/calls"
new_state v-runtime
run glitchtip-init.sh "$work/out" AWS_PROFILE=
if [ "$rc" != 0 ] && grep -qF 'AWS_PROFILE is not set' "$work/out" && [ ! -s "$FAKE_STATE/calls" ]; then
  ok "glitchtip-init.sh on svp-stg without AWS_PROFILE: refused before any aws or kubectl call"
else
  fail "glitchtip-init.sh on svp-stg without AWS_PROFILE: exit $rc, calls $(cat "$FAKE_STATE/calls"): $(cat "$work/out")"
fi

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures case(s) of deploy/k8s/aws-secrets-test.sh" >&2
  exit 1
fi
echo "ok    deploy/k8s/aws-secrets-test.sh: every case"
