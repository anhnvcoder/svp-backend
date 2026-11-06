#!/usr/bin/env bash
# Tests for verify-release.sh, for values-check.sh (which runs it on the releases of a pull request of svp-gitops) and
# for the release sources in common.sh. A fake cosign first on PATH answers from fixtures, on a tree laid out as
# svp-gitops beside a throwaway checkout of what the scripts read: no network, no Docker, no cluster; runs on macOS
# and Linux.

# Usage, from anywhere: deploy/ci/verify-release-test.sh
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

# --- The fake cosign records its arguments in cosign.log and refuses every signature; with FAKE_COSIGN_DIR set it
# accepts every signature, prints FAKE_COSIGN_DIR/<type>.jsonl for verify-attestation --type <type> (refusing without
# that file), and with --certificate-github-workflow-sha accepts only the commit in FAKE_COSIGN_DIR/cert-sha.
mkdir -p "$work/bin" "$work/home"
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
if [ -n "${FAKE_COSIGN_DIR:-}" ]; then
  case $1 in
  verify) exit 0 ;;
  verify-attestation)
    type= sha=
    while [ $# -gt 0 ]; do
      case $1 in
      --type) type=$2 && shift ;;
      --certificate-github-workflow-sha) sha=$2 && shift ;;
      esac
      shift
    done
    # FAKE_COSIGN_DOWN=TYPE: the registry is out of reach for that type; with FAKE_COSIGN_DOWN_ONCE=FILE only for the
    # first call, which writes FILE.
    if [ "${FAKE_COSIGN_DOWN:-}" = "$type" ] && { [ -z "${FAKE_COSIGN_DOWN_ONCE:-}" ] || [ ! -e "$FAKE_COSIGN_DOWN_ONCE" ]; }; then
      [ -z "${FAKE_COSIGN_DOWN_ONCE:-}" ] || : >"$FAKE_COSIGN_DOWN_ONCE"
      echo "Error: GET https://ghcr.io/v2/: dial tcp: i/o timeout" >&2
      exit 1
    fi
    if [ ! -f "$FAKE_COSIGN_DIR/$type.jsonl" ]; then
      echo "Error: none of the attestations matched the predicate type: $type" >&2
      exit 1
    fi
    if [ -n "$sha" ] && [ "$sha" != "$(cat "$FAKE_COSIGN_DIR/cert-sha")" ]; then
      echo "Error: expected GitHub Workflow SHA not found in certificate" >&2
      exit 1
    fi
    cat "$FAKE_COSIGN_DIR/$type.jsonl"
    exit 0
    ;;
  esac
fi
echo "Error: no signatures found" >&2
exit 1
EOF
chmod 755 "$work/bin/cosign"

# on github|local COMMAND...: runs COMMAND with the variables of a made-up GitHub Actions job, or on a machine with
# none of them; the fake cosign first on PATH. git reads no configuration of this machine.
on() {
  local where=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_SHA -u RUNNER_TEMP -u GIT_DIR
    -u GIT_WORK_TREE -u SVP_CODE_ROOT -u SVP_GITOPS_DIR
    PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    FAKE_COSIGN_LOG="$work/cosign.log")
  case $where in
  github)
    "${base[@]}" GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  esac
}
# fresh: empties the files of a job and the log of the fake.
fresh() { : >"$work/output" && : >"$work/summary" && : >"$work/cosign.log"; }

# --- A throwaway checkout of what the scripts read: deploy/ci/, deploy/k8s/lib.sh and the policy's values.
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
digest_a=sha256:$(printf 'a%.0s' $(seq 64))
digest_b=sha256:$(printf 'b%.0s' $(seq 64))

# --- verify-release.sh: build provenance, only where the policy checks it. A copy of the throwaway checkout, whose
# history the cases below change freely, and a tree laid out as svp-gitops (envs/<env>/charts.yaml pinning a commit
# of the copy, overlays envs/<env>/svp-policy.yaml), a git repository whose origin names svp-gitops (never reached);
# the fake cosign answers from $fx.
vr=$work/vr
cp -R "$tree" "$vr"
gv() {
  GIT_DIR=$vr/.git GIT_WORK_TREE=$vr GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
cfg=$work/cfg
gc() {
  GIT_DIR=$cfg/.git GIT_WORK_TREE=$cfg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
off_rev=$(gv rev-parse HEAD)
sed 's/^  requireProvenance: false$/  requireProvenance: true/' "$tree/deploy/helm/svp-policy/values.yaml" \
  >"$vr/deploy/helm/svp-policy/values.yaml"
gv commit -qam "provenance on in the policy's values"
on_rev=$(gv rev-parse HEAD)
gv checkout -q "$off_rev" -- deploy/helm/svp-policy/values.yaml && gv commit -qm "provenance off again"
off_rev=$(gv rev-parse HEAD)
gv update-ref refs/remotes/origin/main HEAD
# charts ENV REV: envs/ENV/charts.yaml of the tree pins commit REV of the copy.
charts() {
  printf 'revision: %s\npodSecurityVersion: v1.36\ncollectorConfigSha256: %s\n' "$2" "$(printf '0%.0s' $(seq 64))" \
    >"$cfg/envs/$1/charts.yaml"
}
overlay() { printf 'imageVerification:\n  requireProvenance: %s\n' "$2" >"$cfg/envs/$1/svp-policy.yaml"; }
mkdir -p "$cfg/envs/stg/images" "$cfg/envs/prd/images" "$cfg/base"
echo "# The base values" >"$cfg/base/README.md"
for env in stg prd; do
  charts "$env" "$off_rev"
  for svc in gateway user-service video-service engagement-service feed-service media-worker; do
    printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-backend/%s\n  tag: ""\n  digest: ""\n' "$svc" \
      >"$cfg/envs/$env/images/$svc.yaml"
  done
  printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-frontend/web\n  tag: ""\n  digest: ""\n' \
    >"$cfg/envs/$env/images/web.yaml"
done
gc init -q -b main && gc add -A && gc commit -qm init
gc remote add origin https://github.com/anhnvcoder/svp-gitops.git
fx=$work/cosign-fixtures
mkdir -p "$fx"
image=ghcr.io/anhnvcoder/svp-backend/gateway
subject=https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
commit=0123456789abcdef0123456789abcdef01234567
# envelope: an in-toto statement on stdin as cosign verify-attestation prints it, one line.
envelope() { jq -c '{payloadType: "application/vnd.in-toto+json", payload: (tojson | @base64)}'; }
jq -n --arg d "${digest_a#sha256:}" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$digest_b" '{
  predicateType: "https://cosign.sigstore.dev/attestation/vuln/v1", subject: [{digest: {sha256: $d}}],
  predicate: {scanner: {result: {platforms: [{platform: "linux/amd64", digest: $p, report: {}},
    {platform: "linux/arm64", digest: $p, report: {}}]}}, metadata: {scanFinishedOn: $t}}}' | envelope >"$fx/vuln.jsonl"
# provenance [JQ]: the provenance.jsonl CI's predicate would give for $digest_a, changed by the jq filter JQ.
provenance() {
  jq -n --arg d "${digest_a#sha256:}" --arg b "$subject" --arg c "$commit" '{
    predicateType: "https://slsa.dev/provenance/v1", subject: [{name: "gateway", digest: {sha256: $d}}],
    predicate: {buildDefinition: {buildType: "https://actions.github.io/buildtypes/workflow/v1",
      externalParameters: {workflow: {ref: "refs/heads/main",
        repository: "https://github.com/anhnvcoder/svp-backend", path: ".github/workflows/images.yml"}},
      resolvedDependencies: [{uri: "git+https://github.com/anhnvcoder/svp-backend@refs/heads/main",
        digest: {gitCommit: $c}}]},
      runDetails: {builder: {id: $b}, metadata: {invocationId: "https://github.com/x/runs/1/attempts/1"}}}}' |
    jq -c "${1:-.}" | envelope >"$fx/slsaprovenance1.jsonl"
}
echo "$commit" >"$fx/cert-sha"
# release NAME WANT_RC [ARGS...]: verify-release.sh --gitops <tree> [ARGS...] $image $digest_a on a machine, output in
# vr.out.
release() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on local env FAKE_COSIGN_DIR="$fx" "$vr/deploy/ci/verify-release.sh" --gitops "$cfg" "$@" "$image" "$digest_a" \
    >"$work/vr.out" 2>&1 || rc=$?
  same "verify-release.sh: $name (exit $want)" "$want" "$rc"
}

rm -f "$fx/slsaprovenance1.jsonl"
release "provenance off everywhere: signature and vuln only" 0
check "verify-release.sh: provenance off: no provenance asked for" lacks "$work/cosign.log" slsaprovenance1
check "verify-release.sh: provenance off: the ok line names no provenance" lacks "$work/vr.out" "provenance of"

overlay stg true
release "on in the stg overlay, the release has no provenance" 1
check "verify-release.sh: names the missing provenance and the release to build again" has "$work/vr.out" \
  "has no provenance attestation of https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main, which the policy requires here: a release built before CI attested provenance; release it again (gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f services=gateway)"
FAKE_COSIGN_DOWN=slsaprovenance1 release "on in the stg overlay, GHCR out of reach for the provenance" 1
check "verify-release.sh: an unreachable registry is not read as a release from before provenance" has "$work/vr.out" \
  "its provenance attestation could not be verified (Error: GET https://ghcr.io/v2/: dial tcp: i/o timeout); check again, do not build it again"
check "verify-release.sh: an unreachable registry asks for no new build" lacks "$work/vr.out" "release it again"
release "on in stg only, checked for prd: no provenance needed" 0 --env prd
check "verify-release.sh: for prd no provenance asked for" lacks "$work/cosign.log" slsaprovenance1

provenance
release "on, a provenance that matches the policy and the certificate" 0
check "verify-release.sh: the ok line names the provenance's commit" has "$work/vr.out" \
  "provenance of ${commit:0:12} by $subject"
check "verify-release.sh: the certificate is asked for the provenance's commit" has "$work/cosign.log" \
  "verify-attestation --type slsaprovenance1 --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity $subject --certificate-github-workflow-sha $commit $image@$digest_a"
# The contract with step 5 of gitops-check.sh: tag_provenance_mismatch of common.sh reads this very ok line.
tp=$work/tag-provenance
mkdir -p "$tp/envs/stg/images"
{ echo "check envs/stg/images/web.yaml" && grep '^ok ' "$work/vr.out"; } >"$work/tp.out"
# tp_case NAME TAG WANT: image.tag TAG in envs/stg/images/web.yaml, stg requiring provenance; the output must be WANT.
tp_case() {
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' "$image" "$2" "$digest_a" >"$tp/envs/stg/images/web.yaml"
  same "tag_provenance_mismatch on the ok line of verify-release.sh: $1" "$3" \
    "$(on local bash -c '. "$1/deploy/ci/common.sh" && tag_provenance_mismatch "$2" "$3" stg' _ "$vr" "$tp" "$work/tp.out")"
}
tp_case "the tag of the provenance's commit agrees" "${commit:0:12}" ""
tp_case "another tag is a mismatch" 89abcdef0123 \
  "envs/stg/images/web.yaml: image.tag is 89abcdef0123, but its provenance says it was built from ${commit:0:12}"
FAKE_COSIGN_DOWN=slsaprovenance1 FAKE_COSIGN_DOWN_ONCE=$work/cosign-once release \
  "on, GHCR out of reach once, then the provenance verifies" 1
rm -f "$work/cosign-once"
check "verify-release.sh: a provenance that verifies on the second call is not read as missing" has "$work/vr.out" \
  "its provenance attestation could not be verified (cosign failed once, then verified one); check again, do not build it again"
check "verify-release.sh: a provenance that verifies on the second call asks for no new build" lacks "$work/vr.out" \
  "release it again"

echo 89abcdef0123456789abcdef0123456789abcdef >"$fx/cert-sha"
release "the certificate names another commit" 1
check "verify-release.sh: says the commits differ" has "$work/vr.out" \
  "the provenance names commit $commit, the certificate of its signature another (or none)"
echo "$commit" >"$fx/cert-sha"

# provenance_case NAME JQ MESSAGE: a provenance changed by JQ is refused with MESSAGE.
provenance_case() {
  provenance "$2"
  release "$1" 1
  check "verify-release.sh: $1: says why" has "$work/vr.out" "$3"
}
provenance_case "another builder" '.predicate.runDetails.builder.id = "https://github.com/x/y/.github/workflows/z.yml@refs/heads/main"' \
  "provenance builder.id is https://github.com/x/y/.github/workflows/z.yml@refs/heads/main, not $subject"
provenance_case "another repository" \
  '.predicate.buildDefinition.externalParameters.workflow.repository = "https://github.com/fork/svp-backend"' \
  "provenance workflow repository is https://github.com/fork/svp-backend, not https://github.com/anhnvcoder/svp-backend"
provenance_case "another ref" '.predicate.buildDefinition.externalParameters.workflow.ref = "refs/heads/feat/x"' \
  "provenance workflow ref is refs/heads/feat/x, not refs/heads/main"
provenance_case "another digest" '.subject[0].digest.sha256 = "'"${digest_b#sha256:}"'"' \
  "provenance the attestation is not about this digest"
provenance_case "not SLSA v1" '.predicateType = "https://slsa.dev/provenance/v0.2"' "provenance not a SLSA v1 provenance"
provenance_case "a short commit" '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit = "0123456"' \
  "provenance resolvedDependencies does not name exactly one commit"
provenance
cat "$fx/slsaprovenance1.jsonl" "$fx/slsaprovenance1.jsonl" >"$fx/two" && mv "$fx/two" "$fx/slsaprovenance1.jsonl"
release "two provenance attestations" 1
check "verify-release.sh: two provenance attestations: says so" has "$work/vr.out" "carries 2 provenance attestations, not exactly one"

# At a commit of the tree (--rev), not as it is on disk.
rm -f "$fx/slsaprovenance1.jsonl"
before=$(gc rev-parse HEAD)
gc add -A envs && gc commit -qm "provenance on in stg"
on_stg=$(gc rev-parse HEAD)
rm "$cfg/envs/stg/svp-policy.yaml"
release "off on disk" 0
release "on at a commit (--rev --env stg), no provenance" 1 --rev "$on_stg" --env stg
check "verify-release.sh: on at a commit: the provenance is missing" has "$work/vr.out" "has no provenance attestation"
release "at the commit before (--rev), off" 0 --rev "$before" --env stg

# Without --gitops: the clone gitops_dir names (SVP_GITOPS_DIR here), as it is on disk.
overlay stg true
rc=0
fresh
on local env FAKE_COSIGN_DIR="$fx" SVP_GITOPS_DIR="$cfg" "$vr/deploy/ci/verify-release.sh" "$image" "$digest_a" \
  >"$work/vr.out" 2>&1 || rc=$?
same "verify-release.sh: the clone of SVP_GITOPS_DIR, on in its stg overlay, no provenance (exit 1)" 1 "$rc"
rc=0
on local env FAKE_COSIGN_DIR="$fx" SVP_GITOPS_DIR="$work/none" "$vr/deploy/ci/verify-release.sh" "$image" "$digest_a" \
  >"$work/vr.out" 2>&1 || rc=$?
same "verify-release.sh: no clone of svp-gitops (exit 1)" 1 "$rc"
check "verify-release.sh: no clone: names what to clone" has "$work/vr.out" "is not a clone of svp-gitops"
rm "$cfg/envs/stg/svp-policy.yaml"

# On in the values at the commit charts.yaml pins: every environment without an overlay inherits it; one that turns it
# off is off. A charts.yaml naming no commit of the copy is refused.
charts stg "$on_rev"
charts prd "$on_rev"
release "on in the values at the pinned commit, no provenance" 1
check "verify-release.sh: on in the values: the provenance is missing" has "$work/vr.out" "has no provenance attestation"
overlay stg false
release "on in the values, off in the stg overlay, checked for stg" 0 --env stg
release "on in the values, prd without overlay, checked for any environment" 1
charts prd "$(printf 'f%.0s' $(seq 40))"
release "a charts.yaml naming no commit of this clone" 1 --env prd
check "verify-release.sh: a charts.yaml naming no commit: names it" has "$work/vr.out" \
  "envs/prd/charts.yaml names no commit of this clone holding deploy/helm/svp-policy/values.yaml"
charts stg "$off_rev"
charts prd "$off_rev"

# Overlays of another shape: refused, never read as off.
printf 'imageVerification:\n  requireProvenance: "true"\n' >"$cfg/envs/stg/svp-policy.yaml"
release "an overlay with a quoted value" 1
check "verify-release.sh: a quoted value: names the overlay" has "$work/vr.out" \
  "envs/stg/svp-policy.yaml: the overlay of svp-policy holds exactly"
printf 'imageVerification:\n  requireProvenance: false\n  mode: Audit\n' >"$cfg/envs/stg/svp-policy.yaml"
release "an overlay that sets another key" 1
check "verify-release.sh: another key: names the overlay" has "$work/vr.out" \
  "envs/stg/svp-policy.yaml: the overlay of svp-policy holds exactly"
printf 'imageVerification: {requireProvenance: true}\n' >"$cfg/envs/stg/svp-policy.yaml"
release "an overlay in flow style" 1
check "verify-release.sh: an overlay refused: cosign never asked" test ! -s "$work/cosign.log"

# Release sources: each image is verified with the identity of the source whose prefix it is under, at the revision
# the environment's charts.yaml pins. A commit of the copy from before the table (the policy's values with the
# identity lines, no files/sources.json) stops the check, naming the commit, before cosign is asked anything.
web_image=ghcr.io/anhnvcoder/svp-frontend/web
web_subject=https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main
backend_image=$image
legacy_subject=https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main
gv rm -q -r deploy/helm/svp-policy/files
awk -v s="$legacy_subject" '{ print }
  /^  namespace: / {
    print "  imagePrefix: ghcr.io/anhnvcoder/short-video-platform/"
    print "  issuer: https://token.actions.githubusercontent.com"
    print "  subject: " s
    print "  provenanceRepository: https://github.com/anhnvcoder/short-video-platform"
    print "  provenanceRef: refs/heads/main"
  }' "$tree/deploy/helm/svp-policy/values.yaml" >"$vr/deploy/helm/svp-policy/values.yaml"
gv add deploy/helm/svp-policy/values.yaml && gv commit -qm "the policy before the table of release sources"
legacy_rev=$(gv rev-parse HEAD)
gv checkout -q "$off_rev" -- deploy/helm/svp-policy && gv commit -qm "the table of release sources again"
same "verify-release.sh: the copy is back on the table of release sources" "" "$(gv diff "$off_rev" HEAD)"
overlay stg false
overlay prd false
image=$web_image
release "the web source's image, signed by svp-frontend" 0 --env stg
check "verify-release.sh: the web source's image is verified with svp-frontend's identity" has "$work/cosign.log" \
  "verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity $web_subject $web_image@$digest_a"
check "verify-release.sh: the web source's image is never verified with the backend's identity" lacks "$work/cosign.log" \
  "--certificate-identity $subject"
overlay stg true
provenance '.predicate.runDetails.builder.id = "'"$web_subject"'"
  | .predicate.buildDefinition.externalParameters.workflow.repository = "https://github.com/anhnvcoder/svp-frontend"'
release "the web source's image with svp-frontend's provenance, on in stg" 0 --env stg
check "verify-release.sh: the ok line names svp-frontend's identity" has "$work/vr.out" "provenance of ${commit:0:12} by $web_subject"
provenance
release "the web source's image with the backend's provenance" 1 --env stg
check "verify-release.sh: the backend's builder is refused for the web source" has "$work/vr.out" \
  "provenance builder.id is $subject, not $web_subject"
rm -f "$fx/slsaprovenance1.jsonl"
overlay stg false
image=ghcr.io/anhnvcoder/svp-frontend/gateway
release "the gateway under the web source's prefix" 1 --env stg
check "verify-release.sh: a service the source does not publish: names what is admitted" has "$work/vr.out" \
  "ghcr.io/anhnvcoder/svp-frontend/gateway is not a release of gateway that the policy of stg admits (at ${off_rev:0:12}: ghcr.io/anhnvcoder/svp-backend/gateway)"
check "verify-release.sh: a service the source does not publish: cosign never asked" test ! -s "$work/cosign.log"
charts stg "$legacy_rev"
image=$backend_image
release "an image at a commit before the table" 1 --env stg
check "verify-release.sh: a commit before the table stops, naming it" has "$work/vr.out" \
  "commit ${legacy_rev:0:12} has no deploy/helm/svp-policy/files/sources.json"
check "verify-release.sh: a commit before the table: cosign never asked" test ! -s "$work/cosign.log"
charts stg "$off_rev"
charts prd "$legacy_rev"
image=$web_image
release "the web source's image, prd before the table, every environment" 1
check "verify-release.sh: every environment: prd before the table stops, naming it" has "$work/vr.out" \
  "commit ${legacy_rev:0:12} has no deploy/helm/svp-policy/files/sources.json"
release "the web source's image, prd before the table, checked for stg" 0 --env stg
charts prd "$off_rev"
image=$backend_image
rm "$cfg/envs/stg/svp-policy.yaml" "$cfg/envs/prd/svp-policy.yaml"

# The functions of common.sh that name no source keep to source backend; a repository's source is read by its prefix;
# oci_labels names the repository of its source and the commit of code_root (SVP_CODE_ROOT, this checkout without).
# shellcheck disable=SC2016 # expanded by the inner shell
got=$(on local bash -c '. "$1/deploy/ci/common.sh" && sign_identity && echo "$sign_subject" && sign_identity web &&
  echo "$sign_subject" && provenance_source && echo "$provenance_repository $provenance_ref" &&
  source_of_repository ghcr.io/anhnvcoder/svp-backend/api/gateway && oci_labels | head -n 2 &&
  oci_labels web | head -n 1' _ "$vr")
same "common.sh: the identity of sources backend and web, and labels of this checkout" \
  "$subject"$'\n'"$web_subject"$'\n'"https://github.com/anhnvcoder/svp-backend refs/heads/main"$'\n'"backend"$'\n'"org.opencontainers.image.source=https://github.com/anhnvcoder/svp-backend"$'\n'"org.opencontainers.image.revision=$(gv rev-parse HEAD)"$'\n'"org.opencontainers.image.source=https://github.com/anhnvcoder/svp-frontend" \
  "$got"
# shellcheck disable=SC2016
got=$(on local env SVP_CODE_ROOT="$cfg" bash -c '. "$1/deploy/ci/common.sh" && echo "$script_root" &&
  oci_labels web | sed -n 2p' _ "$vr")
same "common.sh: SVP_CODE_ROOT labels that tree's commit, scripts stay in this checkout" \
  "$vr"$'\n'"org.opencontainers.image.revision=$(gc rev-parse HEAD)" "$got"
rc=0
on local env SVP_CODE_ROOT="$work/none" bash -c '. "$1/deploy/ci/common.sh"' _ "$vr" >"$work/vr.out" 2>&1 || rc=$?
same "common.sh: an SVP_CODE_ROOT that is no folder (exit 1)" 1 "$rc"
check "common.sh: an SVP_CODE_ROOT that is no folder: says so" has "$work/vr.out" "SVP_CODE_ROOT=$work/none is not a folder"
# shellcheck disable=SC2016
same "common.sh: drill_images are the drillImages of source backend, which the policy admits" \
  "$(jq -r '.sources[] | select(.name == "backend") | .drillImages | join(" ")' "$src/deploy/helm/svp-policy/files/sources.json")" \
  "$(bash -c '. "$1/common.sh" && echo "${drill_images[*]}"' _ "$here")"

# --- values-check.sh --gitops on a pull request of the tree: the policy of one environment changed (its overlay, or
# its charts.yaml) checks every release of that environment and none of the other; an image file checks itself; any
# other file nothing. The gateway is released in both environments.
overlay stg false
for env in stg prd; do
  printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-backend/gateway\n  tag: "%s"\n  digest: "%s"\n' \
    "${off_rev:0:12}" "$digest_a" >"$cfg/envs/$env/images/gateway.yaml"
done
gc add -A && gc commit -qm "the gateway released"
pr_base=$(gc rev-parse HEAD)
# values_check NAME WANT_RC: values-check.sh --gitops with the pull request's base, on a machine, output in vc.out.
values_check() {
  local rc=0
  fresh
  on local env FAKE_COSIGN_DIR="$fx" "$vr/deploy/ci/values-check.sh" --gitops "$cfg" "$pr_base" >"$work/vc.out" 2>&1 ||
    rc=$?
  same "values-check.sh: $1 (exit $2)" "$2" "$rc"
}
echo "# More" >>"$cfg/base/README.md"
gc commit -qam "base only"
values_check "a change of base/ only: nothing to check" 0
check "values-check.sh: base/ only: cosign never asked" test ! -s "$work/cosign.log"
rm -f "$fx/slsaprovenance1.jsonl"
overlay stg true
gc commit -qam "provenance on in stg"
values_check "provenance turned on in stg, its gateway has none" 1
check "values-check.sh: provenance on in stg: says stg's policy changed" has "$work/vc.out" \
  "note  what the releases of stg must carry may have changed since ${pr_base:0:12} (envs/stg/svp-policy.yaml)"
check "values-check.sh: provenance on in stg: names the release without provenance" has "$work/vc.out" \
  "ghcr.io/anhnvcoder/svp-backend/gateway@$digest_a has no provenance attestation"
check "values-check.sh: provenance on in stg: every service of stg is read" has "$work/vc.out" \
  "ok    envs/stg/images/web.yaml: no digest"
check "values-check.sh: provenance on in stg: prd is not read" lacks "$work/vc.out" "envs/prd/"
hint="gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f rescan=true"
check "values-check.sh: the dispatch in the log, naming the code repository" has "$work/vc.out" "  $hint"
provenance
values_check "provenance turned on in stg, the release has it" 0
overlay stg false
gc commit -qam "provenance off in stg"
charts prd "$on_rev"
gc commit -qam "prd runs newer charts"
rm -f "$fx/slsaprovenance1.jsonl"
values_check "prd's charts.yaml moved to values that turn provenance on" 1
check "values-check.sh: prd's charts moved: prd is read" has "$work/vc.out" "check envs/prd/images/gateway.yaml"
check "values-check.sh: prd's charts moved: stg is not" lacks "$work/vc.out" "envs/stg/"
charts prd "$off_rev"
gc commit -qam "prd back"
gc update-ref refs/heads/main HEAD
pr_base=$(gc rev-parse HEAD)
printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-frontend/web\n  tag: "%s"\n  digest: "%s"\n' \
  "${off_rev:0:12}" "$digest_a" >"$cfg/envs/stg/images/web.yaml"
gc commit -qam "web released in stg"
values_check "an image file changed: only it is checked" 0
same "values-check.sh: an image file changed: one check" "check envs/stg/images/web.yaml" "$(grep '^check ' "$work/vc.out")"
fresh
if on github "$vr/deploy/ci/values-check.sh" --gitops "$cfg" "" >/dev/null 2>"$work/vc.err"; then
  fail "values-check.sh: no base, unsigned releases fail"
else ok "values-check.sh: no base, unsigned releases fail"; fi
check "values-check.sh: cosign is asked for the policy's issuer and subject" has "$work/cosign.log" \
  "verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/svp-backend/gateway@$digest_a"
same "values-check.sh: the dispatch in the summary" "values-check failed: refresh the vuln attestations with \`$hint\`; a missing provenance needs a new release (above)" "$(cat "$work/summary")"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
