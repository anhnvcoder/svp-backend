# shellcheck shell=bash
# FROZEN: this adapter gets no new ci_* function. A new script reads GitHub Actions' variables and calls gh directly,
# like any script written for one CI; the functions below stay only for the scripts that already call them, and a
# function is deleted once the last script that calls it is gone. Nothing enforces this: a new function would work,
# but would deepen a layer that is being retired.
#
# What the adapter does: it is the place that knows which CI platform runs a script and how to talk to it. The scripts
# under deploy/ci/, and the scripts of deploy/k8s/ that hint at a CI run or read the repository host's API, call these
# functions instead of reading the platform's variables or calling its CLI. Sourcing it only defines functions;
# common.sh sources it, and so do the scripts that do not source common.sh. Written for bash 3.2 too (macOS).
#
# Two platforms are implemented, told apart by ci_platform:
#   github  a job of GitHub Actions (GITHUB_ACTIONS=true): outputs, the job summary and masks through the files and
#           workflow commands of the runner; pull requests and dispatches through gh, with the job's token.
#   local   a machine: outputs and summaries go to stdout, nothing is masked (there is no log to hide a value from),
#           and nothing is written through the platform's API: a write prints the command it would run instead. Reads
#           (open pull requests) still reach GitHub, where the repository lives, through the machine's gh login.
# Any other CI stops the script that asks: guessing where an output, a summary or a mask goes would lose it silently,
# and a step whose output is lost looks green.
#
# What a gitlab branch would use (GitLab CI, gitlab.com or a self-managed instance):
#   ci_platform           GITLAB_CI=true
#   ci_output             no output file per step: a dotenv report (artifacts:reports:dotenv, one line per value, 5 KB)
#                         that later jobs read; between steps of one job, a shell variable
#   ci_summary            no job summary: the job log, or a file in the job's artifacts
#   ci_mask               no command masks a value made during a job: only variables masked in the project's
#                         settings are hidden, so a value read at run time must never reach the log at all
#   ci_warning            no annotation: a plain line
#   ci_temp_dir           no runner temp directory: ${TMPDIR:-/tmp}
#   ci_repo               CI_PROJECT_PATH
#   ci_run_id             CI_PIPELINE_ID
#   ci_run_url            CI_PIPELINE_URL
#   ci_run_attempt_url    CI_JOB_URL (a retried job gets a new id; there is no attempt number)
#   ci_builder_id         https:// + the ci_config_ref_uri claim of the id_tokens token
#                         (<host>/<CI_PROJECT_PATH>//<CI_CONFIG_PATH>@refs/heads/<branch>), which is also the subject
#                         of a keyless signature made with it
#   ci_repo_url           CI_PROJECT_URL
#   ci_commit             CI_COMMIT_SHA
#   ci_change_request_*   merge requests (glab mr list), with the job's own CI_JOB_TOKEN
#   ci_dispatch_hint      glab ci run with --input (pipeline variables are turned off for new projects on gitlab.com),
#                         with --repo naming the code project
# CI_SERVER_URL is the instance's own URL, so on a self-managed instance every URL above starts with the company's
# domain, not gitlab.com.

# _ci_fail WORDS...: the error line of every function below; they return 1 and leave exiting to the caller.
_ci_fail() { echo "FAIL  $*" >&2; }

# _ci_need NAME: prints the variable NAME, which the platform sets for every job; fails naming it when it is empty.
_ci_need() {
  local value=${!1:-}
  [ -n "$value" ] || {
    _ci_fail "$1 is empty: the CI platform sets it for every job"
    return 1
  }
  printf '%s\n' "$value"
}

# ci_platform: prints github or local; fails on any other CI. GitHub Actions, GitLab CI, Bitbucket Pipelines and most
# others set CI=true; Jenkins sets JENKINS_URL, Azure Pipelines TF_BUILD. CI=false (or 0) on a machine, which some
# build tools read, is not a CI.
ci_platform() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo github
    return 0
  fi
  local which=
  if [ -n "${GITLAB_CI:-}" ]; then
    which="GitLab CI"
  elif [ -n "${JENKINS_URL:-}" ]; then
    which=Jenkins
  elif [ -n "${TF_BUILD:-}" ]; then
    which="Azure Pipelines"
  elif [ -n "${CI:-}" ] && [ "$CI" != false ] && [ "$CI" != 0 ]; then
    which="a CI that sets CI=$CI"
  fi
  if [ -n "$which" ]; then
    _ci_fail "this runs on $which, but only GitHub Actions and local runs are implemented;" \
      "add a branch in deploy/ci/platform.sh for another CI"
    return 1
  fi
  echo local
}

# ci_output KEY VALUE: hands VALUE to the steps and jobs after this one under KEY (a step output on GitHub); prints
# KEY=VALUE on a machine. One line only: a value of several lines needs the platform's multi-line form.
ci_output() {
  local platform file
  platform=$(ci_platform) || return 1
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
    _ci_fail "output name '$1' is not a plain name"
    return 1
  }
  case $2 in *$'\n'* | *$'\r'*)
    _ci_fail "output $1 holds a line break: outputs are one line"
    return 1
    ;;
  esac
  case $platform in
  github)
    file=$(_ci_need GITHUB_OUTPUT) || return 1
    printf '%s=%s\n' "$1" "$2" >>"$file"
    ;;
  local) printf '%s=%s\n' "$1" "$2" ;;
  esac
}

# ci_summary [LINE...]: adds LINEs (stdin when none) to the summary page of the job; prints them on a machine.
ci_summary() {
  local platform file
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    file=$(_ci_need GITHUB_STEP_SUMMARY) || return 1
    if [ $# -gt 0 ]; then printf '%s\n' "$@" >>"$file"; else cat >>"$file"; fi
    ;;
  local) if [ $# -gt 0 ]; then printf '%s\n' "$@"; else cat; fi ;;
  esac
}

# ci_has_summary: true when the job summary is a page apart from the log (so a line written there only is not in the
# log); false on a machine, where ci_summary prints.
ci_has_summary() {
  local platform
  platform=$(ci_platform) || return 1
  [ "$platform" = github ]
}

# ci_summary_tee: copies stdin to stdout and, where the job summary is a page of its own, to the summary too.
ci_summary_tee() {
  local platform file
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    file=$(_ci_need GITHUB_STEP_SUMMARY) || return 1
    tee -a "$file"
    ;;
  local) cat ;;
  esac
}

# ci_mask VALUE: hides VALUE wherever the job's log shows it from now on. On GitHub the mask command's data reads %25
# as %, so a % of the value is written that way. A machine prints nothing: there, the command would print the value.
ci_mask() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) printf '::add-mask::%s\n' "${1//%/%25}" ;;
  local) ;;
  esac
}

# ci_warning MESSAGE: a warning the run's page shows beside the log line (an annotation on GitHub); a plain line on a
# machine.
ci_warning() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) printf '::warning::%s\n' "$1" ;;
  local) printf 'warning: %s\n' "$1" ;;
  esac
}

# ci_temp_dir: a directory for the job's own files, emptied when the job ends (RUNNER_TEMP on GitHub); /tmp on a
# machine.
ci_temp_dir() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need RUNNER_TEMP ;;
  local) echo /tmp ;;
  esac
}

# The code repository (owner/name on its host): the one that holds deploy/ci/ and the workflows that build, sign and
# promote releases. Change it here when the repository moves.
_ci_code_repo=anhnvcoder/svp-backend

# _ci_local_repo: on a machine, owner/name of the repository whose code is built: the code repository's, or, when
# SVP_CODE_ROOT names the checkout of another repository (whose CI runs these scripts from a pinned checkout of this
# one), that checkout's, read from its remote origin on github.com, as a job of that repository would see it. Fails
# when that checkout has no such origin: its repository cannot be named without a guess. The error shows the origin
# without its userinfo: a URL may carry a credential (https://user:token@host/...).
_ci_local_repo() {
  local url repo shown
  if [ -z "${SVP_CODE_ROOT:-}" ]; then
    echo "$_ci_code_repo"
    return 0
  fi
  url=$(git -C "$SVP_CODE_ROOT" remote get-url origin 2>/dev/null) || url=
  if [[ $url =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
    repo=${BASH_REMATCH[2]}
    echo "${repo%.git}"
    return 0
  fi
  shown=$url
  if [[ $url =~ ^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@(.*)$ ]]; then
    shown=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
  fi
  _ci_fail "SVP_CODE_ROOT=$SVP_CODE_ROOT has no remote origin on github.com (got '${shown:-none}'): its repository cannot be named"
  return 1
}

# ci_repo: owner/name of the repository on its host. On a machine, the repository whose code is built
# (_ci_local_repo).
ci_repo() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_REPOSITORY ;;
  local) _ci_local_repo ;;
  esac
}

# ci_run_id: the id of this workflow run, the same for every job and attempt of it; "local" on a machine.
ci_run_id() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_RUN_ID ;;
  local) echo local ;;
  esac
}

# ci_run_url: the page of this run; "local" on a machine.
ci_run_url() {
  local platform server repo id
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    server=$(_ci_need GITHUB_SERVER_URL) && repo=$(_ci_need GITHUB_REPOSITORY) && id=$(_ci_need GITHUB_RUN_ID) ||
      return 1
    echo "$server/$repo/actions/runs/$id"
    ;;
  local) echo local ;;
  esac
}

# ci_run_attempt_url: the page of this attempt of the run (a re-run is a new attempt of the same run); "local" on a
# machine.
ci_run_attempt_url() {
  local platform url
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    url=$(ci_run_url) || return 1
    echo "$url/attempts/${GITHUB_RUN_ATTEMPT:-1}"
    ;;
  local) echo local ;;
  esac
}

# ci_builder_id: the workflow file that runs this job, at the ref it ran from, as a URL: the builder an attestation
# names, and the subject of the keyless certificate this job gets (server URL + job_workflow_ref on GitHub); "local" on
# a machine.
ci_builder_id() {
  local platform server ref
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    server=$(_ci_need GITHUB_SERVER_URL) && ref=$(_ci_need GITHUB_WORKFLOW_REF) || return 1
    echo "$server/$ref"
    ;;
  local) echo local ;;
  esac
}

# ci_repo_url: the web address of the repository on its host. On a machine, that of ci_repo on GitHub.
ci_repo_url() {
  local platform server repo
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    server=$(_ci_need GITHUB_SERVER_URL) && repo=$(_ci_need GITHUB_REPOSITORY) || return 1
    echo "$server/$repo"
    ;;
  local)
    repo=$(ci_repo) || return 1
    echo "https://github.com/$repo"
    ;;
  esac
}

# ci_commit: the full SHA of the commit this run checked out and builds. On a machine, HEAD of the checkout whose code
# is built, which is what a build there starts from: SVP_CODE_ROOT when set, otherwise the checkout this file is in.
ci_commit() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_SHA ;;
  local) git -C "${SVP_CODE_ROOT:-$(dirname "${BASH_SOURCE[0]}")}" rev-parse --verify HEAD ;;
  esac
}

# ci_change_request_list BRANCH BASE [REPO]: prints, in the host's own form (read only by ci_change_request_pick), the
# open change requests (pull requests) from a branch named BRANCH into BASE of REPO (owner/name; ci_repo when empty).
# GitHub's --head matches the bare branch name, so a fork's pull request from a branch of that name is listed too. gh
# lists 30 by default, newest first: 30 fork pull requests from such a branch opened after the bot's would hide it. So
# the list goes up to 500 (gh pages through), and a list that comes back full fails rather than guess. A read, so a
# machine asks GitHub too.
ci_change_request_list() {
  local platform repo list
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    repo=${3:-$(ci_repo)} || return 1
    list=$(gh pr list --repo "$repo" --head "$1" --base "$2" --state open --limit 500 \
      --json number,isCrossRepository,author) || return 1
    [ "$(jq length <<<"$list")" -lt 500 ] || {
      _ci_fail "500 or more open pull requests from a branch $1: close the forks' before promoting"
      return 1
    }
    echo "$list"
    ;;
  esac
}

# ci_change_request_pick [APP]: reads a list of ci_change_request_list on stdin and prints the number of the one CI
# itself opened from the listed repository (by the platform's own bot, or by app APP when given), or nothing. A
# fork's, or one a person opened from a branch of the same name, is not CI's: counting it would bring stale values of
# the branch back, and put CI's title on someone else's diff.
ci_change_request_pick() {
  local platform
  platform=$(ci_platform) || return 1
  [ -z "${1:-}" ] || _ci_name app "$1" || return 1
  case $platform in
  github | local)
    jq -r --arg author "app/${1:-github-actions}" \
      '[.[] | select(.isCrossRepository == false and .author.login == $author)][0].number // empty'
    ;;
  esac
}

# ci_dispatch_hint WORKFLOW REF [NAME=VALUE...]: prints the command a person runs to start WORKFLOW of the code
# repository on REF with those inputs, for a message that asks for such a run; runs nothing. The command names the
# repository, so it starts the right workflow from any directory, a clone of svp-gitops included.
ci_dispatch_hint() {
  local platform hint kv
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    hint="gh workflow run $1 --repo $_ci_code_repo --ref $2"
    shift 2
    for kv in "$@"; do hint="$hint -f $kv"; done
    echo "$hint"
    ;;
  esac
}

# _ci_name WHAT VALUE: fails unless VALUE is a plain name ([A-Za-z0-9._-]), which a query to the host can hold as is.
_ci_name() {
  [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || {
    _ci_fail "$1 '$2' is not a plain name ([A-Za-z0-9._-])"
    return 1
  }
}
