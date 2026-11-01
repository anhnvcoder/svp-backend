#!/usr/bin/env bash
# Runs one verification scenario: its make targets in order, each under a time limit of its own, with its whole output
# in a file. Same on the GitHub runner
# (.github/workflows/verify.yml) and on the rented Linux VM that stands in for it.
#
#   verify-run.sh compose-obs|gitops
#
# The targets of each scenario, in order, are in a file of their own, deploy/ci/verify/<scenario>.sh, which this script
# sources. A scenario file sets build (the name of its first target, which builds what the others use),
# job_minutes_default (the job's limit when SVP_VERIFY_JOB_MINUTES is not set) and k3d (1 when its targets run on
# cluster k3d-svp, 0 otherwise), may define helpers of its own (exported when a step runs them through bash -c), and
# defines scenario_targets, its targets in order through step and skip below. It may read names (every target of its list, once listed) and call chosen (below)
# while its targets run. It sets no other variable of this script, and its own are local to its functions
# with names apart from this script's: step and skip see a caller's locals (bash scopes dynamically), so a local n in
# scenario_targets would take the place of the target count. A name not in the list of this script, a missing file, a
# file that does not declare those, or one whose first target is not its build target stops the script before
# anything starts (exit 2).
#
# The job's log is public, so a target's output never goes there: each writes to $SVP_VERIFY_OUT/logs/<NN>-<name>.log,
# and the log gets fixed lines only (target, limit, result, seconds). deploy/ci/verify-collect.sh later copies what
# passes its scan into the artifact and prints the end of each failed target's output from that copy. A target that
# exits non-zero is a result, not the end of the scenario (a drill with a failed check): the next target still runs,
# and $SVP_VERIFY_OUT/results.tsv gets one line per target (id, name, ok|fail|timeout|skipped|cancelled, exit status,
# start and end in seconds since the epoch, seconds, note). Exits 1 when any target was not ok.
#
# Before the first target: make gitops-clone, main of the deployment configuration svp-gitops cloned anonymously into
# .gitops/svp-gitops of the checkout (the web release of staging for make up, all of it for make k8s-gitops-up), and
# SVP_GITOPS_DIR exported to it for every target (deploy/k8s/lib.sh, gitops_dir). No target can pass without it: when
# the clone fails, nothing starts (exit 1).
#
# The first target builds what the others use (the scenario file's build: up for compose-obs, k8s-gitops-up for
# gitops). When it is not ok, every later target is skipped at once with the note "infrastructure step failed": none of
# them can pass, and waiting for each to fail only spends the job's time. The collect and upload steps of the job still
# run.
#
# SVP_VERIFY_TARGETS (the dispatch's input targets; empty: every target) names the targets to run, separated by
# spaces, each a name of the scenario's list (results.tsv shows them); the build target always runs. The others are
# skipped with the note "not in targets", which does not make the run fail, and keep their id, so a log is named the
# same in every run. A name that is not one of the scenario's, or a character other than a-z, 0-9, - and space, stops
# the script before any target starts (exit 2). A target that reads another's result still needs it, and fails on its
# own without it, so name what it reads with it: the READY video of smoke (k8s-smoke) for drill-k8s-threats.
#
# Deadline: no target starts, and none runs, past the earlier of
#   - the job's start ($SVP_VERIFY_OUT/job-start, written by the job's first step) + SVP_VERIFY_JOB_MINUTES - 25 min,
#     the time the collect and upload steps keep;
#   - this script's start + SVP_VERIFY_STEP_MINUTES (the step's timeout-minutes) - 5 min, so it ends before GitHub
#     stops the step, with time to name the target that ran out and do what follows each target (below).
# Without those variables (the VM) the job's limit is the scenario file's (90 min for compose-obs, 160 for gitops),
# counted from now. A target gets the smaller of its own limit and what is left; GNU timeout stops its whole process
# group, with 120 s more for the drills' traps to put the stack back, then kills it.
#
# After each target, once its result is in results.tsv: deploy/ci/verify-mask.sh env (make up OBS=lgtm and the k3d
# install add tokens to .env), and on k3d verify-mask.sh cluster while the cluster answers, and make k8s-traffic-stop
# when drill traffic still runs. Each under a time limit of its own (at most about 3 min together), so a cluster that
# no longer answers cannot hold the script past its deadline.
#
# Linux only: GNU timeout and date -d.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo" || exit 1
# ci_temp_dir and the other ci_* functions: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$here/platform.sh"
tmp_root=$(ci_temp_dir) || exit 1
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
# The secret lists of deploy/ci/verify-mask.sh.
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}
export SVP_VERIFY_OUT=$out SVP_VERIFY_SECRETS=$secrets repo here

scenarios="compose-obs gitops"
scenario=${1:-}
case $scenario in
  compose-obs | gitops) ;;
  *)
    echo "FAIL  verify-run: unknown scenario '$scenario' ($scenarios); nothing started" >&2
    exit 2
    ;;
esac
scenario_file=$here/verify/$scenario.sh
build= job_minutes_default= k3d=
unset -f scenario_targets
if [ ! -f "$scenario_file" ]; then
  echo "FAIL  verify-run: no file deploy/ci/verify/$scenario.sh for scenario $scenario; nothing started" >&2
  exit 2
fi
# shellcheck source=/dev/null # one of deploy/ci/verify/*.sh, chosen by the case above
. "$scenario_file"
bad=
case $job_minutes_default in '' | *[!0-9]*) bad=1 ;; esac
case $k3d in 0 | 1) ;; *) bad=1 ;; esac
if [ -n "$bad" ] || [ -z "$build" ] || ! declare -F scenario_targets >/dev/null; then
  echo "FAIL  verify-run: deploy/ci/verify/$scenario.sh does not set build, job_minutes_default (minutes) and" \
    "k3d (0 or 1), or does not define scenario_targets; nothing started" >&2
  exit 2
fi
targets=${SVP_VERIFY_TARGETS:-}
case $targets in
  *[!a-z0-9\ -]*)
    # Not printed back: the job's log reads a line that starts with :: as a command.
    echo "FAIL  verify-run: SVP_VERIFY_TARGETS holds a character other than a-z, 0-9, - and space; nothing started" >&2
    exit 2
    ;;
esac
results=$out/results.tsv

now() { date +%s; }
utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
digits() { case $1 in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

step_start=$(now)
job_start=$(cat "$out/job-start" 2>/dev/null) && digits "$job_start" || job_start=$step_start
job_minutes=${SVP_VERIFY_JOB_MINUTES:-$job_minutes_default}
digits "$job_minutes" || job_minutes=$job_minutes_default
deadline=$((job_start + job_minutes * 60 - 25 * 60))
if digits "${SVP_VERIFY_STEP_MINUTES:-}"; then
  step_deadline=$((step_start + SVP_VERIFY_STEP_MINUTES * 60 - 300))
  [ "$step_deadline" -lt "$deadline" ] && deadline=$step_deadline
fi
echo "verify-run $scenario: started $(utc "$step_start"); no target runs past $(utc "$deadline")"

n=0
not_ok=0
current=
timeout_pid=
last_log=
# listing: set while the scenario's targets are only listed into names, before any runs (see the scenarios below).
listing=
names=
infra_failed=
unchosen_note="not in targets"

# chosen NAME: whether NAME runs in this run (see SVP_VERIFY_TARGETS in the header).
chosen() {
  [ -z "$targets" ] || [ "$1" = "$build" ] && return 0
  case " $targets " in *" $1 "*) return 0 ;; esac
  return 1
}

# record ID NAME STATUS EXIT START END NOTE
record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(($6 - $5))" "$7" >>"$results"
  [ "$3" = ok ] || [ "$7" = "$unchosen_note" ] || not_ok=$((not_ok + 1))
  echo "[$1] $2: $3${4:+ (exit $4)}, $(($6 - $5)) s${7:+; $7}"
}

traffic_running() { [ "$k3d" = 1 ] && timeout 10 deploy/k8s/drills/traffic.sh status >/dev/null 2>&1; }
cluster_answers() { timeout 15 kubectl --context k3d-svp --request-timeout=10s get --raw /readyz >/dev/null 2>&1; }
# traffic_stop LOG: stops the drill traffic (traffic.sh waits 20 s at most for it), its output appended to LOG.
traffic_stop() { timeout 60 make -s k8s-traffic-stop >>"${1:-/dev/null}" 2>&1; }

# after LOG: what follows every target (see the header). Mask lines go to this script's stdout, the job's log.
after() {
  timeout 30 "$here/verify-mask.sh" env || echo "verify-run: verify-mask.sh env failed"
  if [ "$k3d" = 1 ] && cluster_answers; then
    # Five namespaces, each read within 10 s.
    timeout 90 "$here/verify-mask.sh" cluster || echo "verify-run: verify-mask.sh cluster failed"
  fi
  if traffic_running; then
    echo "verify-run: drill traffic still running; make k8s-traffic-stop"
    traffic_stop "$1" || echo "verify-run: make k8s-traffic-stop failed"
  fi
}

# On a cancelled run or when GitHub stops the step: stop the target, name it, stop the drill traffic.
on_signal() {
  trap - INT TERM
  if [ -n "$timeout_pid" ]; then
    kill -TERM "$timeout_pid" 2>/dev/null
    wait "$timeout_pid" 2>/dev/null
  fi
  if [ -n "$current" ]; then
    # shellcheck disable=SC2086 # current holds "ID NAME START"
    set -- $current
    record "$1" "$2" cancelled "" "$3" "$(now)" "the run was cancelled or the step timed out"
  fi
  traffic_running && traffic_stop "$last_log"
  exit 130
}
trap on_signal INT TERM

# skip NAME NOTE: records NAME as the next target, skipped for NOTE; for "not in targets" instead when NAME is not
# chosen, and for "infrastructure step failed" once the build target was not ok (see the header).
skip() {
  local t note=$2
  if [ -n "$listing" ]; then
    names="$names $1"
    return
  fi
  t=$(now)
  n=$((n + 1))
  if ! chosen "$1"; then
    note=$unchosen_note
  elif [ -n "$infra_failed" ]; then
    note="infrastructure step failed"
  fi
  record "$(printf '%02d' "$n")" "$1" skipped "" "$t" "$t" "$note"
}

# step NAME LIMIT_MINUTES COMMAND...: runs COMMAND as the next target (see the header).
step() {
  local name=$1 limit=$(($2 * 60)) id start end rc status note= log left
  shift 2
  if [ -n "$listing" ] || ! chosen "$name" || [ -n "$infra_failed" ]; then
    skip "$name" ""
    return
  fi
  start=$(now)
  left=$((deadline - start))
  if [ "$left" -lt 60 ]; then
    skip "$name" deadline
    return
  fi
  n=$((n + 1))
  id=$(printf '%02d' "$n")
  log=$out/logs/$id-$name.log
  if [ "$limit" -gt "$left" ]; then
    limit=$left
    note="limit cut to ${left} s by the deadline"
  fi
  echo "[$id] $name: started $(utc "$start"), limit $limit s"
  current="$id $name $start"
  last_log=$log
  timeout --kill-after=120 "$limit" "$@" >"$log" 2>&1 </dev/null &
  timeout_pid=$!
  wait "$timeout_pid"
  rc=$?
  timeout_pid=
  end=$(now)
  case $rc in
    0) status=ok ;;
    124 | 137) status=timeout note="${note:+$note; }stopped after $limit s" ;;
    *) status=fail ;;
  esac
  current=
  record "$id" "$name" "$status" "$rc" "$start" "$end" "$note"
  [ "$name" = "$build" ] && [ "$status" != ok ] && infra_failed=1
  after "$log"
}

# kc: kubectl on cluster k3d-svp, for the steps of the scenario files; exported, since timeout runs them in a new bash.
kc() { kubectl --context k3d-svp "$@"; }
export -f kc

# --- The scenario's targets: scenario_targets of the scenario file, called twice. With listing set, step and skip only
# add each name to names, which SVP_VERIFY_TARGETS is checked against; then for the run.
listing=1
scenario_targets
listing=
unknown=
# shellcheck disable=SC2086 # targets holds only a-z, 0-9, - and spaces (checked above): split on spaces, no glob
for t in $targets; do
  case "$names " in *" $t "*) ;; *) unknown="$unknown $t" ;; esac
done
if [ -n "$unknown" ]; then
  echo "FAIL  verify-run: not a target of $scenario:$unknown (its targets:$names); nothing started" >&2
  exit 2
fi
case "$names " in
  " $build "*) ;;
  *)
    echo "FAIL  verify-run: the first target of deploy/ci/verify/$scenario.sh is not its build target $build; nothing" \
      "started" >&2
    exit 2
    ;;
esac
make -s gitops-clone || {
  echo "FAIL  verify-run: make gitops-clone (the deployment configuration svp-gitops); nothing started" >&2
  exit 1
}
SVP_GITOPS_DIR=$(. "$repo/deploy/k8s/lib.sh" && echo "$gitops_ci_clone") || exit 1
export SVP_GITOPS_DIR
mkdir -p "$out/logs" || exit 1
printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$results"
[ -n "$targets" ] && echo "verify-run $scenario: targets $build $targets; the others are skipped"
scenario_targets

echo "verify-run $scenario: $n target(s), $not_ok not ok (results.tsv; the outputs reach the artifact after verify-collect.sh)"
[ "$not_ok" = 0 ]
