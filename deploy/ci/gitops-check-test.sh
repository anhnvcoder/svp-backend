#!/usr/bin/env bash
# Negative cases of deploy/ci/gitops-check.sh and of the root chart argocd/apps of a tree of svp-gitops: each case
# changes one thing in a fresh copy of TREE and must fail with its own message, before the check reaches the network.
# Needs bash, git, jq, helm, docker and the history of this repository up to the tree's revisions (origin/main fetched).
# Design notes: docs/reference/ci.md.

# Usage, from anywhere: deploy/ci/gitops-check-test.sh [TREE]
#   TREE: a tree of svp-gitops (base/, envs/, argocd/), never written. Without it, main of
#   https://github.com/anhnvcoder/svp-gitops is cloned anonymously into a temporary directory, as this repository does
#   not hold that tree.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

# --- gitops_dir
ws=$work/ws
mkdir -p "$ws/backend/deploy/k8s"
cp "$repo_root/deploy/k8s/lib.sh" "$ws/backend/deploy/k8s/"
cp "$repo_root/deploy/docker-bake.json" "$ws/backend/deploy/"
gw() { git -C "$1" -c user.name=test -c user.email=test@example.invalid "${@:2}"; }
git init -q "$ws/backend"
gw "$ws/backend" add deploy
gw "$ws/backend" commit -q -m lib
gw "$ws/backend" worktree add -q -b worktree-x "$ws/.worktrees/backend-x"
ws_real=$(cd "$ws" && pwd -P)
# lookup DIR LIB [VAR=VALUE...]: gitops_dir of LIB (a copy of lib.sh), run from DIR without SVP_GITOPS_DIR unless one
# of VAR=VALUE sets it; prints its output, then "rc=<exit status>".
lookup() {
  local dir=$1 lib=$2 out rc=0
  shift 2
  out=$(cd "$dir" && env -u SVP_GITOPS_DIR "$@" bash -c '. "$1" && gitops_dir' _ "$lib" 2>&1) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
# expect NAME OUTPUT WANT...: OUTPUT holds each WANT.
expect() {
  local name=$1 out=$2 w
  shift 2
  for w in "$@"; do
    [[ $out == *"$w"* ]] || {
      fail "$name: no '$w' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
      return
    }
  done
  ok "$name"
}
main_lib=$ws/backend/deploy/k8s/lib.sh
wt_lib=$ws/.worktrees/backend-x/deploy/k8s/lib.sh
clone_hint="git clone https://github.com/anhnvcoder/svp-gitops.git '$ws_real/gitops'"
expect "gitops_dir: no clone in the workspace, the command that makes it" "$(lookup "$ws/backend" "$main_lib")" \
  "$clone_hint" rc=1
mkdir "$ws/gitops"
expect "gitops_dir: a folder that is no git repository is refused" "$(lookup "$ws/backend" "$main_lib")" "$clone_hint" rc=1
git init -q "$ws/gitops"
gw "$ws/gitops" remote add origin https://github.com/someone/other.git
expect "gitops_dir: a repository with another origin is refused" "$(lookup "$ws/backend" "$main_lib")" "$clone_hint" rc=1
gw "$ws/gitops" remote set-url origin https://github.com/anhnvcoder/svp-gitops.git
mkdir -p "$ws/gitops/base"
expect "gitops_dir: the clone beside the main checkout" "$(lookup "$ws/backend" "$main_lib")" "$ws_real/gitops"$'\n'rc=0
expect "gitops_dir: the same from a folder inside the main checkout" "$(lookup "$ws/backend/deploy" "$main_lib")" \
  "$ws_real/gitops"$'\n'rc=0
expect "gitops_dir: the same from a worktree under .worktrees/, not .worktrees/gitops" \
  "$(lookup "$ws/.worktrees/backend-x" "$wt_lib")" "$ws_real/gitops"$'\n'rc=0
git init -q "$ws/other"
gw "$ws/other" remote add origin git@github.com:anhnvcoder/svp-gitops.git
expect "gitops_dir: SVP_GITOPS_DIR names another clone (an SSH remote)" \
  "$(lookup "$ws/.worktrees/backend-x" "$wt_lib" SVP_GITOPS_DIR="$ws/other")" "$ws_real/other"$'\n'rc=0
expect "gitops_dir: SVP_GITOPS_DIR inside a clone is refused" \
  "$(lookup "$ws/backend" "$main_lib" SVP_GITOPS_DIR="$ws/gitops/base")" \
  "SVP_GITOPS_DIR=$ws/gitops/base is not a clone of svp-gitops" "make gitops-clone" rc=1
expect "gitops_dir: SVP_GITOPS_DIR that does not exist is refused" \
  "$(lookup "$ws/backend" "$main_lib" SVP_GITOPS_DIR="$ws/missing")" "git clone https://github.com/anhnvcoder/svp-gitops.git '$ws/missing'" rc=1
[ ! -e "$ws/missing" ] && [ ! -e "$ws/backend/.gitops" ] && ok "gitops_dir: nothing was cloned" ||
  fail "gitops_dir: nothing was cloned"

# --- gitops_clone, from a local repository (the draft backend) standing for svp-gitops: gitops_is_clone is replaced so
# that a clone whose origin is that folder counts, since its own checks are above.
src_branch=$(git -C "$ws/backend" symbolic-ref --short HEAD)
# clone_run [VAR=VALUE...]: gitops_clone of the draft lib.sh into $ws/ci-clone; prints its output, then "rc=<status>".
clone_run() {
  local out rc=0
  out=$(env "$@" bash -c '. "$1" && gitops_url=file://$2 && gitops_ci_clone=$3 &&
    gitops_is_clone() { [ -d "$1/.git" ]; } && gitops_clone' _ "$main_lib" "$ws/backend" "$ws/ci-clone" 2>&1) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
expect "gitops_clone: a GITOPS_REF that is no branch is refused" "$(clone_run GITOPS_REF=typo)" \
  "GITOPS_REF=typo is neither a branch" rc=1
expect "gitops_clone: the next run checks out the clone that run left with no index" \
  "$(clone_run GITOPS_REF="$src_branch")" "svp-gitops at" rc=0
echo changed >>"$ws/ci-clone/deploy/k8s/lib.sh"
expect "gitops_clone: a checked-out clone with a change is still refused" "$(clone_run GITOPS_REF="$src_branch")" \
  "has uncommitted changes" rc=1

if [ $# -ge 1 ]; then
  tree=$(cd "$1" && pwd)
else
  # No credential helper and no prompt: the clone is anonymous, as the clusters' is.
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone -q --depth 1 https://github.com/anhnvcoder/svp-gitops.git \
    "$work/clone" || { echo "FAIL  clone https://github.com/anhnvcoder/svp-gitops.git" >&2; exit 1; }
  tree=$work/clone
fi
for f in argocd/apps/Chart.yaml envs/stg/charts.yaml envs/stg/images/gateway.yaml; do
  [ -f "$tree/$f" ] || { echo "FAIL  $tree has no $f: not a tree of svp-gitops" >&2; exit 1; }
done

# copy: prints a fresh copy of the tree, without .git (the check needs none without BASE), symlinks kept, and without
# the commit an environment pins (gitopsRevision of its charts.yaml), which a copy without .git does not hold: each
# case checks the tree as one, the cases of the pin below make their own clone.
copy() {
  local dir f
  dir=$(mktemp -d "$work/case.XXXXXX")
  (cd "$tree" && tar -cf - --exclude .git .) | tar -xf - -C "$dir"
  for f in "$dir"/envs/*/charts.yaml; do
    sed -i.bak '/^gitopsRevision:/d' "$f" && rm "$f.bak"
  done
  echo "$dir"
}
# check NAME DIR MESSAGE: gitops-check.sh on DIR must fail with MESSAGE on stderr.
check() {
  local out
  if out=$("$here/gitops-check.sh" "$2" 2>&1 >/dev/null); then
    fail "$1: gitops-check.sh passed"
  elif [[ $out == *"$3"* ]]; then
    ok "$1"
  else
    fail "$1: gitops-check.sh failed without '$3':"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
# A chart that prints the values of level 2 from a render of level 1 (in/doc): helm.valuesObject of its Application
# svp-apps, as JSON, which a values file may be.
mkdir -p "$work/lift/templates" "$work/lift/in"
printf 'apiVersion: v2\nname: lift\nversion: 0.1.0\n' >"$work/lift/Chart.yaml"
cat >"$work/lift/templates/values.yaml" <<'TEMPLATE'
{{- range $doc := regexSplit `(?m)^---.*$` (.Files.Get "in/doc") -1 }}
{{- $o := fromYaml $doc }}
{{- if eq (toString $o.kind) "Application" }}
{{ $o.spec.source.helm.valuesObject | toJson }}
{{- end }}
{{- end }}
TEMPLATE
# render_root DIR ENV: renders the root of DIR for ENV as Argo CD does: argocd/apps with value env, or, in a tree with
# the two-level root argocd/root, that chart on k3d and then argocd/apps with the values of the Application svp-apps it
# makes, so a rule of envs/ fails the render at whichever level holds it.
render_root() {
  if [ ! -f "$1/argocd/root/Chart.yaml" ]; then
    helm template svp-root "$1/argocd/apps" --namespace argocd --set-string "env=$2"
    return
  fi
  helm template svp-root "$1/argocd/root" --namespace argocd --set-string "env=$2" --set-string platform=k3d \
    --set nodeArch=arm64 >"$work/lift/in/doc" &&
    helm template lift "$work/lift" >"$work/level2.yaml" &&
    helm template svp-apps "$1/argocd/apps" --namespace argocd -f "$work/level2.yaml"
}
# render NAME DIR ENV MESSAGE: the root of DIR (render_root) must fail for ENV with MESSAGE.
render() {
  local out
  if out=$(render_root "$2" "$3" 2>&1 >/dev/null); then
    fail "$1: the root chart rendered"
  elif [[ $out == *"$4"* ]]; then
    ok "$1"
  else
    fail "$1: the root chart failed without '$4':"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}

# --- the policies on the tree (deploy/ci/gitops-tree-policies/): their conftest verify first, every rule's cases;
# then the input the check builds for them, one case per part of it, and a conftest that gives no answer.
if out=$(make -s -C "$repo_root" conftest-verify 2>&1); then
  ok "tree policies: conftest verify of deploy/ci/gitops-tree-policies/"
else
  fail "tree policies: conftest verify failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
fi
t=$(copy)
rm "$t/envs/stg/images/web.yaml"
check "six image files of seven" "$t" "envs/stg/images/ holds"
render "six image files of seven (root chart)" "$t" stg "envs/stg/images/web.yaml is missing"

t=$(copy)
echo 'replicas: 2' >>"$t/envs/stg/images/gateway.yaml"
render "an image file with another key (root chart)" "$t" stg \
  "envs/stg/images/gateway.yaml holds image, replicas: an image file holds the image block alone"

t=$(copy)
printf 'image:\n  tag: "000000000000"\n' >>"$t/envs/stg/gateway.yaml"
check "an overlay that sets image" "$t" "envs/stg/gateway.yaml sets image, canary or httpRoute.name"
render "an overlay that sets image (root chart)" "$t" stg "envs/stg/gateway.yaml sets image, canary or httpRoute.name"

render "an unknown environment (root chart)" "$(copy)" nope 'env is "nope": envs/ has no directory of that name'

t=$(copy)
sed -i.bak 's/^revision:.*/revision:/' "$t/envs/stg/charts.yaml" && rm "$t/envs/stg/charts.yaml.bak"
check "an empty revision" "$t" "envs/stg/charts.yaml: revision is '', the full commit (40 hex)"
render "an empty revision (root chart)" "$t" stg 'envs/stg/charts.yaml: revision is "", the full commit (40 hex)'

t=$(copy)
sed -i.bak "s/^collectorConfigSha256:.*/collectorConfigSha256: $(printf '0%.0s' $(seq 64))/" "$t/envs/stg/charts.yaml" &&
  rm "$t/envs/stg/charts.yaml.bak"
check "a wrong collectorConfigSha256" "$t" "envs/stg/charts.yaml: collectorConfigSha256 is '$(printf '0%.0s' $(seq 64))'"

# The revision of svp-gitops written short wherever the root writes it: argocd/apps/values.yaml, and, in a tree with the
# two-level root, argocd/root, which sets it for level 2.
t=$(copy)
roots=("$t/argocd/apps/values.yaml")
[ ! -d "$t/argocd/root" ] || roots+=("$t/argocd/root")
while IFS= read -r f; do
  sed -i.bak 's|refs/heads/main|main|g' "$f" && rm "$f.bak"
done < <(find "${roots[@]}" -type f)
check "a short targetRevision" "$t" \
  "every source of https://github.com/anhnvcoder/svp-gitops.git must name a full ref (refs/heads/<branch>) or a commit as targetRevision, not main"

# --- the platform layer (gitops-check.sh --root: steps 1 and 2, no network), on copies of TREE, which has it.
[ -d "$tree/platforms" ] || { echo "FAIL  $tree has no platforms/: a tree from before the platform layer, which the check refuses" >&2; exit 1; }
# check_root NAME WANT_RC MESSAGE DIR: gitops-check.sh --root on DIR; MESSAGE on its output.
check_root() {
  local out rc=0
  out=$("$here/gitops-check.sh" --root "$4" 2>&1) || rc=$?
  if [ "$2" = 0 ] && [ "$rc" != 0 ]; then
    fail "$1: gitops-check.sh --root failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  elif [ "$2" != 0 ] && [ "$rc" = 0 ]; then
    fail "$1: gitops-check.sh --root passed"
  elif [[ $out == *"$3"* ]]; then
    ok "$1"
  else
    fail "$1: no '$3' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
# replace_once FILE OLD NEW: OLD, found exactly once in FILE, becomes NEW; status 1 when it is not there once.
replace_once() {
  local out
  out=$(OLD=$2 NEW=$3 awk '{ s = s $0 "\n" } END {
    old = ENVIRON["OLD"]; i = index(s, old)
    if (i == 0 || index(substr(s, i + length(old)), old)) exit 1
    printf "%s%s%s", substr(s, 1, i - 1), ENVIRON["NEW"], substr(s, i + length(old)) }' "$1") || return 1
  printf '%s\n' "$out" >"$1"
}
# with_block FILE NAME: the three lines of the root's values files `{{- with $NAME }}`, the file named with the ref of
# its source ($values/ or $env/), `{{- end }}`, found once in FILE; status 1 when they are not there once.
with_block() {
  local re='^ *\{\{- with \$'"$2"' \}\}$'
  [ "$(grep -cE "$re" "$1")" = 1 ] || return 1
  grep -E -A2 "$re" "$1"
}
# platform_after_overlay FILE: the root's template FILE reads the platform's values file after the environment's
# overlay, whichever ref each is read through; status 1 when FILE does not hold the two blocks in that order.
platform_after_overlay() {
  local pf ov
  pf=$(with_block "$1" platformFile) && ov=$(with_block "$1" overlay) &&
    replace_once "$1" "$pf"$'\n'"$ov" "$ov"$'\n'"$pf"
}
# platforms_case NAME MESSAGE JQ: a copy of TREE whose components.json is changed by the jq filter JQ fails with
# MESSAGE.
platforms_case() {
  local t
  t=$(copy)
  jq "$3" "$tree/argocd/apps/components.json" >"$t/argocd/apps/components.json"
  check_root "platforms: $1" 1 "$2" "$t"
}
components_json=$tree/argocd/apps/components.json
check_root "platforms: the tree, each environment on each platform of components.json" 0 \
  "ok    argocd/apps for prd on eks on arm64 and amd64 nodes: one Application per component that runs there" "$(copy)"
check_root "platforms: an environment left out of a platform is not rendered there, and says why" 0 \
  "skip  prd on k3d: prd is not in envs of platform k3d (key platforms of components.json)" "$(copy)"
platforms_case "no key platforms, read by the policies" "argocd/apps/components.json: has no key platforms" 'del(.platforms)'
# A platform whose folder is a link to another folder, behind which an overlay sets an image: the lister of the tree
# does not walk into the link, so the check refuses the link itself rather than pass what lies behind it.
t=$(copy)
mkdir -p "$t/hidden"
cp -R "$t/platforms/eks/." "$t/hidden/"
printf 'image:\n  tag: "000000000000"\n' >"$t/hidden/gateway.yaml"
rm -rf "$t/platforms/eks"
ln -s ../hidden "$t/platforms/eks"
check_root "platforms: a platform's folder that is a link to another folder" 1 \
  "platforms/eks is a link to the folder ../hidden" "$t"
t=$(copy)
printf 'image:\n  tag: "000000000000"\n' >"$t/platforms/eks/gateway.values.tpl"
check_root "platforms: a template of a platform that renders the image of a release" 1 \
  "platforms/eks/gateway.values.tpl renders image for stg on eks" "$t"
# argo-cd.yaml holds Argo CD's own values of a platform (deploy/k8s/gitops.sh installs them); a root chart from before
# the file refuses it itself, so the check's rules and the root's render must both pass (the copy's leaves it out).
t=$(copy)
printf 'notifications:\n  enabled: true\n' >"$t/platforms/eks/argo-cd.yaml"
replace_once "$t/argocd/apps/templates/applications.yaml" '(ne $base "README.md")' \
  '(ne $base "README.md") (ne $base "argo-cd.yaml")' || :
check_root "platforms: Argo CD's values of a platform, argo-cd.yaml" 0 \
  "ok    argocd/apps for prd on eks on arm64 and amd64 nodes: one Application per component that runs there" "$t"
# The root chart that leaves platforms out of components.json: an Application of eks alone on k3d.
t=$(copy)
if replace_once "$t/argocd/apps/templates/applications.yaml" '{{- if or (not (hasKey . "platforms")) (has $platform .platforms) }}' \
  '{{- if true }}'; then
  check_root "platforms: a root chart that makes Applications of another platform" 1 \
    "argocd/apps for stg on k3d on arm64 nodes makes the Applications" "$t"
else
  fail "platforms: the root chart of $tree no longer holds the line the case of Applications of another platform changes"
fi
# The root chart that reads the values of the platform after the overlay of the environment. On a two-level root the
# overlay is part of the Application's valuesObject, after every values file: an overlay and the platform's template
# setting one key must give the template's value, and a root chart that merges the overlay over the template fails.
t=$(copy)
if [ -f "$t/argocd/root/Chart.yaml" ]; then
  # shellcheck disable=SC2016 # the layers of the valuesObject in level 2, text of the template
  layers=':= list (get $overlays .name) (get $images .name) (get $platformObjects .name) }}'
  printf 'httpRoute:\n  host: api.overlay.example\n' >>"$t/envs/stg/gateway.yaml"
  check_root "platforms: an overlay and its platform's template setting one key, the template's last" 0 \
    "ok    argocd/apps for stg on eks on arm64 and amd64 nodes: one Application per component that runs there" "$t"
  # shellcheck disable=SC2016 # text of the template
  if replace_once "$t/argocd/apps/templates/applications.yaml" "$layers" \
    ':= list (get $platformObjects .name) (get $overlays .name) (get $images .name) }}'; then
    check_root "platforms: a root chart that merges an environment's overlay over its platform's template" 1 \
      "argocd/apps for stg on eks on arm64 nodes: Application gateway has the helm.valuesObject above (>), want envs/stg/gateway.yaml < envs/stg/images/gateway.yaml < the render of platforms/eks/gateway.values.tpl" "$t"
  else
    fail "platforms: the root chart of $tree no longer holds the layers of the valuesObject the case of their order swaps"
  fi
elif platform_after_overlay "$t/argocd/apps/templates/applications.yaml"; then
  printf 'replicas: 2\n' >"$t/platforms/eks/gateway.yaml"
  check_root "platforms: a root chart that reads a platform's values after the environment's" 1 \
    "Application gateway reads the values files 'base/services/gateway.yaml envs/stg/gateway.yaml platforms/eks/gateway.yaml envs/stg/images/gateway.yaml', want 'base/services/gateway.yaml platforms/eks/gateway.yaml envs/stg/gateway.yaml envs/stg/images/gateway.yaml'" "$t"
else
  fail "platforms: the root chart of $tree no longer holds the lines the case of the values' order changes"
fi
# localHosts, step 3: without it on k3d the render of stg there (the lab's names) fails the whole check, before
# anything reaches the network.
t=$(copy)
jq '.platforms.k3d |= del(.localHosts)' "$components_json" >"$t/argocd/apps/components.json"
check "platforms: k3d without localHosts, whose renders name svp.localhost" "$t" \
  "the render above still names svp.localhost on a platform without localHosts in components.json"

# --- the pin of prd (gitopsRevision of envs/prd/charts.yaml) and the two-level root, on a copy of TREE made a git
# repository: commit A0 holds base/ alone, A the whole tree (the end of origin/main), and prd pins A. A tree from before
# the two-level root gets stand-ins for its two levels in the shape the check holds them to; the cases edit only text
# both shapes share, or record the render of level 1 and change it.
gitops_url=https://github.com/anhnvcoder/svp-gitops.git
pt=$(copy)
pg() { git -C "$1" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "${@:2}"; }
if [ ! -f "$pt/argocd/root/Chart.yaml" ]; then
  mkdir -p "$pt/argocd/root/templates" "$pt/argocd/root/files"
  ln -s ../../../envs "$pt/argocd/root/files/envs"
  printf 'apiVersion: v2\nname: svp-root\nversion: 0.1.0\n' >"$pt/argocd/root/Chart.yaml"
  printf 'env: ""\nplatform: ""\nnodeArch: arm64\ncluster: {}\n' >"$pt/argocd/root/values.yaml"
  cat >"$pt/argocd/root/templates/svp-apps.yaml" <<'TEMPLATE'
{{- $charts := .Files.Get (printf "files/envs/%s/charts.yaml" .Values.env) | fromYaml }}
{{- $rev := get $charts "gitopsRevision" | default "refs/heads/main" }}
{{- $overlays := dict }}
{{- range $file, $content := .Files.Glob (printf "files/envs/%s/*.yaml" .Values.env) }}
{{- if ne (base $file) "charts.yaml" }}{{ $_ := set $overlays (base $file | trimSuffix ".yaml") (fromYaml (toString $content)) }}{{ end }}
{{- end }}
{{- $images := dict }}
{{- range $file, $content := .Files.Glob (printf "files/envs/%s/images/*.yaml" .Values.env) }}
{{- $_ := set $images (base $file | trimSuffix ".yaml") (fromYaml (toString $content)) }}
{{- end }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svp-apps
  namespace: argocd
spec:
  project: svp
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  source:
    repoURL: https://github.com/anhnvcoder/svp-gitops.git
    targetRevision: {{ $rev | quote }}
    path: argocd/apps
    helm:
      valuesObject:
        targetRevision: {{ $rev | quote }}
        env: {{ .Values.env | quote }}
        platform: {{ .Values.platform | quote }}
        nodeArch: {{ .Values.nodeArch | quote }}
        cluster: {{ .Values.cluster | default dict | toJson }}
        envFiles:
          overlays: {{ $overlays | toJson }}
          images: {{ $images | toJson }}
TEMPLATE
  apps_tpl=$pt/argocd/apps/templates/applications.yaml
  # The overlay and the image file leave the values files for the valuesObject, before what the platform's template
  # renders; the chart still reads charts.yaml and checks every file of envs/ at its commit, as before.
  # shellcheck disable=SC2016 # text of the template
  if ! { ov=$(with_block "$apps_tpl" overlay) && im=$(with_block "$apps_tpl" image) &&
    replace_once "$apps_tpl" "$ov"$'\n' '' && replace_once "$apps_tpl" "$im"$'\n' '' &&
    replace_once "$apps_tpl" '        {{- with get $platformObjects .name }}' \
      '        {{- $envFiles := $.Values.envFiles | default dict }}
        {{- with mustMergeOverwrite (dict) (deepCopy (get (get $envFiles "overlays" | default dict) .name | default dict)) (deepCopy (get (get $envFiles "images" | default dict) .name | default dict)) (deepCopy (get $platformObjects .name | default dict)) }}'; }; then
    fail "pin: the root chart of $tree, which has no argocd/root, no longer holds the lines its level 2 stand-in changes"
  fi
fi
pg "$pt" init -q -b main
pg "$pt" add base && pg "$pt" commit -qm base
pin_a0=$(pg "$pt" rev-parse HEAD)
pg "$pt" add -A && pg "$pt" commit -qm tree
pin_a=$(pg "$pt" rev-parse HEAD)
pg "$pt" update-ref refs/remotes/origin/main "$pin_a"
# set_pin DIR COMMIT: envs/prd/charts.yaml of DIR pins COMMIT, as the promote to prd writes it.
set_pin() {
  sed -i.bak '/^gitopsRevision:/d' "$1/envs/prd/charts.yaml" && rm "$1/envs/prd/charts.yaml.bak"
  printf 'gitopsRevision: %s\n' "$2" >>"$1/envs/prd/charts.yaml"
}
set_pin "$pt" "$pin_a"
# gcopy: prints a fresh copy of the pinned tree, .git included.
gcopy() {
  local dir
  dir=$(mktemp -d "$work/pin.XXXXXX")
  (cd "$pt" && tar -cf - .) | tar -xf - -C "$dir"
  echo "$dir"
}
t=$(gcopy)
check_root "pin: prd pinned to a commit on main of svp-gitops" 0 \
  "ok    envs/prd/charts.yaml: gitopsRevision ${pin_a:0:12}, a commit on origin/main of svp-gitops holding argocd/apps" "$t"
check_root "pin: prd renders argocd/apps, base/ and platforms/ at that commit, through level 1" 0 \
  "ok    argocd/apps at ${pin_a:0:12} for prd on eks on arm64 and amd64 nodes: one Application per component that runs there" "$t"
check_root "pin: stg, which pins none, renders the tree, through level 1" 0 \
  "ok    argocd/apps for stg on eks on arm64 and amd64 nodes: one Application per component that runs there" "$t"
# The tree's argocd/apps makes the Applications of every platform on each, and its platforms/eks/ gets a values file
# for the gateway: stg renders them and fails, prd renders the pinned commit's and passes.
t=$(gcopy)
# shellcheck disable=SC2016 # text of the template
if replace_once "$t/argocd/apps/templates/applications.yaml" '{{- if or (not (hasKey . "platforms")) (has $platform .platforms) }}' \
  '{{- if true }}'; then
  printf 'replicas: 2\n' >"$t/platforms/eks/gateway.yaml"
  rc=0
  out=$("$here/gitops-check.sh" --root "$t" 2>&1) || rc=$?
  expect "pin: a change of argocd/apps and platforms/ reaches stg, not prd pinned before it" "$out"$'\n'"rc=$rc" \
    "ok    argocd/apps at ${pin_a:0:12} for prd on eks on arm64 and amd64 nodes" \
    "argocd/apps for stg on k3d on arm64 nodes makes the Applications" \
    $'\n'rc=1
else
  fail "pin: the root chart no longer holds the line of a component's platforms this case changes"
fi
t=$(gcopy)
missing=$(printf 'f%.0s' $(seq 40))
set_pin "$t" "$missing"
check_root "pin: a commit the clone has not" 1 \
  "envs/prd/charts.yaml: gitopsRevision $missing is no commit of $(cd "$t" && pwd -P) (the top of a clone of svp-gitops with its history)" "$t"
t=$(gcopy)
pg "$t" commit -q --allow-empty -m "a branch's"
side=$(pg "$t" rev-parse HEAD)
set_pin "$t" "$side"
check_root "pin: a commit off main (a pull request's, a branch's)" 1 \
  "envs/prd/charts.yaml: gitopsRevision ${side:0:12} is not on origin/main of svp-gitops: prd runs only a set that main held" "$t"
t=$(gcopy)
set_pin "$t" "$pin_a0"
check_root "pin: a commit on main without argocd/apps" 1 \
  "envs/prd/charts.yaml: gitopsRevision ${pin_a0:0:12} holds no argocd/apps/Chart.yaml: there is no root for prd to render at it" "$t"
t=$(gcopy)
set_pin "$t" main
check_root "pin: a branch name, not a commit" 1 \
  "envs/prd/charts.yaml: gitopsRevision is 'main', the full commit (40 hex) of svp-gitops" "$t"
t=$(mktemp -d "$work/case.XXXXXX")
(cd "$pt" && tar -cf - --exclude .git .) | tar -xf - -C "$t"
check_root "pin: a tree that is no clone of svp-gitops" 1 \
  "envs/prd/charts.yaml: gitopsRevision $pin_a is no commit of $(cd "$t" && pwd -P)" "$t"
# record_level1 DIR: argocd/root of DIR becomes a recording of its own render: for each environment on each platform
# (key platforms of components.json) on each architecture, the chart prints what argocd/root rendered there with the
# values the check gives it, so a case changes one environment's Application svp-apps whatever the template.
record_level1() {
  local dir=$1 rec=$work/record target env plat arch args
  rm -rf "${rec:?}" && mkdir -p "$rec/templates" "$rec/files" || return 1
  { echo 'cluster:'; sed 's/^/  /' "$here/cluster-values.example.yaml"; } >"$work/cluster.yaml" || return 1
  for target in $(jq -r '.platforms | to_entries[] | .key as $p | .value.envs[] | "\(.):\($p)"' "$dir/argocd/apps/components.json"); do
    env=${target%%:*} plat=${target#*:}
    for arch in arm64 amd64; do
      args=(--namespace argocd --set-string "env=$env" --set "nodeArch=$arch" --set-string "platform=$plat")
      [ "$plat" != eks ] || args+=(-f "$work/cluster.yaml")
      helm template svp-root "$dir/argocd/root" "${args[@]}" >"$rec/files/$env-$plat-$arch.yaml" || return 1
    done
  done
  printf 'apiVersion: v2\nname: svp-root\nversion: 0.1.0\n' >"$rec/Chart.yaml"
  : >"$rec/values.yaml"
  printf '%s\n' '{{ .Files.Get (printf "files/%s-%s-%s.yaml" .Values.env .Values.platform .Values.nodeArch) }}' \
    >"$rec/templates/svp-apps.yaml"
  rm -rf "${dir:?}/argocd/root" && cp -R "$rec" "$dir/argocd/root"
}
# level1_case NAME FROM TO MESSAGE: level 1 recorded (record_level1), FROM replaced by TO in the renders of prd, fails
# the check with MESSAGE. The gateway's overlay of prd in the tree first gets a key of its own, svpLevelOneCase: main,
# which a case may change in what level 1 hands over.
level1_case() {
  local t f
  t=$(gcopy)
  printf 'svpLevelOneCase: main\n' >>"$t/envs/prd/gateway.yaml"
  record_level1 "$t" || {
    fail "$1: record the render of argocd/root"
    return
  }
  for f in "$t"/argocd/root/files/prd-*.yaml; do
    sed -i.bak "s|$2|$3|g" "$f" && rm "$f.bak"
  done
  check_root "$1" 1 "$4" "$t"
}
level1_case "pin: level 1 that makes svp-apps on main" "$pin_a" refs/heads/main \
  "argocd/root for prd on eks on arm64 nodes: svp-apps has '$gitops_url argocd/apps refs/heads/main refs/heads/main' (repoURL, path, targetRevision, valuesObject.targetRevision), want '$gitops_url argocd/apps $pin_a $pin_a'"
level1_case "pin: level 1 that hands level 2 another content than envs/prd/ of the tree" \
  '"svpLevelOneCase":"main"' '"svpLevelOneCase":"stale"' \
  "argocd/apps at ${pin_a:0:12} for prd on eks on arm64 nodes: Application gateway has the helm.valuesObject above (>), want envs/prd/gateway.yaml < envs/prd/images/gateway.yaml"
# level2_case NAME FROM TO MESSAGE: a commit on main whose argocd/apps has a second source of svp-gitops, ref main at
# refs/heads/main, beside the one with ref values, and reads through ref TO every values file it read through ref FROM
# ($FROM/ becomes $TO/ in its template; none when FROM is TO), pinned by prd, fails the check with MESSAGE, PIN in it
# standing for that commit.
level2_case() {
  local t commit f=argocd/apps/templates/applications.yaml
  t=$(gcopy)
  if ! replace_once "$t/$f" '      ref: values
' '      ref: values
    - repoURL: {{ $.Values.repoURL }}
      targetRevision: refs/heads/main
      ref: main
'; then
    fail "$1: the root chart no longer holds the one source with ref values this case adds a source beside"
    return
  fi
  if [ "$2" != "$3" ]; then
    sed -i.bak "s|\\\$$2/|\\\$$3/|g" "$t/$f" && rm "$t/$f.bak"
    if ! grep -q "\\\$$3/" "$t/$f"; then
      fail "$1: the root chart names no values file through the ref this case changes"
      return
    fi
  fi
  pg "$t" commit -qm "$1" -- "$f"
  commit=$(pg "$t" rev-parse HEAD)
  pg "$t" update-ref refs/remotes/origin/main "$commit"
  set_pin "$t" "$commit"
  check_root "$1" 1 "${4//PIN/$commit}" "$t"
}
level2_case "pin: level 2 with a second source of svp-gitops on main beside the pinned one" values values \
  "Application gateway has sources of $gitops_url at the revisions PIN refs/heads/main; Argo CD refuses an Application whose values files reference one repository at two revisions"
level2_case "pin: level 2 that reads base/ and platforms/ on main" values main \
  "Application gateway reads base/services/gateway.yaml at refs/heads/main"

# --- the policies on rendered manifests (deploy/ci/gitops-policies/), through the Kyverno CLI of KYVERNO_CLI_IMAGE.
# Their kyverno test first: what each must fail and pass, field by field.
if out=$(make -s -C "$repo_root" kyverno-test 2>&1); then
  ok "policies: kyverno test of deploy/ci/gitops-policies/"
else
  fail "policies: kyverno test of deploy/ci/gitops-policies/ failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
fi
# Then the messages of the rule of steps 3 and 4 (gitops-check.sh --policy): resource and file named.
pd=$work/policies
mkdir -p "$pd/base"
# policy_case NAME WANT_RC POLICY MESSAGE FILE...: gitops-check.sh --policy POLICY FILE... (run from $pd, so the files
# are named relative to it) exits WANT_RC (0 or 1) with MESSAGE on its output.
policy_case() {
  local name=$1 want=$2 policy=$3 msg=$4 out rc=0
  shift 4
  out=$(cd "$pd" && "$here/gitops-check.sh" --policy "$policy" "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want" ]; then
    fail "policies: $name: exit $rc, want $want:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  elif [[ $out == *"$msg"* ]]; then
    ok "policies: $name"
  else
    fail "policies: $name: no '$msg' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
pin=sha256:1111111111111111111111111111111111111111111111111111111111111111
# A render as helm prints it: a document of comments alone and a CustomResourceDefinition, which the CLI is not given.
cat >"$pd/base/pinned.yaml" <<EOF
---
# Source: chart/templates/crds.yaml
# comments alone
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: things.example.com
spec:
  group: example.com
  names: {kind: Thing, plural: things}
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            image: {type: string, default: "busybox:1.37"}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: operator
  namespace: platform
spec:
  template:
    spec:
      containers:
        - name: c
          image: quay.io/example/operator:v1@$pin
          args:
            - --helper-image=quay.io/example/helper:v1@$pin
EOF
policy_case "every image pinned, comments and CRDs left out" 0 images-pinned \
  "ok    policy images-pinned: 1 resources pass" base/pinned.yaml
sed "s|quay.io/example/helper:v1@$pin|quay.io/example/helper:v1|" "$pd/base/pinned.yaml" >"$pd/base/flag.yaml"
policy_case "an image flag without its digest, named with its resource and file" 1 images-pinned \
  "  base/flag.yaml: Deployment platform/operator: images without exactly one @sha256:<64 hex>: quay.io/example/helper:v1" \
  base/flag.yaml
cat >"$pd/base/outside.yaml" <<EOF
apiVersion: example.com/v1
kind: Thing
metadata:
  name: thing
  namespace: platform
spec:
  workers:
    template:
      image: quay.io/example/worker:v2
EOF
policy_case "an image where the policy does not read fails as outside it" 1 images-pinned \
  "  base/outside.yaml: quay.io/example/worker:v2 (in a field policy images-pinned does not read: add it there)" \
  base/outside.yaml
cat >"$pd/base/route.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: svp
spec:
  hostnames: [api.svp.localhost]
EOF
policy_case "the lab host on a route" 1 no-lab-hosts \
  "  base/route.yaml: HTTPRoute svp/api: names the lab host svp.localhost: api.svp.localhost" base/route.yaml
sed 's/api\.svp\.localhost/api.example.com/' "$pd/base/route.yaml" >"$pd/base/route-ok.yaml"
policy_case "a real host on a route" 0 no-lab-hosts "ok    policy no-lab-hosts: 1 resources pass" base/route-ok.yaml
# Files of comments and a CustomResourceDefinition alone leave nothing to apply a policy to: no CLI run, one ok line naming
# the folder.
cat >"$pd/base/crd-only.yaml" <<'EOF'
---
# Source: chart/templates/crds.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: things.example.com
spec:
  group: example.com
  names: {kind: Thing, plural: things}
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
EOF
policy_case "files of CRDs and comments alone have no resource to check" 0 images-pinned \
  "ok    policy images-pinned: 0 resources pass" base/crd-only.yaml
# Two renders of one kind and name without a namespace make the Kyverno CLI panic: the case is named instead.
for n in one two; do
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: dup\n' >"$pd/base/ns-$n.yaml"
done
policy_case "one resource rendered twice without a namespace is named, not a panic" 1 no-lab-hosts \
  "base/ns-one.yaml base/ns-two.yaml: Namespace dup is rendered 2 times without a namespace" base/ns-one.yaml base/ns-two.yaml
# A policy that does not compile applies to nothing: the check fails instead of passing. On a copy of deploy/ci/ and
# deploy/k8s/lib.sh, the policy's last expression broken.
bad=$work/bad-policy
mkdir -p "$bad/deploy/k8s"
cp -R "$here" "$bad/deploy/ci"
cp "$repo_root/deploy/k8s/lib.sh" "$bad/deploy/k8s/"
cp "$repo_root/deploy/docker-bake.json" "$bad/deploy/"
cp "$repo_root/Makefile" "$bad/"
sed -i.bak 's/^    - expression: size(variables.unpinned) == 0$/    - expression: size(variables.unpinned) == "0"/' \
  "$bad/deploy/ci/gitops-policies/images-pinned.yaml" && rm "$bad/deploy/ci/gitops-policies/images-pinned.yaml.bak"
if grep -q '== "0"' "$bad/deploy/ci/gitops-policies/images-pinned.yaml"; then
  out=$(cd "$pd" && "$bad/deploy/ci/gitops-check.sh" --policy images-pinned base/pinned.yaml 2>&1) && rc=0 || rc=$?
  if [ "$rc" = 1 ] && [[ $out == *"policy images-pinned has 0 results for the 1 resources rendered"* ||
    $out == *"the Kyverno CLI gave no report of policy images-pinned"* ]]; then
    ok "policies: a policy that does not compile fails the check"
  else
    fail "policies: a policy that does not compile: exit $rc:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
else
  fail "policies: images-pinned.yaml no longer holds the validation the case of a broken policy changes"
fi

# --- the release sources of the image files (step 1 alone: gitops-check.sh --tree). A throwaway copy of this
# repository on its branch main: k0 holds the policy's values as they were before the table of release sources, k2
# the table of the rename (backend and web under their new names, the retired oldbackend and oldweb under the old
# ones, without promoter), k3 the table of the working tree; origin/main is k3.
services=(gateway user-service video-service engagement-service feed-service media-worker web)
code=$work/code
mkdir -p "$code/deploy/k8s" "$code/deploy/helm/svp-policy/files" "$code/deploy/helm/svp-cluster" \
  "$code/deploy/observability/otelcol"
cp -R "$here" "$code/deploy/ci"
cp "$repo_root/deploy/k8s/lib.sh" "$code/deploy/k8s/"
cp "$repo_root/deploy/docker-bake.json" "$code/deploy/"
cp "$repo_root/Makefile" "$code/"
printf 'podSecurityVersion: v1.36\n' >"$code/deploy/helm/svp-cluster/values.yaml"
echo "receivers: {}" >"$code/deploy/observability/otelcol/k8s-config.yaml"
cat >"$code/deploy/helm/svp-policy/values.yaml" <<'VALUES'
imageVerification:
  imagePrefix: ghcr.io/anhnvcoder/short-video-platform/
  issuer: https://token.actions.githubusercontent.com
  subject: https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main
  provenanceRepository: https://github.com/anhnvcoder/short-video-platform
  provenanceRef: refs/heads/main
  requireProvenance: false
VALUES
cg() { git -C "$code" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
cg init -q -b main && cg add -A && cg commit -q -m "before the table"
k0=$(cg rev-parse HEAD)
cp "$repo_root/deploy/helm/svp-policy/values.yaml" "$code/deploy/helm/svp-policy/values.yaml"
# The table of the rename (history: the commit an environment may still pin after the retired sources were dropped).
cat >"$code/deploy/helm/svp-policy/files/sources.json" <<'TABLE'
{
  "sources": [
    {
      "name": "backend",
      "repository": "https://github.com/anhnvcoder/svp-backend",
      "imagePrefix": "ghcr.io/anhnvcoder/svp-backend/",
      "services": ["gateway", "user-service", "video-service", "engagement-service", "feed-service", "media-worker"],
      "drillImages": ["drill-vulnerable", "drill-unsigned", "drill-no-provenance"],
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main",
      "provenanceRef": "refs/heads/main",
      "promoter": "svp-gitops-promoter"
    },
    {
      "name": "web",
      "repository": "https://github.com/anhnvcoder/svp-frontend",
      "imagePrefix": "ghcr.io/anhnvcoder/svp-frontend/",
      "services": ["web"],
      "drillImages": [],
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main",
      "provenanceRef": "refs/heads/main",
      "promoter": "svp-web-promoter"
    },
    {
      "name": "oldbackend",
      "repository": "https://github.com/anhnvcoder/short-video-platform",
      "imagePrefix": "ghcr.io/anhnvcoder/short-video-platform/",
      "services": ["gateway", "user-service", "video-service", "engagement-service", "feed-service", "media-worker"],
      "drillImages": [],
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main",
      "provenanceRef": "refs/heads/main"
    },
    {
      "name": "oldweb",
      "repository": "https://github.com/anhnvcoder/svp-web",
      "imagePrefix": "ghcr.io/anhnvcoder/svp-web/",
      "services": ["web"],
      "drillImages": [],
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main",
      "provenanceRef": "refs/heads/main"
    }
  ]
}
TABLE
cg add -A && cg commit -q -m "the table of the rename"
k2=$(cg rev-parse HEAD)
cp "$repo_root/deploy/helm/svp-policy/files/sources.json" "$code/deploy/helm/svp-policy/files/sources.json"
cg add -A && cg commit -q -m "the table of the working tree"
k3=$(cg rev-parse HEAD)
cg update-ref refs/remotes/origin/main "$k3"
# sources_tree STG_REV PREFIX WEB: a copy of the tree with stg at STG_REV and prd at k3 of the throwaway repository;
# the six services of stg released under PREFIX, web of stg WEB ("repository"); prd runs the releases of the
# working tree's sources. A tag is any 12 hex: which commit built a release is step 5's.
sources_tree() {
  local t env rev svc repo
  t=$(copy)
  for env in stg prd; do
    rev=$1
    [ "$env" = stg ] || rev=$k3
    printf 'revision: %s\npodSecurityVersion: v1.36\ncollectorConfigSha256: %s\n' "$rev" \
      "$(shasum -a 256 <"$code/deploy/observability/otelcol/k8s-config.yaml" | cut -d' ' -f1)" >"$t/envs/$env/charts.yaml"
    for svc in "${services[@]}"; do
      repo=ghcr.io/anhnvcoder/svp-backend/$svc
      [ "$svc" != web ] || repo=ghcr.io/anhnvcoder/svp-frontend/web
      if [ "$env" = stg ]; then
        repo=$2$svc
        [ "$svc" != web ] || repo=$3
      fi
      printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "sha256:%064d"\n' "$repo" "${k0:0:12}" 0 \
        >"$t/envs/$env/images/$svc.yaml"
    done
  done
  echo "$t"
}
# tree_check NAME WANT_RC MESSAGE DIR: gitops-check.sh --tree of the throwaway repository on DIR, with no network (git
# may use local paths only); MESSAGE on its output.
tree_check() {
  local name=$1 want=$2 msg=$3 dir=$4 out rc=0
  out=$(env GIT_ALLOW_PROTOCOL=file "$code/deploy/ci/gitops-check.sh" --tree "$dir" 2>&1) || rc=$?
  if [ "$want" = 0 ] && [ "$rc" != 0 ]; then
    fail "$name: gitops-check.sh --tree failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  elif [ "$want" != 0 ] && [ "$rc" = 0 ]; then
    fail "$name: gitops-check.sh --tree passed"
  elif [[ $out == *"$msg"* ]]; then
    ok "$name"
  else
    fail "$name: no '$msg' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
t=$(sources_tree "$k2" ghcr.io/anhnvcoder/short-video-platform/ ghcr.io/anhnvcoder/svp-web/web)
tree_check "sources: the charts of the rename with the releases of the two retired sources" 0 \
  "ok    envs/stg/images/: seven releases, each of a release source the policy of ${k2:0:12} admits" "$t"
t=$(sources_tree "$k2" ghcr.io/anhnvcoder/svp-backend/ ghcr.io/anhnvcoder/svp-frontend/web)
tree_check "sources: the charts of the rename with the releases of the new sources" 0 \
  "ok    envs/stg/images/: seven releases, each of a release source the policy of ${k2:0:12} admits" "$t"
t=$(sources_tree "$k3" ghcr.io/anhnvcoder/svp-backend/ ghcr.io/anhnvcoder/svp-frontend/web)
tree_check "sources: the charts of the working tree with the releases of the new sources" 0 \
  "ok    envs/stg/images/: seven releases, each of a release source the policy of ${k3:0:12} admits" "$t"
t=$(sources_tree "$k3" ghcr.io/anhnvcoder/svp-backend/ ghcr.io/anhnvcoder/svp-web/web)
tree_check "sources: the charts of the working tree refuse a release of a retired source" 1 \
  "envs/stg/images/web.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-frontend/web with its tag and digest" "$t"
t=$(sources_tree "$k0" ghcr.io/anhnvcoder/short-video-platform/ ghcr.io/anhnvcoder/short-video-platform/web)
tree_check "sources: charts from before the table stop, naming the commit" 1 \
  "FAIL  commit ${k0:0:12} has no deploy/helm/svp-policy/files/sources.json: it is from before the table of release sources" "$t"
tree_check "sources: charts from before the table: the environment that pins them" 1 \
  "FAIL  envs/stg/charts.yaml: the release sources of ${k0:0:12} cannot be read (above)" "$t"
# A conftest that gives no answer fails the check instead of passing: a policy that does not compile (conftest stops,
# no result), a package renamed (no result from it). On copies of the throwaway repository.
t=$(sources_tree "$k3" ghcr.io/anhnvcoder/svp-backend/ ghcr.io/anhnvcoder/svp-frontend/web)
for broken in "syntax:s/^deny contains /deny contains contains /" "package:s/^package gitops.author$/package gitops.authors/"; do
  bad=$work/bad-tree-${broken%%:*}
  cp -R "$code" "$bad"
  sed -i.bak "${broken#*:}" "$bad/deploy/ci/gitops-tree-policies/author.rego" && rm "$bad/deploy/ci/gitops-tree-policies/author.rego.bak"
  if cmp -s "$code/deploy/ci/gitops-tree-policies/author.rego" "$bad/deploy/ci/gitops-tree-policies/author.rego"; then
    fail "tree policies: author.rego no longer holds what the case of a broken policy (${broken%%:*}) changes"
    continue
  fi
  rc=0
  out=$(env GIT_ALLOW_PROTOCOL=file "$bad/deploy/ci/gitops-check.sh" --tree "$t" 2>&1) || rc=$?
  if [ "$rc" = 1 ] && [[ $out == *"FAIL  conftest could not check the tree with the policies of deploy/ci/gitops-tree-policies/"* ]]; then
    ok "tree policies: a conftest that gives no answer fails the check (${broken%%:*})"
  else
    fail "tree policies: a conftest that gives no answer (${broken%%:*}): exit $rc:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
done

# values-check.sh on such a tree, as a machine runs it (env -i: no CI job's variables): the gateway's file naming the
# repository of user-service is refused before any release is verified (no other file carries a digest, so cosign is
# never asked).
t=$(sources_tree "$k3" ghcr.io/anhnvcoder/svp-backend/ ghcr.io/anhnvcoder/svp-frontend/web)
for f in "$t"/envs/*/images/*.yaml; do sed -i.bak 's/^  digest: .*/  digest: ""/' "$f" && rm "$f.bak"; done
printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-backend/user-service\n  tag: "%s"\n  digest: "sha256:%064d"\n' \
  "${k0:0:12}" 0 >"$t/envs/stg/images/gateway.yaml"
rc=0
out=$(env -i PATH="$PATH" HOME="$HOME" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null TMPDIR="${TMPDIR:-/tmp}" "$code/deploy/ci/values-check.sh" --gitops "$t" "" 2>&1) ||
  rc=$?
want="FAIL  envs/stg/images/gateway.yaml: image.repository is ghcr.io/anhnvcoder/svp-backend/user-service, a repository of user-service, not of gateway"
if [ "$rc" = 1 ] && [[ $out == *"$want"* ]] && [[ $out != *"check envs/"* ]]; then
  ok "values-check: an image file naming the repository of another service"
else
  fail "values-check: an image file naming the repository of another service (exit $rc, want 1, '$want', no release verified):"$'\n'"$(sed 's/^/      /' <<<"$out")"
fi

# --- collectorConfigSha256: the Collector's files concatenated (k8s-config.yaml, k8s-k3d.yaml, k8s-eks.yaml), a file a
# revision does not hold adding nothing. k3 holds k8s-config.yaml alone, k4 adds the two destination files, k5 changes
# k8s-eks.yaml alone; origin/main moves to k5 for these cases, then back to k3.
otelcol=$code/deploy/observability/otelcol
printf 'exporters: {}\n' >"$otelcol/k8s-k3d.yaml"
printf 'exporters: {}\n' >"$otelcol/k8s-eks.yaml"
cg add -A && cg commit -q -m "the destination files"
k4=$(cg rev-parse HEAD)
printf 'exporters:\n  debug: {}\n' >"$otelcol/k8s-eks.yaml"
cg commit -q -am "the EKS destination alone"
k5=$(cg rev-parse HEAD)
cg update-ref refs/remotes/origin/main "$k5"
# sha_tree REV SHA: sources_tree with stg at REV (the releases of the new sources) and collectorConfigSha256 SHA.
sha_tree() {
  local t
  t=$(sources_tree "$1" ghcr.io/anhnvcoder/svp-backend/ ghcr.io/anhnvcoder/svp-frontend/web)
  sed -i.bak "s/^collectorConfigSha256:.*/collectorConfigSha256: $2/" "$t/envs/stg/charts.yaml" && rm "$t/envs/stg/charts.yaml.bak"
  echo "$t"
}
sha_at() { (for f in "$@"; do cg show "$f"; done) | shasum -a 256 | cut -d' ' -f1; }
alone=$(sha_at "$k3:deploy/observability/otelcol/k8s-config.yaml")
sha4=$(sha_at "$k4:deploy/observability/otelcol/k8s-config.yaml" "$k4:deploy/observability/otelcol/k8s-k3d.yaml" \
  "$k4:deploy/observability/otelcol/k8s-eks.yaml")
sha5=$(sha_at "$k5:deploy/observability/otelcol/k8s-config.yaml" "$k5:deploy/observability/otelcol/k8s-k3d.yaml" \
  "$k5:deploy/observability/otelcol/k8s-eks.yaml")
charts_ok="podSecurityVersion and collectorConfigSha256 as that commit gives them"
tree_check "collectorConfigSha256: a revision without the destination files, the sha256 of k8s-config.yaml alone" 0 \
  "ok    envs/stg/charts.yaml: charts of ${k3:0:12} on origin/main, $charts_ok" "$(sha_tree "$k3" "$alone")"
tree_check "collectorConfigSha256: the three files concatenated" 0 \
  "ok    envs/stg/charts.yaml: charts of ${k5:0:12} on origin/main, $charts_ok" "$(sha_tree "$k5" "$sha5")"
if [ "$sha4" != "$sha5" ]; then
  ok "collectorConfigSha256: a change of k8s-eks.yaml alone changes the value"
else
  fail "collectorConfigSha256: a change of k8s-eks.yaml alone left the value $sha4"
fi
tree_check "collectorConfigSha256: the value of the files before k8s-eks.yaml changed is refused" 1 \
  "envs/stg/charts.yaml: collectorConfigSha256 is '$sha4', deploy/observability/otelcol/k8s-config.yaml, k8s-k3d.yaml and k8s-eks.yaml at ${k5:0:12}, concatenated, have sha256 $sha5" \
  "$(sha_tree "$k5" "$sha4")"
cg update-ref refs/remotes/origin/main "$k3"
cg checkout -q "$k3"

# --- the author of a pull request (gitops-check.sh --tree DIR BASE, as a machine runs it: env -i, no CI job variables).
# The tree becomes a git repository whose first commit a0 pins k3 in both environments; each case commits one change
# on top of a0. The author is SVP_CHANGE_REQUEST_AUTHOR, or pull_request.user.login and sender.login of an event file.
at=$(sources_tree "$k3" ghcr.io/anhnvcoder/svp-backend/ ghcr.io/anhnvcoder/svp-frontend/web)
at=$(cd "$at" && pwd -P)
ag() { git -C "$at" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
ag init -q && ag add -A && ag commit -q -m "the releases of the working tree's sources"
a0=$(ag rev-parse HEAD)
web_bot='svp-web-promoter[bot]' backend_bot='svp-gitops-promoter[bot]'
six=(gateway user-service video-service engagement-service feed-service media-worker)
# image FILE REPOSITORY SEED: writes the image block of FILE in the tree, a digest of its own for SEED.
image() {
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "sha256:%s"\n' "$2" "${k3:0:12}" \
    "$(printf '%s' "$3" | shasum -a 256 | cut -c1-64)" >"$at/$1"
}
# event AUTHOR SENDER: prints the path of a new event file of a pull request of AUTHOR whose event SENDER caused.
event() {
  local f
  f=$(mktemp "$work/event.XXXXXX")
  jq -n --arg a "$1" --arg s "$2" '{action: "synchronize", pull_request: {user: {login: $a}}, sender: {login: $s}}' >"$f"
  echo "$f"
}
# from_a0: the tree back at a0, on a branch of its own, for the next case's change.
from_a0() { ag checkout -q -f -B case "$a0"; }
# author_case NAME WANT_RC MESSAGE VAR=VALUE...: the change of the tree committed, then gitops-check.sh --tree against
# a0 with the variables VAR=VALUE (the author, or the event); MESSAGE on its output.
author_case() {
  local name=$1 want=$2 msg=$3 out rc=0
  shift 3
  ag add -A && ag commit -q -m "$name" --allow-empty
  out=$(env -i PATH="$PATH" HOME="$HOME" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null TMPDIR="${TMPDIR:-/tmp}" GIT_ALLOW_PROTOCOL=file "$@" \
    "$code/deploy/ci/gitops-check.sh" --tree "$at" "$a0" 2>&1) || rc=$?
  if [ "$want" = 0 ] && [ "$rc" != 0 ]; then
    fail "author: $name: gitops-check.sh --tree failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  elif [ "$want" != 0 ] && [ "$rc" = 0 ]; then
    fail "author: $name: gitops-check.sh --tree passed"
  elif [[ $out == *"$msg"* ]]; then
    ok "author: $name"
  else
    fail "author: $name: no '$msg' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
promoted="the promoter of a release source: its"
from_a0
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/svp-frontend/web w1
author_case "the bot of svp-frontend moves web of stg to another of its releases" 0 \
  "ok    the pull request of $web_bot, $promoted 1 changed files are all files that bot may change" \
  SVP_CHANGE_REQUEST_AUTHOR="$web_bot"
from_a0
image envs/prd/images/web.yaml ghcr.io/anhnvcoder/svp-frontend/web w2
author_case "the bot of svp-frontend moves web of prd" 0 "ok    the pull request of $web_bot, $promoted 1 changed" \
  SVP_CHANGE_REQUEST_AUTHOR="$web_bot"
from_a0
echo '# changed' >>"$at/envs/stg/charts.yaml"
for svc in "${six[@]}"; do image "envs/stg/images/$svc.yaml" "ghcr.io/anhnvcoder/svp-backend/$svc" "s-$svc"; done
author_case "the bot of backend promotes charts.yaml and the six services to stg" 0 \
  "ok    the pull request of $backend_bot, $promoted 7 changed files" SVP_CHANGE_REQUEST_AUTHOR="$backend_bot"
from_a0
echo '# changed' >>"$at/envs/prd/charts.yaml"
for svc in "${six[@]}"; do image "envs/prd/images/$svc.yaml" "ghcr.io/anhnvcoder/svp-backend/$svc" "p-$svc"; done
image envs/prd/images/web.yaml ghcr.io/anhnvcoder/svp-frontend/web p-web
author_case "the bot of backend promotes the whole set of stg to prd, web's release included" 0 \
  "ok    the pull request of $backend_bot, $promoted 8 changed files" SVP_CHANGE_REQUEST_AUTHOR="$backend_bot"
from_a0
echo '# changed' >>"$at/envs/stg/svp-cluster.yaml"
echo '# changed' >>"$at/base/tempo.yaml"
image envs/stg/images/gateway.yaml ghcr.io/anhnvcoder/svp-backend/gateway h1
author_case "a person changes an overlay, base/ and an image file" 0 \
  "ok    the pull request is by anhnvcoder, a person: the files it changes are not limited" SVP_CHANGE_REQUEST_AUTHOR=anhnvcoder
from_a0
echo '# changed' >>"$at/base/tempo.yaml"
author_case "a bot that promotes no release source changes base/" 0 \
  "ok    the pull request of renovate[bot], a bot that promotes no release source: none of its 1 changed files is under envs/" \
  SVP_CHANGE_REQUEST_AUTHOR="renovate[bot]"
# What a bot does not promote fails (each rule a case of make conftest-verify): the files changed and how, as the check
# lists them from git, reach the policy.
from_a0
image envs/stg/images/gateway.yaml ghcr.io/anhnvcoder/svp-backend/gateway x1
author_case "the bot of svp-frontend changes gateway.yaml of stg" 1 \
  "envs/stg/images/gateway.yaml: changed by $web_bot, the bot of release source web, which publishes web: it changes the image files of those services only" \
  SVP_CHANGE_REQUEST_AUTHOR="$web_bot"
from_a0
rm "$at/envs/stg/images/web.yaml"
author_case "the bot of svp-frontend deletes web.yaml" 1 \
  "envs/stg/images/web.yaml: deleted by $web_bot, the bot of release source web: a bot changes files under envs/, never deletes one" \
  SVP_CHANGE_REQUEST_AUTHOR="$web_bot"
# A path git would quote is read as it is, not let through as a path outside envs/.
from_a0
echo 'replicas: 3' >"$at/envs/stg/gätewäy.yaml"
author_case "a bot that promotes no release source adds a file of a quoted name under envs/" 1 \
  "envs/stg/gätewäy.yaml: changed by renovate[bot], a bot that promotes no release source" SVP_CHANGE_REQUEST_AUTHOR="renovate[bot]"
from_a0
image envs/stg/images/gateway.yaml ghcr.io/anhnvcoder/svp-backend/gateway e1
author_case "an author that is no login fails closed" 1 \
  "the author of the pull request cannot be read (above): the files a bot may change depend on which bot it is" \
  SVP_CHANGE_REQUEST_AUTHOR="not a login"
author_case "a run of no pull request on a machine skips the rule" 0 \
  "skip  the author of a pull request: this run checks no pull request"
author_case "a run of a push skips the rule" 0 "skip  the author of a pull request: this run checks no pull request" \
  GITHUB_EVENT_NAME=push SVP_CHANGE_REQUEST_AUTHOR="renovate[bot]"
tree_check "author: without BASE the rule skips" 0 "skip  the author of a pull request: no base" "$at"
author_case "the event of the bot of backend on its own pull request" 0 \
  "ok    the pull request of $backend_bot, $promoted 1 changed files" \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$(event "$backend_bot" "$backend_bot")" SVP_CHANGE_REQUEST_AUTHOR=anhnvcoder
author_case "the event of the bot of svp-frontend, read from the event, not SVP_CHANGE_REQUEST_AUTHOR" 1 \
  "envs/stg/images/gateway.yaml: changed by $web_bot, the bot of release source web" \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$(event "$web_bot" "$web_bot")" SVP_CHANGE_REQUEST_AUTHOR=anhnvcoder
author_case "a person pushes onto the pull request of the bot of backend" 0 \
  "ok    the pull request of $backend_bot, $promoted 1 changed files" \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$(event "$backend_bot" anhnvcoder)"
author_case "the bot of svp-frontend pushes onto the pull request of the bot of backend" 1 \
  "the commit checked was pushed by $web_bot onto the pull request of $backend_bot: a bot pushes onto its own pull requests only" \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$(event "$backend_bot" "$web_bot")"
author_case "a bot pushes onto the pull request of a person" 1 \
  "the commit checked was pushed by renovate[bot] onto the pull request of anhnvcoder" \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$(event anhnvcoder "renovate[bot]")"
author_case "a sender that is no login fails closed" 1 "the sender of the pull request's event cannot be read (above)" \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$(event "$backend_bot" "")"
author_case "an event without the pull request's author fails closed" 1 \
  "the author of the pull request cannot be read (above)" GITHUB_EVENT_NAME=pull_request \
  GITHUB_EVENT_PATH="$(f=$(mktemp "$work/event.XXXXXX") && echo '{"sender": {"login": "anhnvcoder"}}' >"$f" && echo "$f")"
author_case "an event file that cannot be read fails closed" 1 \
  "FAIL  the pull_request event in '$work/no-event.json' cannot be read" \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$work/no-event.json"

# tag_provenance_mismatch of common.sh (step 5 of the check, which needs the network): image.tag against the commit the
# release's check names, and no pass when an environment requiring provenance gets a check that names none.
tp=$work/tag-provenance
mkdir -p "$tp/envs/stg/images" "$tp/envs/prd/images"
printf 'image:\n  tag: "aaaaaaaaaaaa"\n  digest: "sha256:%064d"\n' 0 >"$tp/envs/stg/images/gateway.yaml"
cp "$tp/envs/stg/images/gateway.yaml" "$tp/envs/prd/images/gateway.yaml"
# tp_case NAME ENVS WANT OK_LINE: the check of envs/stg/images/gateway.yaml printed OK_LINE; the output must be WANT.
tp_case() {
  local got
  printf 'check envs/stg/images/gateway.yaml\n%s\n' "$4" >"$tp/out"
  got=$(bash -c '. "$1/common.sh" && tag_provenance_mismatch "$2" "$3" "$4"' _ "$here" "$tp" "$tp/out" "$2")
  [ "$got" = "$3" ] && ok "tag/provenance: $1" || fail "tag/provenance: $1: got '$got'"
}
prov_ok="ok    ghcr.io/x/gateway@sha256:0 signed, one vuln attestation, both platforms, no CRITICAL, within 2880 minutes"
tp_case "the tag is the commit the provenance names" "stg" "" \
  "$prov_ok, provenance of aaaaaaaaaaaa by https://example.invalid/images.yml@refs/heads/main"
tp_case "another commit is a mismatch" "stg" \
  "envs/stg/images/gateway.yaml: image.tag is aaaaaaaaaaaa, but its provenance says it was built from bbbbbbbbbbbb" \
  "$prov_ok, provenance of bbbbbbbbbbbb by https://example.invalid/images.yml@refs/heads/main"
tp_case "no provenance where it is required is a problem" "stg prd" \
  "envs/stg/images/gateway.yaml: stg requires provenance, but the check of its release names no provenance commit" \
  "$prov_ok"
tp_case "a reworded provenance line fails, it does not pass" "stg" \
  "envs/stg/images/gateway.yaml: stg requires provenance, but the check of its release names no provenance commit" \
  "$prov_ok, provenance from aaaaaaaaaaaa signed by https://example.invalid/images.yml@refs/heads/main"
tp_case "no provenance where none is required passes" "prd" "" "$prov_ok"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
