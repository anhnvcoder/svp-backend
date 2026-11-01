#!/usr/bin/env bash
# sign-image.sh [--allow-critical] INDEX DIR DIR: signs and attests one released image,
# keyless: cosign gets a short-lived certificate from Fulcio for the OIDC identity of this
# workflow run (images.yml on refs/heads/main) and records the signature in Rekor; there is no key to leak or rotate.
# INDEX is the directory merge-index.sh wrote (repository, tag, digest); each DIR is one platform leg (platform,
# digest, config-digest, trivy.json, scan times, sbom.spdx.json).
#
# Before anything is signed, the index is read back and must hold exactly the two scanned manifests; the vuln
# predicate is built from the two gating scans (vuln-predicate.sh, which refuses a CRITICAL unless --allow-critical,
# given only for the drill image drill-vulnerable). Then, each a Sigstore bundle (an OCI referrer of the digest):
#   - cosign sign on the index digest (pods run the index digest, so that is what Kyverno verifies);
#   - cosign attest --type spdxjson of each platform's SBOM on that platform's manifest digest;
#   - cosign attest --type vuln of the predicate on the index digest.
# The build provenance is the next step of the job, actions/attest on the index digest, after the signature and the
# vuln attestation: this script hands it the subject as outputs (repository, digest) and provenance=true when it is
# to run, false for a drill image (no release: drill-no-provenance is signed only to show the policy refusing a
# signed, clean image that lacks it) and when the digest has a provenance bundle already.
# The image must lie under the prefix of the release source this run builds for (use_build_source of common.sh: the
# source whose repository runs the job) and be one of its services or drill images: a run of one repository never
# signs under another source's prefix, where the policy expects that source's identity. A release is signed only when
# the workflow running this is the identity of that source (the subject the policy checks, and the one of the
# keyless certificate this job and actions/attest get), so nothing is signed on a machine ("local"), by another
# workflow or by another source's repository.
# Bundles have no --replace: a run started again (Re-run failed jobs) on the same index digest would add a second
# signature, SBOM, vuln attestation or provenance, and two vuln or provenance attestations make verify-release.sh
# refuse the release. So the bundles already on each digest are listed first (bundle_referrers of common.sh), and
# each one is written only when none of its type is there. A digest in cosign's older format (.sig) is refused before
# anything is written: one digest never carries both formats, verifiers read only the bundles.
# Needs cosign on PATH, `docker login ghcr.io` (cosign, and ORAS to list the referrers), and the id-token permission of
# the job.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

predicate_flags=()
if [ "${1:-}" = --allow-critical ]; then
  predicate_flags=(--allow-critical)
  shift
fi
[ $# -eq 3 ] || fail "usage: sign-image.sh [--allow-critical] INDEX DIR DIR"
index=$1 a=$2 b=$3
repo=$(cat "$index/repository") digest=$(cat "$index/digest")
use_build_source
case $repo in "$build_prefix"*) ;; *) fail "$repo is not under $build_prefix, the prefix of release source $build_source_name this run builds for" ;; esac
image=${repo#"$build_prefix"}
use_build_source "$image"
is_digest "$digest" || fail "$index has no index digest"
release=true
jq -e --arg i "$image" '.drillImages | index($i)' <<<"$build_source" >/dev/null && release=false
if [ ${#predicate_flags[@]} -gt 0 ] && { [ "$image" != drill-vulnerable ] || [ "$release" = true ]; }; then
  fail "--allow-critical is only for the drill image drill-vulnerable"
fi
if [ "$release" = true ]; then
  sign_identity "$build_source_name"
  builder=$(ci_builder_id) || fail "read the workflow of this run"
  [ "$builder" = "$sign_subject" ] ||
    fail "this run is the workflow '$builder', but releases of source $build_source_name are signed only as $sign_subject"
fi
check_index "$repo" "$digest" "$a" "$b" || fail "$repo@$digest is not an index of exactly the two scanned manifests"

work=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$work"' EXIT
predicate=$work/vuln.json
"$ci_dir/vuln-predicate.sh" ${predicate_flags[@]+"${predicate_flags[@]}"} "$predicate" "$a" "$b" ||
  fail "build the vuln predicate of $repo@$digest"

format=$(release_format "$repo@$digest") || fail "read how $repo@$digest is signed (above)"
[ "$format" != legacy ] ||
  fail "$repo@$digest carries cosign's older format already: one digest never carries both, nothing written"
have=$(bundle_referrers "$repo@$digest") || fail "list the bundles of $repo@$digest"
# has LIST TYPE: true when LIST (lines of bundle_referrers) holds a bundle of predicate type TYPE.
has() { [ -n "$(bundles_of "$2" <<<"$1")" ]; }

bundle=(--yes --new-bundle-format=true)
if has "$have" "$sign_predicate_type"; then
  echo "skip  $repo@$digest has its signature already"
else
  cosign sign "${bundle[@]}" "$repo@$digest" || fail "sign $repo@$digest"
fi
for dir in "$a" "$b"; do
  child=$(cat "$dir/digest")
  child_have=$(bundle_referrers "$repo@$child") || fail "list the bundles of $repo@$child"
  if has "$child_have" "$sbom_predicate_type"; then
    echo "skip  $repo@$child has its SBOM already"
  else
    cosign attest "${bundle[@]}" --type spdxjson --predicate "$dir/sbom.spdx.json" "$repo@$child" ||
      fail "attest the SBOM of $(cat "$dir/platform") on $repo@$child"
  fi
done
if has "$have" "$vuln_predicate_type"; then
  echo "skip  $repo@$digest has its vuln attestation already"
else
  cosign attest "${bundle[@]}" --type vuln --predicate "$predicate" "$repo@$digest" ||
    fail "attest the vuln predicate on $repo@$digest"
fi
provenance=false
if [ "$release" = true ]; then
  if has "$have" "$provenance_predicate_type"; then
    echo "skip  $repo@$digest has its provenance already"
  else
    provenance=true
  fi
fi
ci_output repository "$repo" && ci_output digest "$digest" && ci_output provenance "$provenance" ||
  fail "hand the subject of the provenance to the next step"
if [ "$release" = true ]; then
  echo "ok    $repo@$digest signed; SBOM on both manifests, vuln on the index; provenance next (actions/attest): $provenance"
else
  echo "ok    $repo@$digest signed; SBOM on both manifests, vuln on the index (a drill image: no provenance)"
fi
