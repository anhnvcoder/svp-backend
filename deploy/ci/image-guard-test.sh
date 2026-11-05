#!/usr/bin/env bash
# Tests of the guards of the image pipeline (deploy/ci/image-guard.sh) and of the steps of the composite actions under
# .github/actions/image-*/ around them, in a throwaway copy of what they read (deploy/ci/, deploy/k8s/lib.sh, the
# policy's release sources, the actions) and a checkout of svp-frontend beside it; the variables of a GitHub Actions
# job are made up. The steps are read from the action files with the pinned yq (never copied here) and run as the
# runner runs a step of shell bash, each given only keys of its env:. A fake docker first on PATH stands in for the
# daemon, the registry (manifests read back, ORAS listing the Sigstore bundle referrers of a digest), grype and the
# pinned cosign, which records each call and adds a referrer for each signature and attestation; there is no cosign on
# PATH. Every run has DOCKER_DEFAULT_PLATFORM=linux/amd64, as the shell of this machine sets it for other projects, and
# the fake docker refuses a call that still carries it. Checked:
#   - every step of the three actions that calls docker unsets DOCKER_DEFAULT_PLATFORM first, and no docker call of a
#     step or guard run here gets it;
#   - leg: the build of each kind of image (service, media-worker, drill images, svp-frontend's web); an image the
#     run's release source does not publish, a tree that is not the run's commit, another repository's tree without what
#     its build and gates read, a repository that is no release source, or another architecture than the host's, is
#     refused before docker builds anything; only drill-vulnerable gets allow-critical;
#   - grype (step grype): --fail-on critical and the tree's .grype.yaml; a Critical blocks unless allow-critical; a
#     grype that fails is no pass; one summary line, the Critical under it, never the report;
#   - push: exactly the scanned image is pushed, and a manifest read back with another config (or no single manifest), a
#     local image tagged anew since the scan, or a leg of another platform fails the leg;
#   - index: exactly the two scanned manifests of the image's own repository, one per platform; a missing leg, a leg of
#     another repository or platform, or an index read back with other digests fails;
#   - sign: what sign-image.sh did, now guard and step: signature, SBOM on each manifest, vuln on the index, all
#     bundles, in that order, by the pinned cosign with the credentials of docker login read-only and the job's OIDC
#     token request by name only, and provenance=true for actions/attest; run again: nothing written twice; a digest in
#     cosign's older format or a registry out of reach: nothing written; a run on a machine, of another workflow, or of
#     another source's repository or prefix: nothing written; a CRITICAL is signed only for drill-vulnerable; drill
#     images get no provenance.
# Runs on macOS and Linux: Docker only for the pinned yq; no network, no cluster.
#
# Usage, from anywhere: deploy/ci/image-guard-test.sh
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
real_docker=$(command -v docker)
yq_image=$(sed -n 's/^YQ_IMAGE[[:space:]]*:=[[:space:]]*//p' "$src/Makefile")

# on github|local COMMAND...: runs COMMAND with the variables of a made-up GitHub Actions job (repository octo/repo,
# changed by the caller), or on a machine with none of them; the fakes first on PATH. git reads no configuration of
# this machine.
on() {
  local where=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_REF -u GITHUB_SHA -u GITHUB_EVENT_NAME
    -u GITHUB_EVENT_PATH -u GITHUB_ACTOR -u RUNNER_TEMP -u GIT_DIR -u GIT_WORK_TREE -u SVP_CODE_ROOT
    -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u DOCKER_CONFIG
    -u TRIVY_IMAGE -u SYFT_IMAGE -u GRYPE_IMAGE -u COSIGN_IMAGE DOCKER_DEFAULT_PLATFORM=linux/amd64
    PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    ORAS_IMAGE="$oras_image" FAKE_ORAS_IMAGE="$oras_image" FAKE_COSIGN_IMAGE="$cosign_image" FAKE_COSIGN="$work/cosign"
    FAKE_BUNDLES="$fb" FAKE_DOCKER_LOG="$work/docker.log" FAKE_PLATFORM_LOG="$work/platform.log"
    FAKE_COSIGN_LOG="$work/cosign.log" FAKE_RAW="$work/raw.json")
  case $where in
  github)
    "${base[@]}" GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 \
      GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main GITHUB_REF=refs/heads/main \
      GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_EVENT_NAME=push GITHUB_ACTOR=octocat \
      RUNNER_TEMP="$work/runner-temp" ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example/oidc \
      ACTIONS_ID_TOKEN_REQUEST_TOKEN=fake-oidc-request-token "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  esac
}
# fresh: empties the files of a job and the logs of the fakes.
fresh() { : >"$work/output" && : >"$work/summary" && : >"$work/cosign.log" && : >"$work/docker.log"; }
# out_of KEY: the value the last run handed on under KEY (GITHUB_OUTPUT in a job, stdout on a machine).
out_of() { sed -n "s/^$1=//p" "$work/output" "$work/run.out" 2>/dev/null | tail -n 1; }
mkdir -p "$work/bin" "$work/home/.docker" "$work/runner-temp" "$work/steps"
echo '{"auths": {}}' >"$work/home/.docker/config.json"

# The throwaway checkout of what the guards and actions read, and a checkout of svp-frontend, another release source's
# repository, whose CI runs the actions from a pinned checkout of this one (code-root). GIT_DIR is set for every git
# call of the test itself, so git can never reach another repository.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$tree/.github"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/docker-bake.json" "$tree/deploy/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
cp -R "$src/.github/actions" "$tree/.github/actions"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
base=$(g rev-parse HEAD)
webtree=$work/svp-frontend
mkdir -p "$webtree"
printf 'FROM scratch\n' >"$webtree/Dockerfile"
printf 'lockfileVersion: 9.0\n' >"$webtree/pnpm-lock.yaml"
printf 'vulnerabilities: []\n' >"$webtree/.trivyignore.yaml"
printf 'ignore: []\n' >"$webtree/.grype.yaml"
gw() {
  GIT_DIR=$webtree/.git GIT_WORK_TREE=$webtree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
gw init -q -b main && gw add -A && gw commit -qm web
gw remote add origin https://github.com/anhnvcoder/svp-frontend.git
web_head=$(gw rev-parse HEAD)
backend_subject=https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
web_subject=https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main
backend_run=(GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com GITHUB_SHA="$base"
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main)
web_run=(GITHUB_REPOSITORY=anhnvcoder/svp-frontend GITHUB_SERVER_URL=https://github.com GITHUB_SHA="$web_head"
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main SVP_CODE_ROOT="$webtree")
cosign_image=fake.invalid/cosign@sha256:$(printf '5%.0s' $(seq 64))
tools=(TRIVY_IMAGE=fake.invalid/trivy@sha256:1 SYFT_IMAGE=fake.invalid/syft@sha256:2 GRYPE_IMAGE=fake.invalid/grype@sha256:3
  COSIGN_IMAGE="$cosign_image")

# The fakes. docker: the host's architecture (FAKE_ARCH, amd64), the id of a local image (FAKE_IMAGE_ID), login, tag,
# push and imagetools create succeed, imagetools inspect --raw answers FAKE_RAW; grype on the SBOM writes FAKE_GRYPE_JSON
# and exits FAKE_GRYPE; ORAS lists the referrers of a fake registry under bundles/ (a folder per subject digest holding
# one file per bundle referrer, named by its digest, holding its predicate type; <hex>.sig for cosign's older format),
# and is out of reach with FAKE_ORAS_DOWN; a run of the cosign image runs the fake cosign with what follows the image.
# Every call in docker.log; a call with DOCKER_DEFAULT_PLATFORM set also in platform.log, and refused. cosign: logs each
# call and adds a referrer for each sign and attest; keeps the last predicate of each type.
oras_image=fake.invalid/oras@sha256:$(printf '0%.0s' $(seq 64))
fb=$work/bundles
mkdir -p "$fb"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ -n "${DOCKER_DEFAULT_PLATFORM+set}" ]; then
  printf 'DOCKER_DEFAULT_PLATFORM=%s docker %s\n' "$DOCKER_DEFAULT_PLATFORM" "$*" >>"$FAKE_PLATFORM_LOG"
  echo "fake docker: DOCKER_DEFAULT_PLATFORM=$DOCKER_DEFAULT_PLATFORM reached docker" >&2
  exit 97
fi
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" != "$FAKE_COSIGN_IMAGE" ] || exec "$FAKE_COSIGN" "${args[@]:$((i + 1))}"
done
case "$1 $2" in
"version --format") echo "${FAKE_ARCH:-amd64}" && exit 0 ;;
"image inspect") echo "${FAKE_IMAGE_ID:?}" && exit 0 ;;
"login ghcr.io") cat >/dev/null && exit 0 ;;
"push --quiet") exit 0 ;;
"buildx imagetools")
  case $3 in
  inspect) cat "$FAKE_RAW" && exit 0 ;;
  create) exit 0 ;;
  esac
  ;;
esac
[ "$1" != tag ] || exit 0
case " $* " in
*" sbom:/out/sbom.spdx.json "*)
  for a in "$@"; do case $a in *:/out) out=${a%:/out} ;; esac; done
  [ "${FAKE_GRYPE:-0}" = 1 ] || { cp "$FAKE_GRYPE_JSON" "$out/grype.json" && echo '{}' >"$out/grype.sarif.raw"; }
  exit "${FAKE_GRYPE:-0}"
  ;;
esac
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
*)
  echo "fake docker: unexpected ORAS command: $*" >&2
  exit 99
  ;;
esac
EOF
cat >"$work/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
cmd=$1 type= ref= predicate=
for a in "$@"; do
  case $a in
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
[ -z "$predicate" ] || cp "$predicate" "$store/last-$type.json"
hex=${ref##*@sha256:}
add() {
  local n
  n=$(($(cat "$store/counter" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$store/counter"
  mkdir -p "$store/$hex"
  echo "$1" >"$store/$hex/$(printf '%s %s' "$n" "$ref" | shasum -a 256 | cut -c1-64)"
}
case "$cmd $type" in
"sign ") add https://sigstore.dev/cosign/sign/v1 ;;
"attest spdxjson") add https://spdx.dev/Document ;;
"attest vuln") add https://cosign.sigstore.dev/attestation/vuln/v1 ;;
*) exit 98 ;;
esac
EOF
chmod 755 "$work/bin/docker" "$work/cosign"

# guard WHERE NAME WANT [VAR=VALUE...] -- ARGS...: image-guard.sh ARGS (on WHERE) with the fakes; ok when it exits WANT.
# Its output in run.out and run.err, its outputs in output (a job) or run.out (a machine).
guard() {
  local where=$1 name=$2 want=$3 vars=() rc=0
  shift 3
  while [ "$1" != -- ]; do vars+=("$1") && shift; done
  shift
  fresh
  on "$where" env "${tools[@]}" ${vars[@]+"${vars[@]}"} "$tree/deploy/ci/image-guard.sh" "$@" \
    >"$work/run.out" 2>"$work/run.err" || rc=$?
  same "$name (exit $want)" "$want" "$rc"
}
# refused NAME WANT_MESSAGE [VAR=VALUE...] -- ARGS...: image-guard.sh ARGS in a job exits 1 naming WANT_MESSAGE, and
# docker was never called.
refused() {
  local name=$1 want=$2
  shift 2
  guard github "$name: refused" 1 "$@"
  check "$name: says $want" has "$work/run.err" "$want"
  check "$name: before docker" test ! -s "$work/docker.log"
}
# yq_ ACTION EXPRESSION: the pinned yq on .github/actions/ACTION/action.yml of the copy, without network.
yq_() { env -u DOCKER_DEFAULT_PLATFORM "$real_docker" run --rm -i --network none "$yq_image" eval "$2" - \
  <"$tree/.github/actions/$1/action.yml"; }
# step ACTION ID WHERE NAME WANT [VAR=VALUE...]: the step ID of action ACTION (on WHERE) with the variables given, each a
# key of the step's env: (or a variable of the job, GITHUB_*, or of a fake, FAKE_*); ok when it exits WANT. Output in step.out, step.err.
step() {
  local action=$1 id=$2 where=$3 name=$4 want=$5 var rc=0 file=$work/steps/$1-$2
  shift 5
  if [ ! -f "$file.run" ]; then
    yq_ "$action" ".runs.steps[] | select(.id == \"$id\") | .run" >"$file.run"
    yq_ "$action" ".runs.steps[] | select(.id == \"$id\") | .env | keys | .[]" >"$file.keys"
    same "$action step $id: shell bash" bash "$(yq_ "$action" ".runs.steps[] | select(.id == \"$id\") | .shell")"
  fi
  for var in "$@"; do
    case $var in FAKE_* | GITHUB_*) continue ;; esac
    grep -qxF -- "${var%%=*}" "$file.keys" || fail "$action step $id: ${var%%=*} is no key of its env:"
  done
  on "$where" env "$@" bash --noprofile --norc -eo pipefail -c "$(cat "$file.run")" \
    >"$work/step.out" 2>"$work/step.err" || rc=$?
  same "$name (exit $want)" "$want" "$rc"
}

# --- Every step of the three actions that calls docker unsets DOCKER_DEFAULT_PLATFORM first (the runs below check
# that no docker call gets it; this covers the steps they do not run, the login of image-sign among them).
for action in image-leg image-index image-sign; do
  docker_steps=$(yq_ "$action" '.runs.steps[] | select(.run != null and (.run | test("(^|[\s(|;&])docker\s")))
    | (.name // .id) + "|" + (.run | split("\n") | .[0])')
  check "$action: its steps that call docker are found" test -n "$docker_steps"
  while IFS='|' read -r step_name first_line; do
    same "$action step '$step_name': unsets DOCKER_DEFAULT_PLATFORM before it calls docker" \
      "unset DOCKER_DEFAULT_PLATFORM" "$first_line"
  done <<<"$docker_steps"
done

digest_of() { echo "sha256:$(shasum -a 256 "$1" | cut -d' ' -f1)"; }
amd64=sha256:$(printf '1%.0s' $(seq 64))
arm64=sha256:$(printf '2%.0s' $(seq 64))
config=sha256:$(printf '3%.0s' $(seq 64))
other=sha256:$(printf '4%.0s' $(seq 64))
backend=ghcr.io/anhnvcoder/svp-backend/
frontend=ghcr.io/anhnvcoder/svp-frontend/

# --- leg: before anything is built.
out=$work/leg
guard github "leg gateway" 0 "${backend_run[@]}" -- leg gateway amd64 "$out"
same "leg gateway: the build" \
  "dockerfile=$tree/deploy/docker/service.Dockerfile context=$tree build-arg=SERVICE=gateway tag=svp-ci/gateway:${base:0:12}-amd64 allow-critical=false" \
  "dockerfile=$(out_of dockerfile) context=$(out_of context) build-arg=$(out_of build-arg) tag=$(out_of tag) allow-critical=$(out_of allow-critical)"
check "leg gateway: the OCI labels of the commit" grep -qE \
  "^labels=org.opencontainers.image.source=https://github.com/anhnvcoder/svp-backend org.opencontainers.image.revision=$base org.opencontainers.image.created=[0-9T:-]+Z$" \
  "$work/output"
same "leg gateway: the pinned tools" "fake.invalid/trivy@sha256:1 fake.invalid/syft@sha256:2 fake.invalid/grype@sha256:3" \
  "$(out_of trivy-image) $(out_of syft-image) $(out_of grype-image)"
same "leg gateway: the scan flags of the rescan, no ignore file in a tree without one" \
  "--scanners vuln,secret --db-repository mirror.gcr.io/aquasec/trivy-db:2,ghcr.io/aquasecurity/trivy-db:2 --format json||" \
  "$(out_of trivy-scan-args)|$(out_of trivyignore)|$(out_of grypeignore)"
same "leg gateway: platform and local tag in OUT" "linux/amd64 svp-ci/gateway:${base:0:12}-amd64" \
  "$(cat "$out/platform") $(cat "$out/local-tag")"
printf 'vulnerabilities: []\n' >"$tree/.trivyignore.yaml"
guard github "leg gateway, a tree with .trivyignore.yaml" 0 "${backend_run[@]}" -- leg gateway amd64 "$out"
same "leg gateway, a tree with .trivyignore.yaml: trivy reads it" "$tree/.trivyignore.yaml|--ignorefile /ignore.yaml" \
  "$(out_of trivyignore)|$(out_of trivy-scan-args | grep -o -- '--ignorefile /ignore.yaml')"
rm -f "$tree/.trivyignore.yaml"
guard github "leg media-worker on arm64" 0 "${backend_run[@]}" FAKE_ARCH=arm64 -- leg media-worker arm64 "$out"
same "leg media-worker: its Dockerfile, no build argument" "$tree/deploy/docker/media-worker.Dockerfile|" \
  "$(out_of dockerfile)|$(out_of build-arg)"
guard github "leg drill-vulnerable" 0 "${backend_run[@]}" -- leg drill-vulnerable amd64 "$out"
same "leg drill-vulnerable: its Dockerfile, allow-critical" "$tree/deploy/ci/drill/vulnerable.Dockerfile true" \
  "$(out_of dockerfile) $(out_of allow-critical)"
guard github "leg drill-no-provenance" 0 "${backend_run[@]}" -- leg drill-no-provenance amd64 "$out"
same "leg drill-no-provenance: built as the gateway, no allow-critical" \
  "$tree/deploy/docker/service.Dockerfile SERVICE=gateway false" \
  "$(out_of dockerfile) $(out_of build-arg) $(out_of allow-critical)"
rm -rf "$work/web-leg"
refused "leg web in this repository" \
  "web is not an image of release source backend (gateway user-service video-service engagement-service feed-service media-worker drill-vulnerable drill-unsigned drill-no-provenance): nothing is built, pushed or signed under ghcr.io/anhnvcoder/svp-backend/" \
  "${backend_run[@]}" -- leg web amd64 "$work/web-leg"
check "leg web in this repository: no output folder" test ! -e "$work/web-leg"
guard github "leg gateway on the other architecture" 1 "${backend_run[@]}" -- leg gateway arm64 "$out"
check "leg gateway on the other architecture: says so" has "$work/run.err" \
  "this host builds amd64, not arm64: the pipeline never emulates"
guard github "leg of svp-frontend, web" 0 "${web_run[@]}" -- leg web amd64 "$out"
same "leg of svp-frontend, web: its Dockerfile and tree, the build id of the commit" \
  "$webtree/Dockerfile $webtree SVP_BUILD_ID=${web_head:0:12} false" \
  "$(out_of dockerfile) $(out_of context) $(out_of build-arg) $(out_of allow-critical)"
same "leg of svp-frontend, web: its ignore files" "$webtree/.trivyignore.yaml $webtree/.grype.yaml" \
  "$(out_of trivyignore) $(out_of grypeignore)"
check "leg of svp-frontend, web: labelled with its repository" has "$work/output" \
  "org.opencontainers.image.source=https://github.com/anhnvcoder/svp-frontend"
refused "leg of svp-frontend, gateway" "gateway is not an image of release source web" \
  "${web_run[@]}" -- leg gateway amd64 "$out"
refused "leg of svp-frontend, drill-vulnerable" "drill-vulnerable is not an image of release source web" \
  "${web_run[@]}" -- leg drill-vulnerable amd64 "$out"
refused "leg of svp-frontend, a tree at another commit" \
  "HEAD of $webtree is $web_head, but this run builds $base of https://github.com/anhnvcoder/svp-frontend" \
  "${web_run[@]}" GITHUB_SHA="$base" -- leg web amd64 "$out"
refused "leg of svp-frontend without code-root (the backend's checkout)" \
  "but this run builds $web_head of https://github.com/anhnvcoder/svp-frontend" \
  "${web_run[@]}" SVP_CODE_ROOT= -- leg web amd64 "$out"
for file in Dockerfile pnpm-lock.yaml .trivyignore.yaml .grype.yaml; do
  mv "$webtree/$file" "$work/moved"
  refused "leg of svp-frontend, a tree without $file" "$webtree has no file $file" \
    "${web_run[@]}" -- leg web amd64 "$out"
  mv "$work/moved" "$webtree/$file"
done
refused "leg of a repository no release source names" \
  "this run is of https://github.com/octo/repo, which is the repository of 0 release sources" \
  "${web_run[@]}" GITHUB_REPOSITORY=octo/repo -- leg web amd64 "$out"

# --- grype (step grype of image-leg) with the fake grype.
# match ID SEVERITY PURL: one match of a grype report.
match() {
  jq -n --arg id "$1" --arg sev "$2" --arg purl "$3" '{
    vulnerability: {id: $id, severity: $sev, fix: {versions: ["9.9.9"], state: "fixed"}},
    artifact: {name: ($purl | sub("^pkg:[^/]+/(.*/)?"; "") | sub("@.*$"; "")),
      version: ($purl | sub("^[^@]*@"; "") | sub("[?#].*$"; "")), purl: $purl}}'
}
# grype_report IGNORED MATCH...: the report the fake grype writes, with IGNORED ignored matches.
grype_report() {
  local ignored=$1
  shift
  jq -s --argjson n "$ignored" '{descriptor: {name: "grype", version: "0.121.0"}, matches: .,
    ignoredMatches: [range($n) | {}]}' <<<"$*" >"$work/grype.json"
}
critical_npm=$(match CVE-2026-1111 Critical pkg:npm/left-pad@1.0.0)
high_npm=$(match CVE-2026-2222 High pkg:npm/zod@3.25.76)
grype() {
  local name=$1 want=$2
  shift 2
  fresh
  rm -rf "$work/gleg" && mkdir -p "$work/gleg"
  echo '{"spdxVersion": "SPDX-2.3", "packages": []}' >"$work/gleg/sbom.spdx.json"
  step image-leg grype github "grype: $name" "$want" OUT="$work/gleg" LABEL="web linux/arm64" \
    GUARD="$tree/deploy/ci/image-guard.sh" GRYPE_IMAGE=fake.invalid/grype@sha256:3 GRYPEIGNORE="$webtree/.grype.yaml" \
    ALLOW_CRITICAL=false GRYPE_CACHE="$work/cache/grype" FAKE_GRYPE_JSON="$work/grype.json" "$@"
}
grype_report 1 "$critical_npm" "$high_npm"
grype "a Critical blocks" 1 FAKE_GRYPE=2
check "grype: --fail-on critical and the tree's .grype.yaml" has "$work/docker.log" \
  "-v $webtree/.grype.yaml:/ignore/grype.yaml:ro fake.invalid/grype@sha256:3 sbom:/out/sbom.spdx.json -c /ignore/grype.yaml --fail-on critical -o json=/out/grype.json -o sarif=/out/grype.sarif.raw -q"
same "grype in a job: one line in the summary, the Critical under it" '- web linux/arm64 (grype): Critical 1, High 1, excepted by .grype.yaml 1
critical  CVE-2026-1111 left-pad@1.0.0 pkg:npm/left-pad@1.0.0 (fixed: 9.9.9)' "$(cat "$work/summary")"
check "grype: a Critical says nothing ships" has "$work/step.out" \
  "web linux/arm64 (grype): Critical vulnerabilities; nothing is pushed, signed or attested"
check "grype: the report itself is not printed" lacks "$work/step.out" '"matches"'
grype "allow-critical lets a Critical through" 0 ALLOW_CRITICAL=true
check "grype: allow-critical runs grype without --fail-on" lacks "$work/docker.log" "--fail-on"
check "grype: allow-critical says so" has "$work/step.out" \
  "note  web linux/arm64 (grype): Critical vulnerabilities let through (allow-critical)"
grype_report 0 "$high_npm"
grype "High and below only counted" 0
check "grype: the counts" has "$work/step.out" "web linux/arm64 (grype): Critical 0, High 1, excepted by .grype.yaml 0"
grype "grype failing (exit 1) is no pass" 2 FAKE_GRYPE=1
check "grype: grype failing is said" has "$work/step.out" "web linux/arm64: grype could not scan"
grype "grype failing is no pass with allow-critical" 2 FAKE_GRYPE=1 ALLOW_CRITICAL=true

# --- push (step 'Push the scanned image' of image-leg has no id: its guard subcommands, then the step by name).
# leg_dir DIR ARCH: a scanned leg of gateway at the backend's commit.
leg_dir() {
  rm -rf "$1" && mkdir -p "$1"
  echo "svp-ci/gateway:${base:0:12}-$2" >"$1/local-tag"
  echo "linux/$2" >"$1/platform"
  echo "$config" >"$1/config-digest"
  jq -n --arg c "$config" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Trivy: {Version: "0.76.0"}, Results: []}' \
    >"$1/trivy.json"
}
push_script=$work/steps/image-leg-push.run
yq_ image-leg '.runs.steps[] | select(.name == "Push the scanned image, compare its config digest") | .run' >"$push_script"
yq_ image-leg '.runs.steps[] | select(.name == "Push the scanned image, compare its config digest") | .env | keys | .[]' \
  >"$work/steps/image-leg-push.keys"
same "image-leg push: the step's env holds what the test sets" "ARCH GH_TOKEN GUARD IMAGE OUT SVP_CODE_ROOT" \
  "$(sort "$work/steps/image-leg-push.keys" | paste -sd' ' -)"
# push NAME WANT [VAR=VALUE...]: the push step on leg $work/pleg of gateway amd64 in the backend's run; the registry
# answers raw.json.
push() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on github env "${backend_run[@]}" IMAGE=gateway ARCH=amd64 OUT="$work/pleg" GUARD="$tree/deploy/ci/image-guard.sh" \
    SVP_CODE_ROOT= GH_TOKEN=fake-token FAKE_IMAGE_ID="$config" "$@" \
    bash --noprofile --norc -eo pipefail -c "$(cat "$push_script")" >"$work/step.out" 2>"$work/step.err" || rc=$?
  same "push: $name (exit $want)" "$want" "$rc"
}
manifest() {
  jq -nc --arg c "$1" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $c}, layers: []}' >"$work/raw.json"
}
remote=${backend}gateway:${base:0:12}-amd64
leg_dir "$work/pleg" amd64
manifest "$config"
push "the scanned image" 0
same "push: tagged and pushed as the commit's tag of its source, read back" \
  "tag svp-ci/gateway:${base:0:12}-amd64 $remote|push --quiet $remote|buildx imagetools inspect --raw $remote" \
  "$(grep -E '^(tag|push|buildx)' "$work/docker.log" | paste -sd'|' -)"
same "push: repository and the digest of the manifest read back" "${backend}gateway $(digest_of "$work/raw.json")" \
  "$(cat "$work/pleg/repository") $(cat "$work/pleg/digest")"
check "push: the token reaches docker login on stdin only" lacks "$work/docker.log" fake-token
leg_dir "$work/pleg" amd64
manifest "$other"
push "a manifest read back with another config" 1
check "push: another config says so" has "$work/step.err" "the scan had $config: not the scanned image"
check "push: another config: no digest handed on" test ! -e "$work/pleg/digest"
jq -n '{mediaType: "application/vnd.oci.image.index.v1+json", manifests: []}' >"$work/raw.json"
push "an index read back" 1
check "push: an index read back is no single manifest" has "$work/step.err" "<not a single manifest>"
manifest "$config"
push "a local image tagged anew since the scan" 1 FAKE_IMAGE_ID="$other"
check "push: a local image tagged anew says so" has "$work/step.err" "is no longer the image that was scanned"
check "push: a local image tagged anew: nothing pushed" lacks "$work/docker.log" "push --quiet"
echo "$other" >"$work/pleg/config-digest"
push "a config digest that is not the report's" 1
check "push: a config digest that is not the report's: nothing pushed" lacks "$work/docker.log" "push --quiet"
leg_dir "$work/pleg" arm64
push "a leg of linux/arm64 as amd64" 1
check "push: another platform says so" has "$work/step.err" "holds a scan of linux/arm64, not linux/amd64"
leg_dir "$work/pleg" amd64
refused "push of svp-frontend, gateway" "gateway is not an image of release source web" \
  "${web_run[@]}" -- push gateway amd64 "$work/pleg"
refused "push of svp-frontend, a tree at another commit" \
  "HEAD of $webtree is $web_head, but this run builds $base of https://github.com/anhnvcoder/svp-frontend" \
  "${web_run[@]}" GITHUB_SHA="$base" -- push web amd64 "$work/pleg"

# --- index (step join of image-index has no id either: guard, then the step by name).
# legs DIR IMAGE PREFIX: the two pushed legs of IMAGE under PREFIX in DIR/legs.
legs() {
  local arch d
  rm -rf "$1/legs"
  for arch in amd64 arm64; do
    d=$1/legs/leg-$2-$arch
    mkdir -p "$d"
    echo "$3$2" >"$d/repository"
    echo "linux/$arch" >"$d/platform"
    if [ $arch = amd64 ]; then echo "$amd64" >"$d/digest"; else echo "$arm64" >"$d/digest"; fi
    echo "$config" >"$d/config-digest"
    jq -n --arg c "$config" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Trivy: {Version: "0.76.0"}, Results: []}' \
      >"$d/trivy.json"
    for f in scan-started scan-finished db-updated-at; do echo 2026-10-29T01:02:03Z >"$d/$f"; done
    echo '{"spdxVersion": "SPDX-2.3"}' >"$d/sbom.spdx.json"
  done
}
# index_of A B: the index of the two manifest digests the registry answers, in raw.json.
index_of() {
  jq -nc --arg a "$1" --arg b "$2" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [
    {digest: $a, platform: {os: "linux", architecture: "amd64"}},
    {digest: $b, platform: {os: "linux", architecture: "arm64"}}]}' >"$work/raw.json"
}
join_name="Join the two manifests into one index, check it"
yq_ image-index ".runs.steps[] | select(.name == \"$join_name\") | .run" >"$work/steps/image-index-join.run"
idx=$work/idx
legs "$idx" gateway "$backend"
guard github "index gateway" 0 "${backend_run[@]}" -- index gateway "$idx/legs"
same "index gateway: repository, tag and the two digests by platform" "${backend}gateway ${base:0:12} $amd64 $arm64" \
  "$(out_of repository) $(out_of tag) $(out_of amd64) $(out_of arm64)"
# join NAME WANT [VAR=VALUE...]: the join step with the outputs of the guard run just before.
join() {
  local name=$1 want=$2 rc=0
  shift 2
  local outs=(REPOSITORY="$(out_of repository)" TAG="$(out_of tag)" AMD64="$(out_of amd64)" ARM64="$(out_of arm64)"
    ANNOTATIONS="$(out_of annotations)")
  fresh
  on github env "${backend_run[@]}" GUARD="$tree/deploy/ci/image-guard.sh" IMAGE=gateway OUT="$idx" SVP_CODE_ROOT= \
    GH_TOKEN=fake-token "${outs[@]}" "$@" bash --noprofile --norc -eo pipefail -c "$(cat "$work/steps/image-index-join.run")" \
    >"$work/step.out" 2>"$work/step.err" || rc=$?
  same "index: $name (exit $want)" "$want" "$rc"
}
index_of "$amd64" "$arm64"
join "the two scanned manifests" 0
check "index: created with the annotations of the commit, from the two digests" grep -qE \
  "^buildx imagetools create --tag ${backend}gateway:${base:0:12} --annotation index:org.opencontainers.image.source=https://github.com/anhnvcoder/svp-backend --annotation index:org.opencontainers.image.revision=$base --annotation index:org.opencontainers.image.created=[0-9T:-]+Z ${backend}gateway@$amd64 ${backend}gateway@$arm64$" \
  "$work/docker.log"
same "index: repository, tag and the digest of the index read back" "${backend}gateway ${base:0:12} $(digest_of "$work/raw.json")" \
  "$(cat "$idx/index/repository") $(cat "$idx/index/tag") $(cat "$idx/index/digest")"
guard github "index gateway, again" 0 "${backend_run[@]}" -- index gateway "$idx/legs"
rm -rf "$idx/index"
index_of "$amd64" "$other"
join "an index read back with another manifest" 1
check "index: another manifest says so" has "$work/step.err" "is not an index of exactly the two scanned manifests"
check "index: another manifest: no digest handed on" test ! -e "$idx/index/digest"
rm -rf "$idx/legs/leg-gateway-arm64"
refused "index, a leg missing" "gateway: a leg did not pass (see the build job); no index, no signature, no release" \
  "${backend_run[@]}" -- index gateway "$idx/legs"
legs "$idx" gateway "$backend"
echo "${backend}feed-service" >"$idx/legs/leg-gateway-arm64/repository"
refused "index, a leg of another repository" "holds a push to another repository than ${backend}gateway" \
  "${backend_run[@]}" -- index gateway "$idx/legs"
legs "$idx" gateway "$backend"
echo linux/arm64 >"$idx/legs/leg-gateway-amd64/platform"
refused "index, a leg of the other platform" "the two legs are not linux/amd64 and linux/arm64" \
  "${backend_run[@]}" -- index gateway "$idx/legs"
legs "$idx" gateway "$backend"
refused "index of svp-frontend, gateway" "gateway is not an image of release source web" \
  "${web_run[@]}" -- index gateway "$idx/legs"
legs "$idx" web "$frontend"
refused "index of svp-frontend without code-root (the backend's checkout)" \
  "but this run builds $web_head of https://github.com/anhnvcoder/svp-frontend" \
  "${web_run[@]}" SVP_CODE_ROOT= -- index web "$idx/legs"

# --- sign: guard sign, then the step sign of image-sign with its outputs. The index of the two legs above.
index_of "$amd64" "$arm64"
index_digest=$(digest_of "$work/raw.json")
hex=${index_digest#sha256:}
sg=$work/sign
# image NAME PREFIX: the artifacts image-sign downloads for an index of NAME under PREFIX.
image() {
  legs "$sg" "$1" "$2"
  rm -rf "$sg/index" && mkdir -p "$sg/index"
  echo "$2$1" >"$sg/index/repository"
  echo "${base:0:12}" >"$sg/index/tag"
  echo "$index_digest" >"$sg/index/digest"
}
# calls: what cosign was asked, comma separated: sign, or the type of an attestation and its subject.
calls() {
  sed -E "s/^(sign) .*/\1/; s/^attest .*--type ([a-z0-9]+) .*@(sha256:[0-9a-f]+)$/\1 \2/" "$work/cosign.log" |
    sed "s/$index_digest/index/; s/$amd64/amd64/; s/$arm64/arm64/" | paste -sd, -
}
vuln_files() { grep -lx https://cosign.sigstore.dev/attestation/vuln/v1 "$fb/$hex"/* 2>/dev/null || true; }
clean() { rm -rf "${fb:?}"/*; }
bundle="--yes --new-bundle-format=true"
repo=${backend}gateway
# run_sign NAME WHERE IMAGE [VAR=VALUE...]: guard sign on the artifacts in $sg, then, when it passed, the step sign of
# image-sign with its outputs, in the same made-up job; ok when the guard exits $want (0 unless set) and the step 0.
# provenance holds the output provenance of the guard.
run_sign() {
  local name=$1 where=$2 img=$3 rc=0 var job=()
  shift 3
  fresh
  on "$where" env "${tools[@]}" "$@" "$tree/deploy/ci/image-guard.sh" sign "$img" "$sg" >"$work/run.out" \
    2>"$work/run.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    local outs=(OUT="$(out_of out)" COSIGN_IMAGE="$(out_of cosign-image)" REPOSITORY="$(out_of repository)"
      DIGEST="$(out_of digest)" AMD64="$(out_of amd64)" ARM64="$(out_of arm64)" PREDICATE="$(out_of predicate)"
      SIGN="$(out_of sign)" SBOM_AMD64="$(out_of sbom-amd64)" SBOM_ARM64="$(out_of sbom-arm64)" VULN="$(out_of vuln)")
    provenance=$(out_of provenance)
    for var in "$@"; do case $var in GITHUB_* | FAKE_*) job+=("$var") ;; esac; done
    step image-sign sign "$where" "$name: the step" 0 ${job[@]+"${job[@]}"} IMAGE="$img" "${outs[@]}"
  else
    provenance=
  fi
  same "$name: the guard (exit ${want:-0})" "${want:-0}" "$rc"
}

clean
image gateway "$backend"
run_sign "sign, a release" github gateway "${backend_run[@]}"
same "sign, a release: signature, SBOM on each manifest, vuln on the index, Sigstore bundles" \
  "sign $bundle $repo@$index_digest
attest $bundle --type spdxjson --predicate $sg/legs/leg-gateway-amd64/sbom.spdx.json $repo@$amd64
attest $bundle --type spdxjson --predicate $sg/legs/leg-gateway-arm64/sbom.spdx.json $repo@$arm64
attest $bundle --type vuln --predicate $sg/vuln.json $repo@$index_digest" "$(cat "$work/cosign.log")"
same "sign, a release: the subject and provenance=true for actions/attest" "$repo $index_digest true" \
  "$(out_of repository) $(out_of digest) $provenance"
same "sign, a release: the vuln predicate is the two scans'" '"0.76.0" ["linux/amd64","linux/arm64"]' \
  "$(jq -c .scanner.version "$fb/last-vuln.json") $(jq -c '[.scanner.result.platforms[].platform]' "$fb/last-vuln.json")"
check "sign, a release: ORAS reads with the credentials of docker login, read-only" has "$work/docker.log" \
  "-v $work/home/.docker/config.json:/auth/config.json:ro $oras_image discover --format json"
same "sign, a release: the pinned cosign, the folder as an absolute path" "$cosign_image $sg" \
  "$(out_of cosign-image) $(out_of out)"
same "sign, a release: every cosign call runs the pinned image" 4 "$(grep -c -- " $cosign_image " "$work/docker.log")"
check "sign, a release: cosign reads the credentials of docker login and the folder, read-only" has "$work/docker.log" \
  "-v $work/home/.docker/config.json:/auth/config.json:ro -e DOCKER_CONFIG=/auth -v $sg:$sg:ro $cosign_image sign"
check "sign, a release: cosign gets the job's OIDC token request by name" has "$work/docker.log" \
  "-e ACTIONS_ID_TOKEN_REQUEST_URL -e ACTIONS_ID_TOKEN_REQUEST_TOKEN -v"
check "sign, a release: the OIDC request token never on a command line" lacks "$work/docker.log" fake-oidc-request-token
run_sign "sign, run again on the same digest" github gateway "${backend_run[@]}"
same "sign, run again: nothing written again" "" "$(cat "$work/cosign.log")"
same "sign, run again: the index still has one signature and one vuln attestation" \
  "1 https://cosign.sigstore.dev/attestation/vuln/v1,1 https://sigstore.dev/cosign/sign/v1" \
  "$(cat "$fb/$hex"/* | sort | uniq -c | sed 's/^ *//' | paste -sd, -)"
same "sign, run again: provenance=true while the provenance is missing" true "$provenance"
echo https://slsa.dev/provenance/v1 >"$fb/$hex/$(printf 'f%.0s' $(seq 64))"
run_sign "sign, run again after actions/attest" github gateway "${backend_run[@]}"
same "sign, run again after actions/attest: provenance=false, nothing written" "false|" \
  "$provenance|$(cat "$work/cosign.log")"
for f in $(vuln_files); do rm -- "$f"; done
run_sign "sign, a run cut off before vuln, run again" github gateway "${backend_run[@]}"
same "sign, a run cut off before vuln, run again: only vuln written" "vuln index" "$(calls)"

clean
: >"$fb/$hex.sig"
want=1 run_sign "sign, a digest in cosign's older format" github gateway "${backend_run[@]}"
same "sign, a digest in cosign's older format: nothing written" "" "$(cat "$work/cosign.log")"
check "sign, a digest in cosign's older format: says so" has "$work/run.err" \
  "$repo@$index_digest carries cosign's older format already: one digest never carries both, nothing written"
clean
want=1 run_sign "sign, the registry out of reach" github gateway "${backend_run[@]}" FAKE_ORAS_DOWN=1
same "sign, the registry out of reach: nothing written" "" "$(cat "$work/cosign.log")"
index_of "$amd64" "$other"
want=1 run_sign "sign, an index read back with another manifest" github gateway "${backend_run[@]}"
check "sign, an index read back with another manifest: says so" has "$work/run.err" \
  "$repo@$index_digest is not an index of exactly the two scanned manifests"
index_of "$amd64" "$arm64"
jq --arg c "$config" '.Results = [{Target: "app", Vulnerabilities: [{Severity: "CRITICAL"}]}]' \
  "$sg/legs/leg-gateway-arm64/trivy.json" >"$work/critical.json"
cp "$work/critical.json" "$sg/legs/leg-gateway-arm64/trivy.json"
want=1 run_sign "sign, a release whose scan lists a CRITICAL" github gateway "${backend_run[@]}"
same "sign, a release whose scan lists a CRITICAL: nothing written" "" "$(cat "$work/cosign.log")"
image gateway "$backend"
want=1 run_sign "sign, the index of another image than asked" github feed-service "${backend_run[@]}"
check "sign, the index of another image than asked: says so" has "$work/run.err" \
  "the index is of $repo, not of image feed-service"

clean
want=1 run_sign "sign, a release on a machine" local gateway
same "sign, a release on a machine: nothing written" "" "$(cat "$work/cosign.log")"
check "sign, a release on a machine: names the workflow" has "$work/run.err" \
  "this run is the workflow 'local', but releases of source backend are signed only as $backend_subject"
want=1 run_sign "sign, a release built by another workflow" github gateway "${backend_run[@]}" \
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/ci.yml@refs/heads/main
same "sign, a release built by another workflow: nothing written" "" "$(cat "$work/cosign.log")"

for how in github local; do
  clean
  image drill-vulnerable "$backend"
  cp "$work/critical.json" "$sg/legs/leg-drill-vulnerable-arm64/trivy.json"
  run_sign "sign, drill-vulnerable with its CRITICAL ($how)" "$how" drill-vulnerable "${backend_run[@]}"
  same "sign, drill-vulnerable ($how): vuln, no provenance" \
    "sign,spdxjson amd64,spdxjson arm64,vuln index|false" "$(calls)|$provenance"
  same "sign, drill-vulnerable ($how): the CRITICAL in its predicate" 1 \
    "$(jq '[.scanner.result.platforms[].report.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$fb/last-vuln.json")"
done
clean
image drill-no-provenance "$backend"
run_sign "sign, drill-no-provenance" github drill-no-provenance "${backend_run[@]}"
same "sign, drill-no-provenance: vuln, never provenance" \
  "sign,spdxjson amd64,spdxjson arm64,vuln index|false" "$(calls)|$provenance"
clean
cp "$work/critical.json" "$sg/legs/leg-drill-no-provenance-arm64/trivy.json"
want=1 run_sign "sign, drill-no-provenance with a CRITICAL" github drill-no-provenance "${backend_run[@]}"
same "sign, drill-no-provenance with a CRITICAL: nothing written" "" "$(cat "$work/cosign.log")"

# A run of svp-frontend: its own repository, commit and identity, its code in the checkout webtree.
clean
image web "$frontend"
run_sign "sign of svp-frontend, its web release" github web "${web_run[@]}"
same "sign of svp-frontend, its web release: signature, SBOMs, vuln, then provenance=true" \
  "sign,spdxjson amd64,spdxjson arm64,vuln index|true" "$(calls)|$provenance"
clean
want=1 run_sign "sign of svp-frontend with the backend's workflow" github web "${web_run[@]}" \
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
same "sign of svp-frontend with the backend's workflow: nothing written" "" "$(cat "$work/cosign.log")"
check "sign of svp-frontend with the backend's workflow: names the source's subject" has "$work/run.err" \
  "releases of source web are signed only as $web_subject"
want=1 run_sign "sign, the backend's run on svp-frontend's image" github web "${backend_run[@]}"
check "sign, the backend's run on svp-frontend's image: names the prefix" has "$work/run.err" \
  "${frontend}web is not under $backend"
image web "$backend"
want=1 run_sign "sign of svp-frontend on the backend's web" github web "${web_run[@]}"
check "sign of svp-frontend on the backend's web: names svp-frontend's prefix" has "$work/run.err" \
  "is not under $frontend, the prefix of release source web"
image gateway "$frontend"
want=1 run_sign "sign of svp-frontend on a gateway under its prefix" github gateway "${web_run[@]}"
check "sign of svp-frontend on a gateway under its prefix: names what it publishes" has "$work/run.err" \
  "gateway is not an image of release source web (web)"
image drill-vulnerable "$frontend"
want=1 run_sign "sign of svp-frontend on a drill image under its prefix" github drill-vulnerable "${web_run[@]}"
same "sign of svp-frontend on a drill image under its prefix: nothing written" "" "$(cat "$work/cosign.log")"
image web "$frontend"
want=1 run_sign "sign of a repository no release source names" github web "${web_run[@]}" GITHUB_REPOSITORY=octo/repo
check "sign of a repository no release source names: says so" has "$work/run.err" \
  "this run is of https://github.com/octo/repo, which is the repository of 0 release sources"
rm -rf "$sg/legs/leg-web-amd64"
want=1 run_sign "sign, a leg missing" github web "${web_run[@]}"
check "sign, a leg missing: says so" has "$work/run.err" "web: a leg did not pass"
clean

check "no docker call of a step or guard got DOCKER_DEFAULT_PLATFORM" test ! -s "$work/platform.log"
[ ! -s "$work/platform.log" ] || cat "$work/platform.log" >&2

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
