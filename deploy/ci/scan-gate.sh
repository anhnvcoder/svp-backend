#!/usr/bin/env bash
# scan-gate.sh: the scan gate outside the image pipeline (image-leg gates its own legs) and the ignore-file check.
# Usage: scan-gate.sh [--allow-critical] LABEL REPORT | --grype LABEL DIR | --check-ignorefile
# --allow-critical (the daily rescan) lets CRITICAL and HIGH with a fix through in trivy's report, never a secret.
# Never prints the raw report: counts, CRITICAL findings, HIGH with a fix, and rule, file and line of each secret.

# Blocks (exit 1) on any secret, whatever its severity (a pushed package cannot be taken back, so nothing ignores one),
# on CRITICAL or HIGH with a fix left after .trivyignore.yaml and .grype.yaml, and on an ignore file breaking its rules.
# Exit 2: the scan could not be read or run. Each rule of .grype.yaml must match an entry of .trivyignore.yaml.
# Design notes: docs/reference/ci.md.
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
  elif [ "${1:-}" = --grype ]; then
    mode=grype
    shift
  fi
  [ $# -eq 2 ] || fail "usage: scan-gate.sh [--allow-critical] LABEL REPORT | --grype LABEL DIR | --check-ignorefile"
fi
label=${1:-} input=${2:-}
tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# check_ignorefiles live|gate: checks .trivyignore.yaml and .grype.yaml (live, also trivy-config-ignore.yaml) with the
# conftest policies of ignorefile-policies/, plus what they cannot: a key written twice, and a path that is no file.
# Live (job config) an expired entry fails; the gates of a report leave it to trivy. conftest and yq run offline.
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
  rc=0
  grype_sbom "$input" --fail-on critical || rc=$?
  # grype exits 2 when a match is at or above --fail-on, 1 when it could not scan.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] || ! jq -e '.descriptor.name == "grype"' "$input/grype.json" >/dev/null 2>&1; then
    echo "FAIL  $label: grype could not scan $input/sbom.spdx.json" >&2
    exit 2
  fi
  read -r critical high fixed excepted < <(jq -r '[.matches[].vulnerability] as $v
    | [([$v[] | select(.severity == "Critical")] | length), ([$v[] | select(.severity == "High")] | length),
      ([$v[] | select(.severity == "High" and .fix.state == "fixed")] | length), (.ignoredMatches // [] | length)]
    | @tsv' "$input/grype.json")
  summary "$label (grype): Critical $critical, High $high (with a fix $fixed), excepted by .grype.yaml $excepted"
  if [ "$critical" -gt 0 ]; then
    jq -r '.matches[] | select(.vulnerability.severity == "Critical")
      | "critical  \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) \(.artifact.purl // "no purl")"
        + " (fixed: \(.vulnerability.fix.versions // [] | join(", ") | if . == "" then "none" else . end))"' \
      "$input/grype.json" | step_summary_tee >&2
  fi
  if [ "$rc" -eq 2 ]; then
    echo "FAIL  $label (grype): Critical vulnerabilities; nothing is pushed, signed or attested" >&2
    blocked=1
  fi
  rc=0
  "$ci_dir/image-guard.sh" fixed-high grype "$label" "$input/grype.json" || rc=$?
  [ "$rc" -le 1 ] || exit 2
  if [ "$rc" -eq 1 ]; then
    echo "FAIL  $label (grype): High vulnerabilities with a fix; nothing is pushed, signed or attested" >&2
    blocked=1
  fi
  [ "$blocked" -eq 0 ] && echo "ok    $label (grype) passes the scan gate"
  exit "$blocked"
fi

report=$input
jq -e '.SchemaVersion == 2 and (.Metadata.ImageID | test("^sha256:[0-9a-f]{64}$"))' "$report" >/dev/null 2>&1 || {
  echo "FAIL  $label: $report is not a trivy image JSON report (SchemaVersion 2 with Metadata.ImageID)" >&2
  exit 2
}
read -r critical high fixed secrets < <(jq -r '[.Results[]?.Vulnerabilities[]?] as $v
  | [([$v[] | select(.Severity == "CRITICAL")] | length), ([$v[] | select(.Severity == "HIGH")] | length),
    ([$v[] | select(.Severity == "HIGH" and .Status == "fixed")] | length), ([.Results[]?.Secrets[]?] | length)]
  | @tsv' "$report")
summary "$label (trivy): CRITICAL $critical, HIGH $high (with a fix $fixed), secrets $secrets"

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
trivy_ convert --format json "${ignore[@]}" /in/vulnerabilities.json >"$tmp/kept.json" || {
  echo "FAIL  $label: trivy could not read $report" >&2
  exit 2
}
rc=0
"$ci_dir/image-guard.sh" fixed-high trivy "$label" "$tmp/kept.json" || rc=$?
[ "$rc" -le 1 ] || exit 2
if [ "$rc" -eq 1 ]; then
  if [ "$allow_critical" = true ]; then
    echo "note  $label (trivy): HIGH vulnerabilities with a fix let through (--allow-critical)" >&2
  else
    echo "FAIL  $label (trivy): HIGH vulnerabilities with a fix; nothing is pushed, signed or attested" >&2
    blocked=1
  fi
fi
[ "$blocked" -eq 0 ] && echo "ok    $label (trivy) passes the scan gate"
exit "$blocked"
