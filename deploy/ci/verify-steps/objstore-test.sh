#!/usr/bin/env bash
# Tests for deploy/ci/verify-steps/objstore.sh over the output of a fake make first on PATH (it logs its arguments,
# prints a made-up go test -v output and exits with the status asked for): a unit test and the eight integration tests
# pass, one with a subtest; then a subtest skipped, an integration test missing, go test failing. Runs on macOS and
# Linux: no network, no Docker, no stack.
#
# Usage, from anywhere: deploy/ci/verify-steps/objstore-test.sh
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
same() { if [ "$3" = "$2" ]; then ok "$1"; else fail "$1: want '$2', got '$3'"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/make" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_MAKE_LOG"
cat "$FAKE_MAKE_OUT"
exit "${FAKE_MAKE_RC:-0}"
EOF
chmod 755 "$work/bin/make"

# objstore NAME [LINE...]: objstore.sh over the passing output plus LINEs (DROP_TEST leaves a test out, FAKE_FAIL makes
# make fail with 2); prints ok or fail, then its summary line. Its output in $work/NAME.log, the make calls in
# $work/NAME.make.
objstore() {
  local name=$1 t status=ok
  shift
  {
    for t in TestNewRejectsMissingConfig TestIntegrationPresignedPost TestIntegrationWorkerPermissions \
      TestIntegrationVideoServicePermissions TestIntegrationDeletePrefix TestIntegrationMultipartChecksum \
      TestIntegrationCacheControl TestIntegrationCreateOnce TestIntegrationWorkerReadsMedia; do
      [ "${DROP_TEST:-}" = "$t" ] || printf '=== RUN   %s\n--- PASS: %s (0.10s)\n' "$t" "$t"
    done
    echo '    --- PASS: TestIntegrationPresignedPost/valid_form (0.01s)'
    [ "$#" = 0 ] || printf '%s\n' "$@"
    printf 'ok  \tgithub.com/anhnvcoder/svp-backend/internal/objstore\t1.2s\n'
  } >"$work/$name.out"
  : >"$work/$name.make"
  PATH="$work/bin:$PATH" FAKE_MAKE_LOG="$work/$name.make" FAKE_MAKE_OUT="$work/$name.out" \
    FAKE_MAKE_RC="${FAKE_FAIL:+2}" "$here/objstore.sh" >"$work/$name.log" 2>&1 </dev/null || status=fail
  printf '%s ' "$status"
  grep '^object store tests: ' "$work/$name.log"
}

same "objstore: passes when every test passes" \
  "ok object store tests: 10 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0" "$(objstore pass)"
same "objstore: runs make test-stack on internal/objstore, once" 'test-stack PKGS=./internal/objstore/...' \
  "$(cat "$work/pass.make")"
grep -qxF -- '--- PASS: TestIntegrationWorkerReadsMedia (0.10s)' "$work/pass.log" &&
  ok "objstore: the output of go test is kept in the step's output" ||
  fail "objstore: the output of go test is kept in the step's output"
same "objstore: a skipped subtest fails it" \
  "fail object store tests: 10 passed, 0 failed, 1 skipped (tests and subtests); make test-stack exit 0" \
  "$(objstore skip '    --- SKIP: TestIntegrationMultipartChecksum/trailer (0.00s)')"
grep -qxF 'FAIL  1 test(s) skipped: every test of the object store must run against it' "$work/skip.log" &&
  ok "objstore: the skip is named" || fail "objstore: the skip is named"
same "objstore: an integration test that did not run fails it" \
  "fail object store tests: 9 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0" \
  "$(DROP_TEST=TestIntegrationMultipartChecksum objstore missing)"
grep -qxF 'FAIL  did not pass: TestIntegrationMultipartChecksum' "$work/missing.log" &&
  ok "objstore: the integration test that did not pass is named" ||
  fail "objstore: the integration test that did not pass is named"
same "objstore: a FAIL line of go test fails it, make passing" \
  "fail object store tests: 10 passed, 1 failed, 0 skipped (tests and subtests); make test-stack exit 0" \
  "$(objstore failed '    --- FAIL: TestIntegrationDeletePrefix/nested (0.00s)')"
same "objstore: go test failing fails it" \
  "fail object store tests: 10 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 2" \
  "$(FAKE_FAIL=1 objstore exit)"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
