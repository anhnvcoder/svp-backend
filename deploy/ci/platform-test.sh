#!/usr/bin/env bash
# Tests for deploy/ci/platform.sh, the functions the CI scripts call for everything that depends on the CI platform,
# and for the scripts that call them. Everything runs in a temporary directory: the variables of a GitHub Actions job
# are made up, and a fake gh and a fake cosign first on PATH record their arguments and answer from fixtures, so no
# test reaches GitHub, a registry or Sigstore. Checked:
#   - github (a made-up job): outputs, the job summary, masks, warnings and run links land where GitHub reads them,
#     and pull requests are read through gh with the job's repository;
#   - local: everything on stdout, no mask, links "local", and no write through the platform's API (reads still are);
#   - another CI (GitLab CI, a CI=true one): a clear error, nothing written;
#   - pull requests of another repository (svp-gitops) and of an app's bot;
#   - the scripts give what they gave when they read GitHub's variables themselves: plan.sh, vuln-predicate.sh,
#     provenance-predicate.sh (the workflow, ref and commit of the run, and the services input of a dispatch),
#     scan-gate.sh and values-check.sh (the signing identity is read from the table of release sources of the
#     policy's chart);
#   - scan-gate.sh with a fake docker standing in for trivy and grype: the flags each pass gets (trivy convert of the
#     secrets with no --severity and no ignore file, of the vulnerabilities with --severity CRITICAL and the tree's
#     .trivyignore.yaml, each reading only its own findings; grype with --fail-on critical and the tree's .grype.yaml),
#     a secret blocks even with --allow-critical, a CRITICAL blocks unless --allow-critical, a scanner that fails or a
#     report that is not trivy's exits 2, one summary line per scan; --check-ignorefile holds .trivyignore.yaml to
#     vulnerabilities with a statement, purls with a version and at most 30 days, refuses an expired entry, and holds
#     .grype.yaml to ignore rules of vulnerability, include-aliases: true, package name and version, each exactly one
#     entry in force of .trivyignore.yaml (the purl's name as grype names the package, with its namespace unless it is
#     a distribution's, a %40 scope decoded), refusing any other key (only-notfixed, fix-state, package.type) and a
#     plain value YAML reads as a null, a bool, a number or a date; the image gates refuse a broken file but leave an
#     expired entry to trivy and job config;
#   - verify-release.sh with a fake cosign that answers from fixtures, on a tree laid out as svp-gitops: without
#     requireProvenance in the policy's values at the commit charts.yaml pins or in the overlays only the signature and
#     the vuln attestation are asked for; with it on (in the values at that commit, in the overlay of an environment,
#     at a commit of the tree with --rev, for one environment with --env, in the clone gitops_dir finds) the release
#     also needs exactly one provenance attestation whose builder.id, workflow repository and ref match the policy and
#     whose commit the certificate names, each fault with its own message; an overlay holding anything else, and a
#     charts.yaml naming no commit, are refused; a provenance cosign cannot read (registry out of reach, or a first
#     call that failed and a second that verified) asks to check again, never for a new release; the ok line it prints
#     is the one tag_provenance_mismatch of common.sh reads (image.tag against the provenance's commit); an image is
#     verified with the identity of the release source whose prefix it is under, in the table at the commit an
#     environment's charts.yaml pins (a commit from before the table stops the check, naming it), a service its
#     source does not publish is refused before cosign, and every environment must admit it without --env;
#   - the release sources in common.sh: sign_identity and provenance_source without a source name are backend's,
#     oci_labels names its source's repository and the commit of SVP_CODE_ROOT, and drill_images is drillImages of
#     source backend;
#   - values-check.sh --gitops on a pull request of that tree: one that turns provenance on in an overlay, or moves an
#     environment's charts.yaml, checks every release of that environment and none of the other; one of an image file
#     checks that file; one of another file checks none;
#   - plan.sh on a push to main that builds no image: promote_charts when a file under deploy/helm/ or one a symbolic
#     link there points to changed, not for docs/;
#   - gitops_supplychain of deploy/ci/verify/gitops.sh: case l gets the newest drill-no-provenance, and none (not
#     empty) with the step failing when GHCR does not give it;
#   - changed-services.sh builds all six images of this repository (never web, which svp-frontend builds) for a change of
#     platform.sh, as for common.sh and rescan.sh, and none for a change under web/ (a file added, then deleted) or of
#     this test, of promote-test.sh, of ghcr-digest.sh and its test, of a scenario file under deploy/ci/verify/, of the
#     scripts of other workflows and of svp-gitops's check (gitops-check.sh with
#     values-check.sh and verify-release.sh and the tests of these), of the policy's values or of docs/; all six for a
#     change of the GRYPE_IMAGE line of the Makefile, none for another line of it;
#   - rescan.sh run attests only the releases of the source of the run's repository, as that source's signing
#     workflow: a run of svp-frontend without --source web, a run of backend with --source web, and a run of svp-frontend from
#     another workflow fail, naming both sources (or the identity), before the host or cosign is asked anything; the
#     scheduled run of backend and the run of svp-frontend with --source web each read their own promote pull request and
#     ask cosign for their own releases only, leaving the other source's to it; on a machine the run is refused first;
#   - another repository's tree (SVP_CODE_ROOT, a checkout whose origin is svp-frontend): on a machine ci_repo, ci_repo_url
#     and ci_commit are that checkout's (and a checkout with no origin on github.com is refused, an origin's
#     credential never shown); plan.sh of svp-frontend's run builds the services of its release source at every run, with
#     no base, refuses a service or a drill its source does not have and a tree whose HEAD is not the run's commit, and
#     in this checkout refuses a run of svp-frontend that forgot SVP_CODE_ROOT, a run of a fork and a run of this
#     repository under its name before the rename (no source names it); in this checkout plan.sh
#     builds the six for services all and refuses services web, and build-image.sh refuses web before it builds
#     anything; scan-gate.sh reads that tree's .trivyignore.yaml and .grype.yaml and stops, naming the file, when the
#     tree has either not;
#   - web_clone of deploy/k8s/lib.sh without WEB_REF checks out the commit of the web release stg runs when it is a
#     release of web, and refuses one under another prefix before anything is cloned.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/platform-test.sh
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

# --- Fakes. gh writes each call to gh.log, one line of %q-quoted arguments, and answers pr list from gh/prs.json; with
# FAKE_GH_FAIL set it fails as the host would. cosign records its arguments and refuses every signature; with
# FAKE_COSIGN_DIR set it accepts every signature, prints FAKE_COSIGN_DIR/<type>.jsonl for verify-attestation --type
# <type> (refusing without that file), and with --certificate-github-workflow-sha accepts only the commit in
# FAKE_COSIGN_DIR/cert-sha.
mkdir -p "$work/bin" "$work/gh" "$work/runner-temp" "$work/home"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
if [ -n "${FAKE_GH_FAIL:-}" ]; then
  echo "HTTP 502: Bad Gateway" >&2
  exit 1
fi
case "$1 $2" in
"pr list") cat "$FAKE_GH_DIR/prs.json" ;;
esac
EOF
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
chmod 755 "$work/bin/gh" "$work/bin/cosign"
echo '[]' >"$work/gh/prs.json"

# on PLATFORM COMMAND...: runs COMMAND with the variables of PLATFORM and none of the others': github (a made-up job of
# repository octo/repo), local (none), gitlab (GitLab CI's own). git reads no configuration of this machine.
on() {
  local platform=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_REF -u GITHUB_SHA -u GITHUB_EVENT_NAME
    -u GITHUB_EVENT_PATH -u RUNNER_TEMP -u CI -u GITLAB_CI -u JENKINS_URL
    -u TF_BUILD -u GIT_DIR -u GIT_WORK_TREE -u PROMOTE_DRY_RUN -u PROMOTE_DRY_RUN_PRS -u RUNNER_ENVIRONMENT
    -u FAKE_GH_FAIL -u SVP_CODE_ROOT
    PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" FAKE_COSIGN_LOG="$work/cosign.log")
  case $platform in
  github)
    "${base[@]}" GITHUB_ACTIONS=true CI=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 \
      GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main GITHUB_REF=refs/heads/main \
      GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$work/event.json" \
      RUNNER_TEMP="$work/runner-temp" "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  gitlab) "${base[@]}" GITLAB_CI=true CI=true "$@" ;;
  esac
}
# fn PLATFORM SNIPPET: runs SNIPPET in bash after sourcing platform.sh, on PLATFORM.
fn() { on "$1" "$BASH" -c ". \"\$0\"; $2" "$here/platform.sh"; }
# fresh: empties the files the platform and the fakes write to.
fresh() { : >"$work/output" && : >"$work/summary" && : >"$work/gh.log" && : >"$work/cosign.log"; }
# gh_line ARGS...: a line of gh.log as the fake writes it for a call with ARGS.
gh_line() { printf '%q ' "$@"; }

# --- ci_platform.
same "github: GITHUB_ACTIONS=true is GitHub Actions" github "$(fn github ci_platform)"
same "local: no CI variable is a machine" local "$(fn local ci_platform)"
same "local: CI=false is no CI" local "$(on local env CI=false "$BASH" -c '. "$0"; ci_platform' "$here/platform.sh")"
for ci in GITLAB_CI=true CI=true CI=1 JENKINS_URL=https://jenkins.example TF_BUILD=True; do
  if out=$(on local env "$ci" "$BASH" -c '. "$0"; ci_platform' "$here/platform.sh" 2>&1); then
    fail "$ci: refused (got '$out')"
  else
    case $out in
    *"only GitHub Actions and local runs are implemented; add a branch in deploy/ci/platform.sh for another CI"*)
      ok "$ci: refused, naming what to do" ;;
    *) fail "$ci: refused, naming what to do (got '$out')" ;;
    esac
  fi
done

# --- github, with the variables of a made-up job.
fresh
got=$(fn github 'ci_output mode build && ci_output base "" && ci_output legs "{\"include\":[]}"')
same "github: outputs go to GITHUB_OUTPUT, not stdout" "" "$got"
same "github: GITHUB_OUTPUT holds KEY=VALUE lines" $'mode=build\nbase=\nlegs={"include":[]}' "$(cat "$work/output")"
fresh
if fn github "ci_output two \$'a\\nb'" 2>/dev/null; then fail "github: a value of two lines is refused"; else
  check "github: a value of two lines is refused, nothing written" test ! -s "$work/output"
fi
if fn github 'ci_output "bad name" x' 2>/dev/null; then fail "github: an output name with a blank is refused"; else
  ok "github: an output name with a blank is refused"
fi
out=$(on github env -u GITHUB_OUTPUT "$BASH" -c '. "$0"; ci_output a b' "$here/platform.sh" 2>&1) &&
  fail "github: no GITHUB_OUTPUT fails" || same "github: no GITHUB_OUTPUT fails, naming it" \
  "FAIL  GITHUB_OUTPUT is empty: the CI platform sets it for every job" "$out"
fresh
got=$(fn github 'ci_summary "line 1" "line 2"; printf "from stdin\n" | ci_summary; printf "both\n" | ci_summary_tee')
same "github: the summary goes to GITHUB_STEP_SUMMARY, tee to stdout as well" both "$got"
same "github: GITHUB_STEP_SUMMARY holds every line" $'line 1\nline 2\nfrom stdin\nboth' "$(cat "$work/summary")"
check "github: the summary is a page apart from the log" fn github ci_has_summary
same "github: a mask is ::add-mask:: with % written %25" '::add-mask::a%25b%25' "$(fn github 'ci_mask "a%b%"')"
same "github: a warning is an annotation" '::warning::look here' "$(fn github 'ci_warning "look here"')"
same "github: the temp directory is RUNNER_TEMP" "$work/runner-temp" "$(fn github ci_temp_dir)"
same "github: the repository" octo/repo "$(fn github ci_repo)"
same "github: the run id" 4242 "$(fn github ci_run_id)"
same "github: the run's page" https://github.example/octo/repo/actions/runs/4242 "$(fn github ci_run_url)"
same "github: the attempt's page" https://github.example/octo/repo/actions/runs/4242/attempts/3 \
  "$(fn github ci_run_attempt_url)"
same "github: attempt 1 when GITHUB_RUN_ATTEMPT is unset" \
  https://github.example/octo/repo/actions/runs/4242/attempts/1 \
  "$(on github env -u GITHUB_RUN_ATTEMPT "$BASH" -c '. "$0"; ci_run_attempt_url' "$here/platform.sh")"
same "github: the builder is the workflow file at its ref" \
  https://github.example/octo/repo/.github/workflows/images.yml@refs/heads/main "$(fn github ci_builder_id)"
same "github: the repository's page" https://github.example/octo/repo "$(fn github ci_repo_url)"
same "github: the ref and the commit of the run" "refs/heads/main 89abcdef0123456789abcdef0123456789abcdef" \
  "$(fn github 'echo "$(ci_ref) $(ci_commit)"')"
same "github: the workflow file and the ref it was read at" ".github/workflows/images.yml refs/heads/main" \
  "$(fn github 'echo "$(ci_workflow_path) $(ci_workflow_ref)"')"
same "github: a ref holding @ stays whole" "a.yml refs/heads/x@y" "$(on github env \
  GITHUB_WORKFLOW_REF=octo/repo/a.yml@refs/heads/x@y "$BASH" -c '. "$0"; echo "$(ci_workflow_path) $(ci_workflow_ref)"' \
  "$here/platform.sh")"
for bad in other/repo/.github/workflows/images.yml@refs/heads/main octo/repo/.github/workflows/images.yml \
  octo/repo/@refs/heads/main octo/repo/a.yml@; do
  if out=$(on github env GITHUB_WORKFLOW_REF="$bad" "$BASH" -c '. "$0"; ci_workflow_path || exit 1; ci_workflow_ref' \
    "$here/platform.sh" 2>&1); then
    fail "github: workflow ref $bad is refused (got '$out')"
  else
    same "github: workflow ref $bad is refused, naming it" \
      "FAIL  GITHUB_WORKFLOW_REF '$bad' is not <repository>/<path>@<ref> of octo/repo" "$out"
  fi
done
jq -n '{inputs: {services: "gateway web", rescan: false}}' >"$work/event.json"
same "github: no dispatch input on a push" "" "$(fn github 'ci_dispatch_input services')"
dispatch() { on github env GITHUB_EVENT_NAME=workflow_dispatch "$BASH" -c ". \"\$0\"; $1" "$here/platform.sh"; }
same "github: a dispatch input, read from the event" "gateway web" "$(dispatch 'ci_dispatch_input services')"
same "github: a dispatch input not given, or false, is empty" "|" \
  "$(dispatch 'echo "$(ci_dispatch_input values_ref)|$(ci_dispatch_input rescan)"')"
if dispatch 'ci_dispatch_input "a b"' 2>/dev/null; then fail "github: an input name with a blank is refused"; else
  ok "github: an input name with a blank is refused"
fi
echo 'not json' >"$work/event.json"
if dispatch 'ci_dispatch_input services' >/dev/null 2>&1; then fail "github: an unreadable event fails"; else
  ok "github: an unreadable event fails"
fi
out=$(on github env -u GITHUB_SHA "$BASH" -c '. "$0"; ci_commit' "$here/platform.sh" 2>&1) &&
  fail "github: no GITHUB_SHA fails" || same "github: no GITHUB_SHA fails, naming it" \
  "FAIL  GITHUB_SHA is empty: the CI platform sets it for every job" "$out"
# Pull requests through gh, with the job's repository.
fresh
jq -n '[{number: 3, isCrossRepository: true, author: {login: "app/github-actions"}},
  {number: 4, isCrossRepository: false, author: {login: "someone"}},
  {number: 5, isCrossRepository: false, author: {login: "app/github-actions"}}]' >"$work/gh/prs.json"
same "github: the bot's own pull request is picked, not a fork's or a person's" 5 \
  "$(fn github 'ci_change_request_list bot/promote main | ci_change_request_pick')"
same "github: the list asks gh for up to 500 open pull requests of the branch" "$(gh_line pr list --repo octo/repo \
  --head bot/promote --base main --state open --limit 500 --json number,isCrossRepository,author)" \
  "$(cat "$work/gh.log")"
jq -n '[range(500) | {number: ., isCrossRepository: true, author: {login: "x"}}]' >"$work/gh/prs.json"
if fn github 'ci_change_request_list bot/promote main' >/dev/null 2>&1; then
  fail "github: a full list of 500 fails rather than guess"
else ok "github: a full list of 500 fails rather than guess"; fi
echo '[]' >"$work/gh/prs.json"
same "github: no pull request, nothing picked" "" "$(fn github 'ci_change_request_list bot/promote main |
  ci_change_request_pick')"

# Pull requests of another repository, opened by an app.
fresh
jq -n '[{number: 5, isCrossRepository: false, author: {login: "app/github-actions"}},
  {number: 6, isCrossRepository: true, author: {login: "app/svp-gitops-promoter"}},
  {number: 7, isCrossRepository: false, author: {login: "app/svp-gitops-promoter"}}]' >"$work/gh/prs.json"
same "github: the app's own pull request of the other repository is picked" 7 \
  "$(fn github 'ci_change_request_list bot/promote-stg main anhnvcoder/svp-gitops | ci_change_request_pick svp-gitops-promoter')"
same "github: the list asks for the other repository" "$(gh_line pr list --repo anhnvcoder/svp-gitops \
  --head bot/promote-stg --base main --state open --limit 500 --json number,isCrossRepository,author)" \
  "$(cat "$work/gh.log")"
echo '[]' >"$work/gh/prs.json"

# --- local: stdout, nothing masked, no write through the API.
fresh
same "local: outputs on stdout" $'mode=build\nbase=' "$(fn local 'ci_output mode build; ci_output base ""')"
same "local: the summary on stdout" $'a\nb' "$(fn local 'ci_summary a; echo b | ci_summary')"
if fn local ci_has_summary; then fail "local: no summary page apart from the log"; else
  ok "local: no summary page apart from the log"
fi
same "local: tee prints once" x "$(fn local 'echo x | ci_summary_tee')"
same "local: a mask prints nothing (it would print the value)" "" "$(fn local 'ci_mask "s3cret-value"')"
same "local: a warning is a plain line" 'warning: look here' "$(fn local 'ci_warning "look here"')"
same "local: the temp directory is /tmp" /tmp "$(fn local ci_temp_dir)"
same "local: this repository" anhnvcoder/svp-backend "$(fn local ci_repo)"
same "local: links are local" "local local local local" \
  "$(fn local 'echo "$(ci_run_id) $(ci_run_url) $(ci_run_attempt_url) $(ci_builder_id)"')"
same "local: the repository's page on GitHub" https://github.com/anhnvcoder/svp-backend \
  "$(fn local ci_repo_url)"
same "local: the ref, the workflow file and its ref are local, no dispatch input" "local local local " \
  "$(fn local 'echo "$(ci_ref) $(ci_workflow_path) $(ci_workflow_ref) $(ci_dispatch_input services)"')"
same "local: the commit is HEAD of the checkout platform.sh is in" "$(git -C "$here" rev-parse --verify HEAD)" \
  "$(fn local ci_commit)"
check "local: no file of a job was written" test ! -s "$work/output" -a ! -s "$work/summary"

# A checkout of svp-frontend, another release source's repository, whose CI runs these scripts from a pinned checkout of
# this one: SVP_CODE_ROOT names it, and on a machine the repository and commit of the run are its own.
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
same "local, SVP_CODE_ROOT: the repository, its page and the commit are the checkout's" \
  "anhnvcoder/svp-frontend https://github.com/anhnvcoder/svp-frontend $web_head" \
  "$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; echo "$(ci_repo) $(ci_repo_url) $(ci_commit)"' \
    "$here/platform.sh")"
gw remote set-url origin git@github.com:anhnvcoder/svp-frontend.git
same "local, SVP_CODE_ROOT: an ssh origin names the same repository" anhnvcoder/svp-frontend \
  "$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; ci_repo' "$here/platform.sh")"
gw remote set-url origin https://gitlab.example/anhnvcoder/svp-frontend.git
if out=$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; ci_repo_url' "$here/platform.sh" 2>&1); then
  fail "local, SVP_CODE_ROOT: an origin off github.com is refused (got '$out')"
else
  same "local, SVP_CODE_ROOT: an origin off github.com is refused, naming it" \
    "FAIL  SVP_CODE_ROOT=$webtree has no remote origin on github.com (got 'https://gitlab.example/anhnvcoder/svp-frontend.git'): its repository cannot be named" \
    "$out"
fi
gw remote set-url origin https://x-access-token:ghs_faketoken0123456789@github.com/anhnvcoder/svp-frontend.git
if out=$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; ci_repo' "$here/platform.sh" 2>&1); then
  fail "local, SVP_CODE_ROOT: an origin carrying a credential is refused (got '$out')"
else
  same "local, SVP_CODE_ROOT: an origin carrying a credential is refused, the credential not shown" \
    "FAIL  SVP_CODE_ROOT=$webtree has no remote origin on github.com (got 'https://github.com/anhnvcoder/svp-frontend.git'): its repository cannot be named" \
    "$out"
fi
gw remote set-url origin https://github.com/anhnvcoder/svp-frontend.git
same "local: the dispatch hint names the code repository" \
  "gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f rescan=true -f values_ref=abc" \
  "$(fn local 'ci_dispatch_hint images.yml main rescan=true values_ref=abc')"
same "github: the dispatch hint names the code repository, not the job's" \
  "gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main" \
  "$(fn github 'ci_dispatch_hint images.yml main')"

# --- another CI: a clear error, nothing written.
fresh
if out=$(fn gitlab 'ci_output mode build; ci_summary x; ci_mask y' 2>&1); then
  fail "gitlab: every function fails"
else
  case $out in *"this runs on GitLab CI"*) ok "gitlab: every function fails, naming GitLab CI" ;;
  *) fail "gitlab: every function fails, naming GitLab CI (got '$out')" ;; esac
fi
if grep -qv '^FAIL  ' <<<"$out"; then fail "gitlab: nothing printed but the errors"; else
  ok "gitlab: nothing printed but the errors"
fi

# --- A throwaway checkout, with its own origin, of what the scripts below read: deploy/ci/, deploy/k8s/lib.sh, the
# policy's values, a chart file and a symbolic link of a chart to a file beside the charts. GIT_DIR is set for every git
# call of the test itself, so git can never reach another repository.
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
digest_a=sha256:$(printf 'a%.0s' $(seq 64))
digest_b=sha256:$(printf 'b%.0s' $(seq 64))

# plan.sh: a drill run on main hands its seven outputs on, in this order, and writes its summary.
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
same "plan.sh on github: nothing on stdout" "" "$got"
same "plan.sh on github: the seven outputs in GITHUB_OUTPUT" "$want_plan" "$(cat "$work/output")"
same "plan.sh on github: the summary" "Mode: drill. Images: drill-vulnerable drill-unsigned drill-no-provenance." "$(cat "$work/summary")"
got=$(on local env EVENT_NAME=workflow_dispatch GIT_REF=refs/heads/main INPUT_DRILL=true "$tree/deploy/ci/plan.sh")
same "plan.sh on a machine: summary then outputs on stdout" \
  "Mode: drill. Images: drill-vulnerable drill-unsigned drill-no-provenance."$'\n'"$want_plan" "$got"

# plan.sh of svp-frontend's run (SVP_CODE_ROOT its checkout, HEAD the run's commit): the services of its release source at
# every run, no base, nothing to promote of the charts.
# web_plan NAME WANT_RC VAR=VALUE...: plan.sh in a made-up run of svp-frontend on github, its outputs in output.
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

# --- rescan.sh run: a run attests only the releases of the source of its own repository, as the identity of that
# source's signing workflow. A clone of svp-gitops on disk whose main names a gateway of backend and a web of svp-frontend;
# gh lists no open promote pull request; the fake cosign refuses every signature, so nothing is ever attested.
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

# vuln-predicate.sh: who made the attestation, from the job's variables; local for each on a machine.
for arch in amd64 arm64; do
  d=$work/leg-$arch
  mkdir -p "$d"
  echo "linux/$arch" >"$d/platform"
  echo "$digest_a" >"$d/digest"
  echo "$digest_b" >"$d/config-digest"
  jq -n --arg c "$digest_b" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Trivy: {Version: "0.76.0"}, Results: []}' \
    >"$d/trivy.json"
  for f in scan-started scan-finished db-updated-at; do echo 2026-10-25T01:02:03Z >"$d/$f"; done
done
on github "$tree/deploy/ci/vuln-predicate.sh" "$work/predicate.json" "$work/leg-amd64" "$work/leg-arm64" >/dev/null
same "vuln-predicate.sh on github: invocation names this attempt, the run and the workflow" \
  '{"uri":"https://github.example/octo/repo/actions/runs/4242/attempts/3","event_id":"4242","builder.id":"https://github.example/octo/repo/.github/workflows/images.yml@refs/heads/main","parameters":null}' \
  "$(jq -c .invocation "$work/predicate.json")"
on local "$tree/deploy/ci/vuln-predicate.sh" "$work/predicate.json" "$work/leg-amd64" "$work/leg-arm64" >/dev/null
same "vuln-predicate.sh on a machine: local for each" \
  '{"uri":"local","event_id":"local","builder.id":"local","parameters":null}' "$(jq -c .invocation "$work/predicate.json")"

# provenance-predicate.sh: the run that built, from the job's variables and the dispatch event (its own test covers
# the rest).
jq -n '{inputs: {services: "all"}}' >"$work/event.json"
on github env GITHUB_EVENT_NAME=workflow_dispatch "$tree/deploy/ci/provenance-predicate.sh" "$work/provenance.json" \
  >/dev/null
same "provenance-predicate.sh on github: workflow, input, commit, builder and attempt of this run" \
  '{"buildDefinition":{"buildType":"https://actions.github.io/buildtypes/workflow/v1","externalParameters":{"workflow":{"ref":"refs/heads/main","repository":"https://github.example/octo/repo","path":".github/workflows/images.yml"},"inputs":{"services":"all"}},"resolvedDependencies":[{"uri":"git+https://github.example/octo/repo@refs/heads/main","digest":{"gitCommit":"89abcdef0123456789abcdef0123456789abcdef"}}]},"runDetails":{"builder":{"id":"https://github.example/octo/repo/.github/workflows/images.yml@refs/heads/main"},"metadata":{"invocationId":"https://github.example/octo/repo/actions/runs/4242/attempts/3"}}}' \
  "$(jq -c . "$work/provenance.json")"

# scan-gate.sh. The verdicts are trivy's and grype's: here a fake docker stands in for both, records each call in
# docker.log (one line of arguments) and answers with the exit code the case sets: FAKE_TRIVY_VULNS for trivy convert
# with --severity (the vulnerability pass), FAKE_TRIVY_SECRETS for the one without (the secret pass), FAKE_GRYPE for
# grype, which also gets FAKE_GRYPE_JSON as its report. Each convert input is kept in fake/ to check what each pass
# reads. What the scanners do with these flags (an entry covering exactly its package version, a HIGH secret found
# without --severity, include-aliases) was run with the pinned images, not here.
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
in= out= file= convert= severity=
for a in "$@"; do
  case $a in
  *:/in:ro) in=${a%:/in:ro} ;;
  *:/out) out=${a%:/out} ;;
  /in/*) file=${a#/in/} ;;
  convert) convert=1 ;;
  --severity) severity=1 ;;
  esac
done
if [ -n "$convert" ]; then
  cp "$in/$file" "$FAKE_DOCKER_DIR/$file"
  if [ -n "$severity" ]; then exit "${FAKE_TRIVY_VULNS:-0}"; else exit "${FAKE_TRIVY_SECRETS:-0}"; fi
fi
case " $* " in
*" sbom:/out/sbom.spdx.json "*)
  [ "${FAKE_GRYPE:-0}" = 1 ] || { cp "$FAKE_GRYPE_JSON" "$out/grype.json" && echo '{}' >"$out/grype.sarif.raw"; }
  exit "${FAKE_GRYPE:-0}"
  ;;
esac
echo "fake docker: unexpected call: $*" >&2
exit 99
EOF
chmod 755 "$work/bin/docker"
mkdir -p "$work/fake"
# gate PLATFORM NAME WANT_EXIT [VAR=VALUE...] -- ARGS...: scan-gate.sh ARGS on PLATFORM with the fake scanners; ok
# when it exits WANT_EXIT. Output in gate.out and gate.err, the fake's calls in docker.log.
gate() {
  local platform=$1 name=$2 want=$3 vars=() rc=0
  shift 3
  while [ "$1" != -- ]; do vars+=("$1") && shift; done
  shift
  fresh
  : >"$work/docker.log"
  rm -f "$work/fake/"*
  on "$platform" env TRIVY_IMAGE=trivy@sha256:1 GRYPE_IMAGE=grype@sha256:1 SVP_TRIVY_CACHE="$work/cache/trivy" \
    SVP_GRYPE_CACHE="$work/cache/grype" FAKE_DOCKER_LOG="$work/docker.log" FAKE_DOCKER_DIR="$work/fake" \
    ${vars[@]+"${vars[@]}"} "$tree/deploy/ci/scan-gate.sh" "$@" >"$work/gate.out" 2>"$work/gate.err" || rc=$?
  same "$name (exit code)" "$want" "$rc"
}
soon=$(date -u -d '+10 days' +%F 2>/dev/null || date -u -v+10d +%F)
late=$(date -u -d '+40 days' +%F 2>/dev/null || date -u -v+40d +%F)
today=$(date -u +%F)
# ignore_entry ID EXPIRED_AT PURL: one entry of .trivyignore.yaml.
ignore_entry() {
  printf '  - id: %s\n    statement: Accepted for the test.\n    expired_at: %s\n    purls:\n      - %s\n' "$1" "$2" "$3"
}
# grype_rule ID NAME VERSION: one rule of .grype.yaml.
grype_rule() {
  printf '  - vulnerability: %s\n    include-aliases: true\n    package:\n      name: %s\n      version: %s\n' "$1" "$2" "$3"
}
# ignore_files: a .trivyignore.yaml with one entry for left-pad@1.0.0 and the matching .grype.yaml, the shape both
# cases below start from.
ignore_files() {
  { echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$soon" pkg:npm/left-pad@1.0.0; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2026-1111 left-pad 1.0.0; } >"$tree/.grype.yaml"
}

# The trivy gate on a report with one HIGH vulnerability and one secret.
jq -n --arg c "$digest_b" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Results: [{Target: "app",
  Vulnerabilities: [{Severity: "HIGH"}], Secrets: [{RuleID: "aws-key", Severity: "HIGH", StartLine: 3}]}]}' \
  >"$work/report.json"
ignore_files
gate github "scan-gate.sh: trivy finds a secret, it blocks" 1 FAKE_TRIVY_SECRETS=5 -- "gw linux/amd64" "$work/report.json"
same "scan-gate.sh on github: one line in the summary, the secret under it" '- gw linux/amd64 (trivy): CRITICAL 0, HIGH 1, secrets 1
secret  aws-key (HIGH) in app line 3' "$(cat "$work/summary")"
same "scan-gate.sh on github: the counts in the log" "gw linux/amd64 (trivy): CRITICAL 0, HIGH 1, secrets 1" \
  "$(cat "$work/gate.out")"
check "scan-gate.sh on github: the secret in the log too, rule, file and line" has "$work/gate.err" \
  "secret  aws-key (HIGH) in app line 3"
same "scan-gate.sh: the secret pass, then the vulnerability pass" \
  "convert --exit-code 5 --format json --output /dev/null --ignorefile  /in/secrets.json --cache-dir /cache
convert --exit-code 5 --format table --table-mode detailed --severity CRITICAL --ignorefile /ignore.yaml /in/vulnerabilities.json --cache-dir /cache" \
  "$(sed 's/^.* trivy@sha256:1 //' "$work/docker.log")"
check "scan-gate.sh: the ignore file trivy reads is the tree's" grep -qF -- "-v $tree/.trivyignore.yaml:/ignore.yaml:ro" \
  "$work/docker.log"
same "scan-gate.sh: the secret pass reads only the secrets" '[{"Target":"app","Secrets":[{"RuleID":"aws-key","Severity":"HIGH","StartLine":3}]}]' \
  "$(jq -c .Results "$work/fake/secrets.json")"
same "scan-gate.sh: the vulnerability pass reads only the vulnerabilities" \
  '[{"Target":"app","Vulnerabilities":[{"Severity":"HIGH"}]}]' "$(jq -c .Results "$work/fake/vulnerabilities.json")"
gate local "scan-gate.sh: --allow-critical never lets a secret through" 1 FAKE_TRIVY_SECRETS=5 -- --allow-critical \
  "gw linux/amd64" "$work/report.json"
same "scan-gate.sh on a machine: the summary line in the log, no counts line" \
  "- gw linux/amd64 (trivy): CRITICAL 0, HIGH 1, secrets 1" "$(cat "$work/gate.out")"
check "scan-gate.sh on a machine: the secret in the log" has "$work/gate.err" "secret  aws-key (HIGH) in app line 3"
gate local "scan-gate.sh: trivy finds a CRITICAL, it blocks" 1 FAKE_TRIVY_VULNS=5 -- "gw linux/amd64" "$work/report.json"
check "scan-gate.sh: a CRITICAL says nothing ships" has "$work/gate.err" \
  "FAIL  gw linux/amd64 (trivy): CRITICAL vulnerabilities; nothing is pushed, signed or attested"
gate local "scan-gate.sh: --allow-critical lets a CRITICAL through" 0 FAKE_TRIVY_VULNS=5 -- --allow-critical \
  "gw linux/amd64" "$work/report.json"
check "scan-gate.sh: --allow-critical says so" has "$work/gate.err" \
  "note  gw linux/amd64 (trivy): CRITICAL vulnerabilities let through (--allow-critical)"
gate local "scan-gate.sh: nothing found passes" 0 -- "gw linux/amd64" "$work/report.json"
check "scan-gate.sh: the pass is said" has "$work/gate.out" "ok    gw linux/amd64 (trivy) passes the scan gate"
check "scan-gate.sh: the report itself is not printed" lacks "$work/gate.out" '"Results"'
gate local "scan-gate.sh: trivy failing is no pass, even with --allow-critical" 2 FAKE_TRIVY_VULNS=1 -- --allow-critical \
  "gw linux/amd64" "$work/report.json"
check "scan-gate.sh: trivy failing is said" has "$work/gate.err" "FAIL  gw linux/amd64: trivy could not read"
gate local "scan-gate.sh: a report that is not trivy's image report is refused" 2 -- "gw linux/amd64" "$work/event.json"
check "scan-gate.sh: says it is not a trivy image report" has "$work/gate.err" "is not a trivy image JSON report"
check "scan-gate.sh: trivy is not asked about it" test ! -s "$work/docker.log"
rm -f "$tree/.trivyignore.yaml" "$tree/.grype.yaml"
gate local "scan-gate.sh: this tree without ignore files passes" 0 -- "gw linux/amd64" "$work/report.json"
check "scan-gate.sh: without .trivyignore.yaml trivy reads no ignore file" grep -qF -- \
  "--severity CRITICAL --ignorefile  /in/vulnerabilities.json" "$work/docker.log"

# The grype gate: grype runs on DIR/sbom.spdx.json with .grype.yaml and --fail-on critical (exit 2 when it finds one).
# match ID SEVERITY PURL: one match of a grype report.
match() {
  jq -n --arg id "$1" --arg sev "$2" --arg purl "$3" '{
    vulnerability: {id: $id, severity: $sev, fix: {versions: ["9.9.9"], state: "fixed"}},
    artifact: {name: ($purl | sub("^pkg:[^/]+/(.*/)?"; "") | sub("@.*$"; "")),
      version: ($purl | sub("^[^@]*@"; "") | sub("[?#].*$"; "")), purl: $purl}}'
}
# grype_report FILE IGNORED MATCH...: a grype JSON report holding the matches and IGNORED ignored matches.
grype_report() {
  local file=$1 ignored=$2
  shift 2
  jq -s --argjson n "$ignored" '{descriptor: {name: "grype", version: "0.121.0"}, matches: .,
    ignoredMatches: [range($n) | {}]}' <<<"$*" >"$file"
}
mkdir -p "$work/leg"
echo '{"spdxVersion": "SPDX-2.3"}' >"$work/leg/sbom.spdx.json"
critical_npm=$(match CVE-2026-1111 Critical pkg:npm/left-pad@1.0.0)
high_npm=$(match CVE-2026-2222 High pkg:npm/zod@3.25.76)
grype_report "$work/grype.json" 1 "$critical_npm" "$high_npm"
ignore_files
grype_gate() { gate "$1" "$2" "$3" FAKE_GRYPE_JSON="$work/grype.json" "${@:4}"; }
grype_gate github "scan-gate.sh --grype: grype finds a Critical, it blocks" 1 FAKE_GRYPE=2 -- --grype "web linux/arm64" \
  "$work/leg"
check "scan-gate.sh --grype: grype runs with --fail-on critical and the tree's .grype.yaml" grep -qF -- \
  "-v $tree/.grype.yaml:/ignore/grype.yaml:ro grype@sha256:1 sbom:/out/sbom.spdx.json -c /ignore/grype.yaml --fail-on critical -o json=/out/grype.json -o sarif=/out/grype.sarif.raw -q" \
  "$work/docker.log"
same "scan-gate.sh --grype on github: one line in the summary, the Critical under it" '- web linux/arm64 (grype): Critical 1, High 1, excepted by .grype.yaml 1
critical  CVE-2026-1111 left-pad@1.0.0 pkg:npm/left-pad@1.0.0 (fixed: 9.9.9)' "$(cat "$work/summary")"
check "scan-gate.sh --grype: the report itself is not printed" lacks "$work/gate.out" '"matches"'
grype_gate local "scan-gate.sh --grype: --allow-critical lets a Critical through" 0 -- --allow-critical --grype \
  "web linux/arm64" "$work/leg"
check "scan-gate.sh --grype: --allow-critical runs grype without --fail-on" lacks "$work/docker.log" "--fail-on"
check "scan-gate.sh --grype: --allow-critical says so" has "$work/gate.err" \
  "note  web linux/arm64 (grype): 1 Critical vulnerabilities let through (--allow-critical)"
grype_report "$work/grype.json" 0 "$high_npm"
grype_gate local "scan-gate.sh --grype: High and below only counted" 0 -- --grype "web linux/arm64" "$work/leg"
check "scan-gate.sh --grype: the counts" has "$work/gate.out" \
  "- web linux/arm64 (grype): Critical 0, High 1, excepted by .grype.yaml 0"
grype_gate local "scan-gate.sh --grype: grype failing (a DB it cannot fetch) is no pass" 2 FAKE_GRYPE=1 -- --grype \
  "web linux/arm64" "$work/leg"
check "scan-gate.sh --grype: grype failing is said" has "$work/gate.err" "FAIL  web linux/arm64: grype could not scan"

# The rules of the ignore files: --check-ignorefile (job config), and the image gates, which refuse a broken file but
# leave an expired entry to trivy (it drops the entry) and to job config.
# ignorefiles NAME WANT_EXIT [WANT_LINE]: --check-ignorefile on the tree's files; ok when it exits WANT_EXIT and, when
# given, prints WANT_LINE. The copy's trivy-config-ignore.yaml names files the copy does not have, so it is set aside
# meanwhile (its rules are checked on this repository by job config).
ignorefiles() {
  gate local "scan-gate.sh --check-ignorefile: $1" "$2" -- --check-ignorefile
  [ -z "${3:-}" ] || check "scan-gate.sh --check-ignorefile: $1, says why" has "$work/gate.out" "$3"
}
mv "$tree/deploy/ci/trivy-config-ignore.yaml" "$work/trivy-config-ignore.yaml"
ignore_files
ignorefiles "an entry and its grype rule" 0
check "scan-gate.sh --check-ignorefile: no scanner runs" test ! -s "$work/docker.log"
printf 'vulnerabilities: []\n' >"$tree/.trivyignore.yaml"
printf 'ignore: []\n' >"$tree/.grype.yaml"
ignorefiles "nothing to except" 0
{
  echo "vulnerabilities:"
  ignore_entry CVE-2026-3333 "$soon" pkg:npm/%40scope/pkg@1.0.0
} >"$tree/.trivyignore.yaml"
{ echo "ignore:" && grype_rule CVE-2026-3333 '"@scope/pkg"' 1.0.0; } >"$tree/.grype.yaml"
ignorefiles "a scoped npm package, quoted in .grype.yaml, %40 in the purl" 0

ignore_files
{ echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$late" pkg:npm/left-pad@1.0.0; } >"$tree/.trivyignore.yaml"
ignorefiles "an entry for more than 30 days" 1 "entry CVE-2026-1111 expires $late, more than 30 days from today"
{ echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$soon" pkg:npm/left-pad; } >"$tree/.trivyignore.yaml"
ignorefiles "a purl without its version" 1 "purl pkg:npm/left-pad is not pkg:<type>/<name>@<version>"
printf 'vulnerabilities:\n  - id: CVE-2026-1111\n    statement: Accepted.\n    expired_at: %s\n' "$soon" \
  >"$tree/.trivyignore.yaml"
ignorefiles "an entry without purls" 1 "entry CVE-2026-1111 has no purls"
{
  echo "vulnerabilities:"
  ignore_entry CVE-2026-1111 "$soon" pkg:npm/left-pad@1.0.0
  printf 'secrets:\n  - id: aws-access-key-id\n'
} >"$tree/.trivyignore.yaml"
ignorefiles "a secrets section" 1 "only vulnerabilities may be ignored, never secrets or anything else: secrets:"
gate local "scan-gate.sh: the image gate refuses a secrets section of .trivyignore.yaml" 1 -- "gw linux/amd64" \
  "$work/report.json"
check "scan-gate.sh: the image gate says the ignore file breaks its rules" has "$work/gate.err" \
  "FAIL  an ignore file breaks its rules: fix it before anything is pushed"

ignore_files
{ echo "only-notfixed: true" && echo "ignore:" && grype_rule CVE-2026-1111 left-pad 1.0.0; } >"$tree/.grype.yaml"
ignorefiles "a root key of .grype.yaml other than ignore (only-notfixed)" 1 \
  ".grype.yaml:1: only the key ignore may be set"
grype_report "$work/grype.json" 0
grype_gate local "scan-gate.sh --grype: the image gate refuses only-notfixed in .grype.yaml" 1 -- --grype \
  "web linux/arm64" "$work/leg"
printf 'ignore:\n  - vulnerability: CVE-2026-1111\n    package:\n      name: left-pad\n      version: 1.0.0\n' \
  >"$tree/.grype.yaml"
ignorefiles "a rule without include-aliases" 1 "rule CVE-2026-1111 needs include-aliases: true once"
printf 'ignore:\n  - vulnerability: CVE-2026-1111\n    include-aliases: true\n    fix-state: fixed\n' >"$tree/.grype.yaml"
ignorefiles "a rule with fix-state and no package" 1 \
  "unexpected line (a rule has only vulnerability, include-aliases, package.name, package.version):     fix-state: fixed"
check "scan-gate.sh --check-ignorefile: a rule with no package, says why" has "$work/gate.out" \
  "rule CVE-2026-1111 needs one package with a plain name and version"
{ echo "ignore:" && grype_rule CVE-2026-1111 left-pad 1.0.0 && echo "      type: npm"; } >"$tree/.grype.yaml"
ignorefiles "a rule with package.type" 1 "unexpected line"
{ echo "ignore:" && grype_rule CVE-2026-1111 left-pad 1.0.1; } >"$tree/.grype.yaml"
ignorefiles "a rule for another version than the entry's" 1 \
  "rule CVE-2026-1111 left-pad@1.0.1 is 0 entries of .trivyignore.yaml in force, not exactly one"
{ echo "ignore:" && grype_rule CVE-2026-9999 left-pad 1.0.0; } >"$tree/.grype.yaml"
ignorefiles "a rule whose id no entry has" 1 "rule CVE-2026-9999 left-pad@1.0.0 is 0 entries"
# grype reads package.name as a regex anchored at both ends: a name must be the purl's name with each metacharacter
# escaped by a backslash. Written any other way it is refused even when an entry with that very name exists (.* would
# cover every package at the version, mini.* and minimis[t] cover minimist), and is not matched against the entries.
for name in '.*' '"mini.*"' 'minimis.' 'minimis[t]' 'libstdc++' 'socket.io-parser' 'mini\st'; do
  plain=${name//\"/}
  { echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" "pkg:npm/$plain@1.2.5"; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2021-44906 "$name" 1.2.5; } >"$tree/.grype.yaml"
  ignorefiles "a rule whose package.name is $name" 1 "package.name $plain is not a purl name with each of"
  check "scan-gate.sh --check-ignorefile: the rule for $name is not matched against the entries" lacks "$work/gate.out" \
    "entries of .trivyignore.yaml"
done
check "scan-gate.sh --check-ignorefile: the refusal gives the name to write" has "$work/gate.out" 'write minist'
# The purl's name escaped, plain or in single quotes, matches its entry; in double quotes YAML would read the escapes.
for case in 'socket\.io-parser pkg:npm/socket.io-parser' "'libstdc\+\+' pkg:apk/alpine/libstdc++" \
  'golang\.org/x/net pkg:golang/golang.org/x/net'; do
  name=${case% *} purl=${case#* }
  { echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" "$purl@1.2.5"; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2021-44906 "$name" 1.2.5; } >"$tree/.grype.yaml"
  ignorefiles "a rule whose package.name is $name, the escaped name of $purl" 0
done
{ echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" pkg:npm/socket.io-parser@1.2.5; } >"$tree/.trivyignore.yaml"
{ echo "ignore:" && grype_rule CVE-2021-44906 'socket\.io-parsers' 1.2.5; } >"$tree/.grype.yaml"
ignorefiles "an escaped name that is not the entry's" 1 "rule CVE-2021-44906 socket.io-parsers@1.2.5 is 0 entries"
{ echo "ignore:" && grype_rule CVE-2021-44906 '"socket\.io-parser"' 1.2.5; } >"$tree/.grype.yaml"
ignorefiles "an escaped name in double quotes" 1 "where YAML reads \\ as an escape"
# The name of a purl is the one grype gives its package: with its namespace (an npm scope, a Go module path), except
# for a distribution's package (apk, deb, rpm), whose namespace is the distribution. A rule for foo would cover the
# unscoped foo too, one for net any package named net.
for case in 'foo pkg:npm/%40scope/foo' 'net pkg:golang/golang.org/x/net' 'alpine/glib pkg:apk/alpine/glib'; do
  name=${case% *} purl=${case#* }
  { echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$soon" "$purl@1.0.0"; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2026-1111 "$name" 1.0.0; } >"$tree/.grype.yaml"
  ignorefiles "a rule for $name, an entry for $purl" 1 "rule CVE-2026-1111 $name@1.0.0 is 0 entries"
done
for case in 'glib 2.88.1-r1 pkg:apk/alpine/glib@2.88.1-r1?arch=aarch64&distro=3.24.0' \
  'libc6 2.36-9+deb12u4 pkg:deb/debian/libc6@2.36-9%2Bdeb12u4?arch=amd64&distro=debian-12'; do
  read -r name version purl <<<"$case"
  { echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$soon" "$purl"; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2026-1111 "$name" "$version"; } >"$tree/.grype.yaml"
  ignorefiles "a rule for $name $version, an entry for $purl (a distribution's package, qualifiers, %2B)" 0
done
# A plain value YAML reads as a null, a bool, a number or a date is not the text it shows: grype drops a null or a date
# from the rule (null as the version covers every version of the package, as the name every package) and reads 1.10
# as 1.1. Refused in vulnerability, name and version even with an entry of that very text; in quotes it is text.
for value in null NULL true False 1.10 017 0x1F 0o17 0b101 1e5 1_000 2026-1-2 2001-12-14T21:59:43Z; do
  { echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" "pkg:npm/minimist@$value"; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2021-44906 minimist "$value"; } >"$tree/.grype.yaml"
  ignorefiles "a rule whose package.version is $value, plain" 1 \
    "package.version $value is a null, a bool, a number or a date to YAML, not text"
  check "scan-gate.sh --check-ignorefile: the rule for version $value is not matched against the entries" lacks \
    "$work/gate.out" "entries of .trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2021-44906 minimist "'$value'"; } >"$tree/.grype.yaml"
  ignorefiles "a rule whose package.version is '$value', in quotes" 0
done
for value in null true 017; do
  { echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" "pkg:npm/$value@1.2.5"; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule CVE-2021-44906 "$value" 1.2.5; } >"$tree/.grype.yaml"
  ignorefiles "a rule whose package.name is $value, plain" 1 \
    "package.name $value is a null, a bool, a number or a date to YAML, not text"
  { echo "ignore:" && grype_rule CVE-2021-44906 "'$value'" 1.2.5; } >"$tree/.grype.yaml"
  ignorefiles "a rule whose package.name is '$value', in quotes" 0
done
for value in null False; do
  { echo "vulnerabilities:" && ignore_entry "$value" "$soon" pkg:npm/lodash@4.17.15; } >"$tree/.trivyignore.yaml"
  { echo "ignore:" && grype_rule "$value" lodash 4.17.15; } >"$tree/.grype.yaml"
  ignorefiles "a rule whose vulnerability is $value, plain" 1 \
    "vulnerability $value is a null, a bool, a number or a date to YAML, not text"
done
# yes and 1:20 are text to the YAML grype reads (1.2: no yes/no bools, no base 60).
{ echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" pkg:deb/debian/yes@1:20; } >"$tree/.trivyignore.yaml"
{ echo "ignore:" && grype_rule CVE-2021-44906 yes 1:20; } >"$tree/.grype.yaml"
ignorefiles "a rule whose name is yes and version 1:20, plain" 0
{ echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" pkg:npm/mini.st@1.2.5; } >"$tree/.trivyignore.yaml"
{ echo "ignore:" && grype_rule CVE-2021-44906 mini.st 1.2.5; } >"$tree/.grype.yaml"
grype_gate local "scan-gate.sh --grype: the image gate refuses a package.name with a regex metacharacter" 1 -- --grype \
  "web linux/arm64" "$work/leg"
check "scan-gate.sh --grype: the image gate says the regex name breaks the rules" has "$work/gate.err" \
  "FAIL  an ignore file breaks its rules: fix it before anything is pushed"

# An expired entry: job config fails, on the entry and on the grype rule that would go on covering its match; the image
# gate does not (trivy drops the entry, so its match blocks again if CRITICAL).
ignore_files
{ echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$today" pkg:npm/left-pad@1.0.0; } >"$tree/.trivyignore.yaml"
ignorefiles "an expired entry" 1 ".trivyignore.yaml:2: entry CVE-2026-1111 expired on $today"
check "scan-gate.sh --check-ignorefile: the grype rule of an expired entry fails too" has "$work/gate.out" \
  "rule CVE-2026-1111 left-pad@1.0.0 is 0 entries of .trivyignore.yaml in force"
gate local "scan-gate.sh: the image gate leaves an expired entry to trivy" 0 -- "gw linux/amd64" "$work/report.json"
grype_gate local "scan-gate.sh --grype: the image gate leaves an expired entry to job config" 0 -- --grype \
  "web linux/arm64" "$work/leg"
rm -f "$tree/.trivyignore.yaml" "$tree/.grype.yaml"
mv "$work/trivy-config-ignore.yaml" "$tree/deploy/ci/trivy-config-ignore.yaml"

# Another repository's tree (SVP_CODE_ROOT): its own .trivyignore.yaml and .grype.yaml, which must both be there.
{ echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$soon" pkg:npm/left-pad@1.0.0; } >"$webtree/.trivyignore.yaml"
{ echo "ignore:" && grype_rule CVE-2026-1111 left-pad 1.0.0; } >"$webtree/.grype.yaml"
grype_gate local "scan-gate.sh --grype, svp-frontend's tree: its files pass" 0 SVP_CODE_ROOT="$webtree" -- --grype \
  "web linux/arm64" "$work/leg"
check "scan-gate.sh --grype, svp-frontend's tree: grype reads its .grype.yaml" grep -qF -- \
  "-v $webtree/.grype.yaml:/ignore/grype.yaml:ro" "$work/docker.log"
mv "$tree/deploy/ci/trivy-config-ignore.yaml" "$work/trivy-config-ignore.yaml"
gate local "scan-gate.sh --check-ignorefile, svp-frontend's tree: its files pass" 0 SVP_CODE_ROOT="$webtree" -- \
  --check-ignorefile
mv "$work/trivy-config-ignore.yaml" "$tree/deploy/ci/trivy-config-ignore.yaml"
for file in .trivyignore.yaml .grype.yaml; do
  mv "$webtree/$file" "$work/web-ignore"
  gate local "scan-gate.sh, svp-frontend's tree without $file" 1 SVP_CODE_ROOT="$webtree" -- "web linux/arm64" \
    "$work/report.json"
  check "scan-gate.sh, svp-frontend's tree without $file: names the file" has "$work/gate.err" \
    "$webtree has no file $file: SVP_CODE_ROOT must be the checkout whose code is built"
  check "scan-gate.sh, svp-frontend's tree without $file: no scanner runs" test ! -s "$work/docker.log"
  mv "$work/web-ignore" "$webtree/$file"
done

# --- changed-services.sh: platform.sh is part of the image pipeline (common.sh sources it), so a change of it builds
# all six; this test, provenance-predicate-test.sh,
# the scripts of the verification runs and of the other workflows, the policy's values and docs/ are read by no
# image job.
changed_by() {
  echo "# changed" >>"$tree/$1"
  g commit -qam "change $1"
  on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null
}
all="engagement-service feed-service gateway media-worker user-service video-service"
same "changed-services: a change of platform.sh builds all six" "$all" "$(changed_by deploy/ci/platform.sh)"
# The web client's source left this repository: a file under web/ (and its removal) builds no image.
mkdir -p "$tree/web" && echo "export {};" >"$tree/web/page.ts"
same "changed-services: a file added under web/ builds nothing" "" "$(g add web && changed_by web/page.ts)"
g rm -q -r web && g commit -qm "drop web/"
same "changed-services: the removal of web/ builds nothing" "" \
  "$(on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null)"
same "changed-services: a change of platform-test.sh builds nothing" "" "$(changed_by deploy/ci/platform-test.sh)"
same "changed-services: a change of promote-test.sh builds nothing" "" "$(changed_by deploy/ci/promote-test.sh)"
same "changed-services: a change of provenance-predicate-test.sh builds nothing" "" \
  "$(changed_by deploy/ci/provenance-predicate-test.sh)"
same "changed-services: a change under deploy/ci/verify/ builds nothing" "" "$(changed_by deploy/ci/verify/gitops.sh)"
same "changed-services: a change of ghcr-digest.sh builds nothing" "" "$(changed_by deploy/ci/ghcr-digest.sh)"
same "changed-services: a change of ghcr-digest-test.sh builds nothing" "" "$(changed_by deploy/ci/ghcr-digest-test.sh)"
same "changed-services: a change of rescan.sh builds all six" "$all" "$(changed_by deploy/ci/rescan.sh)"
for f in gitops-check.sh gitops-check-test.sh values-check.sh verify-release.sh; do
  same "changed-services: a change of $f builds nothing" "" "$(changed_by "deploy/ci/$f")"
done
same "changed-services: a change of common.sh builds all six" "$all" "$(changed_by deploy/ci/common.sh)"
same "changed-services: a change of the policy's values builds nothing" "" \
  "$(changed_by deploy/helm/svp-policy/values.yaml)"
same "changed-services: a change under docs/ builds nothing" "" "$(changed_by docs/decision.md)"
# The Makefile counts only for the lines pinning the tools of the gate.
printf 'TRIVY_IMAGE := trivy@sha256:1\nGRYPE_IMAGE := grype@sha256:1\nK6_IMAGE := k6@sha256:1\n' >"$tree/Makefile"
g add Makefile && g commit -qm "add the Makefile"
sed 's/^GRYPE_IMAGE := grype@sha256:1$/GRYPE_IMAGE := grype@sha256:2/' "$tree/Makefile" >"$work/Makefile" &&
  cp "$work/Makefile" "$tree/Makefile" && g commit -qam "bump grype"
same "changed-services: a change of the GRYPE_IMAGE line builds all six" "$all" \
  "$(on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null)"
same "changed-services: a change of another line of the Makefile builds nothing" "" "$(changed_by Makefile)"

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

# --- plan.sh on a push to main that builds no image (the base: the newest successful push run): promote_charts when
# what the charts read changed (a file under deploy/helm/, or the file a symbolic link there points to), not for docs/.
# plan_charts NAME WANT: plan.sh of a push to main after one commit hands on promote_charts=WANT.
plan_charts() {
  local last
  last=$(jq -nc --arg sha "$(gv rev-parse HEAD~1)" \
    '{workflow_runs: [{head_sha: $sha, conclusion: "success", event: "push", head_branch: "main"}]}')
  fresh
  on github env "${backend_run[@]}" GITHUB_SHA="$(gv rev-parse HEAD)" EVENT_NAME=push GIT_REF=refs/heads/main \
    LAST_SUCCESS_JSON="$last" "$vr/deploy/ci/plan.sh" \
    >/dev/null 2>&1 || fail "plan.sh: $1: exits 0"
  same "plan.sh: $1" "promote_charts=$2 has_images=false" \
    "$(grep '^promote_charts=' "$work/output") $(grep '^has_images=' "$work/output")"
}
echo "# Another decision" >>"$vr/docs/decision.md"
gv commit -qam "a decision"
plan_charts "a push of docs/ only promotes nothing" false
echo "# A comment" >>"$vr/deploy/helm/svp-policy/values.yaml"
gv commit -qam "a comment in a chart"
plan_charts "a push that changes a chart promotes the charts" true
check "plan.sh: the summary names the chart's file" has "$work/summary" "- deploy/helm/svp-policy/values.yaml"
echo "exporters: {}" >>"$vr/deploy/observability/otelcol/k8s-config.yaml"
gv commit -qam "the collector's config"
plan_charts "a push that changes the file a chart's link points to promotes the charts" true

# --- The supply chain step of deploy/ci/verify/gitops.sh in the copy. gitops_supplychain hands the drill the newest
# drill-no-provenance for case l, and none (never empty, which the drill reads as "look it up yourself") when GHCR did
# not give it, the step then failing; a stub ghcr-digest.sh answers for GHCR and a fake make records its
# arguments. gitops_stale has its tests in deploy/ci/verify-collect-test.sh.
sc=$work/supplychain
mkdir -p "$sc/bin"
cat >"$sc/ghcr-digest.sh" <<'STUB'
#!/usr/bin/env bash
# Test stub: answers newest IMAGE and web-amd64 the way GHCR would, failing for the image in FAKE_GHCR_MISSING.
case $1 in
web-amd64) echo "ghcr.io/anhnvcoder/svp-frontend/web@sha256:$(printf 'c%.0s' $(seq 64))" ;;
newest)
  [ "$2" != "${FAKE_GHCR_MISSING:-}" ] || { echo "ghcr.io/anhnvcoder/svp-backend/$2 is not on GHCR" >&2; exit 1; }
  echo "ghcr.io/anhnvcoder/svp-backend/$2@sha256:$(printf 'd%.0s' $(seq 64))"
  ;;
esac
STUB
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s"\n' "$sc/make.args" >"$sc/bin/make"
chmod 755 "$sc/ghcr-digest.sh" "$sc/bin/make"
dnp=ghcr.io/anhnvcoder/svp-backend/drill-no-provenance@sha256:$(printf 'd%.0s' $(seq 64))
# supplychain WANT_RC [VAR=VALUE...]: gitops_supplychain with the stubs, stdout and stderr in sc.out.
supplychain() {
  local want=$1 rc=0
  shift
  rm -f "$sc/make.args"
  # The file as $1: with it as $0, it would take itself for run as a script.
  on local env repo="$vr" here="$sc" "$@" "$BASH" -c 'PATH="$2:$PATH"; . "$1"; gitops_supplychain' bash \
    "$vr/deploy/ci/verify/gitops.sh" "$sc/bin" >"$work/sc.out" 2>&1 || rc=$?
  same "gitops_supplychain: exit $want" "$want" "$rc"
}
supplychain 0
check "gitops_supplychain: case l gets the newest drill-no-provenance" has "$sc/make.args" \
  "SUPPLYCHAIN_NO_PROVENANCE=$dnp"
supplychain 1 FAKE_GHCR_MISSING=drill-no-provenance
check "gitops_supplychain: drill-no-provenance not on GHCR: case l left out with none" has "$sc/make.args" \
  "SUPPLYCHAIN_NO_PROVENANCE=none"
check "gitops_supplychain: drill-no-provenance not on GHCR: the step fails naming it" has "$work/sc.out" \
  "without what GHCR did not give (above): drill-no-provenance;"

# --- web_clone of deploy/k8s/lib.sh without WEB_REF: the commit of the web release stg runs, when that release is
# <imagePrefix>web of a source of the table: web. A release under another prefix is refused before anything is cloned. In a copy of the throwaway
# checkout; the clone of svp-frontend comes from a repository on disk (url.insteadOf of a git config of its own).
wc=$work/webclone
cp -R "$tree" "$wc"
wg=$work/webclone-gitops
wgit() {
  GIT_DIR=$wg/.git GIT_WORK_TREE=$wg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$wg/envs/stg/images"
wgit init -q -b main && wgit remote add origin https://github.com/anhnvcoder/svp-gitops.git
fe=$work/frontend
GIT_DIR=$fe/.git GIT_WORK_TREE=$fe GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q -b main "$fe"
GIT_DIR=$fe/.git GIT_WORK_TREE=$fe GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
  -c user.email=test@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m web
fe_head=$(GIT_DIR=$fe/.git git rev-parse HEAD)
printf '[url "%s"]\n\tinsteadOf = https://github.com/anhnvcoder/svp-frontend.git\n' "$fe/.git" >"$work/webclone.gitconfig"
# web_clone_case NAME WANT_RC REPOSITORY: web_clone with envs/stg/images/web.yaml naming REPOSITORY at the commit of
# $fe, its output in wc.out; the clone is removed first.
web_clone_case() {
  local rc=0
  rm -rf "$wc/.web"
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' "$3" "${fe_head:0:12}" "$digest_a" \
    >"$wg/envs/stg/images/web.yaml"
  # shellcheck disable=SC2016 # expanded by the inner shell
  on local env GIT_CONFIG_GLOBAL="$work/webclone.gitconfig" SVP_GITOPS_DIR="$wg" \
    bash -c '. "$1/deploy/k8s/lib.sh" && web_clone' _ "$wc" >"$work/wc.out" 2>&1 || rc=$?
  same "web_clone: $1 (exit $2)" "$2" "$rc"
}
web_clone_case "stg runs a release of source web" 0 ghcr.io/anhnvcoder/svp-frontend/web
check "web_clone: a release of web: its commit checked out" has "$work/wc.out" \
  "svp-frontend at ${fe_head:0:12} (${fe_head:0:12}) in .web/svp-frontend"
web_clone_case "stg runs web under a prefix no source publishes it under" 1 ghcr.io/anhnvcoder/svp-backend/web
check "web_clone: under another prefix: names the admitted repositories" has "$work/wc.out" \
  "staging runs web from ghcr.io/anhnvcoder/svp-backend/web (envs/stg/images/web.yaml), not a release of a source that publishes web (ghcr.io/anhnvcoder/svp-frontend/web): set WEB_REF"
[ ! -e "$wc/.web" ] && ok "web_clone: under another prefix: nothing cloned" ||
  fail "web_clone: under another prefix: nothing cloned"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
