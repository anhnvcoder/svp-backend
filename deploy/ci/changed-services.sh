#!/usr/bin/env bash
# changed-services.sh BASE HEAD: prints, on one line in alphabetical order, the services whose image must be built
# for the changes from commit BASE to commit HEAD; the reason goes to stderr.
#
# The services are the six this repository builds (built_services of deploy/k8s/lib.sh, the targets of the image table
# deploy/docker-bake.json): web is built by svp-frontend, so no change here ever builds it. A service is built when a
# changed path is one of its image paths (`image_paths` of deploy/k8s/lib.sh: go.mod, go.sum, gen/, internal/,
# services/<svc>/, its Dockerfile, .dockerignore), when its target of the image table changed (compared as JSON between
# the two commits), or when the pipeline that builds, scans and signs changed: then all six. Any other change of the
# image table (group default, a target no service of either commit names, anything outside the targets), or a table
# that BASE does not have, is a change of the pipeline too.
# The pipeline is .github/workflows/images.yml, the composite actions it builds, scans and signs with
# (.github/actions/image-*/), anything under deploy/ci/ but the files no image job reads:
# trivy-config-ignore.yaml (read only by make trivy-config, so renewing one of its entries, due every 90 days at most,
# releases nothing), the scripts of the verification runs of .github/workflows/verify.yml (verify-host.sh,
# verify-mask.sh, verify-collect.sh, the scripts of its steps under deploy/ci/verify-steps/, ghcr-digest.sh, which the
# supply chain step and drill call), every test *-test.sh (run by the jobs
# of ci.yml and on a machine) and the fixtures of tests under testdata/, the scripts of svp-gitops's check:
# gitops-check.sh (svp-gitops's check and make helm-check) with values-check.sh and verify-release.sh,
# which only it, make k8s-gitops-up and the drills run, its Kyverno policies gitops-policies/ and conftest policies
# gitops-tree-policies/,
# contract.sh (the version rule and
# the publishing of the gateway's API contract: job contract of images.yml runs it, but it builds and promotes no
# image), the conftest policies on the ignore files ignorefile-policies/ (the gate applies them, but job config checks
# the files with them on every pull request, as it does a change of the files themselves); the helpers deploy/ci/ sources from deploy/k8s/lib.sh still count (docker_, values_field,
# ghcr_prefix, the image table), and the lines of the Makefile pinning the images the gate runs (TRIVY_IMAGE,
# SYFT_IMAGE, GRYPE_IMAGE, COSIGN_IMAGE); other Makefile changes do not count. So the weekly Renovate pull request that
# bumps those tools builds and scans every image with the new trivy or grype before it merges, instead of the next
# daily rescan on main meeting it first. The cost is on main too: such a change releases all six images again (and opens their promote
# pull request) although no service code changed. Comparing is only done when BASE is HEAD or an ancestor of it:
#   - BASE empty, all zeros, unknown to this clone, or not comparable with HEAD (force push, rewritten history): all
#     six. Building too much costs runner minutes; missing a change would ship an image without it.
#   - HEAD a proper ancestor of BASE (an older run started again after a newer one succeeded): nothing, the newer run
#     built every change up to its own commit.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 2 ] || fail "usage: changed-services.sh BASE HEAD"
head=$(git -C "$repo_root" rev-parse --verify --quiet "$2^{commit}") || fail "HEAD $2 is not a commit of this clone"

all() {
  echo "build every service: $1" >&2
  printf '%s\n' "${built_services[@]}" | sort | paste -sd' ' -
  exit 0
}

case $1 in
'' | *[!0]*) ;;
*) all "no base commit" ;;
esac
[ -n "$1" ] || all "no base commit"
base=$(git -C "$repo_root" rev-parse --verify --quiet "$1^{commit}") || all "base $1 is not in this clone's history"
if [ "$base" = "$head" ]; then
  echo "nothing to build: base is HEAD" >&2
  echo
  exit 0
fi
if ! git -C "$repo_root" merge-base --is-ancestor "$base" "$head"; then
  if git -C "$repo_root" merge-base --is-ancestor "$head" "$base"; then
    echo "nothing to build: HEAD is older than base ${base:0:12}, whose run already built every change up to it" >&2
    echo
    exit 0
  fi
  all "base ${base:0:12} is not an ancestor of HEAD (history rewritten or force pushed)"
fi

# --no-renames lists both sides of a rename, so a file moved out of a service's tree still counts for it.
changed=$(git -C "$repo_root" diff --name-only --no-renames "$base" "$head") ||
  fail "list the files changed since $base"

# under PATH PREFIX: true when PATH is PREFIX or lies inside the directory PREFIX.
under() { [ "$1" = "$2" ] || [ "${1#"$2"/}" != "$1" ]; }

picked=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case $path in
  deploy/ci/trivy-config-ignore.yaml | deploy/ci/verify-host.sh | \
    deploy/ci/verify-mask.sh | deploy/ci/verify-collect.sh | deploy/ci/ghcr-digest.sh | \
    deploy/ci/verify-steps/* | deploy/ci/*-test.sh | deploy/ci/testdata/* | \
    deploy/ci/gitops-check.sh | deploy/ci/values-check.sh | deploy/ci/verify-release.sh | \
    deploy/ci/contract.sh | deploy/ci/gitops-policies/* | deploy/ci/gitops-tree-policies/* | deploy/ci/ignorefile-policies/*)
    continue
    ;;
  esac
  if under "$path" .github/workflows/images.yml || [[ $path == .github/actions/image-*/* ]] ||
    under "$path" deploy/ci || under "$path" deploy/k8s/lib.sh; then
    all "the image pipeline changed ($path)"
  fi
done <<<"$changed"
# -G keeps the Makefile only when an added or removed line of its diff is one of the four pins.
tools=$(git -C "$repo_root" diff --name-only --no-renames -G '^(TRIVY|SYFT|GRYPE|COSIGN)_IMAGE[[:space:]]*:=' \
  "$base" "$head" -- Makefile) || fail "compare the tool images of the Makefile since $base"
[ -z "$tools" ] || all "the image pipeline changed (a tool image pinned in the Makefile)"
# The image table: the services whose target differs between the two commits, or all.
table_hits=
if grep -qxF -- "$image_table" <<<"$changed"; then
  old=$(git -C "$repo_root" show "$base:$image_table" 2>/dev/null) ||
    all "the image pipeline changed (the image table $image_table is new since ${base:0:12})"
  new=$(git -C "$repo_root" show "$head:$image_table") || fail "read the image table $image_table at ${head:0:12}"
  table_hits=$(jq -nr --argjson old "$old" --argjson new "$new" '
    [$old, $new | .group.default.targets // [] | .[]] | unique as $svcs
    | if ($old | del(.target[$svcs[]])) != ($new | del(.target[$svcs[]])) then "*"
      else $svcs[] | select($old.target[.] != $new.target[.]) end') ||
    fail "compare the image table $image_table of ${base:0:12} and ${head:0:12}"
  ! grep -qxF '*' <<<"$table_hits" ||
    all "the image pipeline changed (the image table $image_table, outside the targets of the services)"
fi
for svc in "${built_services[@]}"; do
  hit=
  while IFS= read -r prefix; do
    while IFS= read -r path; do
      [ -n "$path" ] && under "$path" "$prefix" && hit=$path && break
    done <<<"$changed"
    [ -z "$hit" ] || break
  done < <(image_paths "$svc")
  [ -n "$hit" ] || ! grep -qxF -- "$svc" <<<"$table_hits" || hit="$image_table (target $svc)"
  if [ -n "$hit" ]; then
    picked+=("$svc")
    echo "build $svc: $hit changed" >&2
  fi
done
[ ${#picked[@]} -gt 0 ] || echo "nothing to build: no image path changed since ${base:0:12}" >&2
if [ ${#picked[@]} -gt 0 ]; then printf '%s\n' "${picked[@]}" | sort | paste -sd' ' -; else echo; fi
