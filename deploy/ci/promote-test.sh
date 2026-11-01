#!/usr/bin/env bash
# Tests for the guards of the promote jobs of .github/workflows/images.yml (promote_not_behind, promote_stg_ref and
# promote_open_pr of deploy/ci/common.sh), and for the list of releases deploy/ci/rescan.sh reads in svp-gitops. Throwaway repositories on
# disk stand for this repository (deploy/ci/, lib.sh and the policy's release sources, with its own origin) and for
# svp-gitops (envs/stg and envs/prd with charts.yaml and images/, reached as file://); a fake gh first on PATH records
# its arguments and answers the open pull requests from a fixture, so no test reaches GitHub. Checked:
#   - promote_not_behind: a run of a commit older than the revision of stg's charts is refused, naming both; the same
#     commit passes (a dispatch that builds again at that commit), and so does a newer one; a revision that is not a
#     full commit, or one this clone has not, is refused;
#   - promote_stg_ref: main gives the commit of main of svp-gitops, and a full commit on main (an older one, a rollback)
#     is given back; a branch name (the bot's, refs/heads/main), a short SHA, a full commit only of the bot's branch and
#     a full commit svp-gitops has not are refused, each with its own message;
#   - promote_open_pr: the app's own open pull request of the branch, never a fork's or a person's from a branch of that
#     name, asked for up to 500; nothing when the app has none; a full list of 500, and a gh that fails, are refused;
#   - rescan.sh list: the releases of every environment of main of svp-gitops, of bot/promote-stg while the app's pull
#     request is open, of a values_ref of svp-gitops, and of a values_ref that is a commit of this repository from
#     before svp-gitops (deploy/k8s/values/services/); a values_ref that is neither fails; a host that does not answer
#     whether the pull request is open fails the list after main's and values_ref's releases are printed;
#   - rescan.sh list of release source web: backend leaves the release of svp-frontend out, saying so, and
#     rescan.sh list --source web lists it alone, from main and from bot/promote-stg-web of its own app;
#   - after the rename, its retired sources dropped: rescan.sh list finds no source oldweb, and a release on main of
#     svp-gitops under the former prefix of this repository is under the prefix of no source, so it is listed (and the
#     run fails on it); a commit of this repository from before svp-gitops is read as values_ref, its releases (under
#     the former prefix) listed.
# Every run is a machine's (the local platform of platform.sh): env -i leaves none of a CI job's variables to the
# scripts. Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/promote-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
real_git=$(command -v git)

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

# --- The fake gh writes each call to gh.log (one line of %q-quoted arguments) and answers pr list from gh/prs.json;
# without that file it fails, as a host that does not answer.
mkdir -p "$work/bin" "$work/gh" "$work/home"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
case "$1 $2" in
"pr list") cat "$FAKE_GH_DIR/prs.json" ;;
*) exit 1 ;;
esac
EOF
chmod 755 "$work/bin/gh"
echo '[]' >"$work/gh/prs.json"

# on COMMAND...: runs COMMAND as a machine would, with no variable of the caller's but these (env -i: none of a CI
# job's). git reads no configuration of this machine.
on() {
  env -i PATH="$work/bin:$PATH" HOME="$work/home" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-}" LC_ALL="${LC_ALL:-}" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" "$@"
}
fresh() { : >"$work/gh.log"; }
gh_line() { printf '%q ' "$@"; }

# --- This repository: deploy/ci/, lib.sh and the policy's values and release sources.
tree=$work/code
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
"$real_git" init -q --bare "$work/code-origin.git"
g remote add origin "$work/code-origin.git"
c0=$(g rev-parse HEAD)
for n in one two three; do echo "# $n" >>"$tree/README.md" && g add README.md && g commit -qm "$n"; done
c1=$(g rev-parse HEAD~2) c2=$(g rev-parse HEAD~1) c3=$(g rev-parse HEAD)
g push -q origin main
digest() { echo "sha256:$(printf "$1%.0s" $(seq 64))"; }
digest_a=$(digest a) digest_b=$(digest b) digest_c=$(digest c) digest_d=$(digest d)

# guard FUNCTION ARGS...: FUNCTION of common.sh of the throwaway checkout, on a machine; output in guard.out.
guard() {
  local rc=0
  on "$BASH" -c '. "$0"; "$@"' "$tree/deploy/ci/common.sh" "$@" >"$work/guard.out" 2>&1 || rc=$?
  return "$rc"
}
# refused NAME MESSAGE FUNCTION ARGS...: FUNCTION fails with exactly the line MESSAGE.
refused() {
  local name=$1 want=$2
  shift 2
  if guard "$@"; then
    fail "$name: refused (passed: $(cat "$work/guard.out"))"
  else
    same "$name: refused, saying why" "FAIL  $want" "$(cat "$work/guard.out")"
  fi
}

# --- promote_not_behind COMMIT REVISION.
refused "promote_not_behind: a run older than stg's charts" \
  "this run's commit ${c1:0:12} is older than ${c2:0:12}, whose charts stg runs: promoting it would take stg back" \
  promote_not_behind "$c1" "$c2"
check "promote_not_behind: the same commit passes" guard promote_not_behind "$c2" "$c2"
check "promote_not_behind: a newer commit passes" guard promote_not_behind "$c3" "$c2"
refused "promote_not_behind: a revision that is no full commit" \
  "stg's charts name revision '${c2:0:12}', not a full commit of this repository" \
  promote_not_behind "$c3" "${c2:0:12}"
refused "promote_not_behind: a revision this clone has not" \
  "revision ffffffffffff of stg's charts is no commit of this clone: cannot tell whether this run is older" \
  promote_not_behind "$c3" "$(printf 'f%.0s' $(seq 40))"

# --- svp-gitops. main: stg and prd at c0 with the gateway released there, then the gateway of stg released at c1 and
# the charts of stg at c2. bot/promote-stg: one commit on top of main, user-service of stg released at c2.
gtree=$work/gitops-src
gs() {
  GIT_DIR=$gtree/.git GIT_WORK_TREE=$gtree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" \
    -c user.name=owner -c user.email=owner@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
# image_file ENV SERVICE REPOSITORY TAG DIGEST: writes envs/ENV/images/SERVICE.yaml of the svp-gitops tree.
image_file() {
  printf '# The release image of %s in %s.\nimage:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' \
    "$2" "$1" "$3" "$4" "$5" >"$gtree/envs/$1/images/$2.yaml"
}
mkdir -p "$gtree/base"
echo "replicas: 1" >"$gtree/base/gateway.yaml"
for env in stg prd; do
  mkdir -p "$gtree/envs/$env/images"
  printf '# The commit whose charts this environment runs.\nrevision: %s\n' "$c0" >"$gtree/envs/$env/charts.yaml"
  for svc in gateway user-service video-service engagement-service feed-service media-worker web; do
    image_file "$env" "$svc" "ghcr.io/anhnvcoder/svp-backend/$svc" "" ""
  done
  image_file "$env" gateway ghcr.io/anhnvcoder/svp-backend/gateway "${c0:0:12}" "$digest_a"
done
gs init -q -b main && gs add -A && gs commit -qm init
image_file stg gateway ghcr.io/anhnvcoder/svp-backend/gateway "${c1:0:12}" "$digest_b"
printf '# The commit whose charts this environment runs.\nrevision: %s\n' "$c2" >"$gtree/envs/stg/charts.yaml"
gs commit -qam "stg: gateway c1, charts c2"
"$real_git" init -q --bare "$work/gitops.git"
gs remote add origin "$work/gitops.git" && gs push -q origin main
gs checkout -q -b bot
image_file stg user-service ghcr.io/anhnvcoder/svp-backend/user-service "${c2:0:12}" "$digest_a"
gs commit -qam "stg: user-service c2" && gs push -q origin HEAD:refs/heads/bot/promote-stg
gitops_url="file://$work/gitops.git"
# remote ARGS...: git in svp-gitops's own repository.
remote() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" --git-dir="$work/gitops.git" "$@"; }
"$real_git" clone -q "$gitops_url" "$work/clone"

# --- promote_stg_ref REF CLONE.
same "promote_stg_ref: main is the commit of main of svp-gitops" "$(remote rev-parse main)" \
  "$(guard promote_stg_ref main "$work/clone" && cat "$work/guard.out")"
older=$(remote rev-parse main~1)
same "promote_stg_ref: an older full commit on main (a rollback) is given back" "$older" \
  "$(guard promote_stg_ref "$older" "$work/clone" && cat "$work/guard.out")"
for ref in bot/promote-stg refs/heads/main "${older:0:12}"; do
  refused "promote_stg_ref: $ref" "stg_ref '$ref' must be main or a full commit (40 hex digits) of svp-gitops" \
    promote_stg_ref "$ref" "$work/clone"
done
bot_commit=$(remote rev-parse bot/promote-stg)
refused "promote_stg_ref: a full commit only of bot/promote-stg" \
  "stg_ref $bot_commit is not on main of svp-gitops: only a set that main of stg held goes to prd" \
  promote_stg_ref "$bot_commit" "$work/clone"
unknown=$(printf 'e%.0s' $(seq 40))
refused "promote_stg_ref: a full commit svp-gitops has not" "stg_ref $unknown is no commit of svp-gitops" \
  promote_stg_ref "$unknown" "$work/clone"

# --- promote_open_pr REPO BRANCH APP.
open_pr=(promote_open_pr anhnvcoder/svp-gitops bot/promote-stg svp-gitops-promoter)
cat >"$work/gh/prs.json" <<'EOF'
[{"number": 7, "isCrossRepository": true, "author": {"login": "app/svp-gitops-promoter"}},
 {"number": 8, "isCrossRepository": false, "author": {"login": "someone"}},
 {"number": 9, "isCrossRepository": false, "author": {"login": "app/svp-gitops-promoter"}}]
EOF
fresh
same "promote_open_pr: the app's own, not a fork's or a person's" 9 "$(guard "${open_pr[@]}" && cat "$work/guard.out")"
same "promote_open_pr: asks for up to 500 open pull requests of the branch into main" \
  "$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg --base main --state open --limit 500 \
    --json number,isCrossRepository,author)" "$(cat "$work/gh.log")"
echo '[{"number": 8, "isCrossRepository": false, "author": {"login": "someone"}}]' >"$work/gh/prs.json"
check "promote_open_pr: none of the app's" guard "${open_pr[@]}"
check "promote_open_pr: none of the app's, nothing printed" test ! -s "$work/guard.out"
jq -n '[range(500) | {number: ., isCrossRepository: true, author: {login: "someone"}}]' >"$work/gh/prs.json"
refused "promote_open_pr: a full list" \
  "500 or more open pull requests from a branch bot/promote-stg in anhnvcoder/svp-gitops: close the forks' before promoting" \
  "${open_pr[@]}"
rm "$work/gh/prs.json"
if guard "${open_pr[@]}"; then
  fail "promote_open_pr: gh fails: refused (passed: $(cat "$work/guard.out"))"
else
  check "promote_open_pr: gh fails: refused, saying why" has "$work/guard.out" \
    "FAIL  list the open pull requests of bot/promote-stg in anhnvcoder/svp-gitops"
fi
echo '[]' >"$work/gh/prs.json"

# --- rescan.sh list on the clone, as make gitops-clone leaves it.
# list NAME WANT_RC [--source NAME] [VALUES_REF]: rescan.sh list on a machine, stdout in list.out, stderr in list.err.
list() {
  local name=$1 want=$2 rc=0 src=()
  shift 2
  if [ "${1:-}" = --source ]; then
    src=("$1" "$2")
    shift 2
  fi
  fresh
  on "$tree/deploy/ci/rescan.sh" list ${src[@]+"${src[@]}"} "$work/clone" "$@" >"$work/list.out" 2>"$work/list.err" ||
    rc=$?
  same "rescan.sh list: $name (exit $want)" "$want" "$rc"
  [ "$rc" = "$want" ] || sed "s/^/      | /" "$work/list.err" >&2
}
tab=$'\t'
app_pr='[{"number": 9, "isCrossRepository": false, "author": {"login": "app/svp-gitops-promoter"}}]'
person_pr='[{"number": 9, "isCrossRepository": false, "author": {"login": "someone"}},
  {"number": 10, "isCrossRepository": true, "author": {"login": "app/svp-gitops-promoter"}}]'
list "main of svp-gitops" 0
same "rescan.sh list: fourteen image files of main" 14 "$(grep -c "main of svp-gitops, envs/" "$work/list.out")"
check "rescan.sh list: the gateway of stg on main" has "$work/list.out" \
  "gateway${tab}ghcr.io/anhnvcoder/svp-backend/gateway${tab}$digest_b${tab}main of svp-gitops, envs/stg/images/gateway.yaml"
check "rescan.sh list: a service not released, with an empty digest" has "$work/list.out" \
  "web${tab}ghcr.io/anhnvcoder/svp-backend/web${tab}${tab}main of svp-gitops, envs/prd/images/web.yaml"
same "rescan.sh list: the app's open pull request of svp-gitops is asked for" \
  "$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg --base main --state open --limit 500 \
    --json number,isCrossRepository,author)" "$(cat "$work/gh.log")"
check "rescan.sh list: no pull request open, bot/promote-stg not read" lacks "$work/list.out" "bot/promote-stg"
echo "$app_pr" >"$work/gh/prs.json"
list "the app's pull request open" 0
check "rescan.sh list: the release of bot/promote-stg" has "$work/list.out" \
  "user-service${tab}ghcr.io/anhnvcoder/svp-backend/user-service${tab}$digest_a${tab}bot/promote-stg of svp-gitops (pull request #9), envs/stg/images/user-service.yaml"
echo "$person_pr" >"$work/gh/prs.json"
list "only a person's and a fork's pull request" 0
check "rescan.sh list: theirs not read" lacks "$work/list.out" "bot/promote-stg"
# The host does not answer pr list (no prs.json): main's releases and values_ref's are still listed, then it fails.
rm "$work/gh/prs.json"
list "the pull requests not answered" 1 bot/promote-stg
same "rescan.sh list: not answered, the fourteen image files of main still listed" 14 \
  "$(grep -c "main of svp-gitops, envs/" "$work/list.out")"
check "rescan.sh list: not answered, values_ref still listed" has "$work/list.out" \
  "${tab}$digest_a${tab}bot/promote-stg of svp-gitops, envs/stg/images/user-service.yaml"
check "rescan.sh list: not answered, says so" has "$work/list.err" \
  "FAIL  ask the repository's host whether the promote pull request of anhnvcoder/svp-gitops is open"
echo '[]' >"$work/gh/prs.json"
list "values_ref a branch of svp-gitops" 0 bot/promote-stg
check "rescan.sh list: the releases of values_ref" has "$work/list.out" \
  "${tab}$digest_a${tab}bot/promote-stg of svp-gitops, envs/stg/images/user-service.yaml"
list "values_ref a commit of svp-gitops" 0 "$older"
check "rescan.sh list: the releases of that commit" has "$work/list.out" "$older of svp-gitops, envs/"
# A commit of this repository from before svp-gitops held the releases: its deploy/k8s/values/services/. Those were
# released before the rename, under the former prefix of this repository, which no source has: listed, so the run
# fails on them.
mkdir -p "$tree/deploy/k8s/values/services"
for svc in gateway user-service video-service engagement-service feed-service media-worker web; do
  printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/%s\n  tag: ""\n  digest: ""\n' "$svc" \
    >"$tree/deploy/k8s/values/services/$svc.yaml"
done
printf 'replicas: 1\nimage:\n  repository: ghcr.io/anhnvcoder/short-video-platform/web\n  tag: "%s"\n  digest: "%s"\n' \
  "${c0:0:12}" "$digest_c" >"$tree/deploy/k8s/values/services/web.yaml"
g add -A deploy/k8s/values && g commit -qm "the values before svp-gitops"
old=$(g rev-parse HEAD)
list "values_ref a commit of this repository from before svp-gitops" 0 "$old"
check "rescan.sh list: the web release of that commit is listed, under the prefix of no source" has "$work/list.out" \
  "web${tab}ghcr.io/anhnvcoder/short-video-platform/web${tab}$digest_c${tab}commit ${old:0:12} of the code repository, deploy/k8s/values/services/web.yaml"
list "values_ref a commit of this repository without values" 1 "$c3"
check "rescan.sh list: says it is neither" has "$work/list.err" \
  "values_ref $c3 is neither a commit of svp-gitops nor one of this repository with deploy/k8s/values/services/"
list "values_ref no ref at all" 1 no-such-branch
check "rescan.sh list: says it is no ref of svp-gitops" has "$work/list.err" "values_ref no-such-branch is no ref of svp-gitops"

# --- Release source web: web of stg on main is svp-frontend's release, and bot/promote-stg-web holds it too.
gs checkout -q main
image_file stg web ghcr.io/anhnvcoder/svp-frontend/web "aaaaaaaaaaaa" "$digest_d"
gs commit -qam "stg: web of svp-frontend" && gs push -q origin main
gs checkout -q -b web && gs commit -q --allow-empty -m "web branch" && gs push -q origin HEAD:refs/heads/bot/promote-stg-web
"$real_git" -C "$work/clone" fetch -q origin
list "backend, web of svp-frontend in stg" 0
check "rescan.sh list: backend leaves web of svp-frontend out" lacks "$work/list.out" "ghcr.io/anhnvcoder/svp-frontend/web"
check "rescan.sh list: backend says why" has "$work/list.err" \
  "skip  web in main of svp-gitops, envs/stg/images/web.yaml: ghcr.io/anhnvcoder/svp-frontend/web is a release of source web, which its own CI rescans"
same "rescan.sh list: backend lists its thirteen others" 13 "$(grep -c "main of svp-gitops, envs/" "$work/list.out")"
web_pr='[{"number": 11, "isCrossRepository": false, "author": {"login": "app/svp-web-promoter"}}]'
echo "$web_pr" >"$work/gh/prs.json"
list "web, its pull request open" 0 --source web
same "rescan.sh list --source web: web of stg from main and from its branch, nothing else" \
  "web${tab}ghcr.io/anhnvcoder/svp-frontend/web${tab}$digest_d${tab}main of svp-gitops, envs/stg/images/web.yaml
web${tab}ghcr.io/anhnvcoder/svp-frontend/web${tab}$digest_d${tab}bot/promote-stg-web of svp-gitops (pull request #11), envs/stg/images/web.yaml" \
  "$(cat "$work/list.out")"
same "rescan.sh list --source web: asks for the pull request of its own branch" \
  "$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg-web --base main --state open --limit 500 \
    --json number,isCrossRepository,author)" "$(cat "$work/gh.log")"
echo '[]' >"$work/gh/prs.json"

# --- After the rename, its retired sources dropped: no source oldweb, and the gateway of stg on main under the former
# prefix of this repository, which no source of the table has any more.
list "--source oldweb" 1 --source oldweb
check "rescan.sh list --source oldweb: no such source" has "$work/list.err" \
  "no release source named oldweb in deploy/helm/svp-policy/files/sources.json"
check "rescan.sh list --source oldweb: lists nothing" test ! -s "$work/list.out"
gs checkout -q main
image_file stg gateway ghcr.io/anhnvcoder/short-video-platform/gateway "${c0:0:12}" "$digest_a"
gs commit -qam "stg: the gateway under the former prefix" && gs push -q origin main
"$real_git" -C "$work/clone" fetch -q origin
list "backend, a release under the former prefix on main" 0
check "rescan.sh list: the release under the former prefix is listed" has "$work/list.out" \
  "gateway${tab}ghcr.io/anhnvcoder/short-video-platform/gateway${tab}$digest_a${tab}main of svp-gitops, envs/stg/images/gateway.yaml"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
