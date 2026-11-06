#!/usr/bin/env bash
# Prepares test images and runs drill-k8s-supplychain for verify.yml jobs.
# On scheduled runs (SVP_VERIFY_SCHEDULED=true), skips drill cases with attestations nearing maxAttestationAge (72h).
# Usage, from the repo root: deploy/ci/verify-steps/supplychain.sh
# Design notes: docs/reference/ci.md.
set -euo pipefail

ci=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=deploy/ci/common.sh
. "$ci/common.sh"

# stale CASE IMAGE: prints NOTE and exits 0 if IMAGE vuln attestation is older than maxAttestationAge less an hour.
# Exits 1 if within age or if cosign or the time cannot be read.
stale() (
  local source max_age max_s envelopes scanned age hint
  source=$(source_of_repository "${2%@*}") || exit 1
  sign_identity "$source"
  max_age=$(sed -n 's/^  maxAttestationAge: *//p' "$repo_root/deploy/helm/svp-policy/values.yaml")
  [[ $max_age =~ ^[0-9]+[hms]$ ]] || exit 1
  case $max_age in
    *h) max_s=$((${max_age%h} * 3600)) ;;
    *m) max_s=$((${max_age%m} * 60)) ;;
    *s) max_s=${max_age%s} ;;
  esac
  envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" "$2" 2>/dev/null) || exit 1
  scanned=$(jq -rs '[.[].payload | @base64d | fromjson | .predicate.metadata.scanFinishedOn] | min // empty' \
    <<<"$envelopes" 2>/dev/null) || exit 1
  [[ $scanned =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || exit 1
  age=$(jq -nr --arg t "$scanned" 'now - ($t | fromdateiso8601) | floor') && [[ $age =~ ^[0-9]+$ ]] || exit 1
  # An hour short of the maximum: the drill and Kyverno read the age again minutes later, after the cases before c.
  [ "$age" -gt "$((max_s - 3600))" ] || exit 1
  hint="gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f drill=true"
  echo "NOTE  case $1 left out on this scheduled run (it SKIPs): $2 was scanned at $scanned, $((age / 3600)) h ago," \
    "within an hour of $max_age or more; nobody rescans it before a scheduled run, so it is checked on a dispatch run within $max_age" \
    "of: $hint"
)

missing=
unsigned=$("$ci/ghcr-digest.sh" newest drill-unsigned) || missing="$missing drill-unsigned;"
vulnerable=$("$ci/ghcr-digest.sh" newest drill-vulnerable) || missing="$missing drill-vulnerable;"
no_provenance=$("$ci/ghcr-digest.sh" newest drill-no-provenance) || missing="$missing drill-no-provenance;"
if [ "${SVP_VERIFY_SCHEDULED:-}" = true ]; then
  if [ -n "$vulnerable" ] && stale c "$vulnerable"; then vulnerable=; fi
  if [ -n "$no_provenance" ] && stale l "$no_provenance"; then no_provenance=; fi
fi
echo "unsigned: ${unsigned:-none}; vulnerable: ${vulnerable:-none}"
echo "without provenance: ${no_provenance:-none, case l SKIPs}"
rc=0
make drill-k8s-supplychain SUPPLYCHAIN_UNSIGNED="$unsigned" SUPPLYCHAIN_VULNERABLE="$vulnerable" \
  SUPPLYCHAIN_NO_PROVENANCE="${no_provenance:-none}" SUPPLYCHAIN_ENFORCE_TMP="${SUPPLYCHAIN_ENFORCE_TMP:-}" || rc=$?
if [ -n "$missing" ]; then
  echo "FAIL  drill-k8s-supplychain ran without what GHCR did not give (above):$missing"
  exit 1
fi
exit "$rc"
