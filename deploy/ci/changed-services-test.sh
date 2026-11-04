#!/usr/bin/env bash
# Tests for deploy/ci/changed-services.sh, in a throwaway git repository holding a copy of deploy/ci/, deploy/k8s/lib.sh,
# the policy's values, a file under docs/ and a Makefile. Checked: a change of common.sh, rescan.sh or sign-image.sh
# builds all six images of this repository (never web, which svp-frontend builds), and so does one of the GRYPE_IMAGE
# line of the Makefile; none is built for a change under web/ (a file added, then deleted), of a test under deploy/ci/, of
# ghcr-digest.sh, of a scenario file under deploy/ci/verify/, of the scripts of svp-gitops's check (gitops-check.sh with
# values-check.sh and verify-release.sh), of the policy's values, of docs/ or of another line of the Makefile.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/changed-services-test.sh
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
# same NAME WANT GOT: ok when the two strings are equal; shows both otherwise.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}

# The throwaway repository. GIT_DIR is set for every git call of the test itself, so git can never reach another
# repository.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$tree/docs"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
echo "# A decision" >"$tree/docs/decision.md"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
# changed: what changed-services.sh builds for the last commit.
changed() {
  env -u GIT_DIR -u GIT_WORK_TREE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null
}
# changed_by PATH: commits a change of PATH, then prints what changed-services.sh builds for that commit.
changed_by() {
  echo "# changed" >>"$tree/$1"
  g commit -qam "change $1"
  changed
}

all="engagement-service feed-service gateway media-worker user-service video-service"
same "changed-services: a change of common.sh builds all six" "$all" "$(changed_by deploy/ci/common.sh)"
same "changed-services: a change of rescan.sh builds all six" "$all" "$(changed_by deploy/ci/rescan.sh)"
same "changed-services: a change of sign-image.sh builds all six" "$all" "$(changed_by deploy/ci/sign-image.sh)"
# The web client's source left this repository: a file under web/ (and its removal) builds no image.
mkdir -p "$tree/web" && echo "export {};" >"$tree/web/page.ts"
same "changed-services: a file added under web/ builds nothing" "" "$(g add web && changed_by web/page.ts)"
g rm -q -r web && g commit -qm "drop web/"
same "changed-services: the removal of web/ builds nothing" "" "$(changed)"
# No image job reads a test, the scripts of the verification runs and of svp-gitops's check, the policy's values or
# docs/.
for f in changed-services-test.sh plan-test.sh promote-test.sh rescan-test.sh scan-gate-test.sh sign-image-test.sh \
  verify-release-test.sh vuln-predicate-test.sh ghcr-digest.sh ghcr-digest-test.sh verify/gitops.sh gitops-check.sh \
  gitops-check-test.sh values-check.sh verify-release.sh; do
  same "changed-services: a change of $f builds nothing" "" "$(changed_by "deploy/ci/$f")"
done
same "changed-services: a change of the policy's values builds nothing" "" \
  "$(changed_by deploy/helm/svp-policy/values.yaml)"
same "changed-services: a change under docs/ builds nothing" "" "$(changed_by docs/decision.md)"
# The Makefile counts only for the lines pinning the tools of the gate.
printf 'TRIVY_IMAGE := trivy@sha256:1\nGRYPE_IMAGE := grype@sha256:1\nK6_IMAGE := k6@sha256:1\n' >"$tree/Makefile"
g add Makefile && g commit -qm "add the Makefile"
sed 's/^GRYPE_IMAGE := grype@sha256:1$/GRYPE_IMAGE := grype@sha256:2/' "$tree/Makefile" >"$work/Makefile" &&
  cp "$work/Makefile" "$tree/Makefile" && g commit -qam "bump grype"
same "changed-services: a change of the GRYPE_IMAGE line builds all six" "$all" "$(changed)"
same "changed-services: a change of another line of the Makefile builds nothing" "" "$(changed_by Makefile)"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
