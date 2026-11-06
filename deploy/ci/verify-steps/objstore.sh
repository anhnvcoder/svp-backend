#!/usr/bin/env bash
# Runs internal/objstore integration tests against the compose stack; no test may skip.
# Fails on non-zero exit, test failure, skipped tests, or missing integration test cases.
# Usage, from the repo root with stack up: deploy/ci/verify-steps/objstore.sh
# Design notes: docs/reference/ci.md.
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
