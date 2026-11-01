#!/usr/bin/env bash
# Tests for deploy/ci/ghcr-digest.sh. Each case sources the script in a subshell and replaces ghcr_get (GHCR) with a
# fake that serves made-up answers, so nothing reaches the network. A throwaway git repository stands for the code
# repository, with a build commit and a later one. Checked:
#   - newest picks the tag of the newest commit of the clone, past tags that are no commit of it, and prints the
#     digest of the bytes GHCR answers its manifest with;
#   - newest of a name that is no image name fails.
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

# The code repository: a build commit and a later one.
repo=$work/repo
g() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"; }
git init -q --initial-branch=main "$repo"
g commit -q --allow-empty -m build
build=$(g rev-parse HEAD)
g commit -q --allow-empty -m later
release=$(g rev-parse HEAD)

# Tags of an image: the build commit (older), the release commit (newer), tags that are no commit of the clone.
jq -nc --arg old "${build:0:12}" --arg new "${release:0:12}" \
  '{tags: [$old, ($new + "-amd64"), $new, "0123456789ab", "sha256-abc.att"]}' >"$work/tags.json"

# run IMAGE: runs newest IMAGE of the script in a subshell with a fake ghcr_get, prints its output and exit status
# ("<output> rc=<n>").
# Into a file, not a command substitution: bash 3.2 misreads the case patterns of a function inside one.
run() {
  local rc=0
  mkdir -p "$work/dir"
  (
    . "$here/ghcr-digest.sh"
    repo_root=$repo
    ghcr_get() {
      case $2 in
      "tags/list?n=1000") cp "$work/tags.json" "$3" ;;
      "manifests/${release:0:12}") printf '%s' "newest index" >"$3" ;;
      *) return 1 ;;
      esac
    }
    newest "$1" "$work/dir"
  ) >"$work/run.out" 2>&1 || rc=$?
  echo "$(cat "$work/run.out") rc=$rc"
}

got=$(run drill-vulnerable)
same "newest: the index of the newest commit's tag, by the digest of its bytes" \
  "ghcr.io/anhnvcoder/svp-backend/drill-vulnerable@sha256:$(sha 'newest index') rc=0" "$got"
got=$(run 'bad/name')
has "newest: a name that is no image name fails" "$got" "is not an image name"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
