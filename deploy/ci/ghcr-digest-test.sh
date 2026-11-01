#!/usr/bin/env bash
# Tests for deploy/ci/ghcr-digest.sh. Each case sources the script in a subshell and replaces ghcr_get (GHCR) with a
# fake that serves made-up answers, so nothing reaches the network. Two throwaway git repositories stand for the
# project's: the code repository, with a build commit and a later one, and the deployment configuration svp-gitops
# (remote origin named as the real one, never fetched), whose origin/main holds envs/stg/images/web.yaml. Checked:
#   - GHCR answering a digest with other bytes than the digest names fails (web-amd64);
#   - web-amd64 prints the repository and the digest of the linux/amd64 manifest of the index;
#   - web-amd64 of a repository that is no release of web in the table of release sources fails;
#   - newest picks the tag of the newest commit of the clone, past tags that are no commit of it.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/ghcr-digest-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# same NAME WANT GOT: ok when the two strings are equal; shows both otherwise.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
# has NAME HAYSTACK NEEDLE: ok when HAYSTACK holds NEEDLE.
has() {
  case $2 in *"$3"*) ok "$1" ;; *) fail "$1"$'\n'"      want in: $2"$'\n'"      the text: $3" ;; esac
}

sha() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
child=sha256:$(sha amd64-manifest)
arm=sha256:$(sha arm64-manifest)

# The release: an index of two manifests, its digest the sha256 of its bytes.
jq -nc --arg a "$child" --arg b "$arm" '{schemaVersion: 2,
  mediaType: "application/vnd.oci.image.index.v1+json",
  manifests: [{digest: $a, platform: {os: "linux", architecture: "amd64"}},
    {digest: $b, platform: {os: "linux", architecture: "arm64"}}]}' >"$work/index.json"
index=sha256:$(shasum -a 256 "$work/index.json" | cut -d' ' -f1)
printf '%s ' "$(cat "$work/index.json")" >"$work/index-changed.json"

# The code repository: a build commit and a later one, with the table of release sources of the working tree.
repo=$work/repo
g() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"; }
git init -q --initial-branch=main "$repo"
g commit -q --allow-empty -m build
build=$(g rev-parse HEAD)
g commit -q --allow-empty -m later
release=$(g rev-parse HEAD)
mkdir -p "$repo/deploy/helm/svp-policy/files"
cp "$here/../helm/svp-policy/files/sources.json" "$repo/deploy/helm/svp-policy/files/sources.json"

# The configuration: origin/main names the web release; the working tree names another, which must not be read.
config=$work/gitops
c() { git -C "$config" -c user.name=test -c user.email=test@example.invalid "$@"; }
# web_file REPOSITORY: an image file of the web release at the build commit and the index above.
web_file() { printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' "$1" "${build:0:12}" "$index"; }
git init -q --initial-branch=main "$config"
c remote add origin https://github.com/anhnvcoder/svp-gitops.git
mkdir -p "$config/envs/stg/images"
web_file ghcr.io/anhnvcoder/svp-frontend/web >"$config/envs/stg/images/web.yaml"
c add envs
c commit -q -m release
c update-ref refs/remotes/origin/main "$(c rev-parse HEAD)"
web_file ghcr.io/anhnvcoder/svp-frontend/uncommitted >"$config/envs/stg/images/web.yaml"

# Tags of an image: the build commit (older), the release commit (newer), tags that are no commit of the clone.
jq -nc --arg old "${build:0:12}" --arg new "${release:0:12}" \
  '{tags: [$old, ($new + "-amd64"), $new, "0123456789ab", "sha256-abc.att"]}' >"$work/tags.json"

# run MODE [ARG]: runs web_amd64 or newest of the script in a subshell with a fake ghcr_get, prints its output and
# exit status ("<output> rc=<n>"). The fake reads:
#   FAKE_INDEX   the file GHCR answers the index with (default the index above)
#   FAKE_NEWEST  the bytes GHCR answers the manifest of the newest commit's tag with
# Into a file, not a command substitution: bash 3.2 misreads the case patterns of a function inside one.
run() {
  local rc=0
  mkdir -p "$work/dir"
  (
    . "$here/ghcr-digest.sh"
    repo_root=$repo
    export SVP_GITOPS_DIR=$config
    ghcr_get() {
      case $2 in
      "manifests/$index") cp "${FAKE_INDEX:-$work/index.json}" "$3" ;;
      "tags/list?n=1000") cp "$work/tags.json" "$3" ;;
      "manifests/${release:0:12}") printf '%s' "${FAKE_NEWEST:-newest index}" >"$3" ;;
      *) return 1 ;;
      esac
    }
    case $1 in
    web-amd64) web_amd64 "$work/dir" ;;
    newest) newest "$2" "$work/dir" ;;
    esac
  ) >"$work/run.out" 2>&1 || rc=$?
  echo "$(cat "$work/run.out") rc=$rc"
}

got=$(run web-amd64)
same "web-amd64: the linux/amd64 manifest of the release" \
  "ghcr.io/anhnvcoder/svp-frontend/web@$child rc=0" "$got"

got=$(FAKE_INDEX=$work/index-changed.json run web-amd64)
has "web-amd64: GHCR answering the index with other bytes fails" "$got" "with other bytes"
has "web-amd64: GHCR answering with other bytes exits 1" "$got" "rc=1"

# A release of web under the prefix of no release source of it.
web_file ghcr.io/anhnvcoder/svp-web/web >"$config/envs/stg/images/web.yaml"
c commit -q -am "web of another source"
c update-ref refs/remotes/origin/main "$(c rev-parse HEAD)"
got=$(run web-amd64)
has "web-amd64: a repository that is no release of web fails" "$got" \
  "is 'ghcr.io/anhnvcoder/svp-web/web', not a release of web (ghcr.io/anhnvcoder/svp-frontend/web)"
has "web-amd64: a repository that is no release of web exits 1" "$got" "rc=1"

got=$(run newest drill-vulnerable)
same "newest: the index of the newest commit's tag, by the digest of its bytes" \
  "ghcr.io/anhnvcoder/svp-backend/drill-vulnerable@sha256:$(sha 'newest index') rc=0" "$got"
got=$(run newest 'bad/name')
has "newest: a name that is no image name fails" "$got" "is not an image name"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
