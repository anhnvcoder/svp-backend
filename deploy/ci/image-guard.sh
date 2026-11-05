#!/usr/bin/env bash
# image-guard.sh: the guards of the image pipeline, around the tools the composite actions under .github/actions/image-*/
# call directly (docker buildx, trivy, syft, grype, cosign). Each subcommand checks what a step must not get wrong, and
# hands the step what it needs as outputs ($GITHUB_OUTPUT; printed key=value on a machine). The verdict of a scan stays
# the scanner's own exit code, read in the step; nothing here runs a scanner.
#
#   image-guard.sh leg IMAGE ARCH OUT       before the build of one leg (action image-leg)
#   image-guard.sh trivy-report LABEL OUT   before the trivy gate: OUT/trivy.json is a trivy image report
#   image-guard.sh grype-summary LABEL OUT  after grype: counts and the Critical matches of OUT/grype.json
#   image-guard.sh sarif IMAGE ARCH OUT     the SARIF of both scans, one category per image and architecture
#   image-guard.sh push IMAGE ARCH OUT      before the push: prints the tag to push the scanned image as
#   image-guard.sh pushed IMAGE ARCH OUT    after the push: the manifest read back holds the scanned config
#   image-guard.sh index IMAGE LEGS         before the index is joined (action image-index)
#   image-guard.sh index-check IMAGE LEGS OUT   after: the index read back holds exactly the two scanned manifests
#   image-guard.sh sign IMAGE OUT           before signing (action image-sign): what to write, and the vuln predicate
#
# The rules every subcommand keeps, as the pipeline did before (ADR-0015, 0039 §2, 0040):
#   - IMAGE is a service or drill image of the release source whose repository runs the job (use_build_source of
#     common.sh); the code is that of code_root (SVP_CODE_ROOT, the input code-root of the actions: svp-frontend's
#     checkout in its runs) and its HEAD is the commit of the run (check_code_tree). Both are checked before docker is
#     called.
#   - What is pushed is what was scanned: the config digest of the pushed manifest is the ImageID of the trivy report.
#   - The index holds exactly the two scanned manifests; what is signed and attested is the index read back.
#   - Only drill-vulnerable passes CRITICAL vulnerabilities (allow-critical); a secret blocks every image.
#   - A release is signed only when the workflow of the run is the identity of its source; each bundle (signature, SBOM,
#     vuln, provenance) is written only when the digest has none of its type, and a digest in cosign's older format
#     (.sig) is refused.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

# summary LINE: one line of the job summary per scan; where the summary is a page of its own, in the log too.
summary() {
  step_summary "- $1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1"
}

# leg IMAGE ARCH OUT: the image is the source's and the tree the run's commit, then the arguments of the build: the
# Dockerfile and context (this checkout's service.Dockerfile or media-worker.Dockerfile, a drill Dockerfile, or the
# Dockerfile at the top of another repository's tree, which must hold what its build and gates read), the one build
# argument, the OCI labels of the commit, the local tag; ARCH must be this host's architecture (the pipeline never
# emulates). Hands on the pinned tool images, the scan flags (shared with the rescan), the ignore files of the tree and
# allow-critical. Writes OUT/local-tag and OUT/platform.
leg() {
  [ $# -eq 3 ] || fail "usage: image-guard.sh leg IMAGE ARCH OUT"
  local image=$1 arch=$2 out=$3 rev file build_arg='' context=$code_root allow=false labels
  use_build_source "$image"
  check_code_tree
  rev=$(git -C "$code_root" rev-parse HEAD)
  case $image in
  drill-vulnerable) file=$script_root/deploy/ci/drill/vulnerable.Dockerfile allow=true ;;
  # Built exactly like a clean service (the gateway's code) so the only difference with a release is what CI leaves
  # out: drill-unsigned is pushed with no signature, drill-no-provenance is signed and attested vuln like a release but
  # never attested provenance.
  drill-unsigned | drill-no-provenance) file=$script_root/$(dockerfile gateway) build_arg=SERVICE=gateway ;;
  *)
    if [ "$code_root" = "$script_root" ]; then
      printf '%s\n' "${built_services[@]}" | grep -qxF -- "$image" ||
        fail "$image is not an image this repository builds (${built_services[*]}): its source is another repository's"
      file=$code_root/$(dockerfile "$image")
    else
      # Another repository's tree is one image: its Dockerfile at the top, the whole tree its context.
      require_code_files Dockerfile pnpm-lock.yaml .trivyignore.yaml .grype.yaml
      file=$code_root/Dockerfile
    fi
    case $image in
    media-worker) ;;
    # Both architectures of a commit get the same id, which Next uses as its deploymentId and the server as its
    # release name.
    web) build_arg=SVP_BUILD_ID=${rev:0:12} ;;
    *) build_arg=SERVICE=$image ;;
    esac
    ;;
  esac
  [ "$(runner_arch)" = "$arch" ] || fail "this host builds $(runner_arch), not $arch: the pipeline never emulates"
  mkdir -p "$out" || fail "create $out"
  out=$(cd "$out" && pwd)
  labels=$(oci_labels "$build_source_name" | paste -sd' ' -)
  echo "${SVP_LOCAL_REPO:-svp-ci}/$image:${rev:0:12}-$arch" >"$out/local-tag"
  echo "linux/$arch" >"$out/platform"

  step_output out "$out"
  step_output label "$image linux/$arch"
  step_output dockerfile "$file"
  step_output context "$context"
  step_output build-arg "$build_arg"
  step_output labels "$labels"
  step_output tag "$(cat "$out/local-tag")"
  step_output allow-critical "$allow"
  step_output trivy-image "$(tool_image TRIVY_IMAGE)"
  step_output syft-image "$(tool_image SYFT_IMAGE)"
  step_output grype-image "$(tool_image GRYPE_IMAGE)"
  step_output trivy-scan-args "$(trivy_scan_args | paste -sd' ' -)"
  if [ -f "$trivyignore" ]; then step_output trivyignore "$trivyignore"; else step_output trivyignore ""; fi
  if [ -f "$grypeignore" ]; then step_output grypeignore "$grypeignore"; else step_output grypeignore ""; fi
}

# trivy-report LABEL OUT: OUT/trivy.json must be a trivy image report (exit 2 otherwise: the scan could not be read);
# prints its counts and writes the two halves the gate reads apart, OUT/gate/vulnerabilities.json without the secrets
# and OUT/gate/secrets.json without the vulnerabilities, so neither pass counts the other's findings.
trivy_report() {
  [ $# -eq 2 ] || fail "usage: image-guard.sh trivy-report LABEL OUT"
  local label=$1 report=$2/trivy.json critical high secrets
  jq -e '.SchemaVersion == 2 and (.Metadata.ImageID | test("^sha256:[0-9a-f]{64}$"))' "$report" >/dev/null 2>&1 || {
    echo "FAIL  $label: $report is not a trivy image JSON report (SchemaVersion 2 with Metadata.ImageID)" >&2
    exit 2
  }
  read -r critical high secrets < <(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] as $s
    | [([$s[] | select(. == "CRITICAL")] | length), ([$s[] | select(. == "HIGH")] | length),
      ([.Results[]?.Secrets[]?] | length)] | @tsv' "$report")
  summary "$label (trivy): CRITICAL $critical, HIGH $high, secrets $secrets"
  mkdir -p "$2/gate" || fail "create $2/gate"
  jq 'del(.Results[]?.Secrets)' "$report" >"$2/gate/vulnerabilities.json" &&
    jq 'del(.Results[]?.Vulnerabilities)' "$report" >"$2/gate/secrets.json" || fail "split $report"
}

# grype-summary LABEL OUT: the counts of OUT/grype.json (the report of a grype run that answered), each Critical match
# with its fix, and the packages syft found outside a package manager (the node binary of the web image), which only
# grype scans.
grype_summary() {
  [ $# -eq 2 ] || fail "usage: image-guard.sh grype-summary LABEL OUT"
  local label=$1 report=$2/grype.json critical high excepted
  read -r critical high excepted < <(jq -r '[([.matches[] | select(.vulnerability.severity == "Critical")] | length),
    ([.matches[] | select(.vulnerability.severity == "High")] | length), (.ignoredMatches // [] | length)] | @tsv' \
    "$report")
  summary "$label (grype): Critical $critical, High $high, excepted by .grype.yaml $excepted"
  if [ "$critical" -gt 0 ]; then
    jq -r '.matches[] | select(.vulnerability.severity == "Critical")
      | "critical  \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) \(.artifact.purl // "no purl")"
        + " (fixed: \(.vulnerability.fix.versions // [] | join(", ") | if . == "" then "none" else . end))"' \
      "$report" | step_summary_tee >&2
  fi
  [ ! -f "$2/sbom.spdx.json" ] ||
    echo "binaries outside a package manager: $(sbom_binaries "$2/sbom.spdx.json" | sed 's/^$/none/')"
}

# sarif IMAGE ARCH OUT: OUT/trivy.sarif from OUT/trivy.sarif.tmp (trivy convert of the report, HIGH and CRITICAL) and
# OUT/grype.sarif from OUT/grype.sarif.raw when grype wrote one, each under its category for the Security tab.
sarif() {
  [ $# -eq 3 ] || fail "usage: image-guard.sh sarif IMAGE ARCH OUT"
  local out=$3
  jq --arg c "trivy-image-$1-$2/" '.runs[].automationDetails.id = $c' "$out/trivy.sarif.tmp" >"$out/trivy.sarif" ||
    fail "write the SARIF of trivy in $out"
  rm -f "$out/trivy.sarif.tmp"
  [ ! -f "$out/grype.sarif.raw" ] || [ ! -f "$out/grype.json" ] || grype_sarif "$out" "grype-image-$1-$2/"
}

# push IMAGE ARCH OUT: OUT holds the scan of linux/ARCH, its config digest is the ImageID of the report, and the local
# image is still that one (nothing re-tagged it since); prints <prefix>IMAGE:<12 hex of the commit>-ARCH.
push() {
  [ $# -eq 3 ] || fail "usage: image-guard.sh push IMAGE ARCH OUT"
  local image=$1 arch=$2 out=$3 local_tag scanned rev
  use_build_source "$image"
  check_code_tree
  local_tag=$(cat "$out/local-tag") || fail "$out has no local-tag: the leg was not built"
  scanned=$(cat "$out/config-digest") || fail "$out has no config-digest: the leg was not scanned"
  [ "$(jq -r .Metadata.ImageID "$out/trivy.json")" = "$scanned" ] || fail "$out/config-digest is not the scanned image"
  [ "$(cat "$out/platform")" = "linux/$arch" ] || fail "$out holds a scan of $(cat "$out/platform"), not linux/$arch"
  [ "$(docker_ image inspect --format '{{.Id}}' "$local_tag")" = "$scanned" ] ||
    fail "$local_tag is no longer the image that was scanned"
  rev=$(git -C "$code_root" rev-parse HEAD)
  echo "$build_prefix$image:${rev:0:12}-$arch"
}

# pushed IMAGE ARCH OUT: OUT/manifest.json, what the registry serves under the tag just pushed, read back byte for
# byte, is one manifest whose config is the scanned one: docker compresses the layers again on push, so the manifest
# digest differs from the local one, but the config lists the uncompressed digest of every layer. Writes
# OUT/repository and OUT/digest (the sha256 of those bytes); any difference fails the leg before anything is merged.
pushed() {
  [ $# -eq 3 ] || fail "usage: image-guard.sh pushed IMAGE ARCH OUT"
  local image=$1 out=$3 repo digest scanned config
  use_build_source "$image"
  repo=$build_prefix$image
  scanned=$(cat "$out/config-digest")
  digest=sha256:$(shasum -a 256 "$out/manifest.json" | cut -d' ' -f1)
  config=$(jq -r 'select(.mediaType == "application/vnd.oci.image.manifest.v1+json"
      or .mediaType == "application/vnd.docker.distribution.manifest.v2+json") | .config.digest' "$out/manifest.json" \
    2>/dev/null) || config=
  [ "$config" = "$scanned" ] ||
    fail "$repo@$digest has config ${config:-<not a single manifest>}, the scan had $scanned: not the scanned image"
  echo "$repo" >"$out/repository"
  echo "$digest" >"$out/digest"
  echo "ok    pushed $repo as $digest, config $scanned as scanned"
}

# legs IMAGE LEGS: sets a and b to the two leg folders the artifacts of IMAGE were downloaded to (leg-IMAGE-amd64,
# leg-IMAGE-arm64 under LEGS); an image with a failed leg has not both.
legs() {
  a=$2/leg-$1-amd64 b=$2/leg-$1-arm64
  [ -d "$a" ] && [ -d "$b" ] || fail "$1: a leg did not pass (see the build job); no index, no signature, no release"
}

# index IMAGE LEGS: the two legs are pushes of <prefix>IMAGE, one linux/amd64 and one linux/arm64, each with a manifest
# digest; hands on the repository, the tag (12 hex of the commit), the two digests and the annotations of the index.
index() {
  [ $# -eq 2 ] || fail "usage: image-guard.sh index IMAGE LEGS"
  local image=$1 repo dir digest rev a b
  legs "$image" "$2"
  use_build_source "$image"
  check_code_tree
  repo=$build_prefix$image
  for dir in "$a" "$b"; do
    [ "$(cat "$dir/repository")" = "$repo" ] || fail "$dir holds a push to another repository than $repo"
    digest=$(cat "$dir/digest")
    is_digest "$digest" || fail "$dir has no manifest digest"
  done
  [ "$(cat "$a/platform")" = linux/amd64 ] && [ "$(cat "$b/platform")" = linux/arm64 ] ||
    fail "the two legs are not linux/amd64 and linux/arm64"
  rev=$(git -C "$code_root" rev-parse HEAD)
  step_output repository "$repo"
  step_output tag "${rev:0:12}"
  step_output amd64 "$(cat "$a/digest")"
  step_output arm64 "$(cat "$b/digest")"
  step_output annotations "$(oci_labels "$build_source_name" | sed 's/^/index:/' | paste -sd' ' -)"
}

# index-check IMAGE LEGS OUT: OUT/index.json, the index read back under its tag, is an index of exactly the two
# scanned manifests, and the registry serves those very bytes under their digest (check_index). Writes OUT/repository,
# OUT/tag and OUT/digest: the digest that is signed, attested and promoted.
index_check() {
  [ $# -eq 3 ] || fail "usage: image-guard.sh index-check IMAGE LEGS OUT"
  local image=$1 out=$3 repo digest rev a b
  legs "$image" "$2"
  use_build_source "$image"
  check_code_tree
  repo=$build_prefix$image
  rev=$(git -C "$code_root" rev-parse HEAD)
  digest=sha256:$(shasum -a 256 "$out/index.json" | cut -d' ' -f1)
  check_index "$repo" "$digest" "$a" "$b" || fail "$repo@$digest is not an index of exactly the two scanned manifests"
  echo "$repo" >"$out/repository"
  echo "${rev:0:12}" >"$out/tag"
  echo "$digest" >"$out/digest"
  echo "ok    $repo:${rev:0:12} is index $digest of linux/amd64 and linux/arm64"
}

# sign IMAGE OUT: OUT/index (the artifact index-IMAGE) and OUT/legs (leg-IMAGE-*) as image-sign downloads them. The
# index lies under the prefix of the run's source and is IMAGE; a release (not a drill image) is signed only by the
# source's workflow; the index read back holds exactly the two scanned manifests. Writes the vuln predicate of the two
# gating scans to OUT/vuln.json (vuln-predicate.sh, with --allow-critical only for drill-vulnerable), then reads the
# bundles each digest has, and hands on what to write: sign, sbom-amd64, sbom-arm64, vuln (true when none of that type
# is there), provenance (a release whose index has no provenance yet), with repository, digest, amd64, arm64,
# predicate, out (OUT as an absolute path, which the cosign container mounts at that path) and cosign-image (the
# pinned COSIGN_IMAGE).
sign() {
  [ $# -eq 2 ] || fail "usage: image-guard.sh sign IMAGE OUT"
  local image=$1 out=$2 repo digest name release=true flags=() builder format have have_child child dir arch a b cosign
  out=$(cd "$out" && pwd) || fail "$2 is not a folder"
  cosign=$(tool_image COSIGN_IMAGE) || exit 1
  repo=$(cat "$out/index/repository") digest=$(cat "$out/index/digest")
  use_build_source
  case $repo in "$build_prefix"*) ;; *) fail "$repo is not under $build_prefix, the prefix of release source $build_source_name this run builds for" ;; esac
  name=${repo#"$build_prefix"}
  use_build_source "$name"
  [ "$name" = "$image" ] || fail "the index is of $repo, not of image $image"
  legs "$image" "$out/legs"
  is_digest "$digest" || fail "$out/index has no index digest"
  jq -e --arg i "$image" '.drillImages | index($i)' <<<"$build_source" >/dev/null && release=false
  # Only the drill image may carry CRITICAL into its attestation; vuln-predicate.sh refuses one for every other.
  [ "$image" != drill-vulnerable ] || [ "$release" = true ] || flags=(--allow-critical)
  if [ "$release" = true ]; then
    sign_identity "$build_source_name"
    builder=$(run_builder_id)
    [ "$builder" = "$sign_subject" ] ||
      fail "this run is the workflow '$builder', but releases of source $build_source_name are signed only as $sign_subject"
  fi
  check_index "$repo" "$digest" "$a" "$b" || fail "$repo@$digest is not an index of exactly the two scanned manifests"
  "$ci_dir/vuln-predicate.sh" ${flags[@]+"${flags[@]}"} "$out/vuln.json" "$a" "$b" ||
    fail "build the vuln predicate of $repo@$digest"

  format=$(release_format "$repo@$digest") || fail "read how $repo@$digest is signed (above)"
  [ "$format" != legacy ] ||
    fail "$repo@$digest carries cosign's older format already: one digest never carries both, nothing written"
  have=$(bundle_referrers "$repo@$digest") || fail "list the bundles of $repo@$digest"
  step_output repository "$repo"
  step_output digest "$digest"
  step_output out "$out"
  step_output cosign-image "$cosign"
  step_output predicate "$out/vuln.json"
  step_output sign "$(missing "$have" "$sign_predicate_type" "$repo@$digest has its signature already")"
  for dir in "$a" "$b"; do
    arch=${dir##*-}
    child=$(cat "$dir/digest")
    have_child=$(bundle_referrers "$repo@$child") || fail "list the bundles of $repo@$child"
    step_output "$arch" "$child"
    step_output "sbom-$arch" "$(missing "$have_child" "$sbom_predicate_type" "$repo@$child has its SBOM already")"
  done
  step_output vuln "$(missing "$have" "$vuln_predicate_type" "$repo@$digest has its vuln attestation already")"
  if [ "$release" = true ]; then
    step_output provenance "$(missing "$have" "$provenance_predicate_type" "$repo@$digest has its provenance already")"
  else
    step_output provenance false
  fi
}
# missing LIST TYPE NOTE: prints true when LIST (lines of bundle_referrers) holds no bundle of predicate type TYPE,
# otherwise false, and NOTE as a skip line on stderr.
missing() {
  if [ -n "$(bundles_of "$2" <<<"$1")" ]; then
    echo "skip  $3" >&2
    echo false
  else
    echo true
  fi
}

[ $# -gt 0 ] || fail "usage: image-guard.sh leg|trivy-report|grype-summary|sarif|push|pushed|index|index-check|sign ..."
command=$1
shift
case $command in
leg) leg "$@" ;;
trivy-report) trivy_report "$@" ;;
grype-summary) grype_summary "$@" ;;
sarif) sarif "$@" ;;
push) push "$@" ;;
pushed) pushed "$@" ;;
index) index "$@" ;;
index-check) index_check "$@" ;;
sign) sign "$@" ;;
*) fail "image-guard.sh: unknown command $command" ;;
esac
