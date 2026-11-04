#!/usr/bin/env bash
# Tests for deploy/ci/scan-gate.sh, in a throwaway copy of what it reads (deploy/ci/, deploy/k8s/lib.sh, the policy's
# values, the tree's .trivyignore.yaml and .grype.yaml) and a checkout of svp-frontend beside it; the variables of a
# GitHub Actions job are made up. A fake docker first on PATH stands in for trivy and grype, and hands the pinned
# conftest and yq of the ignore-file check to the real docker. Checked:
#   - the flags each pass gets (trivy convert of the secrets with no --severity and no ignore file, of the
#     vulnerabilities with --severity CRITICAL and the tree's .trivyignore.yaml, each reading only its own findings;
#     grype with --fail-on critical and the tree's .grype.yaml);
#   - a secret blocks even with --allow-critical, a CRITICAL blocks unless --allow-critical, a scanner that fails or a
#     report that is not trivy's exits 2; one summary line per scan, in the job's summary (and the log) in a job, in
#     the log on a machine;
#   - the check of the ignore files around their conftest policies (each rule is a case of make conftest-verify):
#     conftest and yq without network, as the caller, on the files read-only; a policy's message in the output; job
#     config refuses an expired entry and its grype rule, the image gates refuse a broken file but leave an expired
#     entry to trivy and job config; a key written twice, a file YAML cannot read, a misconfiguration for a path that is
#     no file fail;
#   - another repository's tree (SVP_CODE_ROOT, svp-frontend's checkout): its own .trivyignore.yaml and .grype.yaml
#     are read, and the gate stops, naming the file, when the tree has either not.
# Runs on macOS and Linux: Docker for conftest and yq (pulled once, then no network), no cluster.
#
# Usage, from anywhere: deploy/ci/scan-gate-test.sh
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

# on github|local COMMAND...: runs COMMAND with the variables of a made-up GitHub Actions job, or on a machine with
# none of them; the fakes of $work/bin first on PATH.
on() {
  local where=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_SHA -u RUNNER_TEMP -u SVP_CODE_ROOT
    PATH="$work/bin:$PATH" HOME="$work/home")
  case $where in
  github)
    "${base[@]}" GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com RUNNER_TEMP="$work/runner-temp" "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  esac
}
# fresh: empties the files a job's outputs and summary go to.
fresh() { : >"$work/output" && : >"$work/summary"; }
mkdir -p "$work/bin" "$work/home" "$work/runner-temp"

# The throwaway copy, and the checkout of svp-frontend (SVP_CODE_ROOT of its runs).
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
webtree=$work/svp-frontend
mkdir -p "$webtree"
digest_b=sha256:$(printf 'b%.0s' $(seq 64))

# scan-gate.sh. The verdicts are trivy's and grype's: here a fake docker stands in for both, records each call in
# docker.log (one line of arguments) and answers with the exit code the case sets: FAKE_TRIVY_VULNS for trivy convert
# with --severity (the vulnerability pass), FAKE_TRIVY_SECRETS for the one without (the secret pass), FAKE_GRYPE for
# grype, which also gets FAKE_GRYPE_JSON as its report. Each convert input is kept in fake/ to check what each pass
# reads. What the scanners do with these flags (an entry covering exactly its package version, a HIGH secret found
# without --severity, include-aliases) was run with the pinned images, not here.
# The pinned conftest and yq run for real (their calls in tools.log).
conftest_image=$(sed -n 's/^CONFTEST_IMAGE[[:space:]]*:=[[:space:]]*//p' "$src/Makefile")
yq_image=$(sed -n 's/^YQ_IMAGE[[:space:]]*:=[[:space:]]*//p' "$src/Makefile")
real_docker=$(command -v docker)
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
*" $CONFTEST_IMAGE "* | *" $YQ_IMAGE "*)
  printf '%s\n' "$*" >>"$FAKE_TOOLS_LOG"
  # FAKE_CONFTEST_EMPTY=1: conftest answers an empty result and exits 0; FAKE_YQ_PATHS_FAIL=1: the yq that lists the
  # paths of trivy-config-ignore.yaml fails.
  case " $* " in
  *" $CONFTEST_IMAGE "*) if [ "${FAKE_CONFTEST_EMPTY:-}" = 1 ]; then echo '[]' && exit 0; fi ;;
  *".misconfigurations[]"*) if [ "${FAKE_YQ_PATHS_FAIL:-}" = 1 ]; then echo "yq: broken" >&2 && exit 1; fi ;;
  esac
  exec "$FAKE_REAL_DOCKER" "$@"
  ;;
esac
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
# gate WHERE NAME WANT_EXIT [VAR=VALUE...] -- ARGS...: scan-gate.sh ARGS (on WHERE) with the fake scanners; ok
# when it exits WANT_EXIT. Output in gate.out and gate.err, the fake's calls in docker.log, conftest's and yq's in
# tools.log.
gate() {
  local where=$1 name=$2 want=$3 vars=() rc=0
  shift 3
  while [ "$1" != -- ]; do vars+=("$1") && shift; done
  shift
  fresh
  : >"$work/docker.log"
  : >"$work/tools.log"
  rm -f "$work/fake/"*
  on "$where" env TRIVY_IMAGE=trivy@sha256:1 GRYPE_IMAGE=grype@sha256:1 CONFTEST_IMAGE="$conftest_image" \
    YQ_IMAGE="$yq_image" SVP_TRIVY_CACHE="$work/cache/trivy" SVP_GRYPE_CACHE="$work/cache/grype" \
    FAKE_DOCKER_LOG="$work/docker.log" FAKE_TOOLS_LOG="$work/tools.log" FAKE_REAL_DOCKER="$real_docker" \
    FAKE_DOCKER_DIR="$work/fake" \
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
same "scan-gate.sh in a job: one line in the summary, the secret under it" '- gw linux/amd64 (trivy): CRITICAL 0, HIGH 1, secrets 1
secret  aws-key (HIGH) in app line 3' "$(cat "$work/summary")"
same "scan-gate.sh in a job: the counts in the log" "gw linux/amd64 (trivy): CRITICAL 0, HIGH 1, secrets 1" \
  "$(cat "$work/gate.out")"
check "scan-gate.sh in a job: the secret in the log too, rule, file and line" has "$work/gate.err" \
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
echo '{"inputs": {"services": "all"}}' >"$work/not-trivy.json"
gate local "scan-gate.sh: a report that is not trivy's image report is refused" 2 -- "gw linux/amd64" "$work/not-trivy.json"
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
same "scan-gate.sh --grype in a job: one line in the summary, the Critical under it" '- web linux/arm64 (grype): Critical 1, High 1, excepted by .grype.yaml 1
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

# The ignore files. Their rules are conftest policies, each case of them a test of deploy/ci/ignorefile-policies/
# (make conftest-verify); here what scan-gate.sh does around them: the pinned conftest and yq run without network, as the
# caller, on the files mounted read-only, the three files together; a policy's message reaches the output; job config
# (--check-ignorefile) checks with today, so an expired entry fails, the image gates do not and refuse a broken file;
# a key written twice and a file YAML cannot read fail; each path of trivy-config-ignore.yaml must be a file.
# ignorefiles NAME WANT_EXIT [WANT_LINE]: --check-ignorefile on the tree's files; ok when it exits WANT_EXIT and, when
# given, prints WANT_LINE.
ignorefiles() {
  gate local "scan-gate.sh --check-ignorefile: $1" "$2" -- --check-ignorefile
  [ -z "${3:-}" ] || check "scan-gate.sh --check-ignorefile: $1, says why" has "$work/gate.out" "$3"
}
# config_ignore PATH: a trivy-config-ignore.yaml of the copy with one entry, for PATH.
config_ignore() {
  printf 'misconfigurations:\n  - id: DS-0026\n    paths:\n      - %s\n    statement: a reason\n    expired_at: %s\n' \
    "$1" "$soon" >"$tree/deploy/ci/trivy-config-ignore.yaml"
}
config_ignore deploy/ci/common.sh
ignore_files
ignorefiles "an entry, its grype rule and a misconfiguration" 0 \
  "ok    .trivyignore.yaml .grype.yaml deploy/ci/trivy-config-ignore.yaml keep their rules"
check "scan-gate.sh --check-ignorefile: no scanner runs" test ! -s "$work/docker.log"
check "scan-gate.sh --check-ignorefile: conftest runs without network, read-only, as the caller, on the files read-only" grep -qF -- \
  "run --rm --network none --read-only --user $(id -u):$(id -g) -v $tree/.trivyignore.yaml:/in/.trivyignore.yaml:ro -v $tree/.grype.yaml:/in/.grype.yaml:ro -v $tree/deploy/ci/trivy-config-ignore.yaml:/in/deploy/ci/trivy-config-ignore.yaml:ro -v $tree/deploy/ci/ignorefile-policies:/policy:ro" \
  "$work/tools.log"
check "scan-gate.sh --check-ignorefile: the pinned conftest on the three files together" grep -qF -- \
  "$conftest_image test --combine --policy /policy --data /data/scan-gate.json --namespace trivyignore --namespace grypeignore --namespace configignore --output json --no-color .trivyignore.yaml .grype.yaml deploy/ci/trivy-config-ignore.yaml" \
  "$work/tools.log"
check "scan-gate.sh --check-ignorefile: the pinned yq looks for a key written twice" grep -qF -- "$yq_image eval-all" \
  "$work/tools.log"
# A conftest that ran no policy, or a yq that cannot list the paths, is no answer: the check fails, never passes.
FAKE_CONFTEST_EMPTY=1 ignorefiles "conftest answers no result" 1 "FAIL  conftest could not check the ignore files"
FAKE_YQ_PATHS_FAIL=1 ignorefiles "yq cannot list the paths of trivy-config-ignore.yaml" 1 \
  "FAIL  yq could not list the paths of deploy/ci/trivy-config-ignore.yaml"
gate local "scan-gate.sh: the image gate checks .trivyignore.yaml and .grype.yaml only" 0 -- "gw linux/amd64" \
  "$work/report.json"
check "scan-gate.sh: the image gate leaves trivy-config-ignore.yaml to job config" lacks "$work/tools.log" \
  trivy-config-ignore.yaml

# A broken file: the policy's message, in job config and in each image gate.
printf 'secrets:\n  - id: aws-access-key-id\n' >>"$tree/.trivyignore.yaml"
ignorefiles "a secrets section" 1 \
  "FAIL  .trivyignore.yaml: only vulnerabilities may be ignored, never secrets or anything else: secrets"
check "scan-gate.sh --check-ignorefile: a broken file says so last" has "$work/gate.err" \
  "an ignore file breaks its rules"
gate local "scan-gate.sh: the image gate refuses a secrets section of .trivyignore.yaml" 1 -- "gw linux/amd64" \
  "$work/report.json"
check "scan-gate.sh: the image gate says the ignore file breaks its rules" has "$work/gate.err" \
  "FAIL  an ignore file breaks its rules: fix it before anything is pushed"
check "scan-gate.sh: the image gate gives the policy's message" has "$work/gate.out" \
  "FAIL  .trivyignore.yaml: only vulnerabilities may be ignored"
{ echo "vulnerabilities:" && ignore_entry CVE-2021-44906 "$soon" pkg:npm/mini.st@1.2.5; } >"$tree/.trivyignore.yaml"
{ echo "ignore:" && grype_rule CVE-2021-44906 mini.st 1.2.5; } >"$tree/.grype.yaml"
grype_report "$work/grype.json" 0
grype_gate local "scan-gate.sh --grype: the image gate refuses a package.name with a regex metacharacter" 1 -- --grype \
  "web linux/arm64" "$work/leg"
check "scan-gate.sh --grype: the image gate says the regex name breaks the rules" has "$work/gate.err" \
  "FAIL  an ignore file breaks its rules: fix it before anything is pushed"

# What conftest's parser cannot show: a key written twice (it keeps the last one; trivy and grype refuse the file), at
# the root or in a rule; and a file YAML cannot read at all (\. is no escape in double quotes).
ignore_files
echo "vulnerabilities: []" >>"$tree/.trivyignore.yaml"
ignorefiles "vulnerabilities twice" 1 "FAIL  .trivyignore.yaml: key vulnerabilities twice (trivy and grype refuse the file)"
gate local "scan-gate.sh: the image gate refuses a key written twice" 1 -- "gw linux/amd64" "$work/report.json"
ignore_files
{ echo "ignore:" && grype_rule CVE-2026-1111 '.*' 1.0.0 && echo "      name: left-pad"; } >"$tree/.grype.yaml"
ignorefiles "package.name twice in a rule" 1 "FAIL  .grype.yaml: key name twice in ignore.0.package"
{ echo "ignore:" && grype_rule CVE-2026-1111 '"left\.pad"' 1.0.0; } >"$tree/.grype.yaml"
ignorefiles "a file YAML cannot read" 1 "FAIL  yq could not read the ignore files:"

# An expired entry: job config fails, on the entry and on the grype rule that would go on covering its match; the image
# gates do not (trivy drops the entry, so its match blocks again if CRITICAL).
ignore_files
{ echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$today" pkg:npm/left-pad@1.0.0; } >"$tree/.trivyignore.yaml"
ignorefiles "an expired entry" 1 "FAIL  .trivyignore.yaml: entry CVE-2026-1111 expired on $today"
check "scan-gate.sh --check-ignorefile: the grype rule of an expired entry fails too" has "$work/gate.out" \
  "rule CVE-2026-1111 left-pad@1.0.0 is 0 entries of .trivyignore.yaml in force"
gate local "scan-gate.sh: the image gate leaves an expired entry to trivy" 0 -- "gw linux/amd64" "$work/report.json"
grype_gate local "scan-gate.sh --grype: the image gate leaves an expired entry to job config" 0 -- --grype \
  "web linux/arm64" "$work/leg"

# Each path of trivy-config-ignore.yaml is a file of the repository: not a file gone, not a directory (a whole tree).
ignore_files
config_ignore deploy/ci/gone.sh
ignorefiles "a misconfiguration for a file gone" 1 \
  "FAIL  deploy/ci/trivy-config-ignore.yaml: path deploy/ci/gone.sh is not a file of the repository"
config_ignore deploy/ci
ignorefiles "a misconfiguration for a directory" 1 \
  "FAIL  deploy/ci/trivy-config-ignore.yaml: path deploy/ci is not a file of the repository"
config_ignore deploy/ci/common.sh
rm -f "$tree/.trivyignore.yaml" "$tree/.grype.yaml"

# Another repository's tree (SVP_CODE_ROOT): its own .trivyignore.yaml and .grype.yaml, which must both be there.
{ echo "vulnerabilities:" && ignore_entry CVE-2026-1111 "$soon" pkg:npm/left-pad@1.0.0; } >"$webtree/.trivyignore.yaml"
{ echo "ignore:" && grype_rule CVE-2026-1111 left-pad 1.0.0; } >"$webtree/.grype.yaml"
grype_gate local "scan-gate.sh --grype, svp-frontend's tree: its files pass" 0 SVP_CODE_ROOT="$webtree" -- --grype \
  "web linux/arm64" "$work/leg"
check "scan-gate.sh --grype, svp-frontend's tree: grype reads its .grype.yaml" grep -qF -- \
  "-v $webtree/.grype.yaml:/ignore/grype.yaml:ro" "$work/docker.log"
gate local "scan-gate.sh --check-ignorefile, svp-frontend's tree: its files pass" 0 SVP_CODE_ROOT="$webtree" -- \
  --check-ignorefile
check "scan-gate.sh --check-ignorefile, svp-frontend's tree: conftest reads its .grype.yaml" grep -qF -- \
  "-v $webtree/.grype.yaml:/in/.grype.yaml:ro" "$work/tools.log"
for file in .trivyignore.yaml .grype.yaml; do
  mv "$webtree/$file" "$work/web-ignore"
  gate local "scan-gate.sh, svp-frontend's tree without $file" 1 SVP_CODE_ROOT="$webtree" -- "web linux/arm64" \
    "$work/report.json"
  check "scan-gate.sh, svp-frontend's tree without $file: names the file" has "$work/gate.err" \
    "$webtree has no file $file: SVP_CODE_ROOT must be the checkout whose code is built"
  check "scan-gate.sh, svp-frontend's tree without $file: no scanner runs" test ! -s "$work/docker.log"
  mv "$work/web-ignore" "$webtree/$file"
done

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
