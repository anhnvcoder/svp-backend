#!/usr/bin/env bash
# The new values of drill-k8s-reloader (reloader/rotate/chainsaw-test.yaml), one NAME=value line each, written to FILE
# (must not exist yet; mode 600), each in the form make env gives its variable (deploy/compose/compose.mk).
# JWT_VERIFY_KEY_NEW is <kid>:<public key> of a new tools/jwtkey pair, JWT_DRILL_SIGNING_KEY its private key (seed),
# which never goes to .env.

# On GitHub Actions each value and its base64 are masked (an ::add-mask:: line on stdout) as soon as they are made: run
# it in a step whose output is the job's log, never one sent to a file. Elsewhere it prints nothing. Never set -x here:
# the trace would print every value. Usage, from anywhere: deploy/k8s/drills/reloader/new-values.sh FILE
set -euo pipefail

fail() {
  echo "FAIL  new-values.sh: $1" >&2
  exit 1
}
[ $# = 1 ] && [ -n "$1" ] || fail "usage: deploy/k8s/drills/reloader/new-values.sh FILE"
out=$1
repo=$(cd "$(dirname "$0")/../../../.." && pwd)

# mask VALUE: hides VALUE wherever the job's log shows it from now on (the data of the command reads %25 as %).
mask() { [ "${GITHUB_ACTIONS:-}" != true ] || printf '::add-mask::%s\n' "${1//%/%25}"; }
# put NAME VALUE: masks VALUE and its base64 (the form a Secret holds it in), then writes the line.
put() {
  mask "$2"
  mask "$(printf '%s' "$2" | base64 | tr -d '\n')"
  printf '%s=%s\n' "$1" "$2" >>"$out"
}

umask 077
# noclobber: a file there already (another run's values, or anything else) is never overwritten.
(set -C && : >"$out") 2>/dev/null || fail "$out exists or cannot be created; the new values go to a new file"

put SVP_S3_ROOT_PASSWORD "$(openssl rand -hex 20)"
for name in SVP_KAFKA_ADMIN_PASSWORD SVP_VIDEO_APP_DB_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_KEDA_PASSWORD \
  SVP_GLITCHTIP_APP_DB_PASSWORD SVP_GRAFANA_ADMIN_PASSWORD; do
  put "$name" "$(openssl rand -hex 24)"
done
put NEXT_SERVER_ACTIONS_ENCRYPTION_KEY "$(openssl rand -base64 32)"

# tools/jwtkey prints JWT_SIGNING_KID, JWT_SIGNING_KEY and JWT_VERIFY_KEYS of one new pair; read with builtins only, so
# nothing but the masks touches the private key before it is masked.
pair=$(cd "$repo" && go run ./tools/jwtkey) || fail "go run ./tools/jwtkey"
kid='' seed='' verify=''
while IFS= read -r line; do
  case $line in
    JWT_SIGNING_KID=*) kid=${line#*=} ;;
    JWT_SIGNING_KEY=*) seed=${line#*=} ;;
    JWT_VERIFY_KEYS=*) verify=${line#*=} ;;
  esac
done <<<"$pair"
pair=
[ -n "$seed" ] || fail "tools/jwtkey printed no JWT_SIGNING_KEY"
put JWT_DRILL_SIGNING_KEY "$seed"
[[ $kid =~ ^[0-9]{8}-[0-9a-f]{8}$ && $verify == "$kid:"* ]] ||
  fail "tools/jwtkey printed no key pair of the form JWT_SIGNING_KID=<date>-<8 hex>, JWT_VERIFY_KEYS=<that kid>:<key>"
put JWT_VERIFY_KEY_NEW "$verify"
