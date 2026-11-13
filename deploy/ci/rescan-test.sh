#!/usr/bin/env bash
# Tests for deploy/ci/rescan.sh run and rescan_one in a throwaway checkout of what they read and a clone of a made-up
# svp-gitops. The variables of a GitHub Actions job are made up; a fake gh and a fake cosign first on PATH record their
# arguments, so no test reaches GitHub, a registry or Sigstore. Runs on macOS and Linux: no network, Docker or cluster.

# Usage, from anywhere: deploy/ci/rescan-test.sh
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

# --- Fakes: gh answers pr list from gh/prs.json (an entry with a head only for that --head); cosign refuses every
# signature and takes every attestation.
mkdir -p "$work/bin" "$work/gh" "$work/home" "$work/runner-temp"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
case "$1 $2" in
"pr list")
  head= prev=
  for a in "$@"; do
    [ "$prev" != --head ] || head=$a
    prev=$a
  done
  jq --arg h "$head" '[.[] | select((.head // $h) == $h) | del(.head)]' "$FAKE_GH_DIR/prs.json"
  ;;
esac
EOF
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
[ "$1" = attest ] && exit 0
echo "Error: no signatures found" >&2
exit 1
EOF
chmod 755 "$work/bin/gh" "$work/bin/cosign"
echo '[]' >"$work/gh/prs.json"

# on github|local COMMAND...: runs COMMAND with the variables of a made-up GitHub Actions job (repository octo/repo),
# or on a machine with none of them; the fakes first on PATH. git reads no configuration of this machine.
on() {
  local where=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_REF -u GITHUB_SHA -u GITHUB_EVENT_NAME
    -u GITHUB_EVENT_PATH -u RUNNER_TEMP -u GIT_DIR -u GIT_WORK_TREE -u SVP_CODE_ROOT
    PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" FAKE_COSIGN_LOG="$work/cosign.log")
  case $where in
  github)
    "${base[@]}" GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 \
      GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main GITHUB_REF=refs/heads/main \
      GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_EVENT_NAME=schedule RUNNER_TEMP="$work/runner-temp" "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  esac
}
# fresh: empties the files of a job and the logs of the fakes.
fresh() { : >"$work/output" && : >"$work/summary" && : >"$work/gh.log" && : >"$work/cosign.log"; }

tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/docker-bake.json" "$tree/deploy/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
digest_a=sha256:$(printf 'a%.0s' $(seq 64))
digest_b=sha256:$(printf 'b%.0s' $(seq 64))
backend_run=(GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com)

# --- rescan.sh run: a run attests only the releases of its own repository's source, as that source's signing workflow.
# A clone of svp-gitops whose main names a gateway of backend and a web of svp-frontend; cosign refuses every signature.
rg=$work/rescan-gitops
gr() {
  GIT_DIR=$rg/.git GIT_WORK_TREE=$rg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$rg/envs/stg/images"
for svc in gateway user-service video-service engagement-service feed-service media-worker; do
  d=
  [ "$svc" != gateway ] || d=$digest_a
  printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-backend/%s\n  tag: "%s"\n  digest: "%s"\n' "$svc" \
    "${d:+0123456789ab}" "$d" >"$rg/envs/stg/images/$svc.yaml"
done
printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-frontend/web\n  tag: "0123456789ab"\n  digest: "%s"\n' "$digest_b" \
  >"$rg/envs/stg/images/web.yaml"
git init -q --bare "$rg.git"
gr init -q -b main && gr add -A && gr commit -qm release && gr remote add origin "$rg.git" && gr push -q origin main
web_run=(GITHUB_REPOSITORY=anhnvcoder/svp-frontend
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main)
backend_rescan=("${backend_run[@]}"
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main)
# rescan_run NAME WANT_RC VAR=VALUE... -- [--source NAME]: rescan.sh run in a made-up job on github with the variables,
# its output in rescan-NAME.out, its OUT rescan-NAME.
rescan_run() {
  local name=$1 want=$2 rc=0 vars=()
  shift 2
  while [ "$1" != -- ]; do
    vars+=("$1")
    shift
  done
  shift
  fresh
  echo '[]' >"$work/gh/prs.json"
  on github env GITHUB_SERVER_URL=https://github.com "${vars[@]}" "$tree/deploy/ci/rescan.sh" run "$@" \
    "$work/rescan-$name" "$rg" >"$work/rescan-$name.out" 2>&1 || rc=$?
  same "rescan.sh run: $name (exit $want)" "$want" "$rc"
}
# nothing_read NAME: neither the host nor cosign was asked, and OUT was not created.
nothing_read() {
  if [ ! -s "$work/gh.log" ] && [ ! -s "$work/cosign.log" ] && [ ! -e "$work/rescan-$1" ]; then
    ok "rescan.sh run: $1: nothing read, nothing attested"
  else
    fail "rescan.sh run: $1: something was read: $(cat "$work/gh.log" "$work/cosign.log")"
  fi
}
rescan_run "the scheduled rescan of backend" 1 "${backend_rescan[@]}" --
check "rescan.sh run: backend: the promote pull request of backend asked for" has "$work/gh.log" "--head bot/promote-stg "
check "rescan.sh run: backend: the web of svp-frontend left to its source" has "$work/rescan-the scheduled rescan of backend.out" \
  "skip  web in main of svp-gitops, envs/stg/images/web.yaml: ghcr.io/anhnvcoder/svp-frontend/web is a release of source web"
check "rescan.sh run: backend: the signature of its gateway asked for" has "$work/cosign.log" \
  "--certificate-identity https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/svp-backend/gateway@$digest_a"
check "rescan.sh run: backend: unsigned, so not attested" lacks "$work/cosign.log" "attest"
rescan_run "svp-frontend without --source" 1 "${web_run[@]}" --
check "rescan.sh run: svp-frontend without --source: names both sources" has "$work/rescan-svp-frontend without --source.out" \
  "FAIL  rescan.sh run --source backend in a run of https://github.com/anhnvcoder/svp-frontend, the repository of release source web: a run attests only the releases of its own source (--source web)"
nothing_read "svp-frontend without --source"
rescan_run "backend with --source web" 1 "${backend_rescan[@]}" -- --source web
check "rescan.sh run: backend with --source web: names both sources" has "$work/rescan-backend with --source web.out" \
  "FAIL  rescan.sh run --source web in a run of https://github.com/anhnvcoder/svp-backend, the repository of release source backend"
nothing_read "backend with --source web"
rescan_run "svp-frontend with --source web, from another workflow" 1 "${web_run[@]}" \
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-frontend/.github/workflows/ci.yml@refs/heads/main -- --source web
check "rescan.sh run: another workflow: names the identity" has \
  "$work/rescan-svp-frontend with --source web, from another workflow.out" \
  "FAIL  this run is https://github.com/anhnvcoder/svp-frontend/.github/workflows/ci.yml@refs/heads/main, but the releases of source web are attested only as https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main"
nothing_read "svp-frontend with --source web, from another workflow"
rescan_run "svp-frontend with --source web" 1 "${web_run[@]}" -- --source web
check "rescan.sh run: svp-frontend: its own promote pull request asked for" has "$work/gh.log" "--head bot/promote-stg-web "
check "rescan.sh run: svp-frontend: the gateway of backend left to its source" has "$work/rescan-svp-frontend with --source web.out" \
  "skip  gateway in main of svp-gitops, envs/stg/images/gateway.yaml: ghcr.io/anhnvcoder/svp-backend/gateway is a release of source backend"
check "rescan.sh run: svp-frontend: the signature of its web asked for, as its identity" has "$work/cosign.log" \
  "--certificate-identity https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/svp-frontend/web@$digest_b"
check "rescan.sh run: svp-frontend: nothing of backend asked for" lacks "$work/cosign.log" "svp-backend/"
fresh
rc=0
on local "$tree/deploy/ci/rescan.sh" run "$work/rescan-local" "$rg" >"$work/rescan-local.out" 2>&1 || rc=$?
same "rescan.sh run on a machine: refused first, as CI only" \
  "1 FAIL  rescan.sh run attests with the workflow's identity: CI only" "$rc $(cat "$work/rescan-local.out")"

# --- rescan_one picks its branch by the format the digest is signed in; the two never swap. rescan.sh is sourced (its
# dispatch only runs when executed) and what rescan_one calls around the branch is replaced: signature check, scan,
# gate, predicate, release_format and replace_vuln_bundle (logging its call). The fake cosign logs `attest --replace`.
repo=ghcr.io/anhnvcoder/svp-backend/gateway
rescan_ci=$work/rescan-ci
mkdir -p "$rescan_ci"
printf '#!/usr/bin/env bash\nexit 0\n' >"$rescan_ci/scan-gate.sh"
printf '#!/usr/bin/env bash\necho {} >"$2"\n' >"$rescan_ci/vuln-predicate.sh"
chmod 755 "$rescan_ci/scan-gate.sh" "$rescan_ci/vuln-predicate.sh"
# rescan_branch NAME FORMAT WANT_RC: rescan_one of the made-up release in a rescan job of backend with release_format
# answering FORMAT; its output in rescan-one.out, the calls of replace_vuln_bundle in rescan-one.replace.
rescan_branch() {
  local name=$1 format=$2 want=$3 rc=0
  fresh
  : >"$work/rescan-one.replace"
  # shellcheck disable=SC2016 # expanded by the inner shell
  on github env "${backend_rescan[@]}" RELEASE_FORMAT="$format" REPLACE_LOG="$work/rescan-one.replace" "$BASH" -c \
    '. "$1/deploy/ci/rescan.sh"
    ci_dir=$2
    verify_signature() { :; }
    scan_index() { mkdir -p "$3/amd64" "$3/arm64" && echo "{}" >"$3/amd64/trivy.json" && echo "{}" >"$3/arm64/trivy.json"; }
    release_format() { echo "$RELEASE_FORMAT"; }
    replace_vuln_bundle() { echo "replace_vuln_bundle $*" >>"$REPLACE_LOG"; }
    rescan_one gateway "$3" "$4" "$5" ""' _ "$tree" "$rescan_ci" "$repo" "$digest_a" "$work/rescan-one" \
    >"$work/rescan-one.out" 2>&1 || rc=$?
  same "rescan_one: $name (exit $want)" "$want" "$rc"
}
rescan_branch "a digest in cosign's older format" legacy 0
check "rescan_one: older format: attested in place with --replace" has "$work/cosign.log" "--replace --type vuln"
check "rescan_one: older format: no bundle replaced" lacks "$work/rescan-one.replace" "replace_vuln_bundle"
rescan_branch "a digest in Sigstore bundles" bundle 0
check "rescan_one: bundles: replace_vuln_bundle on the digest and its predicate" has "$work/rescan-one.replace" \
  "replace_vuln_bundle $repo $digest_a $work/rescan-one/predicate.json"
check "rescan_one: bundles: no --replace attestation" lacks "$work/cosign.log" "--replace"
rescan_branch "a digest with neither" none 1
check "rescan_one: neither: nothing attested" lacks "$work/cosign.log" "attest"
check "rescan_one: neither: nothing replaced" lacks "$work/rescan-one.replace" "replace_vuln_bundle"

# --- ECR: after a digest is attested on GHCR, rescan.sh refreshes it in the ECR of each environment whose envs/ names
# it, as that environment's rescan role. The fakes of ecr-copy-test.sh keep GHCR and the two ECRs as files; rescan_one
# is replaced by what it leaves on GHCR: one new vuln bundle. A clone of svp-gitops: main runs the gateway in stg and
# prd; the open pull request of bot/promote-prd releases a user-service only it names; rollback names a video-service.

# shellcheck source=deploy/ci/ecr-copy-test.sh
. "$here/ecr-copy-test.sh"
ecr_fakes "$work/ecr-bin"
mkdir -p "$work/docker"
echo '{}' >"$work/docker/config.json"
export FAKE_REG=$work/reg FAKE_LOG=$work/ecr-calls.log
stg_account=111111111111 prd_account=222222222222
stg_ecr=$stg_account.dkr.ecr.ap-southeast-1.amazonaws.com prd_ecr=$prd_account.dkr.ecr.ap-southeast-1.amazonaws.com
ghcr=ghcr.io/anhnvcoder/svp-backend
oras_image=registry.example/oras:v0@sha256:$(printf 'e%.0s' $(seq 64))
vuln_type=https://cosign.sigstore.dev/attestation/vuln/v1
fx_release "$ghcr/gateway" gateway
ecr_gateway=$fx_index
fx_release "$ghcr/user-service" user-service 100
ecr_user=$fx_index
mkdir -p "$FAKE_REG/$prd_ecr/svp-backend/user-service"
cp "$FAKE_REG/$ghcr/user-service/"*.json "$FAKE_REG/$prd_ecr/svp-backend/user-service/"
fx_release "$ghcr/video-service" video-service 100
ecr_video=$fx_index
mkdir -p "$FAKE_REG/$stg_ecr/svp-backend/video-service"
cp "$FAKE_REG/$ghcr/video-service/"*.json "$FAKE_REG/$stg_ecr/svp-backend/video-service/"
eg=$work/ecr-gitops
ge() {
  GIT_DIR=$eg/.git GIT_WORK_TREE=$eg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
# ecr_image ENV SERVICE DIGEST: writes envs/ENV/images/SERVICE.yaml of that clone (web is svp-frontend's).
ecr_image() {
  local repo=$ghcr/$2
  [ "$2" != web ] || repo=ghcr.io/anhnvcoder/svp-frontend/web
  mkdir -p "$eg/envs/$1/images"
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' "$repo" "${3:+0123456789ab}" "$3" \
    >"$eg/envs/$1/images/$2.yaml"
}
for e in stg prd; do
  for svc in user-service video-service engagement-service feed-service media-worker web; do ecr_image "$e" "$svc" ""; done
  ecr_image "$e" gateway "$ecr_gateway"
done
git init -q --bare "$eg.git"
ge init -q -b main && ge add -A && ge commit -qm release && ge remote add origin "$eg.git" && ge push -q origin main
ge checkout -q -b prd && ecr_image prd user-service "$ecr_user" && ge commit -qam prd &&
  ge push -q origin HEAD:refs/heads/bot/promote-prd
ge checkout -q -b rollback main && ecr_image stg video-service "$ecr_video" && ge commit -qam rollback &&
  ge push -q origin HEAD:refs/heads/rollback
ge checkout -q main
prd_pr='[{"head": "bot/promote-prd", "number": 12, "isCrossRepository": false, "author": {"login": "app/svp-gitops-promoter"}}]'
# ecr_run NAME WANT_RC VAR=VALUE... -- COMMAND ARGS...: rescan.sh's COMMAND (run or run_digest) in a rescan job of
# backend with the ECR fakes and the replaced rescan_one; output in ecr-NAME.out, the fakes' calls in ecr-calls.log.
ecr_run() {
  local name=$1 want=$2 rc=0 vars=()
  shift 2
  while [ "$1" != -- ]; do
    vars+=("$1")
    shift
  done
  shift
  fresh
  : >"$FAKE_LOG"
  echo "$prd_pr" >"$work/gh/prs.json"
  # shellcheck disable=SC2016 # expanded by the inner shell
  on github env PATH="$work/ecr-bin:$work/bin:$PATH" "${backend_rescan[@]}" ORAS_IMAGE="$oras_image" \
    FAKE_ORAS_IMAGE="$oras_image" FAKE_REG="$FAKE_REG" FAKE_LOG="$FAKE_LOG" DOCKER_CONFIG="$work/docker" \
    FAKE_AWS_ACCOUNTS="svp-stg=$stg_account svp-prd=$prd_account" FAKE_FAIL_REFERRER="$work/fail-referrer" \
    ${vars[@]+"${vars[@]}"} "$BASH" -c '
    . "$1/deploy/ci/rescan.sh"
    . "$1/deploy/ci/ecr-copy-test.sh"
    rescan_one() {
      mkdir -p "$4" && fx_rescan "$2" "$3" "$3-rescan-$$-$RANDOM" >/dev/null && : >"$4/attested"
      echo "rescanned $2@$3"
    }
    shift
    "$@"' _ "$tree" "$@" >"$work/ecr-$name.out" 2>&1 || rc=$?
  same "rescan ECR: $name (exit $want)" "$want" "$rc"
  [ "$rc" = "$want" ] || sed 's/^/      | /' "$work/ecr-$name.out" >&2
  check "rescan ECR: $name: no account ID printed" lacks "$work/ecr-$name.out" "$stg_account"
  check "rescan ECR: $name: no account ID printed (prd)" lacks "$work/ecr-$name.out" "$prd_account"
}
registries=(SVP_ECR_REGISTRY_STG="$stg_ecr" SVP_ECR_REGISTRY_PRD="$prd_ecr")
# one_new_vuln NAME ECR REPO DIGEST: ECR's REPO holds one vuln bundle of DIGEST, the one GHCR has now.
one_new_vuln() {
  same "rescan ECR: $1" "$(fx_bundles "$ghcr/$3" "$4" "$vuln_type")" "$(fx_bundles "$2/svp-backend/$3" "$4" "$vuln_type")"
  same "rescan ECR: $1: exactly one" 1 "$(fx_bundles "$2/svp-backend/$3" "$4" "$vuln_type" | grep -c .)"
}
ecr_run "main, prd's pull request, a rollback" 0 "${registries[@]}" -- run "$work/ecr-run-1" "$eg" rollback
one_new_vuln "the user-service only bot/promote-prd names, refreshed in prd's ECR" "$prd_ecr" user-service "$ecr_user"
one_new_vuln "the video-service of the rollback (vuln 100 hours old), refreshed in stg's ECR" "$stg_ecr" video-service \
  "$ecr_video"
check "rescan ECR: prd's ECR as prd's rescan role" has "$FAKE_LOG" \
  "aws svp-prd ecr batch-delete-image --region ap-southeast-1 --registry-id $prd_account --repository-name svp-backend/user-service"
check "rescan ECR: stg's ECR as stg's rescan role" has "$FAKE_LOG" \
  "aws svp-stg ecr batch-delete-image --region ap-southeast-1 --registry-id $stg_account --repository-name svp-backend/video-service"
check "rescan ECR: the gateway, in no ECR, left out" has "$work/ecr-main, prd's pull request, a rollback.out" \
  "skip  ECR has no $ecr_gateway"
check "rescan ECR: the video-service not in prd's ECR" lacks "$FAKE_LOG" "--registry-id $prd_account --repository-name svp-backend/video-service"

# A commit of the code repository (k3d, before svp-gitops) as values_ref: its digests reach no ECR.
mkdir -p "$tree/deploy/k8s/values/services"
fx_release "$ghcr/feed-service" feed-service
ecr_feed=$fx_index
for svc in gateway user-service video-service engagement-service feed-service media-worker web; do
  repo=$ghcr/$svc d=
  [ "$svc" != web ] || repo=ghcr.io/anhnvcoder/svp-frontend/web
  [ "$svc" != feed-service ] || d=$ecr_feed
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' "$repo" "${d:+0123456789ab}" "$d" \
    >"$tree/deploy/k8s/values/services/$svc.yaml"
done
gt() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
gt init -q -b main && gt add -A && gt commit -qm values
code=$(gt rev-parse HEAD)
ecr_run "values_ref a commit of the code repository" 0 "${registries[@]}" -- run "$work/ecr-run-2" "$eg" "$code"
check "rescan ECR: the code repository's release rescanned" has \
  "$work/ecr-values_ref a commit of the code repository.out" "rescanned $ghcr/feed-service@$ecr_feed"
check "rescan ECR: the code repository's release asked of no ECR" lacks "$FAKE_LOG" "$ecr_feed"

ecr_run "no ECR host in the job" 0 -- run "$work/ecr-run-3" "$eg" rollback
check "rescan ECR: no host: GHCR still rescanned" has "$work/ecr-no ECR host in the job.out" \
  "rescanned $ghcr/video-service@$ecr_video"
check "rescan ECR: no host: AWS never called" lacks "$FAKE_LOG" "aws "
check "rescan ECR: no host: no ECR read" lacks "$FAKE_LOG" "dkr.ecr"

# --- rescan.sh run-digest: a release left in ECR that no ref names. stg: the copy of its leg fails after the index,
# its vuln ages out, the next copy is refused naming the dispatch; run-digest refreshes it and copies the rest; the leg
# passes again. prd: promote-prd copied it, then stopped; run-digest refreshes prd's ECR alone and copies nothing.
fx_release "$ghcr/media-worker" media-worker 100
ecr_media=$fx_index
copy_leg() {
  ecr_run "$1" "$2" -- "$tree/deploy/ci/ecr-copy.sh" copy "$ghcr/media-worker" "$ecr_media" "$stg_ecr"
}
touch "$work/fail-referrer"
copy_leg "the leg's copy fails after the index" 1
copy_leg "the leg run again, its vuln too old" 1
check "rescan ECR: the leg run again: names the dispatch of one digest" has \
  "$work/ecr-the leg run again, its vuln too old.out" "-f image=media-worker -f digest=$ecr_media -f env=<stg|prd>"
ecr_run "run-digest stg" 0 "${registries[@]}" -- run_digest "$work/ecr-digest-1" media-worker "$ecr_media" stg
one_new_vuln "run-digest stg: the new vuln in stg's ECR" "$stg_ecr" media-worker "$ecr_media"
check "rescan ECR: run-digest stg: copied what was missing" has "$work/ecr-run-digest stg.out" "copy    $ghcr/media-worker"
copy_leg "the leg run again after run-digest" 0
check "rescan ECR: the leg after run-digest: nothing left to copy" lacks "$FAKE_LOG" "oras cp"
fx_release "$ghcr/engagement-service" engagement-service 100
ecr_engagement=$fx_index
mkdir -p "$FAKE_REG/$prd_ecr/svp-backend/engagement-service"
cp "$FAKE_REG/$ghcr/engagement-service/"*.json "$FAKE_REG/$prd_ecr/svp-backend/engagement-service/"
ecr_run "run-digest prd" 0 "${registries[@]}" -- run_digest "$work/ecr-digest-2" engagement-service "$ecr_engagement" prd
one_new_vuln "run-digest prd: the new vuln in prd's ECR" "$prd_ecr" engagement-service "$ecr_engagement"
check "rescan ECR: run-digest prd: no copy" lacks "$work/ecr-run-digest prd.out" "copy    "
check "rescan ECR: run-digest prd: stg's ECR not asked" lacks "$FAKE_LOG" "$stg_account"
ecr_run "run-digest without the env's host" 1 SVP_ECR_REGISTRY_STG="$stg_ecr" -- \
  run_digest "$work/ecr-digest-3" engagement-service "$ecr_engagement" prd
check "rescan ECR: run-digest without the host: names its variable" has \
  "$work/ecr-run-digest without the env's host.out" "no ECR host of prd in this job (SVP_ECR_REGISTRY_PRD)"
ecr_run "run-digest of a drill image" 1 "${registries[@]}" -- \
  run_digest "$work/ecr-digest-4" drill-vulnerable "$ecr_engagement" stg
check "rescan ECR: run-digest of a drill image: refused" has "$work/ecr-run-digest of a drill image.out" \
  "drill-vulnerable is no service of release source backend"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
