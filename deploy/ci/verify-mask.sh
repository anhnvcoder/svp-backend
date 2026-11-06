#!/usr/bin/env bash
# verify-mask.sh env|cluster: masks secret-named .env or cluster Secret values (>=8 chars, raw, base64) in the job log
# and keeps them for verify-collect.sh. The repository is public, so the job log is too: masking is the second layer.
# Skips non-secret keys and Helm blobs. Values kept in a private dir, mode 600, never uploaded. Never set -x.
# Design notes: docs/reference/ci.md.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=${SVP_VERIFY_REPO:-$(cd "$here/../.." && pwd)}
env_file=${SVP_VERIFY_ENV_FILE:-$repo/.env}
# The job's own temp directory on GitHub Actions, emptied when the job ends; /tmp on a machine.
tmp_root=${RUNNER_TEMP:-/tmp}
# mask VALUE: prints ::add-mask:: on Actions (%25 decodes to % in runner data); silent locally to avoid printing VALUE.
mask() { [ "${GITHUB_ACTIONS:-}" != true ] || printf '::add-mask::%s\n' "${1//%/%25}"; }
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}
min_len=8
namespaces="svp svp-data svp-obs argocd svp-secrets"
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$here/../observability/glitchtip/dotenv.sh"

fail() {
  echo "verify-mask: $1" >&2
  exit 1
}

umask 077
mkdir -p "$secrets"
chmod 700 "$secrets"
work=$(mktemp -d "$secrets/work.XXXXXX")
trap 'rm -rf "$work"' EXIT

# secret_name NAME: true for the names of .env whose value is a secret.
secret_name() {
  case $1 in
    SENTRY_DSN | *PASSWORD | *SECRET | *SECRET_KEY | *TOKEN | *_KEY | *_KEYS) return 0 ;;
    *) return 1 ;;
  esac
}

# with_base64 < VALUES: each value line, then its base64 on one line; only lines of min_len or more characters.
with_base64() {
  local v
  while IFS= read -r v || [ -n "$v" ]; do
    [ "${#v}" -ge "$min_len" ] || continue
    printf '%s\n' "$v"
    printf '%s' "$v" | base64 | tr -d '\n'
    printf '\n'
  done
}

# keep LIST: adds LIST to $secrets/LIST.values, then masks what no earlier call of this job masked.
keep() {
  touch "$secrets/$1.values"
  LC_ALL=C sort -u "$work/$1" "$secrets/$1.values" -o "$work/$1"
  mv "$work/$1" "$secrets/$1.values"
  touch "$secrets/masked"
  LC_ALL=C comm -13 "$secrets/masked" "$secrets/$1.values" >"$work/new"
  while IFS= read -r v; do mask "$v"; done <"$work/new"
  LC_ALL=C sort -u "$secrets/masked" "$work/new" -o "$secrets/masked"
  echo "verify-mask $1: $(wc -l <"$work/new" | tr -d ' ') new value(s) masked, $(wc -l <"$secrets/$1.values" | tr -d ' ') kept for the artifact scan"
}

case ${1:-} in
  env)
    if [ ! -e "$env_file" ]; then
      : >"$work/env"
      keep env
      exit 0
    fi
    # dotenv_value validates syntax and names any invalid variable without exposing secret values.
    dotenv_value "$env_file" SVP_VERIFY_NO_SUCH_NAME >/dev/null || fail "$env_file breaks the .env rule: nothing masked"
    names=$(LC_ALL=C sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$env_file")
    : >"$work/raw"
    for name in $names; do
      secret_name "$name" || continue
      value=$(dotenv_value "$env_file" "$name") || fail "read $name of $env_file"
      printf '%s\n' "$value" >>"$work/raw"
    done
    with_base64 <"$work/raw" >"$work/env"
    keep env
    if [ ! -e "$secrets/mask-checked" ]; then
      marker=$(openssl rand -hex 16)
      mask "$marker"
      echo "mask-check: $marker"
      touch "$secrets/mask-checked"
    fi
    ;;
  cluster)
    : >"$work/b64"
    for ns in $namespaces; do
      # Request timeout prevents hanging the scenario; nonexistent namespaces are ignored safely.
      kubectl --context k3d-svp --request-timeout=10s -n "$ns" get secrets -o json >"$work/list.json" 2>/dev/null ||
        fail "read the Secrets of namespace $ns of cluster k3d-svp: the previous list stays"
      jq -r '.items[] | select(.type != "helm.sh/release.v1") | (.data // {}) | to_entries[]
        | select(.key | ascii_downcase
          | test("^(username|user|dbname|host|port|ca\\.crt|tls\\.crt|sasl|tls)$|(username|[_-]user|email|_key_id|_kid)$")
          | not) | .value' \
        "$work/list.json" >>"$work/b64" || fail "read the Secret list of namespace $ns as JSON"
    done
    # Decoded values split on control chars and U+FFFD so control chars cannot break log line masking.
    # Replaces control chars with newlines via explode/implode for O(N) performance on binary values.
    jq -R -r '., (@base64d | explode | map(if . < 32 or (. >= 127 and . < 160) or . == 65533 then 10 else . end)
      | implode | split("\n")[] | gsub("^\\s+|\\s+$"; ""))' "$work/b64" |
      while IFS= read -r v || [ -n "$v" ]; do [ "${#v}" -lt "$min_len" ] || printf '%s\n' "$v"; done >"$work/cluster"
    keep cluster
    ;;
  *)
    fail "usage: verify-mask.sh env|cluster"
    ;;
esac
