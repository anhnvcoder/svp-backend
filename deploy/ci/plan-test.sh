#!/usr/bin/env bash
# Tests for deploy/ci/plan.sh, the first job of images.yml, in a throwaway checkout with its own origin; the variables
# of a GitHub Actions job are made up. Checked:
#   - a drill run on main: the seven outputs in GITHUB_OUTPUT and the summary in GITHUB_STEP_SUMMARY in a job; on a
#     machine, the summary then the outputs on stdout;
#   - a run of svp-frontend (SVP_CODE_ROOT its checkout, HEAD the run's commit): the services of its release source at
#     every run, no base, nothing to promote of the charts; a service or a drill its source does not have, and a tree
#     whose HEAD is not the run's commit, are refused; on a machine the run is of the repository of that checkout's
#     origin on github.com (run_repo_url of common.sh), and one off github.com is refused without showing a credential;
#   - in this checkout: a run of svp-frontend that forgot SVP_CODE_ROOT, a run of a fork and a run of this repository
#     under its name before the rename (no source names it) are refused; services all builds the six, services web is
#     refused, and build-image.sh refuses web before it builds anything;
#   - a push to main that builds no image: promote_charts when a file under deploy/helm/ or one a symbolic link there
#     points to changed, not for docs/.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/plan-test.sh
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
    HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
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
# fresh: empties the files a job's outputs and summary go to.
fresh() { : >"$work/output" && : >"$work/summary"; }
mkdir -p "$work/home" "$work/runner-temp"

# A throwaway checkout, with its own origin, of what plan.sh reads: deploy/ci/, deploy/k8s/lib.sh, the policy's values,
# a chart file and a symbolic link of a chart to a file beside the charts. GIT_DIR is set for every git call of the test
# itself, so git can never reach another repository.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$tree/deploy/helm/svp-observability/files" \
  "$tree/deploy/observability/otelcol" "$tree/docs"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
echo "receivers: {}" >"$tree/deploy/observability/otelcol/k8s-config.yaml"
ln -s ../../../observability/otelcol/k8s-config.yaml "$tree/deploy/helm/svp-observability/files/otelcol-k8s-config.yaml"
echo "# A decision" >"$tree/docs/decision.md"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
git init -q --bare "$work/origin.git"
g remote add origin "$work/origin.git" && g push -q origin main
base=$(g rev-parse HEAD)
# A checkout of svp-frontend, another release source's repository, whose CI runs these scripts from a pinned checkout of
# this one: SVP_CODE_ROOT names it.
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

# A drill run on main hands its seven outputs on, in this order, and writes its summary.
want_plan='mode=drill
images=["drill-vulnerable","drill-unsigned","drill-no-provenance"]
legs={"include":[{"image":"drill-vulnerable","arch":"amd64","runner":"ubuntu-24.04"},{"image":"drill-vulnerable","arch":"arm64","runner":"ubuntu-24.04-arm"},{"image":"drill-unsigned","arch":"amd64","runner":"ubuntu-24.04"},{"image":"drill-unsigned","arch":"arm64","runner":"ubuntu-24.04-arm"},{"image":"drill-no-provenance","arch":"amd64","runner":"ubuntu-24.04"},{"image":"drill-no-provenance","arch":"arm64","runner":"ubuntu-24.04-arm"}]}
has_images=true
base=
promote_charts=false
values_ref='
fresh
backend_run=(GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com)
got=$(on github env "${backend_run[@]}" GITHUB_SHA="$base" EVENT_NAME=workflow_dispatch GIT_REF=refs/heads/main \
  INPUT_DRILL=true "$tree/deploy/ci/plan.sh")
same "plan.sh in a job: nothing on stdout" "" "$got"
same "plan.sh in a job: the seven outputs in GITHUB_OUTPUT" "$want_plan" "$(cat "$work/output")"
same "plan.sh in a job: the summary" "Mode: drill. Images: drill-vulnerable drill-unsigned drill-no-provenance." "$(cat "$work/summary")"
fresh
got=$(on local env EVENT_NAME=workflow_dispatch GIT_REF=refs/heads/main INPUT_DRILL=true "$tree/deploy/ci/plan.sh")
same "plan.sh on a machine: summary then outputs on stdout" \
  "Mode: drill. Images: drill-vulnerable drill-unsigned drill-no-provenance."$'\n'"$want_plan" "$got"
check "plan.sh on a machine: no file of a job was written" test ! -s "$work/output" -a ! -s "$work/summary"

# plan.sh of svp-frontend's run (SVP_CODE_ROOT its checkout, HEAD the run's commit): the services of its release source at
# every run, no base, nothing to promote of the charts.
# web_plan NAME WANT_RC VAR=VALUE...: plan.sh in a made-up job of svp-frontend, its outputs in output.
web_plan() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on github env GITHUB_REPOSITORY=anhnvcoder/svp-frontend GITHUB_SERVER_URL=https://github.com GITHUB_SHA="$web_head" \
    SVP_CODE_ROOT="$webtree" GIT_REF=refs/heads/main "$@" "$tree/deploy/ci/plan.sh" >/dev/null 2>"$work/plan.err" ||
    rc=$?
  same "plan.sh of svp-frontend: $name (exit $want)" "$want" "$rc"
}
web_plan "a push to main" 0 EVENT_NAME=push
same "plan.sh of svp-frontend: a push to main builds web on both architectures, no base" 'mode=build
images=["web"]
legs={"include":[{"image":"web","arch":"amd64","runner":"ubuntu-24.04"},{"image":"web","arch":"arm64","runner":"ubuntu-24.04-arm"}]}
has_images=true
base=
promote_charts=false
values_ref=' "$(cat "$work/output")"
web_plan "a pull request" 0 EVENT_NAME=pull_request PR_BASE_REF=main GIT_REF=refs/pull/7/merge
same "plan.sh of svp-frontend: a pull request builds web" 'images=["web"]' "$(grep '^images=' "$work/output")"
web_plan "a dispatch with services web" 0 EVENT_NAME=workflow_dispatch INPUT_SERVICES=web
same "plan.sh of svp-frontend: services web builds web" 'images=["web"]' "$(grep '^images=' "$work/output")"
web_plan "a dispatch with services gateway" 1 EVENT_NAME=workflow_dispatch INPUT_SERVICES=gateway
check "plan.sh of svp-frontend: services gateway is refused, naming what the source publishes" has "$work/plan.err" \
  "services: 'gateway' is not an image of release source web (web)"
web_plan "a drill" 1 EVENT_NAME=workflow_dispatch INPUT_DRILL=true
check "plan.sh of svp-frontend: a drill is refused" has "$work/plan.err" "release source web has no drill image to build"
web_plan "a rescan" 0 EVENT_NAME=schedule
same "plan.sh of svp-frontend: a rescan builds nothing" 'mode=rescan has_images=false' \
  "$(grep '^mode=' "$work/output") $(grep '^has_images=' "$work/output")"
web_plan "a tree at another commit than the run's" 1 EVENT_NAME=push GITHUB_SHA="$base"
check "plan.sh of svp-frontend: a tree at another commit: names SVP_CODE_ROOT" has "$work/plan.err" \
  "HEAD of $webtree is $web_head, but this run builds $base of https://github.com/anhnvcoder/svp-frontend: set SVP_CODE_ROOT"
# On a machine with SVP_CODE_ROOT the checkout of svp-frontend, the run is of that checkout's repository, read from its
# origin on github.com (https or ssh), at its HEAD; an origin off github.com is refused, a credential in it never shown.
# repo_of: run_repo_url of common.sh so, with its errors.
# shellcheck disable=SC2016 # expanded by the inner shell
repo_of() { on local env SVP_CODE_ROOT="$webtree" bash -c '. "$1/deploy/ci/common.sh" && run_repo_url' _ "$tree" 2>&1; }
same "run_repo_url on a machine, SVP_CODE_ROOT: the checkout's repository" https://github.com/anhnvcoder/svp-frontend \
  "$(repo_of)"
got=$(on local env SVP_CODE_ROOT="$webtree" EVENT_NAME=push GIT_REF=refs/heads/main "$tree/deploy/ci/plan.sh" 2>/dev/null |
  grep '^images=')
same "plan.sh on a machine, SVP_CODE_ROOT: builds the services of svp-frontend's source" 'images=["web"]' "$got"
gw remote set-url origin git@github.com:anhnvcoder/svp-frontend.git
same "run_repo_url on a machine, SVP_CODE_ROOT: an ssh origin names the same repository" \
  https://github.com/anhnvcoder/svp-frontend "$(repo_of)"
gw remote set-url origin https://gitlab.example/anhnvcoder/svp-frontend.git
same "run_repo_url on a machine, SVP_CODE_ROOT: an origin off github.com is refused, naming it" \
  "FAIL  SVP_CODE_ROOT=$webtree has no remote origin on github.com (got 'https://gitlab.example/anhnvcoder/svp-frontend.git'): its repository cannot be named" \
  "$(repo_of)"
gw remote set-url origin https://x-access-token:ghs_faketoken0123456789@github.com/anhnvcoder/svp-frontend.git
same "run_repo_url on a machine, SVP_CODE_ROOT: an origin carrying a credential is refused, the credential not shown" \
  "FAIL  SVP_CODE_ROOT=$webtree has no remote origin on github.com (got 'https://github.com/anhnvcoder/svp-frontend.git'): its repository cannot be named" \
  "$(repo_of)"
gw remote set-url origin https://github.com/anhnvcoder/svp-frontend.git
# A job of svp-frontend that forgot SVP_CODE_ROOT: this checkout is not the run's commit, so plan.sh stops before it plans
# from this checkout's diff; a run of a repository that is no release source (a fork) stops too.
plan_own() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on github env GITHUB_SERVER_URL=https://github.com GIT_REF=refs/heads/main EVENT_NAME=push "$@" \
    "$tree/deploy/ci/plan.sh" >/dev/null 2>"$work/plan.err" || rc=$?
  same "plan.sh in this checkout: $name (exit $want)" "$want" "$rc"
}
plan_own "a run of svp-frontend without SVP_CODE_ROOT" 1 GITHUB_REPOSITORY=anhnvcoder/svp-frontend GITHUB_SHA="$web_head"
check "plan.sh in this checkout: a run of svp-frontend without SVP_CODE_ROOT: names SVP_CODE_ROOT" has "$work/plan.err" \
  "HEAD of $tree is $base, but this run builds $web_head of https://github.com/anhnvcoder/svp-frontend: set SVP_CODE_ROOT"
lacks "$work/output" "images=" && ok "plan.sh in this checkout: a run of svp-frontend without SVP_CODE_ROOT: no output" ||
  fail "plan.sh in this checkout: a run of svp-frontend without SVP_CODE_ROOT: no output"
plan_own "a run of a fork" 1 GITHUB_REPOSITORY=someone/svp-backend GITHUB_SHA="$base"
check "plan.sh in this checkout: a run of a fork: no release source" has "$work/plan.err" \
  "this run is of https://github.com/someone/svp-backend, which is the repository of 0 release sources"
# A run of this repository under the name it had before the rename names no release source of the table: backend
# builds; such a run builds, pushes and signs nothing.
plan_own "a run under the name before the rename" 1 GITHUB_REPOSITORY=anhnvcoder/short-video-platform GITHUB_SHA="$base"
check "plan.sh in this checkout: a run under the name before the rename: no release source" has "$work/plan.err" \
  "this run is of https://github.com/anhnvcoder/short-video-platform, which is the repository of 0 release sources"
lacks "$work/output" "images=" && ok "plan.sh in this checkout: a run under the name before the rename: no output" ||
  fail "plan.sh in this checkout: a run under the name before the rename: no output"
# web is no service of release source backend (svp-frontend publishes it), and this repository holds no source of it:
# a dispatch builds the six, never web, and build-image.sh refuses web before anything is built.
plan_own "a dispatch with services all" 0 "${backend_run[@]}" GITHUB_SHA="$base" EVENT_NAME=workflow_dispatch \
  INPUT_SERVICES=all
same "plan.sh in this checkout: services all builds the six, not web" \
  'images=["gateway","user-service","video-service","engagement-service","feed-service","media-worker"]' \
  "$(grep '^images=' "$work/output")"
plan_own "a dispatch with services web" 1 "${backend_run[@]}" GITHUB_SHA="$base" EVENT_NAME=workflow_dispatch \
  INPUT_SERVICES="gateway web"
check "plan.sh in this checkout: services web is refused, naming the six" has "$work/plan.err" \
  "services: 'web' is not an image this repository builds (gateway user-service video-service engagement-service feed-service media-worker)"
rc=0
on github env "${backend_run[@]}" GITHUB_SHA="$base" "$tree/deploy/ci/build-image.sh" web amd64 "$work/leg" \
  >/dev/null 2>"$work/build.err" || rc=$?
same "build-image.sh in this checkout: web (exit 1)" 1 "$rc"
# Source backend no longer publishes web, so the source of the run refuses it before the list of this checkout's
# services is read.
check "build-image.sh in this checkout: web is refused, not an image of its release source" has "$work/build.err" \
  "web is not an image of release source backend (gateway user-service video-service engagement-service feed-service media-worker drill-vulnerable drill-unsigned drill-no-provenance): nothing is built, pushed or signed under ghcr.io/anhnvcoder/svp-backend/"
[ ! -e "$work/leg" ] && ok "build-image.sh in this checkout: web: nothing built, no output folder" ||
  fail "build-image.sh in this checkout: web: nothing built, no output folder"

# A push to main that builds no image (the base: the newest successful push run): promote_charts when what the charts
# read changed (a file under deploy/helm/, or the file a symbolic link there points to), not for docs/.
# plan_charts NAME WANT: plan.sh of a push to main after one commit hands on promote_charts=WANT.
plan_charts() {
  local last
  last=$(jq -nc --arg sha "$(g rev-parse HEAD~1)" \
    '{workflow_runs: [{head_sha: $sha, conclusion: "success", event: "push", head_branch: "main"}]}')
  fresh
  on github env "${backend_run[@]}" GITHUB_SHA="$(g rev-parse HEAD)" EVENT_NAME=push GIT_REF=refs/heads/main \
    LAST_SUCCESS_JSON="$last" "$tree/deploy/ci/plan.sh" \
    >/dev/null 2>&1 || fail "plan.sh: $1: exits 0"
  same "plan.sh: $1" "promote_charts=$2 has_images=false" \
    "$(grep '^promote_charts=' "$work/output") $(grep '^has_images=' "$work/output")"
}
echo "# Another decision" >>"$tree/docs/decision.md"
g commit -qam "a decision"
plan_charts "a push of docs/ only promotes nothing" false
echo "# A comment" >>"$tree/deploy/helm/svp-policy/values.yaml"
g commit -qam "a comment in a chart"
plan_charts "a push that changes a chart promotes the charts" true
check "plan.sh: the summary names the chart's file" has "$work/summary" "- deploy/helm/svp-policy/values.yaml"
echo "exporters: {}" >>"$tree/deploy/observability/otelcol/k8s-config.yaml"
g commit -qam "the collector's config"
plan_charts "a push that changes the file a chart's link points to promotes the charts" true

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
