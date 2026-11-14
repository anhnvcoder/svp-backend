#!/usr/bin/env bash
# Tests for deploy/ci/ecr-copy.sh against registries kept as files under FAKE_REG: a GHCR holding releases (index, two
# platform manifests, five Sigstore bundles) and an ECR. A fake docker (the fake oras for the pinned ORAS image), cosign
# and aws first on PATH act on those files and log their calls to FAKE_LOG: no network, registry or account.
# Sourced (by deploy/ci/rescan-test.sh), it only defines ecr_fakes and the fx_* fixture helpers.

# Usage, from anywhere: deploy/ci/ecr-copy-test.sh
set -euo pipefail

fx_issuer=https://token.actions.githubusercontent.com
fx_backend=https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
fx_frontend=https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main
fx_bundle=application/vnd.dev.sigstore.bundle.v0.3+json

# ecr_fakes BIN: writes the fakes into BIN. They read FAKE_REG (a file <digest>.json per manifest under
# FAKE_REG/<host>/<repository>/), FAKE_LOG, FAKE_ORAS_IMAGE, FAKE_FAIL_REFERRER (while it exists, the next copy of a
# referrer fails and removes it) and FAKE_AWS_ACCOUNTS ("profile=account ..."; a profile must match --registry-id).
ecr_fakes() {
  mkdir -p "$1"
  cat >"$1/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = run ] || { echo "fake docker: only run, not $1" >&2; exit 99; }
while [ $# -gt 0 ] && [ "$1" != "$FAKE_ORAS_IMAGE" ]; do shift; done
[ $# -gt 0 ] || { echo "fake docker: no image $FAKE_ORAS_IMAGE" >&2; exit 99; }
shift
exec "$(dirname "$0")/oras" "$@"
EOF
  cat >"$1/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "oras $*" >>"$FAKE_LOG"
cmd=$1
shift
pos=() flags=" "
while [ $# -gt 0 ]; do
  case $1 in
  --format | --artifact-type | --registry-config | --from-registry-config | --to-registry-config | \
    --from-distribution-spec | --to-distribution-spec)
    flags+="$1=$2 "
    shift 2
    ;;
  -r | --recursive) echo "fake oras: no -r" >&2; exit 98 ;;
  -*) flags+="$1 "; shift ;;
  *) pos+=("$1"); shift ;;
  esac
done
file() { echo "$FAKE_REG/${1%@*}/${1##*@}.json"; }
case $cmd in
discover)
  f=$(file "${pos[0]}")
  [ -f "$f" ] || { echo "Error: ${pos[0]}: not found" >&2; exit 1; }
  jq -s --arg s "${pos[0]##*@}" '{referrers: [.[] | select(.subject.digest == $s) | {digest, artifactType,
    annotations: {"dev.sigstore.bundle.predicateType": .svp.type}}]}' "$(dirname "$f")"/*.json
  ;;
manifest)
  f=$(file "${pos[1]}")
  [ -f "$f" ] || { echo "Error: ${pos[1]}: not found" >&2; exit 1; }
  jq 'del(.svp, .digest)' "$f"
  ;;
cp)
  [[ $flags == *" --from-distribution-spec=v1.1-referrers-tag "* &&
    $flags == *" --to-distribution-spec=v1.1-referrers-api "* ]] || { echo "fake oras: cp needs both specs" >&2; exit 97; }
  from=${pos[0]} to=${pos[1]}
  [[ $to != *@* ]] || { echo "fake oras: a destination by digest" >&2; exit 97; }
  f=$(file "$from")
  [ -f "$f" ] || { echo "Error: $from: not found" >&2; exit 1; }
  if jq -e .subject >/dev/null "$f" && [ -e "${FAKE_FAIL_REFERRER:-/nonexistent}" ]; then
    rm "$FAKE_FAIL_REFERRER"
    echo "Error: failed to copy to $to: 503 Service Unavailable" >&2
    exit 1
  fi
  mkdir -p "$FAKE_REG/$to"
  cp "$f" "$FAKE_REG/$to/"
  for c in $(jq -r '.manifests[]?.digest' "$f"); do cp "$FAKE_REG/${from%@*}/$c.json" "$FAKE_REG/$to/"; done
  ;;
*) echo "fake oras: no $cmd" >&2; exit 96 ;;
esac
EOF
  cat >"$1/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "cosign $*" >>"$FAKE_LOG"
cmd=$1
shift
type= issuer= identity= ref=
while [ $# -gt 0 ]; do
  case $1 in
  --type) type=$2; shift 2 ;;
  --certificate-oidc-issuer) issuer=$2; shift 2 ;;
  --certificate-identity) identity=$2; shift 2 ;;
  -*) shift ;;
  *) ref=$1; shift ;;
  esac
done
dir=$FAKE_REG/${ref%@*} s=${ref##*@}
[ -f "$dir/$s.json" ] || { echo "Error: $ref: MANIFEST_UNKNOWN" >&2; exit 1; }
case $cmd:$type in
verify:) pt=https://sigstore.dev/cosign/sign/v1 ;;
verify-attestation:vuln) pt=https://cosign.sigstore.dev/attestation/vuln/v1 ;;
verify-attestation:spdxjson) pt=https://spdx.dev/Document ;;
verify-attestation:slsaprovenance1) pt=https://slsa.dev/provenance/v1 ;;
*) echo "fake cosign: no $cmd $type" >&2; exit 95 ;;
esac
out=$(jq -sc --arg s "$s" --arg pt "$pt" --arg id "$identity" --arg iss "$issuer" '.[]
  | select(.subject.digest == $s and .svp.type == $pt and .svp.identity == $id and .svp.issuer == $iss)
  | {payloadType: "application/vnd.in-toto+json", payload: (.svp.statement | tojson | @base64)}' "$dir"/*.json)
if [ -z "$out" ]; then
  echo "Error: no matching signatures or attestations of $pt for $identity" >&2
  exit 1
fi
printf '%s\n' "$out"
EOF
  cat >"$1/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "aws ${AWS_PROFILE:-default} $*" >>"$FAKE_LOG"
op="$1 $2"
shift 2
ids=()
while [ $# -gt 0 ]; do
  case $1 in
  --region) region=$2; shift 2 ;;
  --registry-id) account=$2; shift 2 ;;
  --repository-name) name=$2; shift 2 ;;
  --image-ids)
    shift
    while [ $# -gt 0 ] && [[ $1 != --* ]]; do ids+=("${1#imageDigest=}"); shift; done
    ;;
  *) echo "fake aws: no $1" >&2; exit 94 ;;
  esac
done
for pair in ${FAKE_AWS_ACCOUNTS:-}; do
  if [ "${pair%%=*}" = "${AWS_PROFILE:-}" ] && [ "${pair#*=}" != "$account" ]; then
    echo "An error occurred (AccessDeniedException): profile ${AWS_PROFILE:-} is not of account $account" >&2
    exit 254
  fi
done
dir=$FAKE_REG/$account.dkr.ecr.$region.amazonaws.com/$name
case $op in
"ecr describe-images")
  [ -f "$dir/${ids[0]}.json" ] || {
    echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: The image with imageId {imageDigest:'${ids[0]}'} does not exist within the repository with name '$name' in the registry with id '$account'" >&2
    exit 254
  }
  echo '{"imageDetails": [{}]}'
  ;;
"ecr batch-delete-image")
  for d in "${ids[@]}"; do rm "$dir/$d.json"; done
  echo '{"imageIds": [], "failures": []}'
  ;;
*) echo "fake aws: no $op" >&2; exit 94 ;;
esac
EOF
  chmod 755 "$1/docker" "$1/oras" "$1/cosign" "$1/aws"
}

# fx_digest NAME: a made-up digest, unique per NAME.
fx_digest() { echo "sha256:$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1)"; }
# fx_ago HOURS: the time HOURS ago, as scanFinishedOn has it.
fx_ago() { jq -rn --argjson h "$1" 'now - $h * 3600 | floor | todate'; }
# fx_put REPO JSON: writes manifest JSON (its digest field names it) into REPO (<host>/<path>) of FAKE_REG.
fx_put() {
  mkdir -p "$FAKE_REG/$1"
  jq . <<<"$2" >"$FAKE_REG/$1/$(jq -r .digest <<<"$2").json"
}
# fx_bundle REPO SUBJECT PREDICATE_TYPE NAME IDENTITY STATEMENT: puts a Sigstore bundle of SUBJECT; prints its digest.
fx_bundle() {
  local d
  d=$(fx_digest "$4")
  fx_put "$1" "$(jq -n --arg d "$d" --arg s "$2" --arg pt "$3" --arg id "$5" --arg iss "$fx_issuer" --arg at "$fx_bundle" \
    --argjson st "$6" '{digest: $d, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: $at,
      subject: {digest: $s}, svp: {type: $pt, identity: $id, issuer: $iss, statement: $st}}')"
  echo "$d"
}
# fx_vuln REPO INDEX AMD64 ARM64 HOURS_AGO NAME [IDENTITY]: puts a vuln bundle of a scan finished HOURS_AGO; prints it.
fx_vuln() {
  fx_bundle "$1" "$2" https://cosign.sigstore.dev/attestation/vuln/v1 "$6" "${7:-$fx_backend}" "$(jq -n \
    --arg d "${2#sha256:}" --arg a "$3" --arg r "$4" --arg t "$(fx_ago "$5")" '{
      predicateType: "https://cosign.sigstore.dev/attestation/vuln/v1", subject: [{digest: {sha256: $d}}],
      predicate: {metadata: {scanFinishedOn: $t}, scanner: {result: {platforms: [
        {platform: "linux/amd64", digest: $a, report: {Results: []}},
        {platform: "linux/arm64", digest: $r, report: {Results: []}}]}}}}')"
}
# shellcheck disable=SC2034 # fx_prov and fx_sbom_amd64 are set for the callers that read them
# fx_release REPO NAME [HOURS_AGO [IDENTITY]]: puts a release as image-sign leaves it in REPO; sets fx_index, fx_amd64,
# fx_arm64 and fx_sign, fx_vuln, fx_prov, fx_sbom_amd64, fx_sbom_arm64 (the digests of its five bundles).
fx_release() {
  local repo=$1 n=$2 age=${3:-1} id=${4:-$fx_backend} source=https://github.com/anhnvcoder/svp-backend
  [ "$id" != "$fx_frontend" ] || source=https://github.com/anhnvcoder/svp-frontend
  fx_index=$(fx_digest "$n-index") fx_amd64=$(fx_digest "$n-amd64") fx_arm64=$(fx_digest "$n-arm64")
  fx_put "$repo" "$(jq -n --arg d "$fx_amd64" '{digest: $d, mediaType: "application/vnd.oci.image.manifest.v1+json"}')"
  fx_put "$repo" "$(jq -n --arg d "$fx_arm64" '{digest: $d, mediaType: "application/vnd.oci.image.manifest.v1+json"}')"
  fx_put "$repo" "$(jq -n --arg d "$fx_index" --arg a "$fx_amd64" --arg r "$fx_arm64" '{digest: $d,
    mediaType: "application/vnd.oci.image.index.v1+json", manifests: [
      {digest: $a, platform: {os: "linux", architecture: "amd64"}},
      {digest: $r, platform: {os: "linux", architecture: "arm64"}}]}')"
  fx_sign=$(fx_bundle "$repo" "$fx_index" https://sigstore.dev/cosign/sign/v1 "$n-sign" "$id" '{}')
  fx_vuln=$(fx_vuln "$repo" "$fx_index" "$fx_amd64" "$fx_arm64" "$age" "$n-vuln" "$id")
  fx_prov=$(fx_bundle "$repo" "$fx_index" https://slsa.dev/provenance/v1 "$n-prov" "$id" "$(jq -n \
    --arg d "${fx_index#sha256:}" --arg b "$id" --arg r "$source" '{predicateType: "https://slsa.dev/provenance/v1",
      subject: [{digest: {sha256: $d}}], predicate: {runDetails: {builder: {id: $b}}, buildDefinition: {
        externalParameters: {workflow: {repository: $r, ref: "refs/heads/main"}},
        resolvedDependencies: [{digest: {gitCommit: "0123456789abcdef0123456789abcdef01234567"}}]}}}')")
  fx_sbom_amd64=$(fx_bundle "$repo" "$fx_amd64" https://spdx.dev/Document "$n-sbom-amd64" "$id" '{}')
  fx_sbom_arm64=$(fx_bundle "$repo" "$fx_arm64" https://spdx.dev/Document "$n-sbom-arm64" "$id" '{}')
}
# fx_rescan REPO INDEX NAME: what rescan_one leaves on GHCR: one new vuln bundle of INDEX, the older ones gone.
fx_rescan() {
  local index children new f
  index=$FAKE_REG/$1/$2.json
  children=$(jq -r '.manifests[].digest' "$index")
  # shellcheck disable=SC2086 # two digests
  new=$(fx_vuln "$1" "$2" $children 0 "$3")
  for f in $(fx_bundles "$1" "$2" https://cosign.sigstore.dev/attestation/vuln/v1); do
    [ "$f" = "$new" ] || rm "$FAKE_REG/$1/$f.json"
  done
  echo "$new"
}
# fx_bundles REPO SUBJECT PREDICATE_TYPE: the digests of SUBJECT's bundles of PREDICATE_TYPE in REPO, one per line.
fx_bundles() {
  [ -d "$FAKE_REG/$1" ] || return 0
  jq -rs --arg s "$2" --arg pt "$3" '.[] | select(.subject.digest == $s and .svp.type == $pt) | .digest' \
    "$FAKE_REG/$1"/*.json | sort
}

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

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
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

# A copy of what ecr-copy.sh reads (deploy/ci/, lib.sh, the policy's values and sources), without the Makefile: the
# ORAS image comes from the environment, so the fake docker can tell it.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/docker-bake.json" "$tree/deploy/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
ecr_fakes "$work/bin"
mkdir -p "$work/docker" "$work/home"
echo '{}' >"$work/docker/config.json"
oras_image=registry.example/oras:v0@sha256:$(printf 'e%.0s' $(seq 64))
account=111111111111
ecr=$account.dkr.ecr.ap-southeast-1.amazonaws.com
ghcr=ghcr.io/anhnvcoder/svp-backend
export FAKE_REG=$work/reg FAKE_LOG=$work/calls.log

# run NAME WANT_RC COMMAND ARGS...: ecr-copy.sh COMMAND ARGS... with the fakes first on PATH and none of a CI job's
# variables; its output in out/NAME, the calls of the fakes in calls.log (emptied first).
mkdir -p "$work/out"
run() {
  local name=$1 want=$2 rc=0
  shift 2
  : >"$FAKE_LOG"
  env -i PATH="$work/bin:$PATH" HOME="$work/home" TMPDIR="${TMPDIR:-/tmp}" DOCKER_CONFIG="$work/docker" \
    ORAS_IMAGE="$oras_image" FAKE_ORAS_IMAGE="$oras_image" FAKE_REG="$FAKE_REG" FAKE_LOG="$FAKE_LOG" \
    FAKE_FAIL_REFERRER="$work/fail-referrer" "$tree/deploy/ci/ecr-copy.sh" "$@" >"$work/out/$name" 2>&1 || rc=$?
  same "$name (exit $want)" "$want" "$rc"
  [ "$rc" = "$want" ] || sed 's/^/      | /' "$work/out/$name" >&2
  check "$name: the account ID is never printed" lacks "$work/out/$name" "$account"
}
# count NAME REPO SUBJECT PREDICATE_TYPE WANT: ok when ECR's REPO holds WANT bundles of PREDICATE_TYPE on SUBJECT.
count() { same "$1" "$5" "$(fx_bundles "$ecr/$2" "$3" "$4" | grep -c . || true)"; }
vuln_type=https://cosign.sigstore.dev/attestation/vuln/v1
sign_type=https://sigstore.dev/cosign/sign/v1
sbom_type=https://spdx.dev/Document
prov_type=https://slsa.dev/provenance/v1

# --- copy: a release new to ECR, every kind of bundle on its subject.
fx_release "$ghcr/gateway" gateway
run "copy: a new release" 0 copy "$ghcr/gateway" "$fx_index" "$ecr"
check "copy: prints the reference copied to, its account hidden" has "$work/out/copy: a new release" \
  "<account>.dkr.ecr.ap-southeast-1.amazonaws.com/svp-backend/gateway@$fx_index"
check "copy: the index and both manifests" test -f "$FAKE_REG/$ecr/svp-backend/gateway/$fx_index.json" -a \
  -f "$FAKE_REG/$ecr/svp-backend/gateway/$fx_amd64.json" -a -f "$FAKE_REG/$ecr/svp-backend/gateway/$fx_arm64.json"
count "copy: the signature on the index" svp-backend/gateway "$fx_index" "$sign_type" 1
count "copy: the vuln on the index" svp-backend/gateway "$fx_index" "$vuln_type" 1
count "copy: the provenance on the index" svp-backend/gateway "$fx_index" "$prov_type" 1
count "copy: the SBOM on linux/amd64" svp-backend/gateway "$fx_amd64" "$sbom_type" 1
count "copy: the SBOM on linux/arm64" svp-backend/gateway "$fx_arm64" "$sbom_type" 1
check "copy: oras copies without -r, GHCR's fallback tag to ECR's referrers API" has "$FAKE_LOG" \
  "oras cp --no-tty --from-registry-config /auth/config.json --to-registry-config /auth/config.json --from-distribution-spec v1.1-referrers-tag --to-distribution-spec v1.1-referrers-api $ghcr/gateway@$fx_index $ecr/svp-backend/gateway"
check "copy: verified in ECR with backend's identity" has "$FAKE_LOG" \
  "cosign verify --certificate-oidc-issuer $fx_issuer --certificate-identity $fx_backend $ecr/svp-backend/gateway@$fx_index"
check "copy: the SBOM verified on its manifest" has "$FAKE_LOG" \
  "cosign verify-attestation --type spdxjson --certificate-oidc-issuer $fx_issuer --certificate-identity $fx_backend $ecr/svp-backend/gateway@$fx_arm64"
check "copy: the provenance verified on the index" has "$FAKE_LOG" \
  "cosign verify-attestation --type slsaprovenance1 --certificate-oidc-issuer $fx_issuer --certificate-identity $fx_backend $ecr/svp-backend/gateway@$fx_index"
gateway=$fx_index gateway_sbom_arm64=$fx_sbom_arm64

# --- copy: all there already: nothing copied, still verified.
run "copy: all in ECR" 0 copy "$ghcr/gateway" "$gateway" "$ecr"
check "copy: all in ECR: nothing copied" lacks "$FAKE_LOG" "oras cp"
check "copy: all in ECR: still verified" has "$FAKE_LOG" "cosign verify --certificate-oidc-issuer"

# --- copy: cut off after the index (the first referrer fails), then run again.
fx_release "$ghcr/user-service" user-service
touch "$work/fail-referrer"
run "copy: a referrer fails" 1 copy "$ghcr/user-service" "$fx_index" "$ecr"
check "copy: a referrer fails: the index is there" test -f "$FAKE_REG/$ecr/svp-backend/user-service/$fx_index.json"
count "copy: a referrer fails: no signature yet" svp-backend/user-service "$fx_index" "$sign_type" 0
check "copy: a referrer fails: names it" has "$work/out/copy: a referrer fails" "FAIL  copy the signature $fx_sign of $fx_index"
run "copy: run again after the failure" 0 copy "$ghcr/user-service" "$fx_index" "$ecr"
check "copy: run again: the index not copied again" lacks "$FAKE_LOG" "$ghcr/user-service@$fx_index $ecr"
count "copy: run again: the signature" svp-backend/user-service "$fx_index" "$sign_type" 1
count "copy: run again: the vuln" svp-backend/user-service "$fx_index" "$vuln_type" 1
count "copy: run again: the provenance" svp-backend/user-service "$fx_index" "$prov_type" 1
count "copy: run again: the SBOM of linux/amd64" svp-backend/user-service "$fx_amd64" "$sbom_type" 1
count "copy: run again: the SBOM of linux/arm64" svp-backend/user-service "$fx_arm64" "$sbom_type" 1

# --- copy: only the SBOM of one manifest missing.
rm "$FAKE_REG/$ecr/svp-backend/gateway/$gateway_sbom_arm64.json"
run "copy: one SBOM missing" 0 copy "$ghcr/gateway" "$gateway" "$ecr"
same "copy: one SBOM missing: that one copied, nothing else" 1 "$(grep -c '^oras cp' "$FAKE_LOG")"
check "copy: one SBOM missing: copied from GHCR" has "$FAKE_LOG" "$ghcr/gateway@$gateway_sbom_arm64 $ecr/svp-backend/gateway"

# --- copy: ECR's vuln older than maxAttestationAge; GHCR's newer one is not copied over it, the copy fails.
fx_release "$ghcr/video-service" video-service 100
run "copy: the vuln in ECR too old" 1 copy "$ghcr/video-service" "$fx_index" "$ecr"
video=$fx_index video_amd64=$fx_amd64 video_arm64=$fx_arm64 video_old=$fx_vuln
check "copy: the vuln too old: names the rescan with values_ref" has "$work/out/copy: the vuln in ECR too old" \
  "gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f rescan=true and -f values_ref="
check "copy: the vuln too old: and the dispatch of one digest" has "$work/out/copy: the vuln in ECR too old" \
  "-f image=video-service -f digest=$video -f env=<stg|prd>"
new=$(fx_rescan "$ghcr/video-service" "$video" video-service-vuln-2)
run "copy: GHCR rescanned, ECR's vuln still too old" 1 copy "$ghcr/video-service" "$video" "$ecr"
check "copy: GHCR rescanned: its vuln kept out" lacks "$FAKE_LOG" "$ghcr/video-service@$new"
count "copy: GHCR rescanned: ECR keeps one vuln" svp-backend/video-service "$video" "$vuln_type" 1

# --- refresh: the new vuln in, the old one deleted, nothing else.
rm "$FAKE_REG/$ecr/svp-backend/video-service/$(fx_bundles "$ecr/svp-backend/video-service" "$video_arm64" "$sbom_type").json"
run "refresh: a newer vuln on GHCR" 0 refresh "$ghcr/video-service" "$video" "$ecr"
same "refresh: exactly the new vuln in ECR" "$new" "$(fx_bundles "$ecr/svp-backend/video-service" "$video" "$vuln_type")"
check "refresh: the old one deleted through ECR's API" has "$FAKE_LOG" \
  "aws default ecr batch-delete-image --region ap-southeast-1 --registry-id $account --repository-name svp-backend/video-service --image-ids imageDigest=$video_old"
count "refresh: the signature kept" svp-backend/video-service "$video" "$sign_type" 1
count "refresh: the provenance kept" svp-backend/video-service "$video" "$prov_type" 1
count "refresh: the SBOM of linux/amd64 kept" svp-backend/video-service "$video_amd64" "$sbom_type" 1
count "refresh: the missing SBOM of linux/arm64 copied" svp-backend/video-service "$video_arm64" "$sbom_type" 1
run "copy: after the refresh" 0 copy "$ghcr/video-service" "$video" "$ecr"
check "copy: after the refresh: nothing copied" lacks "$FAKE_LOG" "oras cp"

# --- refresh: two older vuln bundles in ECR, both deleted in one call.
fx_vuln "$ecr/svp-backend/video-service" "$video" "$video_amd64" "$video_arm64" 90 stray-a >/dev/null
new=$(fx_rescan "$ghcr/video-service" "$video" video-service-vuln-3)
run "refresh: two older ones" 0 refresh "$ghcr/video-service" "$video" "$ecr"
same "refresh: two older ones: one vuln left, the new one" "$new" \
  "$(fx_bundles "$ecr/svp-backend/video-service" "$video" "$vuln_type")"
same "refresh: two older ones: one delete call" 1 "$(grep -c 'batch-delete-image' "$FAKE_LOG")"

# --- refresh: a release ECR does not hold is left out; no error.
fx_release "$ghcr/feed-service" feed-service
run "refresh: not in ECR" 0 refresh "$ghcr/feed-service" "$fx_index" "$ecr"
check "refresh: not in ECR: says so" has "$work/out/refresh: not in ECR" "skip  ECR has no $fx_index"
check "refresh: not in ECR: nothing copied" lacks "$FAKE_LOG" "oras cp"
check "refresh: not in ECR: nothing deleted" lacks "$FAKE_LOG" "batch-delete-image"

# --- copy: signed by another identity than its source's (svp-frontend's workflow for a backend image): stops.
fx_release "$ghcr/media-worker" media-worker 1 "$fx_frontend"
run "copy: another identity" 1 copy "$ghcr/media-worker" "$fx_index" "$ecr"
check "copy: another identity: names the one expected" has "$work/out/copy: another identity" \
  "has no signature of $fx_backend"

# --- Refused before any registry or account is asked.
refused() {
  run "$1" 1 "${@:3}"
  check "$1: says why" has "$work/out/$1" "$2"
  check "$1: asks no registry" test ! -s "$FAKE_LOG"
}
refused "copy: a drill image" "is no release repository" copy "$ghcr/drill-vulnerable" "$gateway" "$ecr"
refused "copy: no ECR host" "REGISTRY is no ECR host" copy "$ghcr/gateway" "$gateway" .dkr.ecr.ap-southeast-1.amazonaws.com
refused "copy: no digest" "is not sha256:<64 hex>" copy "$ghcr/gateway" latest "$ecr"
refused "delete: no such command" "usage: ecr-copy.sh copy|refresh" delete "$ghcr/gateway" "$gateway" "$ecr"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
