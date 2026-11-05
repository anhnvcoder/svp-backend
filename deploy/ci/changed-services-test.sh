#!/usr/bin/env bash
# Tests for deploy/ci/changed-services.sh, in a throwaway git repository holding a copy of deploy/ci/, deploy/k8s/lib.sh,
# the image table deploy/docker-bake.json, the policy's values, the composite actions of the image pipeline, another action, a file under docs/ and a Makefile.
# Checked: a change of common.sh, rescan.sh, image-guard.sh or of a file of one of the actions under
# .github/actions/image-*/ builds all six images of this repository (never web, which svp-frontend builds), and so does
# one of the GRYPE_IMAGE line of the Makefile; none is built for a change under web/ (a file added, then deleted), of
# another action under .github/actions/, of a test under deploy/ci/ or its fixtures under testdata/, of
# the scripts of the verification runs (verify-host.sh, verify-mask.sh, verify-collect.sh, the scripts of the steps
# under deploy/ci/verify-steps/, ghcr-digest.sh), of the drills under deploy/k8s/drills/, of the scripts of svp-gitops's
# check (gitops-check.sh with values-check.sh, verify-release.sh and its conftest policies), of the policy's values, of
# docs/ or of another line of the Makefile. The image table: a change of one service's target builds that service
# only, a change of the table's form alone (same JSON) builds nothing, and a change of group default, of a part of the
# table outside the services' targets, or a table the base commit lacks builds all six.
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
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$tree/docs" "$tree/.github/actions/other"
cp -R "$here" "$tree/deploy/ci"
cp -R "$src/.github/actions/image-leg" "$src/.github/actions/image-index" "$src/.github/actions/image-sign" \
  "$tree/.github/actions/"
echo "name: other" >"$tree/.github/actions/other/action.yml"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/docker-bake.json" "$tree/deploy/"
cp -R "$src/deploy/k8s/drills" "$tree/deploy/k8s/"
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
same "changed-services: a change of image-guard.sh builds all six" "$all" "$(changed_by deploy/ci/image-guard.sh)"
# The composite actions are the pipeline: one of them changed alone builds every image.
for a in image-leg image-index image-sign; do
  same "changed-services: a change of the action $a alone builds all six" "$all" \
    "$(changed_by ".github/actions/$a/action.yml")"
done
same "changed-services: a change of another action builds nothing" "" "$(changed_by .github/actions/other/action.yml)"
# The web client's source left this repository: a file under web/ (and its removal) builds no image.
mkdir -p "$tree/web" && echo "export {};" >"$tree/web/page.ts"
same "changed-services: a file added under web/ builds nothing" "" "$(g add web && changed_by web/page.ts)"
g rm -q -r web && g commit -qm "drop web/"
same "changed-services: the removal of web/ builds nothing" "" "$(changed)"
# No image job reads a test, the scripts of the verification runs and of svp-gitops's check, the drills, the policy's
# values or docs/.
for f in changed-services-test.sh plan-test.sh promote-test.sh rescan-test.sh scan-gate-test.sh sign-image-test.sh \
  image-guard-test.sh image-gate-test.sh testdata/image-gate/clean.json verify-release-test.sh vuln-predicate-test.sh \
  ghcr-digest.sh ghcr-digest-test.sh verify-host.sh verify-mask.sh verify-collect.sh verify-collect-test.sh \
  verify-steps/steps.sh verify-steps/supplychain.sh verify-steps/supplychain-test.sh \
  verify-steps/admission-metrics.sh verify-steps/objstore.sh gitops-check.sh gitops-check-test.sh values-check.sh \
  verify-release.sh ignorefile-policies/grypeignore.rego gitops-tree-policies/author.rego; do
  same "changed-services: a change of $f builds nothing" "" "$(changed_by "deploy/ci/$f")"
done
for f in drills/run.sh drills/.chainsaw.yaml drills/gitops/env/chainsaw-test.yaml drills/gitops/gitops-test.sh \
  drills/templates/port-forward.yaml; do
  same "changed-services: a change of deploy/k8s/$f builds nothing" "" "$(changed_by "deploy/k8s/$f")"
done
# A file of deploy/ci/ that is none of those still builds every image: the list is of names, not of a folder.
same "changed-services: a change of another script of deploy/ci/ beside the verification scripts builds all six" "$all" \
  "$(changed_by deploy/ci/vuln-predicate.sh)"
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

# The image table, compared as JSON between the two commits.
# table_change NAME JQ: rewrites the table with the jq filter JQ, commits it, then prints what changed-services.sh builds.
table_change() {
  jq "$2" "$tree/deploy/docker-bake.json" >"$work/table.json" && cp "$work/table.json" "$tree/deploy/docker-bake.json"
  g commit -qam "image table: $1"
  changed
}
same "changed-services: a build argument added to the target of video-service builds video-service only" \
  video-service "$(table_change "an argument of video-service" '.target["video-service"].args.EXTRA = "1"')"
same "changed-services: another Dockerfile in the target of media-worker builds media-worker only" media-worker \
  "$(table_change "media-worker's Dockerfile" '.target["media-worker"].dockerfile = "deploy/docker/worker.Dockerfile"')"
jq -c . "$tree/deploy/docker-bake.json" >"$work/table.json" && cp "$work/table.json" "$tree/deploy/docker-bake.json"
g commit -qam "image table: on one line"
same "changed-services: the table written in another form, the same JSON, builds nothing" "" "$(changed)"
same "changed-services: the order of group default changed builds all six" "$all" \
  "$(table_change "the group" '.group.default.targets |= reverse')"
same "changed-services: a part of the table outside the targets of the services builds all six" "$all" \
  "$(table_change "a variable" '.variable = {"TAG": {"default": "dev"}}')"
same "changed-services: a target no service names builds all six" "$all" \
  "$(table_change "a target of no service" '.target._base = {"context": "."}')"
g rm -q deploy/docker-bake.json && g commit -qm "drop the image table"
g checkout -q HEAD~1 -- deploy/docker-bake.json && g commit -qm "the image table again"
same "changed-services: a table the base commit lacks builds all six" "$all" "$(changed)"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
