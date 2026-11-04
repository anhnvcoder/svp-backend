#!/usr/bin/env bash
# Tests for deploy/ci/sign-image.sh and the Sigstore bundle helpers of deploy/ci/common.sh the rescan uses
# (bundle_referrers, release_format, replace_vuln_bundle), against a fake registry, in a throwaway checkout of what they
# read and a checkout of svp-frontend beside it; the variables of a GitHub Actions job are made up. With them, the
# guards push-image.sh, merge-index.sh and build-image.sh keep before docker is called in a run of svp-frontend. The
# section's own comment below lists the cases. Runs on macOS and Linux: no network, no Docker, no cluster.
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

# A throwaway checkout of what the scripts read (deploy/ci/, deploy/k8s/lib.sh, the policy's values), and a checkout of
# svp-frontend, another release source's repository, whose CI runs these scripts from a pinned checkout of this one
# (SVP_CODE_ROOT). GIT_DIR is set for every git call of the test itself, so git can never reach another repository.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
base=$(g rev-parse HEAD)
webtree=$work/svp-frontend
mkdir -p "$webtree"
printf 'vulnerabilities: []\n' >"$webtree/.trivyignore.yaml"
gw() {
  GIT_DIR=$webtree/.git GIT_WORK_TREE=$webtree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
gw init -q -b main && gw add -A && gw commit -qm web
gw remote add origin https://github.com/anhnvcoder/svp-frontend.git
web_head=$(gw rev-parse HEAD)
backend_run=(GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com)

# --- sign-image.sh and the Sigstore bundles of a release (bundle_referrers, release_format and replace_vuln_bundle of
# common.sh). A fake registry under bundles/: a folder per subject digest holding one file per bundle referrer (named
# by its digest, holding its predicate type), and a file <hex>.sig for a signature in cosign's older format. A fake
# docker first on PATH serves the index (buildx imagetools inspect --raw) and answers ORAS: discover lists the
# referrers with their dev.sigstore.bundle.predicateType annotation, manifest fetch --descriptor of a .sig tag finds
# the older format or answers "not found", manifest delete takes the referrer off the list and still exits 1
# "unsupported", as GHCR does (FAKE_DELETE_IGNORED: it leaves the list as it was). A fake cosign logs each call, adds a
# referrer for each sign and attest in the bundle format, and verifies one vuln attestation per vuln referrer. Checked:
#   - a release: signature, SBOM on each manifest, vuln on the index, all bundles, in that order, and provenance=true
#     with the index as subject for the step of actions/attest; run again on the same digest (Re-run failed jobs):
#     nothing written again; once the provenance is there: provenance=false; a run cut off before vuln: only vuln;
#   - a digest in cosign's older format, or one the registry gives no answer for: nothing written;
#   - a run on a machine or of another workflow: nothing written, naming the identity; the drill images: no provenance
#     (also on a machine), drill-no-provenance refuses --allow-critical;
#   - a run of svp-frontend (another release source's repository, running these scripts from a checkout of this one):
#     its web release is signed with provenance=true; refused when its builder is the backend's subject, when the image
#     is under the backend's prefix (or the backend's run signs under svp-frontend's), when the image is no service or
#     drill image of svp-frontend's source, or when the run's repository is no source at all; push-image.sh and
#     merge-index.sh of that run refuse an image svp-frontend does not publish and a tree whose HEAD is not the run's
#     commit, build-image.sh a tree without its .trivyignore.yaml, before docker is called;
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
if [ "$1 $2 $3 $4" = "buildx imagetools inspect --raw" ]; then
  cat "$FAKE_INDEX"
  exit 0
fi
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
sign_amd64=sha256:$(printf '1%.0s' $(seq 64))
sign_arm64=sha256:$(printf '2%.0s' $(seq 64))
sign_config=sha256:$(printf '3%.0s' $(seq 64))
jq -nc --arg a "$sign_amd64" --arg b "$sign_arm64" '{schemaVersion: 2,
  mediaType: "application/vnd.oci.image.index.v1+json", manifests: [
    {digest: $a, platform: {os: "linux", architecture: "amd64"}},
    {digest: $b, platform: {os: "linux", architecture: "arm64"}}]}' >"$work/sign-index.json"
sign_digest=sha256:$(shasum -a 256 "$work/sign-index.json" | cut -d' ' -f1)
hex=${sign_digest#sha256:}
for arch in amd64 arm64; do
  d=$work/sign-leg-$arch
  mkdir -p "$d"
  echo "linux/$arch" >"$d/platform"
  if [ $arch = amd64 ]; then echo "$sign_amd64" >"$d/digest"; else echo "$sign_arm64" >"$d/digest"; fi
  echo "$sign_config" >"$d/config-digest"
  jq -n --arg c "$sign_config" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Trivy: {Version: "0.76.0"}, Results: []}' \
    >"$d/trivy.json"
  for f in scan-started scan-finished db-updated-at; do echo 2026-10-29T01:02:03Z >"$d/$f"; done
  echo '{"spdxVersion": "SPDX-2.3"}' >"$d/sbom.spdx.json"
done
backend_subject=https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
web_subject=https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main
backend_sign=("${backend_run[@]}" GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main)
web_sign=(GITHUB_REPOSITORY=anhnvcoder/svp-frontend GITHUB_SERVER_URL=https://github.com
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main GITHUB_SHA="$web_head"
  SVP_CODE_ROOT="$webtree")
# bundled WHERE [VAR=VALUE...] -- COMMAND...: COMMAND (on WHERE) with the fakes of this section first on PATH.
bundled() {
  local where=$1 vars=()
  shift
  while [ "$1" != -- ]; do vars+=("$1") && shift; done
  shift
  on "$where" env PATH="$bb:$PATH" ORAS_IMAGE="$oras_image" FAKE_ORAS_IMAGE="$oras_image" \
    FAKE_BUNDLES="$fb" FAKE_DOCKER_LOG="$work/docker.log" FAKE_INDEX="$work/sign-index.json" \
    ${vars[@]+"${vars[@]}"} "$@"
}
# image NAME [PREFIX]: the index directory merge-index.sh would write for image NAME under PREFIX (the backend's
# when empty).
image() {
  rm -rf "$work/sign-index" && mkdir -p "$work/sign-index"
  echo "${2:-ghcr.io/anhnvcoder/svp-backend/}$1" >"$work/sign-index/repository"
  echo "$sign_digest" >"$work/sign-index/digest"
}
# sign WHERE [VAR=VALUE...] -- [--allow-critical]: sign-image.sh on the image of the index directory; prints its
# exit code. Its output in sign.out and sign.err, the outputs of a github run in output, cosign's calls in cosign.log.
sign() {
  local where=$1 vars=() rc=0
  shift
  while [ "$1" != -- ]; do vars+=("$1") && shift; done
  shift
  fresh
  : >"$work/docker.log"
  bundled "$where" ${vars[@]+"${vars[@]}"} -- "$tree/deploy/ci/sign-image.sh" "$@" "$work/sign-index" \
    "$work/sign-leg-amd64" "$work/sign-leg-arm64" >"$work/sign.out" 2>"$work/sign.err" || rc=$?
  echo "$rc"
}
# calls: what cosign was asked, comma separated: sign, or the type of an attestation and its subject (index, amd64 or
# arm64).
calls() {
  sed -E "s/^(sign) .*/\1/; s/^attest .*--type ([a-z0-9]+) .*@(sha256:[0-9a-f]+)$/\1 \2/" "$work/cosign.log" |
    sed "s/$sign_digest/index/; s/$sign_amd64/amd64/; s/$sign_arm64/arm64/" | paste -sd, -
}
# provenance_out: the provenance output of the last run, from GITHUB_OUTPUT on github or stdout on a machine.
provenance_out() { grep -h '^provenance=' "$work/output" "$work/sign.out"; }
# vuln_files: the referrers of the index that are vuln bundles.
vuln_files() { grep -lx https://cosign.sigstore.dev/attestation/vuln/v1 "$fb/$hex"/* 2>/dev/null || true; }
clean() { rm -rf "${fb:?}"/*; }
bundle="--yes --new-bundle-format=true"
repo=ghcr.io/anhnvcoder/svp-backend/gateway

clean
image gateway
same "sign-image.sh, a release: signed and attested" 0 "$(sign github "${backend_sign[@]}" --)"
same "sign-image.sh, a release: signature, SBOM on each manifest, vuln on the index, Sigstore bundles" \
  "sign $bundle $repo@$sign_digest
attest $bundle --type spdxjson --predicate $work/sign-leg-amd64/sbom.spdx.json $repo@$sign_amd64
attest $bundle --type spdxjson --predicate $work/sign-leg-arm64/sbom.spdx.json $repo@$sign_arm64
attest $bundle --type vuln --predicate PREDICATE $repo@$sign_digest" \
  "$(sed -E 's/--predicate [^ ]*vuln\.json/--predicate PREDICATE/' "$work/cosign.log")"
same "sign-image.sh, a release: the subject and provenance=true for actions/attest" \
  "repository=$repo
digest=$sign_digest
provenance=true" "$(cat "$work/output")"
same "sign-image.sh, a release: the vuln predicate is the scan's" '"0.76.0"' \
  "$(jq -c .scanner.version "$fb/last-vuln.json")"
check "sign-image.sh, a release: ORAS reads with the credentials of docker login, read-only" has "$work/docker.log" \
  "-v $work/home/.docker/config.json:/auth/config.json:ro $oras_image discover --format json"
same "sign-image.sh, run again on the same digest: signed (exit 0)" 0 "$(sign github "${backend_sign[@]}" --)"
same "sign-image.sh, run again: nothing written again" "" "$(cat "$work/cosign.log")"
same "sign-image.sh, run again: the index still has one signature and one vuln attestation" \
  "1 https://cosign.sigstore.dev/attestation/vuln/v1,1 https://sigstore.dev/cosign/sign/v1" \
  "$(cat "$fb/$hex"/* | sort | uniq -c | sed 's/^ *//' | paste -sd, -)"
same "sign-image.sh, run again: provenance=true while the provenance is missing" provenance=true "$(provenance_out)"
echo https://slsa.dev/provenance/v1 >"$fb/$hex/$(printf 'f%.0s' $(seq 64))"
same "sign-image.sh, run again after actions/attest: signed (exit 0)" 0 "$(sign github "${backend_sign[@]}" --)"
same "sign-image.sh, run again after actions/attest: provenance=false, nothing written" "provenance=false|" \
  "$(provenance_out)|$(cat "$work/cosign.log")"
for f in $(vuln_files); do rm -- "$f"; done
same "sign-image.sh, a run cut off before vuln, run again: signed (exit 0)" 0 "$(sign github "${backend_sign[@]}" --)"
same "sign-image.sh, a run cut off before vuln, run again: only vuln written" "vuln index" "$(calls)"

clean
: >"$fb/$hex.sig"
same "sign-image.sh, a digest in cosign's older format: refused" 1 "$(sign github "${backend_sign[@]}" --)"
same "sign-image.sh, a digest in cosign's older format: nothing written" "" "$(cat "$work/cosign.log")"
check "sign-image.sh, a digest in cosign's older format: says so" has "$work/sign.err" \
  "$repo@$sign_digest carries cosign's older format already: one digest never carries both, nothing written"
clean
same "sign-image.sh, the registry out of reach: refused" 1 "$(sign github "${backend_sign[@]}" FAKE_ORAS_DOWN=1 --)"
same "sign-image.sh, the registry out of reach: nothing written" "" "$(cat "$work/cosign.log")"

clean
same "sign-image.sh, a release on a machine: refused (workflow local)" 1 "$(sign local --)"
same "sign-image.sh, a release on a machine: nothing written" "" "$(cat "$work/cosign.log")"
check "sign-image.sh, a release on a machine: names the workflow" has "$work/sign.err" \
  "this run is the workflow 'local', but releases of source backend are signed only as $backend_subject"
same "sign-image.sh, a release built by another workflow: refused" 1 \
  "$(sign github "${backend_sign[@]}" GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/ci.yml@refs/heads/main --)"
same "sign-image.sh, a release built by another workflow: nothing written" "" "$(cat "$work/cosign.log")"

image drill-vulnerable
for how in github local; do
  clean
  same "sign-image.sh, the drill image ($how): signed and attested" 0 \
    "$(sign "$how" "${backend_sign[@]}" -- --allow-critical)"
  same "sign-image.sh, the drill image ($how): vuln, no provenance" \
    "sign,spdxjson amd64,spdxjson arm64,vuln index|provenance=false" "$(calls)|$(provenance_out)"
done
image drill-no-provenance
clean
same "sign-image.sh, drill-no-provenance: signed and attested" 0 "$(sign github "${backend_sign[@]}" --)"
same "sign-image.sh, drill-no-provenance: vuln, never provenance" \
  "sign,spdxjson amd64,spdxjson arm64,vuln index|provenance=false" "$(calls)|$(provenance_out)"
clean
same "sign-image.sh, drill-no-provenance with --allow-critical: refused" 1 \
  "$(sign github "${backend_sign[@]}" -- --allow-critical)"
same "sign-image.sh, drill-no-provenance with --allow-critical: nothing written" "" "$(cat "$work/cosign.log")"

# A run of svp-frontend: its own repository, commit and identity, its code in the checkout webtree.
clean
image web ghcr.io/anhnvcoder/svp-frontend/
same "sign-image.sh of svp-frontend, its web release: signed and attested" 0 "$(sign github "${web_sign[@]}" --)"
same "sign-image.sh of svp-frontend, its web release: signature, SBOMs, vuln, then provenance=true" \
  "sign,spdxjson amd64,spdxjson arm64,vuln index|provenance=true" "$(calls)|$(provenance_out)"
clean
same "sign-image.sh of svp-frontend with the backend's workflow: refused" 1 \
  "$(sign github "${web_sign[@]}" GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main --)"
same "sign-image.sh of svp-frontend with the backend's workflow: nothing written" "" "$(cat "$work/cosign.log")"
check "sign-image.sh of svp-frontend with the backend's workflow: names the source's subject" has "$work/sign.err" \
  "releases of source web are signed only as $web_subject"
same "sign-image.sh, the backend's run on svp-frontend's image: refused" 1 "$(sign github "${backend_sign[@]}" --)"
check "sign-image.sh, the backend's run on svp-frontend's image: names the prefix" has "$work/sign.err" \
  "ghcr.io/anhnvcoder/svp-frontend/web is not under ghcr.io/anhnvcoder/svp-backend/"
image web
same "sign-image.sh of svp-frontend on the backend's web: refused" 1 "$(sign github "${web_sign[@]}" --)"
check "sign-image.sh of svp-frontend on the backend's web: names svp-frontend's prefix" has "$work/sign.err" \
  "is not under ghcr.io/anhnvcoder/svp-frontend/, the prefix of release source web"
image gateway ghcr.io/anhnvcoder/svp-frontend/
same "sign-image.sh of svp-frontend on a gateway under its prefix: refused" 1 "$(sign github "${web_sign[@]}" --)"
check "sign-image.sh of svp-frontend on a gateway under its prefix: names what it publishes" has "$work/sign.err" \
  "gateway is not an image of release source web (web)"
image drill-vulnerable ghcr.io/anhnvcoder/svp-frontend/
same "sign-image.sh of svp-frontend on a drill image under its prefix: refused" 1 \
  "$(sign github "${web_sign[@]}" -- --allow-critical)"
same "sign-image.sh of svp-frontend on a drill image under its prefix: nothing written" "" "$(cat "$work/cosign.log")"
image web ghcr.io/anhnvcoder/svp-frontend/
same "sign-image.sh of a repository no release source names: refused" 1 \
  "$(sign github "${web_sign[@]}" GITHUB_REPOSITORY=octo/repo --)"
check "sign-image.sh of a repository no release source names: says so" has "$work/sign.err" \
  "this run is of https://github.com/octo/repo, which is the repository of 0 release sources"

# push-image.sh, merge-index.sh and build-image.sh of svp-frontend's run: an image it does not publish, a tree that is
# not the run's commit, or one without what its build reads, is refused before docker is called.
# refused_early NAME WANT_MESSAGE [VAR=VALUE...] -- COMMAND...: COMMAND in svp-frontend's run changed by the
# assignments exits 1 naming WANT_MESSAGE, docker never called.
refused_early() {
  local name=$1 want=$2 vars=() rc=0
  shift 2
  while [ "$1" != -- ]; do vars+=("$1") && shift; done
  shift
  : >"$work/docker.log"
  bundled github "${web_sign[@]}" ${vars[@]+"${vars[@]}"} -- "$@" >/dev/null 2>"$work/early.err" || rc=$?
  if [ "$rc" = 1 ] && grep -qF -- "$want" "$work/early.err" && [ ! -s "$work/docker.log" ]; then
    ok "$name: refused before docker"
  else
    fail "$name: refused before docker (exit $rc; $(cat "$work/early.err"); docker: $(cat "$work/docker.log"))"
  fi
}
mkdir -p "$work/leg-out"
refused_early "push-image.sh of svp-frontend's run, image gateway" "gateway is not an image of release source web" -- \
  "$tree/deploy/ci/push-image.sh" gateway amd64 "$work/leg-out"
refused_early "merge-index.sh of svp-frontend's run, image gateway" "gateway is not an image of release source web" -- \
  "$tree/deploy/ci/merge-index.sh" gateway "$work/sign-leg-amd64" "$work/sign-leg-arm64" "$work/index-out"
refused_early "push-image.sh of svp-frontend's run, a tree at another commit" \
  "HEAD of $webtree is $web_head, but this run builds $base of https://github.com/anhnvcoder/svp-frontend" \
  GITHUB_SHA="$base" -- "$tree/deploy/ci/push-image.sh" web amd64 "$work/leg-out"
refused_early "merge-index.sh of svp-frontend's run without SVP_CODE_ROOT (the backend's checkout)" \
  "but this run builds $web_head of https://github.com/anhnvcoder/svp-frontend" SVP_CODE_ROOT= -- \
  "$tree/deploy/ci/merge-index.sh" web "$work/sign-leg-amd64" "$work/sign-leg-arm64" "$work/index-out"
printf 'FROM scratch\n' >"$webtree/Dockerfile"
printf 'lockfileVersion: 9.0\n' >"$webtree/pnpm-lock.yaml"
mv "$webtree/.trivyignore.yaml" "$work/web-trivyignore"
refused_early "build-image.sh of svp-frontend's run, a tree without its .trivyignore.yaml" \
  "$webtree has no file .trivyignore.yaml" -- "$tree/deploy/ci/build-image.sh" web amd64 "$work/leg-out"
mv "$work/web-trivyignore" "$webtree/.trivyignore.yaml"
rm -f "$webtree/Dockerfile" "$webtree/pnpm-lock.yaml"

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
    replace_vuln_bundle "$2" "$3" "$4"' _ "$tree" "$repo" "$sign_digest" "$work/sign-leg-amd64/sbom.spdx.json" \
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
