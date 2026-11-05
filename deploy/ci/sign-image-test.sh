#!/usr/bin/env bash
# Tests for the Sigstore bundle helpers of deploy/ci/common.sh the rescan uses (bundle_referrers, release_format,
# replace_vuln_bundle), against a fake registry, in a throwaway checkout of what they read; the variables of a GitHub
# Actions job are made up. Signing itself (action image-sign and its guard) is tested by deploy/ci/image-guard-test.sh.
# The section's own comment below lists the cases. Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/sign-image-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# check NAME COMMAND...: ok when COMMAND succeeds.
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
# same NAME WANT GOT: ok when the two strings are equal; shows both otherwise.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

# on github|local COMMAND...: runs COMMAND with the variables of a made-up GitHub Actions job (repository octo/repo),
# or on a machine with none of them. git reads no configuration of this machine.
on() {
  local where=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_REF -u GITHUB_SHA -u GITHUB_EVENT_NAME
    -u GITHUB_EVENT_PATH -u RUNNER_TEMP -u GIT_DIR -u GIT_WORK_TREE -u SVP_CODE_ROOT
    HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FAKE_COSIGN_LOG="$work/cosign.log")
  case $where in
  github)
    "${base[@]}" GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 \
      GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main GITHUB_REF=refs/heads/main \
      GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_EVENT_NAME=push RUNNER_TEMP="$work/runner-temp" "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  esac
}
# fresh: empties the files of a job and the log of the fake cosign.
fresh() { : >"$work/output" && : >"$work/summary" && : >"$work/cosign.log"; }
mkdir -p "$work/home" "$work/runner-temp"

# A throwaway checkout of what the scripts read (deploy/ci/, deploy/k8s/lib.sh, the policy's values). GIT_DIR is set for
# every git call of the test itself, so git can never reach another repository.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/docker-bake.json" "$tree/deploy/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
backend_run=(GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com)

# --- The Sigstore bundles of a release (bundle_referrers, release_format and replace_vuln_bundle of common.sh). A fake
# registry under bundles/: a folder per subject digest holding one file per bundle referrer (named by its digest,
# holding its predicate type), and a file <hex>.sig for a signature in cosign's older format. A fake docker first on
# PATH answers ORAS: discover lists the referrers with their dev.sigstore.bundle.predicateType annotation, manifest
# fetch --descriptor of a .sig tag finds the older format or answers "not found", manifest delete takes the referrer
# off the list and still exits 1 "unsupported", as GHCR does (FAKE_DELETE_IGNORED: it leaves the list as it was). A
# fake cosign logs each call, adds a referrer for each sign and attest in the bundle format, and verifies one vuln
# attestation per vuln referrer. Checked:
#   - replace_vuln_bundle (the rescan of a release in bundles): the new vuln bundle is kept and every older one taken
#     off, the signature and the provenance never; a registry that keeps a bundle on the list, a second bundle that
#     appears meanwhile, or cosign verifying another count than one fails it, naming the digest;
#   - release_format: bundle, legacy or none, and a digest carrying both is refused.
bb=$work/bundle-bin
fb=$work/bundles
mkdir -p "$bb" "$fb" "$work/home/.docker"
echo '{"auths": {}}' >"$work/home/.docker/config.json"
oras_image=fake.invalid/oras@sha256:$(printf '0%.0s' $(seq 64))
cat >"$bb/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
while [ $# -gt 0 ] && [ "$1" != "$FAKE_ORAS_IMAGE" ]; do shift; done
[ $# -gt 0 ] || {
  echo "fake docker: unexpected call" >&2
  exit 99
}
shift
ref=
for a in "$@"; do case $a in *@sha256:* | *:sha256-*) ref=$a ;; esac; done
if [ -n "${FAKE_ORAS_DOWN:-}" ]; then
  echo "Error: Get \"https://ghcr.io/v2/\": dial tcp: i/o timeout" >&2
  exit 1
fi
store=${FAKE_BUNDLES:?}
case "$1 $2" in
"discover --format")
  hex=${ref##*@sha256:}
  for f in "$store/$hex"/*; do
    [ -f "$f" ] || continue
    jq -n --arg d "sha256:${f##*/}" --arg t "$(cat "$f")" \
      '{digest: $d, artifactType: "application/vnd.dev.sigstore.bundle.v0.3+json",
        annotations: {"dev.sigstore.bundle.predicateType": $t}}'
  done | jq -s --arg r "$ref" '{reference: $r, referrers: .}'
  ;;
"manifest fetch")
  hex=${ref##*:sha256-}
  hex=${hex%.sig}
  if [ -f "$store/$hex.sig" ]; then
    echo '{"mediaType": "application/vnd.oci.image.manifest.v1+json"}'
  else
    echo "Error response from registry: failed to find \"$ref\": $ref: not found" >&2
    exit 1
  fi
  ;;
"manifest delete")
  if [ -z "${FAKE_DELETE_IGNORED:-}" ]; then
    for f in "$store"/*/"${ref##*@sha256:}"; do [ ! -f "$f" ] || rm -- "$f"; done
  fi
  echo "Error response from registry: unsupported: The operation is unsupported." >&2
  exit 1
  ;;
*)
  echo "fake docker: unexpected ORAS command: $*" >&2
  exit 99
  ;;
esac
EOF
cat >"$bb/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
cmd=$1 type= legacy= ref= predicate=
for a in "$@"; do
  case $a in
  --new-bundle-format=false) legacy=1 ;;
  --type) type=next ;;
  --predicate) predicate=next ;;
  *)
    [ "$type" != next ] || type=$a
    [ "$predicate" != next ] || predicate=$a
    ;;
  esac
  ref=$a
done
store=${FAKE_BUNDLES:?}
# A copy of the predicate of the last attestation of each type.
[ -z "$predicate" ] || cp "$predicate" "$store/last-$type.json"
hex=${ref##*@sha256:}
# add PREDICATE_TYPE: one more referrer of the subject, its digest made up from a counter.
add() {
  local n
  n=$(($(cat "$store/counter" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$store/counter"
  mkdir -p "$store/$hex"
  echo "$1" >"$store/$hex/$(printf '%s %s' "$n" "$ref" | shasum -a 256 | cut -c1-64)"
  # FAKE_ALSO: another writer adds a vuln bundle at the same time.
  [ -z "${FAKE_ALSO:-}" ] ||
    echo https://cosign.sigstore.dev/attestation/vuln/v1 >"$store/$hex/$(printf 'also %s' "$n" | shasum -a 256 | cut -c1-64)"
}
case $cmd in
sign)
  if [ -n "$legacy" ]; then : >"$store/$hex.sig"; else add https://sigstore.dev/cosign/sign/v1; fi
  ;;
attest)
  case $type in
  spdxjson) add https://spdx.dev/Document ;;
  vuln) add https://cosign.sigstore.dev/attestation/vuln/v1 ;;
  *) exit 98 ;;
  esac
  ;;
verify-attestation)
  [ "$type" = vuln ] || exit 98
  n=${FAKE_VERIFIED:-$(grep -lx https://cosign.sigstore.dev/attestation/vuln/v1 "$store/$hex"/* 2>/dev/null | wc -l)}
  for _ in $(seq "$n"); do echo '{"payloadType":"application/vnd.in-toto+json","payload":"e30="}'; done
  ;;
*) exit 98 ;;
esac
EOF
chmod 755 "$bb/docker" "$bb/cosign"
# The index digest of the release, and the predicate the rescan attests (any file: the fake cosign only copies it).
sign_digest=sha256:$(printf '4%.0s' $(seq 64))
hex=${sign_digest#sha256:}
echo '{"spdxVersion": "SPDX-2.3"}' >"$work/predicate.json"
backend_subject=https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
backend_sign=("${backend_run[@]}" GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main)
# bundled WHERE [VAR=VALUE...] -- COMMAND...: COMMAND (on WHERE) with the fakes of this section first on PATH.
bundled() {
  local where=$1 vars=()
  shift
  while [ "$1" != -- ]; do vars+=("$1") && shift; done
  shift
  on "$where" env PATH="$bb:$PATH" ORAS_IMAGE="$oras_image" FAKE_ORAS_IMAGE="$oras_image" \
    FAKE_BUNDLES="$fb" FAKE_DOCKER_LOG="$work/docker.log" ${vars[@]+"${vars[@]}"} "$@"
}
# vuln_files: the referrers of the index that are vuln bundles.
vuln_files() { grep -lx https://cosign.sigstore.dev/attestation/vuln/v1 "$fb/$hex"/* 2>/dev/null || true; }
clean() { rm -rf "${fb:?}"/*; }
bundle="--yes --new-bundle-format=true"
repo=ghcr.io/anhnvcoder/svp-backend/gateway

# replace_vuln_bundle on a release in bundles with its signature, its provenance and two vuln bundles of earlier
# rescans, one of them with a digest that sorts after every other (the one Kyverno would read).
old_low=$(printf '0%.0s' $(seq 63))3 old_high=$(printf 'f%.0s' $(seq 64))
# rescan_fixture: the bundles of that release.
rescan_fixture() {
  clean
  mkdir -p "$fb/$hex"
  echo https://sigstore.dev/cosign/sign/v1 >"$fb/$hex/$(printf '0%.0s' $(seq 63))1"
  echo https://slsa.dev/provenance/v1 >"$fb/$hex/$(printf '0%.0s' $(seq 63))2"
  echo https://cosign.sigstore.dev/attestation/vuln/v1 >"$fb/$hex/$old_low"
  echo https://cosign.sigstore.dev/attestation/vuln/v1 >"$fb/$hex/$old_high"
}
# replace NAME WANT_RC [VAR=VALUE...]: replace_vuln_bundle on that release in a rescan job of backend; its output in
# replace.out.
replace() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  : >"$work/docker.log"
  # shellcheck disable=SC2016 # expanded by the inner shell
  bundled github "${backend_sign[@]}" "$@" -- "$BASH" -c '. "$1/deploy/ci/common.sh" && sign_identity backend &&
    replace_vuln_bundle "$2" "$3" "$4"' _ "$tree" "$repo" "$sign_digest" "$work/predicate.json" \
    >"$work/replace.out" 2>&1 || rc=$?
  same "replace_vuln_bundle: $name (exit $want)" "$want" "$rc"
}
rescan_fixture
replace "two older vuln bundles" 0
new=$(vuln_files)
same "replace_vuln_bundle: one vuln bundle left, the new one" "1 new" \
  "$(grep -c . <<<"$new") $(case ${new##*/} in "$old_low" | "$old_high") echo old ;; *) echo new ;; esac)"
same "replace_vuln_bundle: the signature and the provenance stay" \
  "https://sigstore.dev/cosign/sign/v1 https://slsa.dev/provenance/v1" \
  "$(cat "$fb/$hex/$(printf '0%.0s' $(seq 63))1" "$fb/$hex/$(printf '0%.0s' $(seq 63))2" | paste -sd' ' -)"
same "replace_vuln_bundle: the two older ones deleted, nothing else" \
  "$repo@sha256:$old_low $repo@sha256:$old_high" \
  "$(sed -n 's/.* manifest delete --force \([^ ]*\) .*/\1/p' "$work/docker.log" | sort | paste -sd' ' -)"
check "replace_vuln_bundle: attested as a bundle" has "$work/cosign.log" "attest $bundle --type vuln --predicate"
check "replace_vuln_bundle: names the one left" has "$work/replace.out" \
  "ok    $repo@$sign_digest: one vuln bundle, sha256:${new##*/}"
rescan_fixture
replace "a registry that keeps the older bundles on the list" 1 FAKE_DELETE_IGNORED=1
check "replace_vuln_bundle: a registry that keeps them: names them" has "$work/replace.out" \
  "$repo@$sign_digest: the vuln bundles left are"
rescan_fixture
replace "a second new vuln bundle meanwhile" 1 FAKE_ALSO=1
check "replace_vuln_bundle: a second new vuln bundle: nothing taken off" lacks "$work/docker.log" " manifest delete "
check "replace_vuln_bundle: a second new vuln bundle: says so" has "$work/replace.out" \
  "$repo@$sign_digest: not exactly one new vuln bundle after the attestation"
rescan_fixture
replace "cosign verifying two" 1 FAKE_VERIFIED=2
check "replace_vuln_bundle: cosign verifying two: says so" has "$work/replace.out" \
  "cosign verifies 2 vuln attestations of $backend_subject, not exactly one"

# release_format: prints its answer for that release, or FAIL and the last line it wrote.
format() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  bundled local -- "$BASH" -c '. "$1/deploy/ci/common.sh" && release_format "$2"' _ "$tree" "$repo@$sign_digest" \
    2>"$work/format.err" || echo "FAIL $(tail -n 1 "$work/format.err")"
}
clean
same "release_format: nothing signed" none "$(format)"
: >"$fb/$hex.sig"
same "release_format: cosign's older format" legacy "$(format)"
rescan_fixture
same "release_format: Sigstore bundles" bundle "$(format)"
: >"$fb/$hex.sig"
same "release_format: both: refused" \
  "FAIL FAIL  $repo@$sign_digest carries Sigstore bundles and cosign's older format ($repo:sha256-$hex.sig): verifiers read the bundles only" \
  "$(format)"
clean

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
