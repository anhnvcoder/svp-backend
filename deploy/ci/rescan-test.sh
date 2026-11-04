#!/usr/bin/env bash
# Tests for deploy/ci/rescan.sh run and rescan_one, in a throwaway checkout of what they read and a clone of a made-up
# svp-gitops; the variables of a GitHub Actions job are made up, and a fake gh and a fake cosign first on PATH record
# their arguments, so no test reaches GitHub, a registry or Sigstore. Checked:
#   - rescan.sh run attests only the releases of the source of the run's repository, as that source's signing
#     workflow: a run of svp-frontend without --source web, a run of backend with --source web, and a run of
#     svp-frontend from another workflow fail, naming both sources (or the identity), before the host or cosign is
#     asked anything; the scheduled run of backend and the run of svp-frontend with --source web each read their own
#     promote pull request and ask cosign for their own releases only, leaving the other source's to it; on a machine
#     the run is refused first;
#   - rescan_one picks its branch by the format the digest is signed in (below).
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/rescan-test.sh
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

# --- Fakes. gh writes each call to gh.log, one line of %q-quoted arguments, and answers pr list from gh/prs.json.
# cosign records its arguments, refuses every signature and takes every attestation.
mkdir -p "$work/bin" "$work/gh" "$work/home" "$work/runner-temp"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
case "$1 $2" in
"pr list") cat "$FAKE_GH_DIR/prs.json" ;;
esac
EOF
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
[ "$1" = attest ] && exit 0
echo "Error: no signatures found" >&2
exit 1
EOF
chmod 755 "$work/bin/gh" "$work/bin/cosign"
echo '[]' >"$work/gh/prs.json"

# on github|local COMMAND...: runs COMMAND with the variables of a made-up GitHub Actions job (repository octo/repo),
# or on a machine with none of them; the fakes first on PATH. git reads no configuration of this machine.
on() {
  local where=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_REF -u GITHUB_SHA -u GITHUB_EVENT_NAME
    -u GITHUB_EVENT_PATH -u RUNNER_TEMP -u GIT_DIR -u GIT_WORK_TREE -u SVP_CODE_ROOT
    PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" FAKE_COSIGN_LOG="$work/cosign.log")
  case $where in
  github)
    "${base[@]}" GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 \
      GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main GITHUB_REF=refs/heads/main \
      GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_EVENT_NAME=schedule RUNNER_TEMP="$work/runner-temp" "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  esac
}
# fresh: empties the files of a job and the logs of the fakes.
fresh() { : >"$work/output" && : >"$work/summary" && : >"$work/gh.log" && : >"$work/cosign.log"; }

# A throwaway checkout of what rescan.sh reads: deploy/ci/, deploy/k8s/lib.sh and the policy's values.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
digest_a=sha256:$(printf 'a%.0s' $(seq 64))
digest_b=sha256:$(printf 'b%.0s' $(seq 64))
backend_run=(GITHUB_REPOSITORY=anhnvcoder/svp-backend GITHUB_SERVER_URL=https://github.com)

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

# --- rescan_one picks its branch by the format the digest is signed in: cosign's older format keeps `attest
# --replace`, a release in bundles goes to replace_vuln_bundle, and the two never swap. rescan.sh is sourced (its
# dispatch only runs when it is executed) and what rescan_one calls around the branch is replaced: the signature check,
# the scan, the gate and the predicate (the scripts of ci_dir), release_format (answering what the case gives),
# replace_vuln_bundle (logging its call). The fake cosign logs `attest ... --replace`.
repo=ghcr.io/anhnvcoder/svp-backend/gateway
rescan_ci=$work/rescan-ci
mkdir -p "$rescan_ci"
printf '#!/usr/bin/env bash\nexit 0\n' >"$rescan_ci/scan-gate.sh"
printf '#!/usr/bin/env bash\necho {} >"$2"\n' >"$rescan_ci/vuln-predicate.sh"
chmod 755 "$rescan_ci/scan-gate.sh" "$rescan_ci/vuln-predicate.sh"
# rescan_branch NAME FORMAT WANT_RC: rescan_one of the made-up release in a rescan job of backend with release_format
# answering FORMAT; its output in rescan-one.out, the calls of replace_vuln_bundle in rescan-one.replace.
rescan_branch() {
  local name=$1 format=$2 want=$3 rc=0
  fresh
  : >"$work/rescan-one.replace"
  # shellcheck disable=SC2016 # expanded by the inner shell
  on github env "${backend_rescan[@]}" RELEASE_FORMAT="$format" REPLACE_LOG="$work/rescan-one.replace" "$BASH" -c \
    '. "$1/deploy/ci/rescan.sh"
    ci_dir=$2
    verify_signature() { :; }
    scan_index() { mkdir -p "$3/amd64" "$3/arm64" && echo "{}" >"$3/amd64/trivy.json" && echo "{}" >"$3/arm64/trivy.json"; }
    release_format() { echo "$RELEASE_FORMAT"; }
    replace_vuln_bundle() { echo "replace_vuln_bundle $*" >>"$REPLACE_LOG"; }
    rescan_one gateway "$3" "$4" "$5" ""' _ "$tree" "$rescan_ci" "$repo" "$digest_a" "$work/rescan-one" \
    >"$work/rescan-one.out" 2>&1 || rc=$?
  same "rescan_one: $name (exit $want)" "$want" "$rc"
}
rescan_branch "a digest in cosign's older format" legacy 0
check "rescan_one: older format: attested in place with --replace" has "$work/cosign.log" "--replace --type vuln"
check "rescan_one: older format: no bundle replaced" lacks "$work/rescan-one.replace" "replace_vuln_bundle"
rescan_branch "a digest in Sigstore bundles" bundle 0
check "rescan_one: bundles: replace_vuln_bundle on the digest and its predicate" has "$work/rescan-one.replace" \
  "replace_vuln_bundle $repo $digest_a $work/rescan-one/predicate.json"
check "rescan_one: bundles: no --replace attestation" lacks "$work/cosign.log" "--replace"
rescan_branch "a digest with neither" none 1
check "rescan_one: neither: nothing attested" lacks "$work/cosign.log" "attest"
check "rescan_one: neither: nothing replaced" lacks "$work/rescan-one.replace" "replace_vuln_bundle"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
