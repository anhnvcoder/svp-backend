#!/usr/bin/env bash
# Tests for who made the predicate deploy/ci/vuln-predicate.sh writes: in a made-up GitHub Actions job, its invocation
# names this attempt of the run, the run id and the workflow file at its ref; on a machine, "local" for each. The two
# platform legs are fixtures in a temporary directory. Runs on macOS and Linux: no network, no Docker, no cluster.

# Usage, from anywhere: deploy/ci/vuln-predicate-test.sh
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
# predicate VAR=VALUE...: vuln-predicate.sh on the two legs with only these GitHub variables; prints the invocation.
predicate() {
  env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT \
    -u GITHUB_WORKFLOW_REF -u SVP_CODE_ROOT "$@" "$here/vuln-predicate.sh" "$work/predicate.json" "$work/leg-amd64" \
    "$work/leg-arm64" >/dev/null
  jq -c .invocation "$work/predicate.json"
}

digest_a=sha256:$(printf 'a%.0s' $(seq 64))
digest_b=sha256:$(printf 'b%.0s' $(seq 64))
for arch in amd64 arm64; do
  d=$work/leg-$arch
  mkdir -p "$d"
  echo "linux/$arch" >"$d/platform"
  echo "$digest_a" >"$d/digest"
  echo "$digest_b" >"$d/config-digest"
  jq -n --arg c "$digest_b" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Trivy: {Version: "0.76.0"}, Results: []}' \
    >"$d/trivy.json"
  for f in scan-started scan-finished db-updated-at; do echo 2026-10-25T01:02:03Z >"$d/$f"; done
done

same "vuln-predicate.sh in a job: invocation names this attempt, the run and the workflow" \
  '{"uri":"https://github.example/octo/repo/actions/runs/4242/attempts/3","event_id":"4242","builder.id":"https://github.example/octo/repo/.github/workflows/images.yml@refs/heads/main","parameters":null}' \
  "$(predicate GITHUB_ACTIONS=true GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example \
    GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main)"
same "vuln-predicate.sh in a job: attempt 1 when GITHUB_RUN_ATTEMPT is unset" \
  https://github.example/octo/repo/actions/runs/4242/attempts/1 \
  "$(predicate GITHUB_ACTIONS=true GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example \
    GITHUB_RUN_ID=4242 GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main | jq -r .uri)"
same "vuln-predicate.sh on a machine: local for each" \
  '{"uri":"local","event_id":"local","builder.id":"local","parameters":null}' "$(predicate)"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
