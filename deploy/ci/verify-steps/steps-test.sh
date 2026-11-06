#!/usr/bin/env bash
# Tests for steps.sh and verify.yml job invariants (step order, if conditions, timeouts, no ${{ }} in run).
# Runs on macOS and Linux (bash, jq, yq through Docker; no network, no cluster) on valid and broken verify.yml variants.
# Usage, from anywhere: deploy/ci/verify-steps/steps-test.sh
# Design notes: docs/reference/ci.md.
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
gitops="k8s-gitops-up drill-k8s-gitops gitops-admission-metrics k8s-smoke drill-k8s-reloader drill-k8s-supplychain drill-k8s-threats"
dev="k8s-up k8s-smoke drill-k8s-reloader drill-k8s-supplychain"

# steps NAME NAMES TARGETS ARG [VAR=VALUE...]: runs steps.sh ARG with NAMES and TARGETS, logging to $work/NAME.log.
steps() {
  local name=$1 names=$2 targets=$3 arg=$4 rc=0
  shift 4
  env -u GITHUB_ACTIONS -u SVP_VERIFY_STEPS SVP_VERIFY_STEP_NAMES="$names" SVP_VERIFY_TARGETS="$targets" \
    SVP_VERIFY_OUT="$work/$name.out" "$@" "$here/steps.sh" "$arg" >"$work/$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}

same "check: no targets passes" 0 "$(steps all "$gitops" "" check)"
has all "every step is named" "verify steps: every step ($gitops)"
same "check: steps of the job pass" 0 "$(steps two "$gitops" "drill-k8s-threats  k8s-smoke" check)"
has two "the build step is named as always running" "verify steps: k8s-gitops-up (the build step always runs) and drill-k8s-threats  k8s-smoke"
same "check: the build step may be named" 0 "$(steps build "$compose" up check)"
same "check: a name that is no step of the job stops it" 2 "$(steps unknown "$gitops" "drill-k8s-threats drill-k8s-thraets" check)"
has unknown "it names the name and the job's steps" "not a step of this job: drill-k8s-thraets (its steps: $gitops); nothing started"
same "check: a step of the other job is unknown" 2 "$(steps other "$compose" k8s-smoke check)"
same "check: the build step of job gitops is no step of dev-k3d" 2 "$(steps dev-other "$dev" k8s-gitops-up check)"
has other "the steps of compose-obs are listed" "(its steps: $compose)"
same "check: a check of the scenario that is now a test of drill-k8s-gitops is unknown" 2 \
  "$(steps old "$gitops" gitops-external-secrets check)"
same "check: a list with another character stops it" 2 "$(steps bad "$gitops" $'k8s-smoke\n::warning::BAD-TARGET-MARKER' check)"
lacks bad "the rejected list is not printed back" BAD-TARGET-MARKER
has bad "it says why" "targets holds a character other than a-z, 0-9, - and space; nothing started"
same "check: a job without steps stops it" 2 "$(steps none "" "" check)"
same "steps.sh: another argument stops it" 2 "$(steps usage "$gitops" "" run)"

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
    gitops-admission-metrics skipped 'not in targets' k8s-smoke success '' drill-k8s-reloader absent 'no step of that id in the job' \
    drill-k8s-supplychain cancelled '' drill-k8s-threats absent 'no step of that id in the job')")" "$(cat "$work/table.out/results.tsv")"
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

yq_image=$(sed -n 's/^YQ_IMAGE[[:space:]]*:=[[:space:]]*//p' "$src/Makefile")
# workflow_json FILE: returns workflow FILE parsed as JSON via yq.
workflow_json() {
  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(dirname "$1"):/w:ro" "$yq_image" -o json \
    "/w/$(basename "$1")"
}
# problems FILE: outputs rule violations found in workflow FILE, or empty if valid.
problems() {
  workflow_json "$1" | jq -r '
    def want_if($build; $name):
      "${{ !cancelled() && steps.\($build).outcome == '"'"'success'"'"' && (!inputs.targets || contains(format('"'"' {0} '"'"', inputs.targets), '"'"' \($name) '"'"')) }}";
    def after: "always() && steps.ref.outcome == '"'"'success'"'"'";
    (if .on.workflow_dispatch.inputs.scenario.options != ["compose-obs", "gitops", "dev-k3d"] then "scenario: the options are compose-obs, gitops and dev-k3d" else empty end),
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
       then "\($job): timeout-minutes \($j["timeout-minutes"]) holds less than the steps'"'"' \($sum), 20 of setup and 25 after them" else empty end),
      ([$steps[] | select(.name == "New values of drill-k8s-reloader")] | first // null) as $values
      | (if ($names | index("drill-k8s-reloader")) == null then empty
         elif $values == null or $values.i > ($b.i // -1) or $values.if != null
           or ($values.run | contains("deploy/k8s/drills/reloader/new-values.sh \"$RUNNER_TEMP/verify-reloader/new-values\"") | not)
           or ($values.run | contains("echo \"SVP_DRILL_NEW_VALUES=$RUNNER_TEMP/verify-reloader/new-values\" >>\"$GITHUB_ENV\"") | not)
         then "\($job): the new values of drill-k8s-reloader are not made and masked by a step of their own before the build step" else empty end),
      ([$steps[] | select(.name == "Check gitops_ref")] | first // null) as $refcheck
      | (if $j.env.SVP_GITOPS_REF == null then empty
         elif $refcheck == null or $refcheck.i > ($clone.i // -1) then "\($job): gitops_ref is not checked before the clone of svp-gitops"
         elif ($clone.run | contains("make gitops-clone GITOPS_REF=\"$SVP_GITOPS_REF\"") | not) then "\($job): svp-gitops is not cloned at gitops_ref"
         else empty end))'
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
same "workflow: the job dev-k3d lists its steps" "$dev" "$(workflow_json "$wf" | jq -r '.jobs["dev-k3d"].env.SVP_VERIFY_STEP_NAMES')"
same "workflow: dev-k3d runs on a dispatch of its scenario only (no schedule)" "inputs.scenario == 'dev-k3d'" \
  "$(workflow_json "$wf" | jq -r '.jobs["dev-k3d"].if')"
same "workflow: dev-k3d reads gitops_ref through env only" '${{ inputs.gitops_ref }}' \
  "$(workflow_json "$wf" | jq -r '.jobs["dev-k3d"].env.SVP_GITOPS_REF')"
same "workflow: gitops_ref defaults to main" main "$(workflow_json "$wf" | jq -r '.on.workflow_dispatch.inputs.gitops_ref.default')"
same "workflow: dev-k3d's supply chain step puts the policy in Enforce for the drill" "1 deploy/ci/verify-steps/supplychain.sh" \
  "$(workflow_json "$wf" | jq -r '.jobs["dev-k3d"].steps[] | select(.id == "drill-k8s-supplychain") | "\(.env.SUPPLYCHAIN_ENFORCE_TMP) \(.run | split(" ")[0])"')"

refcheck=$(workflow_json "$wf" | jq -r '.jobs["dev-k3d"].steps[] | select(.name == "Check gitops_ref") | .run')
# gitops_ref NAME VALUE: executes Check gitops_ref logic with SVP_GITOPS_REF=VALUE, logging to $work/NAME.log.
gitops_ref() {
  local rc=0
  SVP_GITOPS_REF=$2 bash -c "$refcheck" >"$work/$1.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
same "gitops_ref: main passes" 0 "$(gitops_ref ref-main main)"
same "gitops_ref: a full commit SHA passes" 0 "$(gitops_ref ref-sha "$(printf '0123456789abcdef%.0s' 1 2)01234567")"
same "gitops_ref: a branch name fails" 1 "$(gitops_ref ref-branch feat/reloader)"
same "gitops_ref: a short SHA fails" 1 "$(gitops_ref ref-short 0123456)"
same "gitops_ref: an upper-case SHA fails" 1 "$(gitops_ref ref-upper "$(printf '0123456789ABCDEF%.0s' 1 2)01234567")"
same "gitops_ref: empty fails" 1 "$(gitops_ref ref-empty "")"
same "gitops_ref: a workflow command fails" 1 "$(gitops_ref ref-inject $'main\n::warning::BAD-REF-MARKER')"
lacks ref-inject "the rejected value is not printed back" BAD-REF-MARKER
has ref-branch "it says why" "gitops_ref is main or a full commit SHA of svp-gitops (40 hex); nothing started"

mkdir -p "$work/broken"
# broken NAME WANT SED: applies sed expression to workflow and asserts problems output contains WANT.
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
broken budget "gitops: timeout-minutes 245 holds less" 's/timeout-minutes: 250/timeout-minutes: 245/'
broken dev-budget "dev-k3d: timeout-minutes 200 holds less" 's/timeout-minutes: 210/timeout-minutes: 200/'
broken dev-reloader-if "step drill-k8s-reloader has another if:" \
  "/id: drill-k8s-reloader/{n;s/steps.k8s-up.outcome == 'success' \&\& //;}"
broken values-after "dev-k3d: the new values of drill-k8s-reloader are not made and masked by a step of their own before the build step" \
  '/- name: New values of drill-k8s-reloader/,/>>"$GITHUB_ENV"/d
/id: k8s-up$/i\
      - name: New values of drill-k8s-reloader\
        run: |\
          install -d -m 700 "$RUNNER_TEMP/verify-reloader"\
          deploy/k8s/drills/reloader/new-values.sh "$RUNNER_TEMP/verify-reloader/new-values"\
          echo "SVP_DRILL_NEW_VALUES=$RUNNER_TEMP/verify-reloader/new-values" >>"$GITHUB_ENV"'
broken no-values "gitops: the new values of drill-k8s-reloader are not made" '/- name: New values of drill-k8s-reloader/,/>>"$GITHUB_ENV"/d'
broken ref-unchecked "dev-k3d: gitops_ref is not checked before the clone" 's/- name: Check gitops_ref/- name: Check something/'
broken ref-ignored "dev-k3d: svp-gitops is not cloned at gitops_ref" 's/make gitops-clone GITOPS_REF="$SVP_GITOPS_REF"/make gitops-clone/'
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
