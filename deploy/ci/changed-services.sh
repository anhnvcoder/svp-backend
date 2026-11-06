#!/usr/bin/env bash
# changed-services.sh BASE HEAD: prints, on one line in alphabetical order, the services whose image must be built for
# the changes from commit BASE to commit HEAD; the reason goes to stderr.
# Design notes: docs/reference/ci.md.

# The services are the six of built_services (deploy/k8s/lib.sh); web is built by svp-frontend, so no change here builds
# it. A service is built when a changed path is in its image_paths or its target of the image table changed; a change of
# the pipeline that builds, scans and signs (images.yml, the actions image-*, deploy/ci/ but the files no image job
# reads, deploy/k8s/lib.sh, the tool images pinned in the Makefile, the rest of the image table) builds all six.

# So a Renovate bump of trivy or grype builds and scans every image before it merges, not the daily rescan on main
# first; the cost is a full release on main too. BASE empty, unknown or not comparable with HEAD (force push): all six,
# since a missed change would ship an image without it. HEAD a proper ancestor of BASE (an older run started again):
# nothing.
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
