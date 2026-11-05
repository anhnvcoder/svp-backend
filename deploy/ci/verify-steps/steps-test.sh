#!/usr/bin/env bash
# Tests for deploy/ci/verify-steps/steps.sh, and for the shape of the jobs of .github/workflows/verify.yml that it
# relies on, read as JSON with yq (YQ_IMAGE of the Makefile, through Docker without network):
#   - check: an empty list, steps of the job and its build step pass; a name the job does not have (one of the other
#     job's, a name the scenario had before), or a character other than a-z, 0-9, - and space, exits 2 without printing
#     the list back;
#   - table: one line per step of SVP_VERIFY_STEP_NAMES in order with its outcome from the steps context, a skipped
#     step's reason, absent for an id the job lacks, and no output of a step;
#   - the workflow: in each job, the steps of SVP_VERIFY_STEP_NAMES in that order, the build step without if: after
#     the check of the targets and the clone of svp-gitops, every other one with exactly the if: of its name (not
#     cancelled, build step succeeded, in targets), each with its timeout-minutes and its output to its file, none with
#     continue-on-error; no ${{ }} in a run:; the steps that mask, tabulate, collect, upload and clean up after them with
#     always() once the ref check passed; the sum of the steps' timeout-minutes, 20 minutes of setup and 25 for those
#     steps within the job's timeout-minutes. The same check over copies of the workflow each broken one way must fail.
# Runs on macOS and Linux: bash, jq and Docker; no network, no cluster.
#
# Usage, from anywhere: deploy/ci/verify-steps/steps-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
same() { if [ "$3" = "$2" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi; }
has() { if grep -qF -- "$3" "$work/$1.log"; then ok "$1: $2"; else fail "$1: $2"; fi; }
lacks() { if grep -qF -- "$3" "$work/$1.log"; then fail "$1: $2"; else ok "$1: $2"; fi; }

compose="up smoke drill-obs-threats test-stack-objstore"
gitops="k8s-gitops-up drill-k8s-gitops gitops-admission-metrics k8s-smoke drill-k8s-supplychain drill-k8s-threats"

# steps NAME NAMES TARGETS ARG [VAR=VALUE...]: steps.sh ARG for the steps NAMES and the input TARGETS, as on a machine;
# its output in $work/NAME.log; prints its status.
steps() {
  local name=$1 names=$2 targets=$3 arg=$4 rc=0
  shift 4
  env -u GITHUB_ACTIONS -u SVP_VERIFY_STEPS SVP_VERIFY_STEP_NAMES="$names" SVP_VERIFY_TARGETS="$targets" \
    SVP_VERIFY_OUT="$work/$name.out" "$@" "$here/steps.sh" "$arg" >"$work/$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}

# --- check.
same "check: no targets passes" 0 "$(steps all "$gitops" "" check)"
has all "every step is named" "verify steps: every step ($gitops)"
same "check: steps of the job pass" 0 "$(steps two "$gitops" "drill-k8s-threats  k8s-smoke" check)"
has two "the build step is named as always running" "verify steps: k8s-gitops-up (the build step always runs) and drill-k8s-threats  k8s-smoke"
same "check: the build step may be named" 0 "$(steps build "$compose" up check)"
same "check: a name that is no step of the job stops it" 2 "$(steps unknown "$gitops" "drill-k8s-threats drill-k8s-thraets" check)"
has unknown "it names the name and the job's steps" "not a step of this job: drill-k8s-thraets (its steps: $gitops); nothing started"
same "check: a step of the other job is unknown" 2 "$(steps other "$compose" k8s-smoke check)"
has other "the steps of compose-obs are listed" "(its steps: $compose)"
same "check: a check of the scenario that is now a test of drill-k8s-gitops is unknown" 2 \
  "$(steps old "$gitops" gitops-external-secrets check)"
same "check: a list with another character stops it" 2 "$(steps bad "$gitops" $'k8s-smoke\n::warning::BAD-TARGET-MARKER' check)"
lacks bad "the rejected list is not printed back" BAD-TARGET-MARKER
has bad "it says why" "targets holds a character other than a-z, 0-9, - and space; nothing started"
same "check: a job without steps stops it" 2 "$(steps none "" "" check)"
same "steps.sh: another argument stops it" 2 "$(steps usage "$gitops" "" run)"

# --- table.
json=$(jq -n '{
  ref: {outcome: "success", conclusion: "success", outputs: {}},
  "k8s-gitops-up": {outcome: "success", conclusion: "success", outputs: {}},
  "drill-k8s-gitops": {outcome: "failure", conclusion: "failure", outputs: {leak: "OUTPUT-MARKER"}},
  "gitops-admission-metrics": {outcome: "skipped", conclusion: "skipped", outputs: {}},
  "k8s-smoke": {outcome: "success", conclusion: "success", outputs: {}},
  "drill-k8s-supplychain": {outcome: "cancelled", conclusion: "cancelled", outputs: {}}}')
same "table: exits 0 whatever the steps gave" 0 \
  "$(steps table "$gitops" "k8s-smoke drill-k8s-gitops drill-k8s-supplychain drill-k8s-threats" table SVP_VERIFY_STEPS="$json")"
same "table: one line per step in order: outcome, why a step was skipped, absent for an id the job lacks" \
  "$(printf 'step\toutcome\tnote\n%s\n' "$(printf '%s\t%s\t%s\n' k8s-gitops-up success '' drill-k8s-gitops failure '' \
    gitops-admission-metrics skipped 'not in targets' k8s-smoke success '' drill-k8s-supplychain cancelled '' \
    drill-k8s-threats absent 'no step of that id in the job')")" "$(cat "$work/table.out/results.tsv")"
has table "the table is printed" "  drill-k8s-gitops             failure"
lacks table "no output of a step is read" OUTPUT-MARKER
grep -q OUTPUT-MARKER "$work/table.out/results.tsv" && fail "table: no output of a step in results.tsv" ||
  ok "table: no output of a step in results.tsv"
json=$(jq -n '{up: {outcome: "failure"}, smoke: {outcome: "skipped"}, "drill-obs-threats": {outcome: "skipped"},
  "test-stack-objstore": {outcome: "skipped"}}')
steps table-build "$compose" smoke table SVP_VERIFY_STEPS="$json" >/dev/null
same "table: after a failed build step, a chosen step skipped is for it, the others not in targets" \
  "$(printf '%s\n' "up failure " "smoke skipped build step failed" "drill-obs-threats skipped not in targets" \
    "test-stack-objstore skipped not in targets")" \
  "$(awk -F '\t' 'NR > 1 { print $1, $2, $3 }' "$work/table-build.out/results.tsv")"
json=$(jq -n '{up: {outcome: "success"}, smoke: {outcome: "skipped"}, "drill-obs-threats": {outcome: "skipped"},
  "test-stack-objstore": {outcome: "skipped"}}')
steps table-cancelled "$compose" "" table SVP_VERIFY_STEPS="$json" >/dev/null
same "table: a step skipped after a successful build step was not run (a cancel)" "smoke skipped not run" \
  "$(awk -F '\t' 'NR == 3 { print $1, $2, $3 }' "$work/table-cancelled.out/results.tsv")"
same "table: steps context that is not JSON stops it" 2 "$(steps table-bad "$compose" "" table SVP_VERIFY_STEPS='{not json')"

# --- The workflow.
yq_image=$(sed -n 's/^YQ_IMAGE[[:space:]]*:=[[:space:]]*//p' "$src/Makefile")
# workflow_json FILE: FILE (a workflow) as JSON.
workflow_json() {
  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(dirname "$1"):/w:ro" "$yq_image" -o json \
    "/w/$(basename "$1")"
}
# problems FILE: one line per rule of the header that the jobs of workflow FILE break; nothing when it keeps them.
problems() {
  workflow_json "$1" | jq -r '
    def want_if($build; $name):
      "${{ !cancelled() && steps.\($build).outcome == '"'"'success'"'"' && (!inputs.targets || contains(format('"'"' {0} '"'"', inputs.targets), '"'"' \($name) '"'"')) }}";
    def after: "always() && steps.ref.outcome == '"'"'success'"'"'";
    (if .on.workflow_dispatch.inputs.scenario.options != ["compose-obs", "gitops"] then "scenario: the options are compose-obs and gitops" else empty end),
    (.jobs | to_entries[] | .key as $job | .value as $j
    | ($j.env.SVP_VERIFY_STEP_NAMES // "" | split(" ") | map(select(. != ""))) as $names
    | ($names[0] // "") as $build
    | [$j.steps | to_entries[] | {i: .key} + .value] as $steps
    | [$steps[] | select(.id as $id | $names | index($id))] as $named
    | ($steps | map(select(.id == $build)) | first // {}) as $b
    | ([$steps[] | select(.["timeout-minutes"] != null) | .["timeout-minutes"]] | add // 0) as $sum
    | (if ($names | length) == 0 then "\($job): no SVP_VERIFY_STEP_NAMES" else empty end),
      (if $steps[0].id != "ref" then "\($job): the ref check is not the first step" else empty end),
      (if ([$named[].id] != $names) then "\($job): the steps of SVP_VERIFY_STEP_NAMES are not all there in that order" else empty end),
      (if $b.if != null then "\($job): the build step \($build) has an if:" else empty end),
      ([$steps[] | select(.run == "deploy/ci/verify-steps/steps.sh check")] | first // null) as $check
      | (if $check == null or $check.i > ($b.i // -1) then "\($job): the targets are not checked before the build step" else empty end),
      ([$steps[] | select(.name == "make gitops-clone")] | first // null) as $clone
      | (if $clone == null or $clone.i > ($b.i // -1) then "\($job): svp-gitops is not cloned before the build step" else empty end),
      ($named[] | select(.id != $build) | select(.if != want_if($build; .id)) | "\($job): step \(.id) has another if: than its name gives"),
      ($named[] | select(.["timeout-minutes"] == null) | "\($job): step \(.id) has no timeout-minutes"),
      ($named[] | select(.id as $id | (.run // "") | endswith(">\"$SVP_VERIFY_OUT/logs/\($id).log\" 2>&1 </dev/null") | not)
        | "\($job): step \(.id) does not send its output to its file"),
      ($steps[] | select(.["continue-on-error"] != null) | "\($job): step \(.id // .name // .uses) has continue-on-error"),
      ($steps[] | select((.run // "") | contains("${{")) | "\($job): step \(.id // .name) puts an expression into a shell"),
      ($steps[] | select(.i > ($b.i // 0)) | select((.id as $id | $names | index($id)) | not) | select(.if != after)
        | "\($job): step \(.name // .uses) after the build step does not run always() once the ref check passed"),
      ([$steps[] | select(.name == "Table of the steps")] | first // null) as $table
      | (if $table == null or $table.env.SVP_VERIFY_STEPS != "${{ toJSON(steps) }}" or $table.i < ($named | last | .i)
         then "\($job): no table of the steps after them, from toJSON(steps)" else empty end),
      ([$steps[] | select(.name | tostring | startswith("Mask what the build step added"))] | first // null) as $mask
      | (if $mask == null or $mask.i != ($b.i // -2) + 1 then "\($job): the build step is not followed by a mask" else empty end),
      (if ($j["timeout-minutes"] // 0) < $sum + 45
       then "\($job): timeout-minutes \($j["timeout-minutes"]) holds less than the steps'"'"' \($sum), 20 of setup and 25 after them" else empty end))'
}

wf=$src/.github/workflows/verify.yml
got=$(problems "$wf") || fail "workflow: read .github/workflows/verify.yml as JSON with yq"
same "workflow: the jobs of verify.yml keep every rule" "" "$got"
same "workflow: the job compose lists its steps" "$compose" \
  "$(workflow_json "$wf" | jq -r '.jobs.compose.env.SVP_VERIFY_STEP_NAMES')"
same "workflow: the job gitops lists its steps" "$gitops" "$(workflow_json "$wf" | jq -r '.jobs.gitops.env.SVP_VERIFY_STEP_NAMES')"
workflow_json "$wf" | jq -e '.jobs.gitops.steps[] | select(.id == "k8s-gitops-up") | .run | startswith("make k8s-gitops-up GITOPS_REV=\"$SVP_GITOPS_SHA\" ")' >/dev/null &&
  workflow_json "$wf" | jq -e '.jobs.gitops.steps[] | select(.name == "make gitops-clone") | .run | contains("echo \"SVP_GITOPS_SHA=$sha\" >>\"$GITHUB_ENV\"")' >/dev/null &&
  ok "workflow: gitops builds the cluster at the commit of origin/main the clone fetched" ||
  fail "workflow: gitops builds the cluster at the commit of origin/main the clone fetched"
workflow_json "$wf" | jq -e '.jobs.gitops.steps[] | select(.id == "drill-k8s-supplychain") | .env.SVP_VERIFY_SCHEDULED == "${{ github.event_name == '"'"'schedule'"'"' && '"'"'true'"'"' || '"'"''"'"' }}"' >/dev/null &&
  ok "workflow: only a scheduled run tells the supply chain step it is one" ||
  fail "workflow: only a scheduled run tells the supply chain step it is one"

# Copies broken one way each: the check must name it.
mkdir -p "$work/broken"
# broken NAME WANT SED: the workflow with the sed script SED applied must break the rule WANT names.
broken() {
  sed "$3" "$wf" >"$work/broken/$1.yml"
  cmp -s "$wf" "$work/broken/$1.yml" && { fail "workflow, broken $1: the sed script changed nothing"; return; }
  if problems "$work/broken/$1.yml" | grep -qF -- "$2"; then ok "workflow, broken $1: caught ($2)"; else
    fail "workflow, broken $1: not caught ($2)"; fi
}
broken not-cancelled "step smoke has another if:" 's/if: ${{ !cancelled() \&\& steps.up.outcome/if: ${{ steps.up.outcome/'
broken no-build-check "step drill-k8s-threats has another if:" \
  "/id: drill-k8s-threats/{n;s/steps.k8s-gitops-up.outcome == 'success' \&\& //;}"
broken other-name "step k8s-smoke has another if:" "/id: k8s-smoke/{n;s/' k8s-smoke '/' drill-k8s-threats '/;}"
broken no-timeout "step drill-k8s-threats has no timeout-minutes" '/id: drill-k8s-threats/{n;n;d;}'
broken budget "gitops: timeout-minutes 200 holds less" 's/timeout-minutes: 205/timeout-minutes: 200/'
broken output "step smoke does not send its output to its file" 's|run: make smoke >"$SVP_VERIFY_OUT/logs/smoke.log" 2>&1 </dev/null|run: make smoke|'
broken continue "has continue-on-error" '/id: k8s-smoke/a\
        continue-on-error: true'
broken interpolated "puts an expression into a shell" 's|run: deploy/ci/verify-steps/steps.sh check|run: deploy/ci/verify-steps/steps.sh check ${{ inputs.targets }}|'
broken order "are not all there in that order" 's/SVP_VERIFY_STEP_NAMES: up smoke drill-obs-threats/SVP_VERIFY_STEP_NAMES: up drill-obs-threats smoke/'
broken cleanup "after the build step does not run always()" "/- name: make k8s-down\$/{n;s/if: always() \&\& /if: /;}"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
