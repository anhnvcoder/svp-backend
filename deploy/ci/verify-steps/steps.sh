#!/usr/bin/env bash
# The step list of a job of .github/workflows/verify.yml: one step per target, whose id is the target's name, the first
# of them the build step (up, k8s-gitops-up, k8s-up) that builds what the others use. The job names them in order in
# SVP_VERIFY_STEP_NAMES; the dispatch's input targets reaches here only through SVP_VERIFY_TARGETS (empty on a
# scheduled run: every step).
#
#   steps.sh check   before anything is built: every name of SVP_VERIFY_TARGETS (separated by spaces) is a step of
#                    the job, the build step's included (it always runs); a character other than a-z, 0-9, - and space,
#                    or a name the job does not have, exits 2. The rejected list is never printed back: the job's log
#                    reads a line that starts with :: as a command. Filtering is the steps' own if: (the name in
#                    targets, the build step's outcome success); nothing is added to what the dispatch names, so a
#                    step that reads another's result (drill-k8s-threats reads the READY video of k8s-smoke) is named
#                    with it.
#   steps.sh table   once the steps have run (whatever their outcome): $SVP_VERIFY_OUT/results.tsv, one line per step
#                    of SVP_VERIFY_STEP_NAMES in order, "step outcome note", printed to the log too. The outcome is the
#                    step's own, from SVP_VERIFY_STEPS (the job's steps context as JSON: toJSON(steps)): success,
#                    failure (a step that ran out of its timeout-minutes too), cancelled or skipped; absent when the
#                    job has no step of that id. A skipped step's note says why: not in targets, build step failed, or
#                    not run (the run was cancelled, or a step before the build failed). Only the outcome of each
#                    step is read from that JSON, never an output.
#
# SVP_VERIFY_OUT defaults to verify in $RUNNER_TEMP (/tmp on a machine). Usage, from anywhere:
# deploy/ci/verify-steps/steps.sh check|table
set -euo pipefail

names=${SVP_VERIFY_STEP_NAMES:-}
targets=${SVP_VERIFY_TARGETS:-}
read -r build _ <<<"$names" || :

fail() {
  echo "FAIL  verify steps: $1" >&2
  exit 2
}

[ -n "$build" ] || fail "SVP_VERIFY_STEP_NAMES names no step"

# chosen NAME: whether step NAME runs in this run.
chosen() {
  [ -z "$targets" ] || [ "$1" = "$build" ] && return 0
  case " $targets " in *" $1 "*) return 0 ;; esac
  return 1
}

case ${1:-} in
  check)
    case $targets in
      *[!a-z0-9\ -]*) fail "targets holds a character other than a-z, 0-9, - and space; nothing started" ;;
    esac
    unknown=
    # shellcheck disable=SC2086 # targets holds only a-z, 0-9, - and spaces (checked above): split on spaces, no glob
    for t in $targets; do
      case " $names " in *" $t "*) ;; *) unknown="$unknown $t" ;; esac
    done
    [ -z "$unknown" ] || fail "not a step of this job:$unknown (its steps: $names); nothing started"
    if [ -z "$targets" ]; then
      echo "verify steps: every step ($names)"
    else
      echo "verify steps: $build (the build step always runs) and $targets; the others are skipped"
    fi
    ;;
  table)
    out=${SVP_VERIFY_OUT:-${RUNNER_TEMP:-/tmp}/verify}
    mkdir -p "$out"
    steps=${SVP_VERIFY_STEPS:-}
    [ -n "$steps" ] || steps='{}'
    build_outcome=$(jq -r --arg s "$build" '.[$s].outcome // "absent"' <<<"$steps") ||
      fail "SVP_VERIFY_STEPS is not the steps context as JSON"
    {
      printf 'step\toutcome\tnote\n'
      for name in $names; do
        outcome=$(jq -r --arg s "$name" '.[$s].outcome // "absent"' <<<"$steps")
        case $outcome in success | failure | cancelled | skipped) ;; *) outcome=absent ;; esac
        note=
        if [ "$outcome" = skipped ]; then
          if ! chosen "$name"; then
            note="not in targets"
          elif [ "$build_outcome" != success ]; then
            note="build step failed"
          else
            note="not run"
          fi
        elif [ "$outcome" = absent ]; then
          note="no step of that id in the job"
        fi
        printf '%s\t%s\t%s\n' "$name" "$outcome" "$note"
      done
    } >"$out/results.tsv"
    awk -F '\t' 'NR > 1 { printf "  %-28s %-9s %s\n", $1, $2, $3 }' "$out/results.tsv"
    ;;
  *)
    fail "usage: steps.sh check|table"
    ;;
esac
