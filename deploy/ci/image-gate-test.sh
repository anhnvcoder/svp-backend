#!/usr/bin/env bash
# Tests of the gates of the image pipeline with the real tools: the steps of .github/actions/image-leg/action.yml, read
# from that file with the pinned yq (never copied here), run as the runner runs a step of shell bash, with the trivy,
# syft, grype and conftest the Makefile pins, on the fixtures of deploy/ci/testdata/image-gate/ (trivy reports, an SPDX
# document, a tar that is no image). No image of a service is built, no registry is logged in to, no vulnerability DB
# is downloaded: trivy convert reads a report with no DB, and grype runs with its network cut, as when its DB cannot be
# fetched. Checked, each a negative case of the pipeline's gates beside its control:
#   - trivy gate: a CRITICAL blocks, unless allow-critical (drill-vulnerable); an entry of .trivyignore.yaml in force
#     covers it, an expired one no longer does; a HIGH secret blocks (no --severity on the secret pass), with
#     allow-critical too, and only its rule, file and line are printed; a report that is not trivy's, or one trivy
#     cannot read (an exit code that is neither 0 nor 5), is no pass;
#   - grype: no DB it can fetch (exit 1) is no pass, with allow-critical too;
#   - syft: a tar it cannot read fails the leg; a real image tar gives an SPDX document;
#   - the rules of the ignore files the leg checks first: an expired entry blocks;
#   - no docker call of these steps gets DOCKER_DEFAULT_PLATFORM: each step runs with it set to linux/amd64, as the shell
#     of this machine sets it for other projects, and a docker first on PATH refuses a call that still carries it.
# Runs on macOS and Linux with Docker (the pinned images pulled once).
#
# Usage, from anywhere: deploy/ci/image-gate-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
fixtures=$here/testdata/image-gate
action=$src/.github/actions/image-leg/action.yml
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
pinned() { sed -n "s/^$1[[:space:]]*:=[[:space:]]*//p" "$src/Makefile"; }
docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

yq_image=$(pinned YQ_IMAGE) trivy_image=$(pinned TRIVY_IMAGE) syft_image=$(pinned SYFT_IMAGE) grype_image=$(pinned GRYPE_IMAGE)
for image in "$yq_image" "$trivy_image" "$syft_image" "$grype_image"; do docker_ pull -q "$image" >/dev/null; done
# yq_ EXPRESSION: the pinned yq on the action file, without network.
yq_() { docker_ run --rm -i --network none "$yq_image" eval "$1" - <"$action"; }

# step ID WANT_EXIT [VAR=VALUE...]: the step ID of image-leg with the variables of its env: given here (each must be a
# key of that env:, so the test sets nothing the action does not), plus GITHUB_STEP_SUMMARY and DOCKER_DEFAULT_PLATFORM;
# ok when it exits WANT_EXIT. Output in step.out and step.err, the job summary in summary.
step() {
  local id=$1 want=$2 keys script var rc=0
  shift 2
  script=$(yq_ ".runs.steps[] | select(.id == \"$id\") | .run")
  keys=$(yq_ ".runs.steps[] | select(.id == \"$id\") | .env | keys | .[]")
  same "image-leg step $id: shell bash" bash "$(yq_ ".runs.steps[] | select(.id == \"$id\") | .shell")"
  for var in "$@"; do
    grep -qxF -- "${var%%=*}" <<<"$keys" || fail "image-leg step $id: ${var%%=*} is no key of its env:"
  done
  : >"$work/summary"
  env -u GITHUB_ACTIONS -u GITHUB_OUTPUT DOCKER_DEFAULT_PLATFORM=linux/amd64 PATH="$work/bin:$PATH" \
    GITHUB_STEP_SUMMARY="$work/summary" "$@" bash --noprofile --norc -eo pipefail -c "$script" \
    >"$work/step.out" 2>"$work/step.err" || rc=$?
  same "$name (exit $want)" "$want" "$rc"
}
mkdir -p "$work/bin" "$work/out" "$work/cache/trivy" "$work/cache/grype"
# The docker the steps call: the real one, unless the call still carries DOCKER_DEFAULT_PLATFORM (logged in
# platform.log, refused); while the file offline exists, every container runs with no network.
real_docker=$(command -v docker)
cat >"$work/bin/docker" <<EOF
#!/usr/bin/env bash
if [ -n "\${DOCKER_DEFAULT_PLATFORM+set}" ]; then
  echo "DOCKER_DEFAULT_PLATFORM=\$DOCKER_DEFAULT_PLATFORM docker \$*" >>"$work/platform.log"
  echo "test docker: DOCKER_DEFAULT_PLATFORM=\$DOCKER_DEFAULT_PLATFORM reached docker" >&2
  exit 97
fi
if [ "\$1" = run ] && [ -e "$work/offline" ]; then shift && exec "$real_docker" run --network none "\$@"; fi
exec "$real_docker" "\$@"
EOF
chmod 755 "$work/bin/docker"

# The ignore files of a tree: one entry for left-pad@1.0.0 until EXPIRED_AT, and the grype rule that follows it.
soon=$(date -u -d '+10 days' +%F 2>/dev/null || date -u -v+10d +%F)
today=$(date -u +%F)
# ignore_files DIR EXPIRED_AT: writes DIR/.trivyignore.yaml and DIR/.grype.yaml.
ignore_files() {
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n    statement: Accepted for the test.\n    expired_at: %s\n    purls:\n      - pkg:npm/left-pad@1.0.0\n' \
    "$2" >"$1/.trivyignore.yaml"
  printf 'ignore:\n  - vulnerability: CVE-2026-1111\n    include-aliases: true\n    package:\n      name: left-pad\n      version: 1.0.0\n' \
    >"$1/.grype.yaml"
}
mkdir -p "$work/tree"
ignore_files "$work/tree" "$soon"

# --- The trivy gate (step trivy-gate) on a report of the fixtures, as the scan step leaves it in OUT/trivy.json.
# gate NAME WANT REPORT [VAR=VALUE...]: the gate on REPORT, no ignore file and allow-critical false unless given.
gate() {
  name="trivy gate: $1"
  local want=$2 report=$3
  shift 3
  rm -rf "$work/out" && mkdir -p "$work/out"
  cp "$fixtures/$report" "$work/out/trivy.json"
  step trivy-gate "$want" OUT="$work/out" LABEL="gw linux/amd64" GUARD="$src/deploy/ci/image-guard.sh" \
    TRIVY_IMAGE="$trivy_image" TRIVY_CACHE="$work/cache/trivy" TRIVYIGNORE= ALLOW_CRITICAL=false "$@"
}
gate "a HIGH only passes" 0 clean.json
check "trivy gate: the pass is said" has "$work/step.out" "ok    gw linux/amd64 (trivy) passes the scan gate"
same "trivy gate: one summary line" "- gw linux/amd64 (trivy): CRITICAL 0, HIGH 1, secrets 0" "$(cat "$work/summary")"
check "trivy gate: the report itself is not printed" lacks "$work/step.out" '"Results"'
gate "a CRITICAL blocks" 1 critical.json
check "trivy gate: a CRITICAL says nothing ships" has "$work/step.out" \
  "gw linux/amd64 (trivy): CRITICAL vulnerabilities; nothing is pushed, signed or attested"
check "trivy gate: trivy's table names the CRITICAL" has "$work/step.err" CVE-2026-1111
gate "a CRITICAL with allow-critical (drill-vulnerable) passes" 0 critical.json ALLOW_CRITICAL=true
check "trivy gate: allow-critical says so" has "$work/step.out" \
  "note  gw linux/amd64 (trivy): CRITICAL vulnerabilities let through (allow-critical)"
gate "a CRITICAL covered by an entry of .trivyignore.yaml in force passes" 0 critical.json \
  TRIVYIGNORE="$work/tree/.trivyignore.yaml"
ignore_files "$work/tree" "$today"
gate "a CRITICAL whose entry expired today blocks" 1 critical.json TRIVYIGNORE="$work/tree/.trivyignore.yaml"
ignore_files "$work/tree" "$soon"
gate "a HIGH secret blocks" 1 secret.json
check "trivy gate: the secret, rule, file and line, in the log" has "$work/step.err" \
  "secret  aws-access-key-id (HIGH) in /app/config.env line 3"
check "trivy gate: the secret in the job summary" has "$work/summary" \
  "secret  aws-access-key-id (HIGH) in /app/config.env line 3"
check "trivy gate: never the matched text" lacks "$work/step.err" "KEY=*"
check "trivy gate: never the matched text in the summary" lacks "$work/summary" "KEY=*"
gate "a secret blocks with allow-critical too" 1 secret.json ALLOW_CRITICAL=true
gate "a report that is not trivy's image report" 2 not-trivy.json
check "trivy gate: says it is not a trivy image report" has "$work/step.err" "is not a trivy image JSON report"
gate "a report trivy cannot read (exit 1, neither 0 nor 5)" 2 unreadable.json ALLOW_CRITICAL=true
check "trivy gate: trivy failing is said" has "$work/step.out" "gw linux/amd64: trivy could not read"

# --- grype (step grype) with no DB it can fetch: the network of every container cut.
: >"$work/offline"
grype() {
  name="grype: $1"
  local want=$2
  shift 2
  rm -rf "$work/out" && mkdir -p "$work/out"
  cp "$fixtures/sbom.spdx.json" "$work/out/"
  step grype "$want" OUT="$work/out" LABEL="web linux/arm64" \
    GUARD="$src/deploy/ci/image-guard.sh" GRYPE_IMAGE="$grype_image" GRYPEIGNORE="$work/tree/.grype.yaml" \
    ALLOW_CRITICAL=false GRYPE_CACHE="$work/cache/grype" "$@"
}
grype "a DB it cannot fetch is no pass" 2
check "grype: says it could not scan" has "$work/step.out" "web linux/arm64: grype could not scan"
check "grype: says nothing passed" lacks "$work/step.out" "passes the scan gate"
grype "a DB it cannot fetch is no pass with allow-critical too" 2 ALLOW_CRITICAL=true
rm -f "$work/offline"

# --- syft (step sbom) on the tar of the leg.
sbom() {
  name="syft: $1"
  local want=$2 tar=$3
  rm -rf "$work/out" && mkdir -p "$work/out"
  cp "$tar" "$work/out/image.tar"
  step sbom "$want" IMAGE=gateway OUT="$work/out" SYFT_IMAGE="$syft_image"
}
sbom "a tar that is no image fails the leg" 1 "$fixtures/corrupt.tar"
check "syft: no SPDX document of a broken tar" test ! -s "$work/out/sbom.spdx.json"
docker_ save --output "$work/real.tar" "$yq_image"
sbom "a real image tar gives its SPDX document" 0 "$work/real.tar"
spdx_with_packages() { jq -e '.spdxVersion and (.packages | length > 0)' "$1" >/dev/null; }
check "syft: the SPDX document" spdx_with_packages "$work/out/sbom.spdx.json"

# --- The rules of the ignore files (step rules): the leg checks them before it builds, with today's date.
rules() {
  name="ignore-file rules: $1"
  step rules "$2" SCAN_GATE="$src/deploy/ci/scan-gate.sh" SVP_CODE_ROOT="$work/tree"
}
ignore_files "$work/tree" "$soon"
rules "an entry in force and its grype rule pass" 0
ignore_files "$work/tree" "$today"
rules "an expired entry blocks the leg" 1
check "ignore-file rules: names the expired entry" has "$work/step.out" "entry CVE-2026-1111 expired on $today"

check "no docker call of a step got DOCKER_DEFAULT_PLATFORM" test ! -s "$work/platform.log"
[ ! -s "$work/platform.log" ] || cat "$work/platform.log" >&2

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
