#!/usr/bin/env bash
# Two digests GHCR serves to anyone, for the supply chain drill (scenario gitops of deploy/ci/verify/gitops.sh, and
# deploy/k8s/drills/supplychain.sh for case l):
#   ghcr-digest.sh web-amd64
#       Prints <image.repository>@<digest of the linux/amd64 manifest> of the web release Argo CD runs: image.repository
#       and image.digest (an index) of envs/stg/images/web.yaml at origin/<GITOPS_REV, default main> of the clone of
#       svp-gitops gitops_dir names (SVP_GITOPS_DIR, which the scenario's run sets), the web of a release source. A real
#       image of a release source that no signature or attestation names (they name the index), which the drill sends
#       as its unsigned web image.
#   ghcr-digest.sh newest IMAGE
#       Prints ghcr.io/anhnvcoder/svp-backend/IMAGE@<digest> of the newest index of IMAGE (drill-vulnerable,
#       drill-unsigned, drill-no-provenance) on GHCR: its tags of 12 hex digits name the commit of main that CI built
#       them at, and the newest commit of this clone among them wins.
# GHCR is read like a node pulls: an anonymous token for the repository, then the manifest by digest or tag, its bytes
# hashed to the digest asked for. Written for bash 3.2 too (macOS).
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../k8s/lib.sh"
# ci_dispatch_hint: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$(dirname "${BASH_SOURCE[0]}")/platform.sh"

# ghcr_get NAME PATH OUT: GET https://ghcr.io/v2/NAME/PATH (NAME without ghcr.io/) into OUT with an anonymous pull
# token, asking for an index or a manifest of either format. The token goes to curl on stdin, never on a command line.
ghcr_get() {
  local token
  token=$(curl -fsS --max-time 10 "https://ghcr.io/token?scope=repository:$1:pull&service=ghcr.io" |
    jq -r '.token // empty') && [ -n "$token" ] || return 1
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -fsS --max-time 20 -H @- -o "$3" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "https://ghcr.io/v2/$1/$2"
}

# manifest NAME REF OUT: writes the manifest or index NAME:REF (REF a tag or sha256:<64 hex>) to OUT, byte for byte as
# GHCR stores it, and prints the sha256 digest of those bytes; a REF that is a digest must be that digest.
manifest() {
  local got
  ghcr_get "$1" "manifests/$2" "$3" || {
    echo "FAIL  GHCR does not serve ghcr.io/$1 ${2} to an anonymous pull" >&2
    return 1
  }
  got=sha256:$(shasum -a 256 "$3" | cut -d' ' -f1)
  case $2 in
  sha256:*)
    [ "$got" = "$2" ] || {
      echo "FAIL  GHCR answered ghcr.io/$1@$2 with other bytes ($got)" >&2
      return 1
    }
    ;;
  esac
  echo "$got"
}

# web_amd64 DIR: prints <image.repository>@<digest of the linux/amd64 manifest> of the web release (see the header),
# GHCR's answer read into DIR.
web_amd64() {
  local gitops rev rev_sha values repo tag index child file=envs/stg/images/web.yaml
  gitops=$(gitops_dir) || exit 1
  rev="origin/${GITOPS_REV:-main} of svp-gitops"
  rev_sha=$(git -C "$gitops" rev-parse --verify --quiet "refs/remotes/origin/${GITOPS_REV:-main}^{commit}") ||
    fail "origin/${GITOPS_REV:-main} is not in the clone of svp-gitops $gitops"
  values=$(git -C "$gitops" show "$rev_sha:$file") || fail "read $file at $rev (${rev_sha:0:12})"
  repo=$(values_field repository <<<"$values") || fail "read image.repository of $file at $rev"
  release_source_of web "$repo" >/dev/null ||
    fail "image.repository of $file at $rev is '$repo', not a release of web ($(release_repositories web))"
  tag=$(values_field tag <<<"$values") || fail "read image.tag of $file at $rev"
  index=$(values_field digest <<<"$values") || fail "read image.digest of $file at $rev"
  [ -n "$tag" ] && [ -n "$index" ] || fail "$file at $rev names no web release yet (image.tag or image.digest empty)"
  manifest "${repo#ghcr.io/}" "$index" "$1/web-index.json" >/dev/null || exit 1
  child=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest]
    | if length == 1 then .[0] else "" end' "$1/web-index.json") || child=
  [[ $child =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$repo@$index is not an index with one linux/amd64 manifest"
  echo "$repo@$child"
}

# newest IMAGE DIR: see the header; GHCR's answers go to DIR.
newest() {
  local image=$1 tmp=$2 name tag commit commits= best digest
  [[ $image =~ ^[a-z0-9-]+$ ]] || fail "newest: '$image' is not an image name"
  name=${ghcr_prefix#ghcr.io/}/$image
  ghcr_get "$name" "tags/list?n=1000" "$tmp/tags.json" || fail "GHCR does not list the tags of ghcr.io/$name anonymously"
  for tag in $(jq -r '.tags[]? | select(test("^[0-9a-f]{12}$"))' "$tmp/tags.json"); do
    commit=$(git -C "$repo_root" rev-parse --verify --quiet "$tag^{commit}") && [[ $commit == "$tag"* ]] || continue
    commits="$commits $commit"
  done
  [ -n "$commits" ] ||
    fail "ghcr.io/$name has no tag that is a commit of this clone: build it ($(ci_dispatch_hint images.yml main drill=true))"
  # The first of the commits in topological order is one that none of the others descends from: on main, where CI
  # builds them, the newest (two commits of the same second still in their order).
  # shellcheck disable=SC2086 # full SHAs, split on spaces
  best=$(git -C "$repo_root" rev-list --topo-order --max-count=1 $commits) || fail "order the commits of the tags"
  digest=$(manifest "$name" "${best:0:12}" "$tmp/index.json") || exit 1
  echo "$ghcr_prefix/$image@$digest"
}

# Sourced (by deploy/ci/ghcr-digest-test.sh, which replaces ghcr_get), the functions above are all that is defined.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  case ${1:-} in
  web-amd64) web_amd64 "$tmp" ;;
  newest) newest "${2:-}" "$tmp" ;;
  *) fail "usage: ghcr-digest.sh web-amd64 | newest IMAGE" ;;
  esac
fi
