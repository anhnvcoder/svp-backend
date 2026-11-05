#!/usr/bin/env bash
# Step drill-k8s-supplychain of job gitops of .github/workflows/verify.yml: make drill-k8s-supplychain with the images it
# needs, read from GHCR without credentials (deploy/ci/ghcr-digest.sh newest): the newest drill-unsigned as the unsigned
# image of cases b, h and i (no signature or attestation names it), the newest drill-vulnerable for case c, and for case
# l (signed and attested vuln, without build provenance) the newest drill-no-provenance. An image that cannot be read is
# left out and the step fails after the drill, even when the drill passes: its case SKIPs, except drill-unsigned, which
# the drill then looks up itself; case l gets none, never empty, which the drill reads as "look it up yourself".
#
# Cases c and l pass only when their drill image's vuln attestation is within the policy's maximum age
# (imageVerification.maxAttestationAge of chart svp-policy, 72h): dispatch images.yml -f drill=true less than that before
# a dispatched run, as no image file of svp-gitops names a drill image and the daily rescan never attests one again.
# Nobody dispatches it before a scheduled run (SVP_VERIFY_SCHEDULED=true, which the job sets on a scheduled run only;
# any other value is a dispatch): there the image of c or l whose vuln attestation is older than that age less an hour
# is left out (c empty, l none: the case SKIPs, failing nothing), with a NOTE line naming the case, its age and that
# dispatch. The age is read as the drill reads it: the oldest scanFinishedOn of the attestations cosign verifies,
# anonymously, with the identity of the release source whose prefix the image is under. An image whose age cannot be
# read is kept: the drill reads it again and fails the case with what it got. A dispatched run keeps both whatever
# their age.
#
# Usage, from the repo root: deploy/ci/verify-steps/supplychain.sh
set -euo pipefail

ci=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=deploy/ci/common.sh
. "$ci/common.sh"

# stale CASE IMAGE: status 0, after printing the NOTE line, when the vuln attestation of IMAGE (REPOSITORY@DIGEST) is
# older than the policy's maximum age less an hour; status 1 otherwise, also when cosign or the time cannot be read.
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
  SUPPLYCHAIN_NO_PROVENANCE="${no_provenance:-none}" || rc=$?
if [ -n "$missing" ]; then
  echo "FAIL  drill-k8s-supplychain ran without what GHCR did not give (above):$missing"
  exit 1
fi
exit "$rc"
