#!/usr/bin/env bash
# scan-gate.sh: the gate between scanning an image and pushing or attesting it. The verdict is the scanners' own, from
# their flags; this script picks the flags, reads the exit codes and prints one line per scan for the job summary.
#
#   scan-gate.sh [--allow-critical] LABEL REPORT
#     REPORT is the JSON of `trivy image --scanners vuln,secret` with every severity and .trivyignore.yaml (the record
#     the vuln attestation and the SARIF are made from); LABEL names the image in the output (gateway linux/amd64).
#     trivy convert reads it twice: the vulnerabilities with --severity CRITICAL --ignorefile .trivyignore.yaml
#     --exit-code, the secrets with --exit-code and no --severity (a severity filter would hide a HIGH secret). Each
#     pass gets only its own part of the report, so neither counts the other's findings.
#   scan-gate.sh [--allow-critical] --grype LABEL DIR
#     Runs grype (grype_sbom of common.sh) on DIR/sbom.spdx.json, the SBOM syft wrote of the image, with
#     --fail-on critical and .grype.yaml, and writes DIR/grype.json and DIR/grype.sarif.raw. syft finds what was
#     installed without a package manager, such as the node binary of the web image, which trivy does not list.
#   scan-gate.sh --check-ignorefile
#     Checks the rules of .trivyignore.yaml and .grype.yaml (check_ignorefiles below, the rules themselves in
#     deploy/ci/ignorefile-policies/), with no image and no report, and those of deploy/ci/trivy-config-ignore.yaml, the
#     misconfigurations make trivy-config leaves out. Job config of ci.yml runs it on every pull request and push: a pull
#     request that changes nothing but an ignore file builds no image.
#
# Blocks (exit 1) on:
#   - any secret, whatever its severity: a public package and its signature cannot be taken back, so a secret pushed
#     once is leaked for good. There is no way around it: .trivyignore.yaml may hold only vulnerabilities, and no
#     --skip-files, --skip-dirs or --secret-config is ever passed to trivy.
#   - any CRITICAL vulnerability left after the exceptions, fixed upstream or not, in trivy's report or grype's.
#     --allow-critical lets CRITICAL through (only for the drill image drill-vulnerable and for the daily rescan, which
#     records the real result); it never lets a secret through.
#   - an ignore file that breaks its rules (below; an expired entry aside, which only job config fails on).
# HIGH and below are only reported: counts in the job summary, details in the SARIF. Exit 2: the scan could not be
# read or run (REPORT is not a trivy image report, trivy or grype failed, the grype DB could not be fetched).
#
# Prints counts and, for findings that block, trivy's table of the CRITICAL vulnerabilities, and rule, file and line of
# each secret: never the matched text (trivy masks secrets in its findings anyway; the raw report is never printed).
#
# The exceptions are those of the tree being scanned (code_root of common.sh): this checkout's, or those of the checkout
# of another repository named by SVP_CODE_ROOT (its CI runs this script from a pinned checkout of this one), where both
# files must exist: a tree without them is the wrong tree, not one without exceptions.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"
require_code_files .trivyignore.yaml .grype.yaml
config_ignore=$ci_dir/trivy-config-ignore.yaml

allow_critical=false
mode=trivy
if [ "${1:-}" = --check-ignorefile ]; then
  [ $# -eq 1 ] || fail "usage: scan-gate.sh --check-ignorefile"
  mode=check
else
  if [ "${1:-}" = --allow-critical ]; then
    allow_critical=true
    shift
  fi
  if [ "${1:-}" = --grype ]; then
    mode=grype
    shift
  fi
  [ $# -eq 2 ] || fail "usage: scan-gate.sh [--allow-critical] [--grype] LABEL REPORT|DIR | --check-ignorefile"
fi
label=${1:-} input=${2:-}
tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# check_ignorefiles live|gate: the rules of .trivyignore.yaml and .grype.yaml of the tree (each when present) and, live
# (job config), of deploy/ci/trivy-config-ignore.yaml too. The rules are conftest policies on the parsed files, written
# and explained in deploy/ci/ignorefile-policies/ (tested by make conftest-verify), run on the files together
# (--combine: each rule of .grype.yaml must be an entry of .trivyignore.yaml). Live, an expired entry breaks the rules;
# the image gates leave it to trivy, which drops it. Two checks stay here, as the policies cannot make them: no mapping
# of a file has a key twice (conftest's parser keeps the last one, trivy and grype refuse the file; yq sees every key),
# and each path of trivy-config-ignore.yaml is a file of the repository. conftest and yq run from the images the
# Makefile pins (CONFTEST_IMAGE, YQ_IMAGE), without network, as the caller, with the files mounted read-only. Prints a
# FAIL line per broken rule; live, an ok line when none is.
check_ignorefiles() {
  local live=false files=() mounts=() image failed=0 out rc=0 path config=${config_ignore#"$repo_root"/}
  [ "$1" = gate ] || live=true
  if [ -f "$trivyignore" ]; then files+=(.trivyignore.yaml) && mounts+=(-v "$trivyignore:/in/.trivyignore.yaml:ro"); fi
  if [ -f "$grypeignore" ]; then files+=(.grype.yaml) && mounts+=(-v "$grypeignore:/in/.grype.yaml:ro"); fi
  if [ "$live" = true ] && [ -f "$config_ignore" ]; then
    files+=("$config") && mounts+=(-v "$config_ignore:/in/$config:ro")
  fi
  [ ${#files[@]} -gt 0 ] || return 0

  # stderr apart from the output read below: docker writes the progress of a first pull there.
  image=$(tool_image YQ_IMAGE) || return 1
  out=$(in_container "$image" eval-all --no-doc '.. | select(tag == "!!map") | filename as $f | (path | join(".")) as $p
    | keys | group_by(.) | .[] | select(length > 1) | $f + ": key " + .[0] + " twice"
    + (if $p == "" then "" else " in " + $p end) + " (trivy and grype refuse the file)"' "${files[@]}" 2>"$tmp/err") || {
    printf 'FAIL  yq could not read the ignore files: %s\n' "$(cat "$tmp/err")"
    return 1
  }
  [ -z "$out" ] || { sed 's/^/FAIL  /' <<<"$out" && failed=1; }

  image=$(tool_image CONFTEST_IMAGE) || return 1
  printf '{"scan_gate": {"today": "%s", "live": %s}}\n' "$(date -u +%F)" "$live" >"$tmp/scan-gate.json"
  mounts+=(-v "$ci_dir/ignorefile-policies:/policy:ro" -v "$tmp/scan-gate.json:/data/scan-gate.json:ro")
  out=$(in_container "$image" test --combine --policy /policy --data /data/scan-gate.json --namespace trivyignore \
    --namespace grypeignore --namespace configignore --output json --no-color "${files[@]}" 2>"$tmp/err") || rc=$?
  # An answer that ran no policy at all (no result, or results with neither a success nor a failure) is no answer.
  jq -e 'type == "array" and length > 0 and ([.[] | (.successes // 0) + (.failures // [] | length)] | add) > 0' \
    <<<"$out" >/dev/null 2>&1 || {
    printf 'FAIL  conftest could not check the ignore files: %s\n' "$(cat "$tmp/err")"
    return 1
  }
  jq -r '.[].failures[]?.msg | "FAIL  " + .' <<<"$out"
  [ "$rc" -eq 0 ] || failed=1

  if [ "$live" = true ] && [ -f "$config_ignore" ]; then
    image=$(tool_image YQ_IMAGE) || return 1
    # The paths as the policy reads them; a file of another shape lists none here, and failed above.
    in_container "$image" '.misconfigurations[] | .paths[] | select(tag == "!!str")' "$config" >"$tmp/paths" 2>"$tmp/err" || {
      printf 'FAIL  yq could not list the paths of %s: %s\n' "$config" "$(cat "$tmp/err")"
      return 1
    }
    while IFS= read -r path; do
      [ -f "$repo_root/$path" ] || {
        echo "FAIL  $config: path $path is not a file of the repository"
        failed=1
      }
    done <"$tmp/paths"
  fi

  [ "$failed" -ne 0 ] || [ "$live" = false ] || echo "ok    ${files[*]} keep their rules"
  return "$failed"
}
# in_container IMAGE ARGS...: IMAGE with ARGS, without network, as the caller, with a read-only root file system, in /in
# with the volumes of mounts (of check_ignorefiles, the caller).
in_container() {
  docker_ run --rm --network none --read-only --user "$(id -u):$(id -g)" "${mounts[@]}" -w /in "$@"
}

if [ "$mode" = check ]; then
  check_ignorefiles live || fail "an ignore file breaks its rules"
  exit 0
fi

blocked=0
if ! check_ignorefiles gate; then
  echo "FAIL  an ignore file breaks its rules: fix it before anything is pushed" >&2
  blocked=1
fi

# summary LINE: one line of the job summary per scan; where the summary is a page of its own, in the log too.
summary() {
  step_summary "- $1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1"
}

if [ "$mode" = grype ]; then
  fail_on=()
  [ "$allow_critical" = true ] || fail_on=(--fail-on critical)
  rc=0
  grype_sbom "$input" ${fail_on[@]+"${fail_on[@]}"} || rc=$?
  # grype exits 2 when a match is at or above --fail-on, 1 when it could not scan.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] || ! jq -e '.descriptor.name == "grype"' "$input/grype.json" >/dev/null 2>&1; then
    echo "FAIL  $label: grype could not scan $input/sbom.spdx.json" >&2
    exit 2
  fi
  read -r critical high excepted < <(jq -r '[([.matches[] | select(.vulnerability.severity == "Critical")] | length),
    ([.matches[] | select(.vulnerability.severity == "High")] | length), (.ignoredMatches // [] | length)] | @tsv' \
    "$input/grype.json")
  summary "$label (grype): Critical $critical, High $high, excepted by .grype.yaml $excepted"
  if [ "$critical" -gt 0 ]; then
    jq -r '.matches[] | select(.vulnerability.severity == "Critical")
      | "critical  \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) \(.artifact.purl // "no purl")"
        + " (fixed: \(.vulnerability.fix.versions // [] | join(", ") | if . == "" then "none" else . end))"' \
      "$input/grype.json" | step_summary_tee >&2
  fi
  if [ "$rc" -eq 2 ]; then
    echo "FAIL  $label (grype): Critical vulnerabilities; nothing is pushed, signed or attested" >&2
    blocked=1
  elif [ "$critical" -gt 0 ]; then
    echo "note  $label (grype): $critical Critical vulnerabilities let through (--allow-critical)" >&2
  fi
  [ "$blocked" -eq 0 ] && echo "ok    $label (grype) passes the scan gate"
  exit "$blocked"
fi

report=$input
jq -e '.SchemaVersion == 2 and (.Metadata.ImageID | test("^sha256:[0-9a-f]{64}$"))' "$report" >/dev/null 2>&1 || {
  echo "FAIL  $label: $report is not a trivy image JSON report (SchemaVersion 2 with Metadata.ImageID)" >&2
  exit 2
}
read -r critical high secrets < <(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] as $s
  | [([$s[] | select(. == "CRITICAL")] | length), ([$s[] | select(. == "HIGH")] | length),
    ([.Results[]?.Secrets[]?] | length)] | @tsv' "$report")
summary "$label (trivy): CRITICAL $critical, HIGH $high, secrets $secrets"

# Each pass reads only its own findings: the vulnerabilities without the secrets, the secrets without the
# vulnerabilities. trivy exits 5 (--exit-code) for a finding, 1 when it fails.
jq 'del(.Results[]?.Secrets)' "$report" >"$tmp/vulnerabilities.json" &&
  jq 'del(.Results[]?.Vulnerabilities)' "$report" >"$tmp/secrets.json" || fail "split $report"
trivy_mounts=(-v "$tmp:/in:ro")
ignore=(--ignorefile '')
if [ -f "$trivyignore" ]; then
  trivy_mounts+=(-v "$trivyignore:/ignore.yaml:ro")
  ignore=(--ignorefile /ignore.yaml)
fi
# convert ARGS...: trivy convert with ARGS; sets rc to 0 (nothing found) or 5 (found), and stops (exit 2) when trivy
# failed.
convert() {
  rc=0
  trivy_ convert --exit-code 5 "$@" >&2 || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ] || {
    echo "FAIL  $label: trivy could not read $report" >&2
    exit 2
  }
}
convert --format json --output /dev/null --ignorefile '' /in/secrets.json
if [ "$rc" -ne 0 ]; then
  echo "FAIL  $label: secrets found; nothing is pushed, signed or attested" >&2
  # Rule, file and line only: the matched text stays out of logs and summaries of a public repository.
  jq -r '.Results[]? | .Target as $t | .Secrets[]? | "secret  \(.RuleID) (\(.Severity)) in \($t) line \(.StartLine)"' \
    "$report" | step_summary_tee >&2
  blocked=1
fi
convert --format table --table-mode detailed --severity CRITICAL "${ignore[@]}" /in/vulnerabilities.json
if [ "$rc" -ne 0 ]; then
  if [ "$allow_critical" = true ]; then
    echo "note  $label (trivy): CRITICAL vulnerabilities let through (--allow-critical)" >&2
  else
    echo "FAIL  $label (trivy): CRITICAL vulnerabilities; nothing is pushed, signed or attested" >&2
    blocked=1
  fi
fi
[ "$blocked" -eq 0 ] && echo "ok    $label (trivy) passes the scan gate"
exit "$blocked"
