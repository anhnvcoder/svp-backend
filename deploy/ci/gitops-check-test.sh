#!/usr/bin/env bash
# Negative cases of deploy/ci/gitops-check.sh and of the root chart argocd/apps of a tree of the deployment repository
# svp-gitops. The rules on the tree's files (step 1) are conftest policies, each case of them a test of
# deploy/ci/gitops-tree-policies/ (make conftest-verify, run first here); this script checks what the script does around
# them and the rules that need a render, a tool or git. Each case changes one thing in a fresh copy of TREE and must
# fail with its own message; the root chart is also rendered on its own (helm template), since Argo CD relies on its
# render failing, not on the check:
#   - the policies on the tree, through the input the check builds: envs/stg/images/ with six of the seven image files
#     (the tree's entries), an empty revision in envs/stg/charts.yaml (the text of a file), a wrong
#     collectorConfigSha256 (the value the revision's commit derives), components.json without key platforms; a
#     conftest that gives no answer (a policy that does not compile) or none from one policy (a package renamed) fails
#     the check instead of passing;
#   - the root chart: six image files of seven, an image file with a key besides image, an overlay of a release of
#     chart svp-service that sets image, an unknown environment (env=nope), an empty revision;
#   - a short targetRevision (main, not refs/heads/main) for the sources of svp-gitops in argocd/apps/values.yaml;
#   - the platform layer (gitops-check.sh --root, steps 1 and 2, on copies of TREE, which must have platforms/): TREE
#     passes, each environment on each platform of key platforms of components.json, with a line for each pair it
#     leaves out; a template of a platform rendering a release's image, a root chart making Applications of another
#     platform and one reading a platform's values after the environment's each fail with their own message, while
#     argo-cd.yaml of a platform passes the policies and the root's render (a root chart that refuses the file made to
#     leave it out); k3d without localHosts fails the whole check on the render of stg there naming svp.localhost
#     (step 3, charts of this repository, no network);
#   - the Kyverno policies on rendered manifests (deploy/ci/gitops-policies/, the CLI of KYVERNO_CLI_IMAGE, no
#     network once its image is pulled): their kyverno test (make kyverno-test); through gitops-check.sh --policy, a
#     render with every image pinned passes, a document of comments alone and a CustomResourceDefinition left out; an
#     image flag without its digest fails naming file, resource and image; an image where policy images-pinned does
#     not read fails as outside it; the lab host on a route fails policy no-lab-hosts, a real one passes; a policy
#     that does not compile fails the check instead of passing;
#   - the release sources of the image files (gitops-check.sh --tree, on a throwaway copy of this repository with a
#     commit from before the table of release sources, one with the table of the rename (with the retired sources,
#     which prd may still pin) and one with the table of the working tree), the tables the check reads at each
#     revision: the table of the rename passes with the releases of the retired sources and with those of the new
#     ones; the working tree's passes with the new ones and refuses a retired one; charts from before the table stop,
#     naming the commit; values-check.sh refuses an image file naming the repository of another service before it
#     verifies any release;
#   - the author of a pull request (gitops-check.sh --tree TREE BASE on the same throwaway repository, the author in
#     SVP_CHANGE_REQUEST_AUTHOR or in an event file), how the check reads the author, the sender and the files changed:
#     the bot of svp-frontend moves web of stg and of prd, the bot of backend promotes charts.yaml and the six services
#     to stg and the whole set, web's included, to prd, a person changes anything, a bot that promotes no source
#     changes base/: each passes; the bot of svp-frontend changing gateway.yaml of stg or deleting web.yaml, a bot that
#     promotes no source adding a file of a name git quotes under envs/: each fails with its own message; an author
#     that is no login, an event without one, an event file that cannot be read, a sender that is no login, a bot
#     pushing onto another's pull request fail; a run of no pull request, of a push, or without BASE skips; the event's
#     author wins over SVP_CHANGE_REQUEST_AUTHOR, and a person pushing onto a bot's pull request is judged by the bot's
#     rule;
#   - tag_provenance_mismatch of common.sh, which step 5 reads the release checks with (offline, synthetic checks):
#     image.tag against the commit the provenance names, and a check that names no provenance commit in an environment
#     requiring provenance (a reworded line of verify-release.sh) fails instead of passing.
# First, gitops_dir of deploy/k8s/lib.sh, which every script asks for the clone of svp-gitops, in a draft workspace laid
# out as the lab's (<workspace>/backend, a git repository holding a copy of lib.sh; a worktree of it in
# <workspace>/.worktrees/; <workspace>/gitops): from the main checkout, from a folder inside it and from the worktree it
# names <workspace>/gitops once that is a clone of svp-gitops; SVP_GITOPS_DIR names another clone; a missing folder, a
# folder that is no git repository, a repository with another origin and a folder inside a clone are refused with the
# command that makes the clone, and nothing is cloned. Then gitops_clone: a GITOPS_REF that is no branch fails, and
# the next run checks out the clone it left (no index, every file read as deleted) instead of refusing it; a change to
# a checked-out clone is still refused.
# Every case fails before the check reaches the network (chart repositories, GHCR): needs bash, git, jq, helm, docker
# (conftest, the Kyverno CLI) and the history of this repository up to the tree's revisions (a full clone, origin/main fetched).
#
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

# copy: prints a fresh copy of the tree, without .git (the check needs none without BASE), symlinks kept.
copy() {
  local dir
  dir=$(mktemp -d "$work/case.XXXXXX")
  (cd "$tree" && tar -cf - --exclude .git .) | tar -xf - -C "$dir"
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
# render NAME DIR ENV MESSAGE: helm template of DIR/argocd/apps for ENV must fail with MESSAGE.
render() {
  local out
  if out=$(helm template svp-root "$2/argocd/apps" --namespace argocd --set-string "env=$3" 2>&1 >/dev/null); then
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

t=$(copy)
sed -i.bak 's|^targetRevision: .*|targetRevision: main|' "$t/argocd/apps/values.yaml" && rm "$t/argocd/apps/values.yaml.bak"
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
# Argo CD's values of a platform (deploy/k8s/gitops.sh installs Argo CD with them after argocd/bootstrap.json's): the
# file argo-cd.yaml, which the policies hold to the rules of a platform's file.
# A root chart from before the file refuses it itself: the copy's leaves it out as it leaves README.md out, as one that
# lets it through does, so the check's rules and the root's render must both pass.
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
# The root chart that reads the values of the platform after the overlay of the environment.
t=$(copy)
if replace_once "$t/argocd/apps/templates/applications.yaml" '          {{- with $platformFile }}
          - $values/{{ . }}
          {{- end }}
          {{- with $overlay }}
          - $values/{{ . }}
          {{- end }}' '          {{- with $overlay }}
          - $values/{{ . }}
          {{- end }}
          {{- with $platformFile }}
          - $values/{{ . }}
          {{- end }}'; then
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

# --- the author of a pull request (gitops-check.sh --tree DIR BASE of the throwaway repository, as a machine runs it:
# env -i, so no CI job's variables). The tree becomes a git repository whose first commit a0 pins k3 in both
# environments with releases of the working tree's sources; each case commits one change on top of a0. The author is
# SVP_CHANGE_REQUEST_AUTHOR, or pull_request.user.login and sender.login of an event file, as the workflow of svp-gitops
# gives them (GITHUB_EVENT_NAME, GITHUB_EVENT_PATH).
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
# What each bot promotes passes.
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
# Who the author is: none, unreadable, read from the event; the sender of the event.
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
