#!/usr/bin/env bash
# Tests for supplychain.sh with stubs for GHCR, make, and cosign in a temporary tree.
# Verifies image resolution, SUPPLYCHAIN_ENFORCE_TMP propagation, and scheduled run attestation age expiration.
# Runs on macOS and Linux: no network, no Docker, no cluster.
# Usage, from anywhere: deploy/ci/verify-steps/supplychain-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
same() { if [ "$3" = "$2" ]; then ok "$1"; else fail "$1: want '$2', got '$3'"; fi; }
has() { if grep -qF -- "$3" "$work/$1.log"; then ok "$1: $2"; else fail "$1: $2"; fi; }
lacks() { if grep -qF -- "$3" "$work/$1.log"; then fail "$1: $2"; else ok "$1: $2"; fi; }

tree=$work/tree
mkdir -p "$tree/deploy/ci/verify-steps" "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$work/bin"
cp "$here/supplychain.sh" "$tree/deploy/ci/verify-steps/"
cp "$src/deploy/ci/common.sh" "$tree/deploy/ci/"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/docker-bake.json" "$tree/deploy/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
cat >"$tree/deploy/ci/ghcr-digest.sh" <<'EOF'
#!/usr/bin/env bash
# Test stub: answers newest IMAGE the way GHCR would, failing for the image in FAKE_GHCR_MISSING.
[ "$1" = newest ] || exit 2
[ "$2" != "${FAKE_GHCR_MISSING:-}" ] || { echo "ghcr.io/anhnvcoder/svp-backend/$2 is not on GHCR" >&2; exit 1; }
echo "ghcr.io/anhnvcoder/svp-backend/$2@sha256:$(printf 'd%.0s' $(seq 64))"
EOF
cat >"$work/bin/make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_MAKE_LOG"
exit "${FAKE_MAKE_RC:-0}"
EOF
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
[ "$1" = verify-attestation ] && [ "${FAKE_COSIGN_FAIL:-}" != 1 ] || exit 1
case ${*: -1} in
  *drill-vulnerable@*) h=${FAKE_SCAN_HOURS_C:-$FAKE_SCAN_HOURS} ;;
  *) h=${FAKE_SCAN_HOURS_L:-$FAKE_SCAN_HOURS} ;;
esac
echo "$*" >>"$FAKE_COSIGN_LOG"
jq -nc --argjson h "$h" \
  '{payload: ({predicate: {metadata: {scanFinishedOn: (now - $h * 3600 | floor | todate)}}} | tojson | @base64)}'
EOF
chmod 755 "$tree/deploy/ci/ghcr-digest.sh" "$work/bin/make" "$work/bin/cosign"
digest=sha256:$(printf 'd%.0s' $(seq 64))
dun=ghcr.io/anhnvcoder/svp-backend/drill-unsigned@$digest
dvu=ghcr.io/anhnvcoder/svp-backend/drill-vulnerable@$digest
dnp=ghcr.io/anhnvcoder/svp-backend/drill-no-provenance@$digest

# run NAME [VAR=VALUE...]: runs supplychain.sh with test stubs, logging output and tool arguments.
run() {
  local name=$1 rc=0
  shift
  : >"$work/$name-make.log"
  : >"$work/$name-cosign.log"
  env -u GITHUB_ACTIONS -u CI -u SVP_VERIFY_SCHEDULED -u SUPPLYCHAIN_ENFORCE_TMP PATH="$work/bin:$PATH" FAKE_MAKE_LOG="$work/$name-make.log" \
    FAKE_COSIGN_LOG="$work/$name-cosign.log" FAKE_SCAN_HOURS=10 "$@" "$tree/deploy/ci/verify-steps/supplychain.sh" \
    >"$work/$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
# made NAME: outputs recorded arguments passed to make for run NAME.
made() { cat "$work/$1-make.log"; }
args() {
  printf '%s\n' drill-k8s-supplychain "SUPPLYCHAIN_UNSIGNED=$1" "SUPPLYCHAIN_VULNERABLE=$2" "SUPPLYCHAIN_NO_PROVENANCE=$3" \
    "SUPPLYCHAIN_ENFORCE_TMP=${4:-}"
}

same "supplychain: every image on GHCR, the drill passing, passes" 0 "$(run all)"
same "supplychain: the drill gets the newest drill-unsigned, drill-vulnerable and drill-no-provenance" \
  "$(args "$dun" "$dvu" "$dnp")" "$(made all)"
same "supplychain: a dispatched run reads no attestation age" "" "$(cat "$work/all-cosign.log")"
same "supplychain: SUPPLYCHAIN_ENFORCE_TMP=1 (job dev-k3d) reaches the drill" 0 "$(run enforce SUPPLYCHAIN_ENFORCE_TMP=1)"
same "supplychain: ... with the images as without it" "$(args "$dun" "$dvu" "$dnp" 1)" "$(made enforce)"
same "supplychain: a dispatched run keeps an image whatever its age" 0 "$(run dispatch-old FAKE_SCAN_HOURS=100)"
same "supplychain: ... and hands it to the drill" "$(args "$dun" "$dvu" "$dnp")" "$(made dispatch-old)"
lacks dispatch-old "nothing is noted on a dispatched run" NOTE
same "supplychain: the drill failing fails the step with its status" 2 "$(run drill-fails FAKE_MAKE_RC=2)"
same "supplychain: drill-no-provenance not on GHCR fails the step" 1 \
  "$(run no-provenance FAKE_GHCR_MISSING=drill-no-provenance)"
same "supplychain: drill-no-provenance not on GHCR: case l gets none, not empty" "$(args "$dun" "$dvu" none)" \
  "$(made no-provenance)"
has no-provenance "drill-no-provenance not on GHCR: the step fails naming it" \
  "FAIL  drill-k8s-supplychain ran without what GHCR did not give (above): drill-no-provenance;"
same "supplychain: drill-unsigned not on GHCR fails the step" 1 "$(run no-unsigned FAKE_GHCR_MISSING=drill-unsigned)"
same "supplychain: drill-unsigned not on GHCR: the drill gets it empty (and looks it up itself)" \
  "$(args "" "$dvu" "$dnp")" "$(made no-unsigned)"
has no-unsigned "drill-unsigned not on GHCR: the step fails naming it" \
  "without what GHCR did not give (above): drill-unsigned;"
same "supplychain: drill-vulnerable not on GHCR fails the step, the drill passing" 1 \
  "$(run no-vulnerable FAKE_GHCR_MISSING=drill-vulnerable)"
same "supplychain: drill-vulnerable not on GHCR: case c gets it empty" "$(args "$dun" "" "$dnp")" "$(made no-vulnerable)"

same "supplychain: scheduled, an attestation of c older than 72h leaves case c out, failing nothing" 0 \
  "$(run old-c SVP_VERIFY_SCHEDULED=true FAKE_SCAN_HOURS_C=100)"
same "supplychain: ... c gets it empty, l kept" "$(args "$dun" "" "$dnp")" "$(made old-c)"
has old-c "the NOTE names the case and the image" "NOTE  case c left out on this scheduled run (it SKIPs): $dvu was scanned at"
has old-c "the age is in hours" ", 100 h ago, within an hour of 72h or more;"
has old-c "case c names the build of the drill images" "gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f drill=true"
grep -q -- "--certificate-identity https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main $dvu\$" \
  "$work/old-c-cosign.log" &&
  ok "supplychain: the age is read with the identity of the image's release source" ||
  fail "supplychain: the age is read with the identity of the image's release source ($(cat "$work/old-c-cosign.log"))"
same "supplychain: scheduled, an attestation within the last hour before 72h leaves the case out too" \
  "$(args "$dun" "" "$dnp")" "$(run near-c SVP_VERIFY_SCHEDULED=true FAKE_SCAN_HOURS_C=71.5 >/dev/null && made near-c)"
same "supplychain: scheduled, an attestation of l older than 72h leaves case l out with none" 0 \
  "$(run old-l SVP_VERIFY_SCHEDULED=true FAKE_SCAN_HOURS_L=80)"
same "supplychain: ... l gets none, c kept" "$(args "$dun" "$dvu" none)" "$(made old-l)"
has old-l "case l (drill-no-provenance) names the build of the drill images too" "-f drill=true"
lacks old-l "case l names no rescan" "rescan=true"
same "supplychain: scheduled, attestations within 72h keep both cases" "$(args "$dun" "$dvu" "$dnp")" \
  "$(run fresh SVP_VERIFY_SCHEDULED=true FAKE_SCAN_HOURS=10 >/dev/null && made fresh)"
lacks fresh "nothing is noted for a case kept" NOTE
same "supplychain: scheduled, cosign without an answer keeps the cases (the drill fails them)" \
  "$(args "$dun" "$dvu" "$dnp")" \
  "$(run no-cosign SVP_VERIFY_SCHEDULED=true FAKE_COSIGN_FAIL=1 FAKE_SCAN_HOURS=100 >/dev/null && made no-cosign)"
same "supplychain: SVP_VERIFY_SCHEDULED other than true is a dispatch" "$(args "$dun" "$dvu" "$dnp")" \
  "$(run not-true SVP_VERIFY_SCHEDULED=1 FAKE_SCAN_HOURS=100 >/dev/null && made not-true)"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
