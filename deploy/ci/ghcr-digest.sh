#!/usr/bin/env bash
# A digest GHCR serves to anyone, for the supply chain drill (step drill-k8s-supplychain of .github/workflows/verify.yml, deploy/ci/verify-steps/supplychain.sh, and
# deploy/k8s/drills/run.sh with the tests of deploy/k8s/drills/supplychain/ for cases b, h, i and l):
#   ghcr-digest.sh newest IMAGE
#       Prints ghcr.io/anhnvcoder/svp-backend/IMAGE@<digest> of the newest index of IMAGE (drill-vulnerable,
#       drill-unsigned, drill-no-provenance) on GHCR: its tags of 12 hex digits name the commit of main that CI built
#       them at, and the newest commit of this clone among them wins.
# GHCR is read like a node pulls, anonymously, with the pinned ORAS (ORAS_IMAGE of the Makefile): oras repo tags for
# the tags, oras resolve for the digest of one. Written for bash 3.2 too (macOS).
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ghcr_oras ARGS...: the pinned ORAS with ARGS, as the calling user, with no credentials.
ghcr_oras() {
  local image
  image=$(tool_image ORAS_IMAGE) || return 1
  docker_ run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp "$image" "$@"
}

# newest IMAGE DIR: see the header; GHCR's answers go to DIR.
newest() {
  local image=$1 tmp=$2 name tag commit commits= best digest
  [[ $image =~ ^[a-z0-9-]+$ ]] || fail "newest: '$image' is not an image name"
  name=${ghcr_prefix#ghcr.io/}/$image
  ghcr_oras repo tags "ghcr.io/$name" >"$tmp/tags" || fail "GHCR does not list the tags of ghcr.io/$name anonymously"
  for tag in $(grep -xE '[0-9a-f]{12}' "$tmp/tags" || true); do
    commit=$(git -C "$repo_root" rev-parse --verify --quiet "$tag^{commit}") && [[ $commit == "$tag"* ]] || continue
    commits="$commits $commit"
  done
  [ -n "$commits" ] ||
    fail "ghcr.io/$name has no tag that is a commit of this clone: build it (gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f drill=true)"
  # The first of the commits in topological order is one that none of the others descends from: on main, where CI
  # builds them, the newest (two commits of the same second still in their order).
  # shellcheck disable=SC2086 # full SHAs, split on spaces
  best=$(git -C "$repo_root" rev-list --topo-order --max-count=1 $commits) || fail "order the commits of the tags"
  digest=$(ghcr_oras resolve "ghcr.io/$name:${best:0:12}") && [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "GHCR does not serve ghcr.io/$name:${best:0:12} to an anonymous pull"
  echo "$ghcr_prefix/$image@$digest"
}

# Sourced (by deploy/ci/ghcr-digest-test.sh, which replaces ghcr_oras), the functions above are all that is defined.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  case ${1:-} in
  newest) newest "${2:-}" "$tmp" ;;
  *) fail "usage: ghcr-digest.sh newest IMAGE" ;;
  esac
fi
