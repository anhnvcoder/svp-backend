#!/usr/bin/env bash
# verify-release.sh [--gitops DIR] [--rev REV] [--env ENV] REPOSITORY DIGEST: true when the release may be deployed.
# It needs a signature and one vuln attestation of the release source's images.yml on main (both platforms, no
# CRITICAL, at most 48 hours old: 24 spare before Kyverno's 72) and, where the policy requires it, one provenance.
# Anonymous, so a pull request job can run it.

# The policy, and with it the release source and its identity, is read from the svp-gitops tree as Kyverno reads it.
# The provenance must name the commit the signing certificate names: one claiming another commit is refused.
# The same cosign commands read releases in Sigstore bundles and in cosign's older format; a digest carries one only.
# Design notes: docs/reference/ci.md.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

rev= env= dir=
while [ $# -gt 2 ]; do
  case $1 in
  --gitops) dir=$2 ;;
  --rev) rev=$2 ;;
  --env) env=$2 ;;
  *) break ;;
  esac
  shift 2
done
[ $# -eq 2 ] || fail "usage: verify-release.sh [--gitops DIR] [--rev REV] [--env ENV] REPOSITORY DIGEST"
repo=$1 digest=$2
is_digest "$digest" || fail "$digest is not sha256:<64 hex>"
max=$(attest_max_age)
provenance=$(provenance_required "$rev" "$env" "$dir") || fail "read whether chart svp-policy checks build provenance (above)"
source=$(release_source_in "$repo" "$rev" "$env" "$dir") || fail "find the release source of $repo (above)"
use_release_source "$source"

cosign_ verify --certificate-oidc-issuer "$sign_issuer" --certificate-identity "$sign_subject" "$repo@$digest" \
  >/dev/null || fail "$repo@$digest has no signature of $sign_subject (release source $source_name)"
envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$sign_issuer" \
  --certificate-identity "$sign_subject" "$repo@$digest" 2>/dev/null) ||
  fail "$repo@$digest has no vuln attestation of $sign_subject"
count=$(printf '%s\n' "$envelopes" | grep -c . || true)
# More than one and Kyverno would read any one of them: the release is not trusted.
[ "$count" -eq 1 ] || fail "$repo@$digest carries $count vuln attestations, not exactly one"
problem=$(printf '%s\n' "$envelopes" | jq -r '.payload | @base64d' | check_vuln_statement "$digest" "$max") ||
  fail "$repo@$digest: vuln attestation $problem"
if [ "$provenance" = true ]; then
  if [ "$source_name" = backend ]; then
    rebuild="gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f services=${repo##*/}"
  else
    # Another source's release is built by that repository's own workflow, not by a dispatch of this one.
    rebuild="a run of images.yml on main of $provenance_repository"
  fi
  envelopes=$(cosign_ verify-attestation --type slsaprovenance1 --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" "$repo@$digest" 2>/dev/null) || {
    # Only cosign's own "no attestation of this type" means a release from before provenance; any other error (GHCR or
    # Sigstore out of reach) is no reason to build it again.
    absent=0
    why=$(provenance_absent "$sign_issuer" "$sign_subject" "$repo@$digest" 2>&1) || absent=$?
    [ "$absent" -ne 0 ] ||
      fail "$repo@$digest has no provenance attestation of $sign_subject, which the policy requires here: a release built before CI attested provenance; release it again ($rebuild)"
    fail "$repo@$digest: its provenance attestation could not be verified (${why:-cosign failed once, then verified one}); check again, do not build it again"
  }
  count=$(printf '%s\n' "$envelopes" | grep -c . || true)
  # As for vuln: Kyverno keeps one payload per type, so with two it could read either.
  [ "$count" -eq 1 ] || fail "$repo@$digest carries $count provenance attestations, not exactly one"
  commit=$(printf '%s\n' "$envelopes" | jq -r '.payload | @base64d' | check_provenance_statement "$digest") ||
    fail "$repo@$digest: provenance $commit"
  cosign_ verify-attestation --type slsaprovenance1 --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" --certificate-github-workflow-sha "$commit" "$repo@$digest" >/dev/null 2>&1 ||
    fail "$repo@$digest: the provenance names commit $commit, the certificate of its signature another (or none)"
  provenance=", provenance of ${commit:0:12} by $sign_subject"
else
  provenance=
fi
echo "ok    $repo@$digest signed, one vuln attestation, both platforms, no CRITICAL, within $((max / 60)) minutes$provenance"
