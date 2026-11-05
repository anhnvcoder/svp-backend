#!/usr/bin/env bash
# Step test-stack-objstore of job compose of .github/workflows/verify.yml: the object store's own tests against the
# stack's object store (make test-stack PKGS=./internal/objstore/..., go test -race -count=1 -v), the one place they run
# instead of skipping. Its output counted: fails when make test-stack exits non-zero, when go test reports a FAIL,
# when any test or subtest SKIPs (a skipped case proves nothing about the store), or when one of the integration tests
# (presigned POST, worker and video-service permissions, DeletePrefix, multipart with CRC32, Cache-Control read back
# anonymously, create only once, the worker listing and reading media/) did not PASS, each named.
#
# make is the one on PATH. Usage, from the repo root, the stack up: deploy/ci/verify-steps/objstore.sh
set -uo pipefail

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
make test-stack PKGS=./internal/objstore/... 2>&1 | tee "$tmp"
rc=${PIPESTATUS[0]}
passes=$(grep -cE '^ *--- PASS: ' "$tmp")
fails=$(grep -cE '^ *--- FAIL: ' "$tmp")
skips=$(grep -cE '^ *--- SKIP: ' "$tmp")
missing=
for t in TestIntegrationPresignedPost TestIntegrationWorkerPermissions TestIntegrationVideoServicePermissions \
  TestIntegrationDeletePrefix TestIntegrationMultipartChecksum TestIntegrationCacheControl TestIntegrationCreateOnce \
  TestIntegrationWorkerReadsMedia; do
  grep -qE "^--- PASS: $t " "$tmp" || missing="$missing $t"
done
echo "object store tests: $passes passed, $fails failed, $skips skipped (tests and subtests); make test-stack exit $rc"
[ -z "$missing" ] || echo "FAIL  did not pass:$missing"
[ "$skips" = 0 ] || echo "FAIL  $skips test(s) skipped: every test of the object store must run against it"
[ "$rc" = 0 ] && [ "$fails" = 0 ] && [ "$skips" = 0 ] && [ -z "$missing" ]
