#!/usr/bin/env bash
# Tests for deploy/ci/ghcr-digest.sh: each case sources the script in a subshell with a fake ghcr_oras (the pinned ORAS
# against GHCR) and a throwaway git repository for the code repository. Runs on macOS and Linux: no network, no Docker.

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
printf '%s\n' "${build:0:12}" "${release:0:12}-amd64" "${release:0:12}" 0123456789ab sha256-abc.att >"$work/tags"
digest=sha256:$(sha 'newest index')

# run IMAGE [RESOLVED]: runs newest IMAGE of the script in a subshell with a fake ghcr_oras (oras resolve of the newest
# tag answers RESOLVED, by default $digest), prints its output and exit status
# ("<output> rc=<n>").
# Into a file, not a command substitution: bash 3.2 misreads the case patterns of a function inside one.
run() {
  local rc=0 image=$1 resolved=${2:-$digest}
  mkdir -p "$work/dir"
  (
    . "$here/ghcr-digest.sh"
    repo_root=$repo
    ghcr_oras() {
      case "$*" in
      "repo tags ghcr.io/anhnvcoder/svp-backend/$image") cat "$work/tags" ;;
      "resolve ghcr.io/anhnvcoder/svp-backend/$image:${release:0:12}") echo "$resolved" ;;
      *) return 1 ;;
      esac
    }
    newest "$image" "$work/dir"
  ) >"$work/run.out" 2>&1 || rc=$?
  echo "$(cat "$work/run.out") rc=$rc"
}

got=$(run drill-vulnerable)
same "newest: the index of the newest commit's tag, by the digest oras resolve answers" \
  "ghcr.io/anhnvcoder/svp-backend/drill-vulnerable@$digest rc=0" "$got"
got=$(run drill-vulnerable "not a digest")
has "newest: an answer of oras resolve that is no sha256 digest fails" "$got" "does not serve"
got=$(run 'bad/name')
has "newest: a name that is no image name fails" "$got" "is not an image name"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
