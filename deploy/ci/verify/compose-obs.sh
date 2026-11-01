# shellcheck shell=bash
# Scenario compose-obs of deploy/ci/verify-run.sh, which sources this file: the compose stack with OBS=lgtm (job compose
# of .github/workflows/verify.yml). make up OBS=lgtm, make smoke, make drill-obs-threats, then the object store's own
# tests against the stack (make test-stack of internal/objstore), the one place they run instead of skipping.
#
# Steps that are not a make target of their own:
#   test-stack-objstore        make test-stack PKGS=./internal/objstore/... (go test -race -count=1 -v against the
#                              stack's object store), its output counted: fails when go test fails, when any test or
#                              subtest SKIPs (a skipped case proves nothing about the store), or when one of the
#                              integration tests (presigned POST, worker and video-service permissions, DeletePrefix,
#                              multipart with CRC32, Cache-Control read back anonymously, create only once, the
#                              worker listing and reading media/) did not PASS

build=up
job_minutes_default=90
k3d=0

# --- Steps of their own; exported, since timeout runs them in a new bash.

# objstore_tests: see test-stack-objstore in the header.
objstore_tests() {
  local tmp rc passes fails skips missing= t
  tmp=$(mktemp)
  make test-stack PKGS=./internal/objstore/... 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  passes=$(grep -cE '^ *--- PASS: ' "$tmp")
  fails=$(grep -cE '^ *--- FAIL: ' "$tmp")
  skips=$(grep -cE '^ *--- SKIP: ' "$tmp")
  for t in TestIntegrationPresignedPost TestIntegrationWorkerPermissions TestIntegrationVideoServicePermissions \
    TestIntegrationDeletePrefix TestIntegrationMultipartChecksum TestIntegrationCacheControl TestIntegrationCreateOnce \
    TestIntegrationWorkerReadsMedia; do
    grep -qE "^--- PASS: $t " "$tmp" || missing="$missing $t"
  done
  rm -f "$tmp"
  echo "object store tests: $passes passed, $fails failed, $skips skipped (tests and subtests); make test-stack exit $rc"
  [ -z "$missing" ] || echo "FAIL  did not pass:$missing"
  [ "$skips" = 0 ] || echo "FAIL  $skips test(s) skipped: every test of the object store must run against it"
  [ "$rc" = 0 ] && [ "$fails" = 0 ] && [ "$skips" = 0 ] && [ -z "$missing" ]
}

export -f objstore_tests

scenario_targets() {
  step up 40 make up OBS=lgtm
  step smoke 15 make smoke
  step drill-obs-threats 30 make drill-obs-threats
  step test-stack-objstore 20 bash -c objstore_tests
}
