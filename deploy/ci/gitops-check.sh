#!/usr/bin/env bash
# gitops-check.sh GITOPS_DIR [BASE]: the check of a tree of the deployment repository svp-gitops (base/, envs/,
# argocd/), run by that repository's workflow from a checkout of this repository at a pinned commit, and on a machine
# against a clone. Exit 0 when every step passes; each step prints one line per thing it checked, FAIL lines on stderr.
#
# gitops-check.sh --worktree GITOPS_DIR: the same render of a clone of svp-gitops (main, in CI), with the charts of this
# repository's working tree standing for the revision of every environment: what `make helm-check` runs on a change of
# the charts before it is merged. Step 1 then checks the shape of charts.yaml and of the image files only, since the
# revision they pin and what derives from it are svp-gitops's own check, and step 5 (the release images, which are
# svp-gitops's) is left out.
#
#   1. The tree: envs/ holds exactly stg and prd. Each envs/<env>/charts.yaml holds exactly revision (a full commit of
#      this repository on origin/main), podSecurityVersion and collectorConfigSha256, both equal to what that commit
#      gives (podSecurityVersion of deploy/helm/svp-cluster/values.yaml, the sha256 of
#      deploy/observability/otelcol/k8s-config.yaml). envs/<env>/images/ holds exactly one file per service, each the
#      image block alone (repository, tag, digest), the repository that service's image of a release source of the
#      table chart svp-policy reads at revision (release_source_of of deploy/k8s/lib.sh: what the policy of <env>
#      admits); a revision from before that table fails. Whether the release is signed, and built from the commit its
#      tag names, is step 5's.
#      The platform layer: key platforms of argocd/apps/components.json maps each platform to the environments that run
#      on it (envs, each of stg and prd on at least one platform) and whether its renders may name the lab's
#      *.svp.localhost (localHosts, false when left out); a missing or malformed key fails. platforms/ holds exactly a
#      folder per platform of that map, argocd/apps/files/platforms is a symlink to it, each file of
#      platforms/<platform>/ is README.md, <name>.yaml or <name>.values.tpl with <name> a component that runs on that
#      platform, or argo-cd.yaml, the platform's values of Argo CD (after argocd/bootstrap.json's), and platforms of a
#      component in components.json, when set, lists platforms of the map, each once (no
#      platforms: every platform). A tree without platforms/ fails.
#      The author of a pull request, with BASE: a bot's pull request merges with no review where no code owner owns
#      the files (envs/stg/), so a bot's token, leaked or misused, may change only what that bot promotes. Each file
#      changed from BASE to HEAD of a pull request whose author is a bot (pull_request.user.login of the event in
#      GITHUB_EVENT_PATH; on a machine, where GITHUB_EVENT_NAME is unset, SVP_CHANGE_REQUEST_AUTHOR) is judged with
#      the table of release sources at the revision its environment pins at HEAD. The bot <promoter>[bot] of source N
#      changes envs/stg/images/<svc>.yaml and envs/prd/images/<svc>.yaml with <svc> in N's services; the bot of
#      backend, whose repository holds the charts, also envs/stg/charts.yaml, envs/prd/charts.yaml and every image
#      file of envs/prd/images/ (the promote to prd copies the whole set of stg, web's included); nothing else, and no
#      bot deletes a file. A bot that promotes no source (Renovate) changes nothing under envs/. A person's pull
#      request is not limited here. A bot that caused the event (sender.login: who opened the pull request or pushed
#      the commit checked) other than the author fails, since the files allowed are the author's. An author or sender
#      that cannot be read fails; without BASE, or for a run of no pull request, the rule prints one skip line.
#      gitops-check.sh --tree GITOPS_DIR [BASE] runs this step alone (its test).
#   2. The root chart argocd/apps for each environment on each platform the platform layer runs it on, on amd64 and
#      arm64 nodes (helm lint and template). The root gets value platform, and on
#      eks value cluster from deploy/ci/cluster-values.example.yaml, the form the bootstrap sets with the session's
#      real values, which never go to git: argocd/apps/values.yaml sets no cluster (or an empty map), and no file of
#      platforms/ sets a key cluster. A file of platforms/ is held to an overlay's rules: a YAML map, no image, canary or
#      httpRoute.name for a release of chart svp-service (envs/<env>/images/ names its image), and the same for what
#      the root renders from a template <name>.values.tpl (helm.valuesObject of the Application). The root fails when
#      an overlay or an image file breaks its rules. It makes one Application per component that runs on the platform,
#      each reading the values files base/ (and archValues of its architecture) < platforms/<platform>/<name>.yaml <
#      envs/<env>/<name>.yaml < envs/<env>/images/<name>.yaml that exist, in that order, then a valuesObject exactly
#      when platforms/<platform>/<name>.values.tpl exists. Every source it reads from svp-gitops names a full ref
#      (refs/heads/<branch>) or a commit as targetRevision, never a short name, which Argo CD may resolve to a tag of
#      that name. Argo Rollouts gets exactly one traffic router plugin on each architecture, the asset built for it,
#      both of one release. gitops-check.sh --root GITOPS_DIR runs steps 1 and 2 alone (their test, no network).
#   3. The charts of this repository (deploy/helm/*, at the revision of each environment) with base/ alone and with
#      the values each environment on each platform reads, as Argo CD reads them (helm lint and template); no render on
#      a platform without localHosts names svp.localhost: a grep of their whole text, and policy no-lab-hosts of
#      deploy/ci/gitops-policies/ on the charts' renders (hosts of routes, Gateways and Ingresses, the env values of
#      containers). Chart svp-cluster: no ExternalSecret or SecretStore with base/
#      alone (the dev path's), one ExternalSecret per entry of its files/external-secrets.yaml and one SecretStore per
#      namespace there in each environment on each platform, the entries with inClusterObjectStore left out where its
#      s3.mode is external and those with enabledBy where that key of externalSecrets is not true (provider
#      kubernetes in stg, aws in prd, no svp-secrets in prd), valid against the CRDs of the External Secrets chart
#      components.json pins (kubeconform -strict in KUBECONFORM_IMAGE of the Makefile).
#   4. Every image pinned by digest. Renders, with `helm template --include-crds`, every component of
#      components.json with its base/ values (upstream charts at their pinned versions, the charts of this repository
#      at each revision; a component that does not run on k3d, the dev path's platform, with its platform's values
#      instead) and Argo CD as argocd/bootstrap.json installs it, then again with each platform's argo-cd.yaml, as
#      deploy/k8s/gitops.sh installs it there. Policy images-pinned of deploy/ci/gitops-policies/
#      holds every image of those renders to exactly one digest: image fields of containers, image settings in their
#      env, args and command (an operator's --xxx-image=... flag, an env value it starts pods from), image keys of a
#      custom resource's spec, image settings in a ConfigMap (see the policy). Kyverno checks only the release images
#      of namespace svp at admission, so the images of the platform namespaces are held to their digests here instead:
#      a tag can be pushed again to other content, a digest cannot. Under the policy, a scan of the renders' text
#      (image_refs) for any other image reference without its digest fails it as outside the policy. Every environment
#      runs the images built once for the base: each component with values of a platform (platforms/<platform>/) is
#      rendered again with them, and that render runs no other version (tag or digest) of an image the base runs,
#      though it may run fewer or others (the cloud's object store instead of the cluster's, a controller of the
#      cloud); each component with an overlay in envs/<env>/ is rendered again with it after those, and the images of
#      that render, the seven service images included, must be exactly those of the render it adds to (the
#      platform's, else the base's), compared on the images image_refs reads. The images of every render are held to
#      their digests.
#   5. deploy/ci/values-check.sh --gitops on the image files changed from commit BASE to HEAD of GITOPS_DIR (every one
#      without BASE): signed release, vuln attestation, and the build provenance the environment's policy asks for.
#      For a release whose provenance was checked, image.tag must be the 12 hex of the commit the provenance names
#      (tag_provenance_mismatch of common.sh); in an environment that requires provenance, a check of a release that
#      names no provenance commit fails too.
#
# gitops-check.sh --policy images-pinned|no-lab-hosts FILE...: the rule of step 4 or of step 3's policy alone, on
# rendered manifests as they are (its test).
#
# GITOPS_DIR is read, never written: everything else happens in a temporary directory. Needs bash, git, jq, helm,
# docker and network access (chart repositories, GHCR), and, without --worktree, the history of this repository up to
# every revision (a full clone, origin/main fetched). With BASE, GITOPS_DIR must be the top of its own git repository.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

worktree='' tree_only='' root_only='' policy_only=''
if [ "${1:-}" = --policy ]; then
  policy_only=${2:-}
  case $policy_only in images-pinned | no-lab-hosts) ;; *) policy_only= ;; esac
  [ -n "$policy_only" ] && [ $# -ge 3 ] || fail "usage: gitops-check.sh --policy images-pinned|no-lab-hosts FILE..."
  shift 2
elif [ "${1:-}" = --worktree ]; then
  worktree=1
  shift
  [ $# -eq 1 ] || fail "usage: gitops-check.sh --worktree GITOPS_DIR"
elif [ "${1:-}" = --tree ]; then
  tree_only=1
  shift
  [ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: gitops-check.sh --tree GITOPS_DIR [BASE]"
elif [ "${1:-}" = --root ]; then
  root_only=1
  shift
  [ $# -eq 1 ] || fail "usage: gitops-check.sh --root GITOPS_DIR"
fi
if [ -n "$policy_only" ]; then
  tools="jq docker"
else
  [ $# -ge 1 ] && [ $# -le 2 ] ||
    fail "usage: gitops-check.sh GITOPS_DIR [BASE] | gitops-check.sh --worktree GITOPS_DIR | gitops-check.sh --tree GITOPS_DIR [BASE] | gitops-check.sh --root GITOPS_DIR | gitops-check.sh --policy images-pinned|no-lab-hosts FILE..."
  tree=$(cd "$1" 2>/dev/null && pwd -P) || fail "$1 is not a directory"
  base=${2:-}
  tools="git jq helm docker"
  [ -z "$tree_only" ] || tools="git jq"
  [ -z "$root_only" ] || tools="git jq helm"
fi
for tool in $tools; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
main=origin/main
envs="prd stg"
# The platform of the dev path (make k8s-up), which installs every component that runs on it with base/ alone: the
# renders with base/ alone are that platform's.
dev_platform=k3d
# The release source whose repository holds the charts: its bot also promotes charts.yaml and prd.
chart_source=backend
service_chart=deploy/helm/svp-service
zero_digest=sha256:0000000000000000000000000000000000000000000000000000000000000000

tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
# Helm's repository list, index cache and pulled charts stay in the temporary directory, not in .k8s/helm of the dev
# path nor in the user's configuration.
export HELM_CACHE_HOME=$tmp/helm/cache HELM_CONFIG_HOME=$tmp/helm/config HELM_DATA_HOME=$tmp/helm/data

failed=0
problem() {
  echo "FAIL  $1" >&2
  failed=1
}
# step NAME: stops after a step that found a problem, so a broken tree is not rendered.
step() {
  [ "$failed" -eq 0 ] || fail "$1: the problems above"
}

# The rules on rendered manifests are policies of deploy/ci/gitops-policies/ (images-pinned, no-lab-hosts; each with
# its kyverno test under test/), the same language as the admission of the clusters, applied by the Kyverno CLI of
# KYVERNO_CLI_IMAGE of the Makefile, without a cluster or network.
policies=$ci_dir/gitops-policies
pinned_re='^[^@]+@sha256:[0-9a-f]{64}$'
# kyverno_apply ROOT POLICY FILE...: policy POLICY on the resources of the rendered FILEs, which must not hold one
# resource twice (the CLI's fake cluster stops at a second copy). Prints one line per resource that does not pass,
# "  <file, relative to ROOT>: <kind> <namespace>/<name>: <message>", and returns 1 then, or when the CLI gives no
# report, or one without a result for every resource (a policy that does not compile applies to nothing), or when
# two resources of one kind and name are rendered without a namespace (named before the CLI is run). FILEs with no
# resource left once comments and CustomResourceDefinitions are dropped: the CLI is not run, one "ok" line. Sets
# kyverno_checked to the number of resources.
kyverno_apply() {
  local root=$1 policy=$2 dir n=0 f image args=() want got
  shift 2
  image=$(tool_image KYVERNO_CLI_IMAGE) || { echo "  no Kyverno CLI to apply policy $policy with (above)"; return 1; }
  dir=$(mktemp -d "$tmp/kyverno.XXXXXX") || fail "create a directory for the Kyverno CLI"
  : >"$dir/index"
  for f in "$@"; do
    n=$((n + 1))
    # The CLI refuses a document of comments alone; CustomResourceDefinitions describe resources, they are none. Each
    # resource's file, kind, namespace and name go to the index, which names the file a result is about.
    awk -v src="${f#"$root"/}" -v index_file="$dir/index" '
      function unquote(v) { gsub(/^["'\'']|["'\'']$/, "", v); return v }
      function flush() {
        if (keep && !crd) { printf "---\n%s", doc; print src "\t" kind "\t" ns "\t" name >>index_file }
        doc = ""; keep = 0; crd = 0; meta = 0; kind = ""; ns = ""; name = ""
      }
      /^---/ { flush(); next }
      {
        doc = doc $0 "\n"
        if ($0 ~ /^[^#[:space:]]/) { keep = 1; meta = ($0 ~ /^metadata:/) }
        if ($0 ~ /^kind:/) { kind = unquote($2); if (kind == "CustomResourceDefinition") crd = 1 }
        if (meta && $0 ~ /^  name:/) name = unquote($2)
        if (meta && $0 ~ /^  namespace:/) ns = unquote($2)
      }
      END { flush() }' "$f" >"$dir/$n.yaml"
    args+=(--resource "/r/$n.yaml")
  done
  kyverno_checked=$(wc -l <"$dir/index" | tr -d ' ')
  if [ "$kyverno_checked" -eq 0 ]; then
    echo "  ok    no resources to apply policy $policy to in $(dirname "${1#"$root"/}"): comments and CustomResourceDefinitions alone"
    return 0
  fi
  # The CLI panics on a second copy of a resource rendered without a namespace (it reads both as one in default).
  awk -F '\t' '$3 == "" { k = $2 "\t" $4; n[k]++; if (index(" " f[k] " ", " " $1 " ") == 0) f[k] = f[k] (f[k] == "" ? "" : " ") $1 }
    END { for (k in n) if (n[k] > 1) { split(k, p, "\t"); print "  " f[k] ": " p[1] " " p[2] " is rendered " n[k] " times without a namespace: the Kyverno CLI cannot apply a policy to two copies of one resource" } }' \
    "$dir/index" | sort >"$dir/duplicates"
  if [ -s "$dir/duplicates" ]; then
    cat "$dir/duplicates"
    return 1
  fi
  docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$policies:/p:ro" -v "$dir:/r:ro" "$image" apply \
    "/p/$policy.yaml" --remove-color --policy-report --output-format json "${args[@]}" >"$dir/report" 2>"$dir/err" || true
  if ! got=$(jq -e '.results | length' "$dir/report" 2>/dev/null); then
    sed 's/^/    /' "$dir/err"
    echo "  the Kyverno CLI gave no report of policy $policy (above)"
    return 1
  fi
  want=$kyverno_checked
  if [ "$got" != "$want" ]; then
    sed 's/^/    /' "$dir/err"
    echo "  policy $policy has $got results for the $want resources rendered: a policy that does not compile applies to nothing"
    return 1
  fi
  jq -r '.results[] | select(.result != "pass") | .resources[0] as $r
    | (.message | index(": ")) as $i
    | (if .result == "fail" and $i then .message[:$i + 2] + (.message[$i + 2:] | split(" ") | unique | join(" "))
       elif .result == "fail" then .message else "\(.result): \(.message)" end) as $m
    | [$r.kind, ($r.namespace // ""), $r.name, $m]
    | @tsv' "$dir/report" >"$dir/problems"
  [ -s "$dir/problems" ] || return 0
  # The files of a resource by kind and name (the CLI reports a resource rendered without a namespace in default).
  awk -F '\t' 'FILENAME == ARGV[1] { k = $2 "\t" $4; if (index(" " f[k] " ", " " $1 " ") == 0) f[k] = f[k] (f[k] == "" ? "" : " ") $1; next }
    { k = $1 "\t" $3; print "  " (k in f ? f[k] : "?") ": " $1 " " $2 "/" $3 ": " $4 }' \
    "$dir/index" "$dir/problems" | sort -u
  return 1
}
# pin_check ROOT FILE...: every image of the rendered FILEs pinned by exactly one digest. Policy images-pinned (see
# the policy for where it reads an image), then the net under it: an image reference image_refs finds in the text,
# without exactly one digest, that the policy did not name, lies where the policy does not read, and fails as such
# (extend the policy). One line per problem; status 1 with any.
pin_check() {
  local root=$1 f rc=0
  shift
  kyverno_apply "$root" images-pinned "$@" >"$tmp/pins" || rc=1
  cat "$tmp/pins"
  sed -n 's/.*: images without exactly one @sha256:<64 hex>: //p' "$tmp/pins" | tr ' ' '\n' >"$tmp/pins-named"
  for f in "$@"; do image_refs "${f#"$root"/}" "$f"; done | sort -u >"$tmp/pins-text"
  awk -F '\t' -v re="$pinned_re" 'FILENAME == ARGV[1] { named[$0] = 1; next }
    $2 !~ re && !($2 in named) { print "  " $1 ": " $2 " (in a field policy images-pinned does not read: add it there)"; bad = 1 }
    END { exit bad }' "$tmp/pins-named" "$tmp/pins-text" || rc=1
  return "$rc"
}

# image_refs NAME FILE: every image reference of the rendered manifests in FILE, "NAME<TAB>image" per line, read from
# their text wherever it is, CustomResourceDefinitions left out (their schemas describe image fields, they hold none):
# the images two renders are compared by (step 4), and the net under policy images-pinned (pin_check).
image_refs() {
  awk -v name="$1" '
    function unquote(ref) {
      gsub(/^["'\'']|["'\'',]+$/, "", ref)
      return ref
    }
    function emit(ref) {
      ref = unquote(ref)
      if (ref != "") print name "\t" ref
    }
    # A setting of an image rather than the image itself: FOO_IMAGE_PULL_POLICY, FOO_IMAGE_TAG, --image-pull-secrets=...
    function image_attribute(key) {
      key = tolower(key); gsub(/_/, "-", key)
      return key ~ /images?-?(pull-?policy|pull-?secrets?|tag|digest|version|registry|repository|repo)$/
    }
    # The value of a setting named as an image, shaped like one: a reference with "/", ":" or "@", or a bare name
    # (alpine). Not a number, a duration or a boolean: --imageVerifyCacheMaxSize=1048576 has "image" in its name too.
    function image_value(ref) {
      ref = unquote(ref)
      return ref ~ /[\/:@]/ || (ref ~ /^[a-z][a-z0-9._-]*$/ && ref !~ /^(true|false)$/)
    }
    # An env name or an upper-case key (a ConfigMap loaded as env) with the word IMAGE or IMAGES: OPERATOR_IMAGE_NAME,
    # RELATED_IMAGE_FOO.
    function image_env(key) {
      return key ~ /^[A-Z0-9_]+$/ && key ~ /(^|_)IMAGES?(_|$)/ && !image_attribute(key)
    }
    # Documents are kept whole until their kind is known.
    function flush(   i, n, line, rest, ref, key, flag) {
      if (!crd) for (i = 1; i <= nl; i++) {
        line = lines[i]
        # An env entry renders as two lines, "- name: FOO_IMAGE" then "value: ...": the name is read on the first.
        if (match(line, /^[ \t]*- name:[ \t]+["'\'']?[A-Z0-9_]+["'\'']?[ \t]*$/)) {
          key = line; sub(/^[ \t]*- name:[ \t]+/, "", key); key = unquote(key); sub(/[ \t]+$/, "", key)
          if (image_env(key) && i < nl && match(lines[i + 1], /^[ \t]*value:[ \t]+[^ \t#|>{\[]/)) {
            rest = substr(lines[i + 1], RSTART + RLENGTH - 1)
            sub(/[ \t]+#.*$/, "", rest)
            if (image_value(rest)) emit(rest)
          }
          continue
        }
        # FOO_IMAGE: ... on one line, as in a ConfigMap an operator loads as its environment.
        if (match(line, /^[ \t]*(- )?["'\'']?[A-Z0-9_]+["'\'']?:[ \t]+[^ \t#|>{\[]/)) {
          key = line; sub(/^[ \t]*(- )?/, "", key); sub(/:.*$/, "", key); key = unquote(key)
          rest = substr(line, RSTART + RLENGTH - 1)
          sub(/[ \t]+#.*$/, "", rest)
          if (image_env(key) && image_value(rest)) emit(rest)
        }
        # An image field: image:, imageName:, initImage:, any key ending in image or Image, with a scalar value.
        if (match(line, /^[ \t]*(- )?[A-Za-z]*([Ii]mage|imageName):[ \t]+[^ \t#|>{\[]/)) {
          rest = substr(line, RSTART + RLENGTH - 1)
          sub(/[ \t]+#.*$/, "", rest)
          emit(rest)
          continue
        }
        # A flag whose name holds "image" (--acme-http01-solver-image=..., --prometheus-config-reloader=... is below),
        # its value shaped like an image (image_value).
        rest = line
        while (match(rest, /--[A-Za-z0-9-]*image[A-Za-z0-9-]*=[^ \t"'\'',]+/)) {
          ref = substr(rest, RSTART, RLENGTH); flag = ref; sub(/^[^=]*=/, "", ref); sub(/=.*$/, "", flag)
          if (!image_attribute(flag) && image_value(ref)) emit(ref)
          rest = substr(rest, RSTART + RLENGTH)
        }
        # Anything else shaped like registry/path:tag or registry/path@sha256:..., the registry a host name with a
        # dot: an env value or a flag the operator starts other pods from. A URL is not one (its host follows "/").
        rest = line
        while (match(rest, /(^|[ \t"'\''=,])[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]+)?\/[A-Za-z0-9._\/-]+(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]+)?/)) {
          ref = substr(rest, RSTART, RLENGTH); sub(/^[ \t"'\''=,]/, "", ref)
          rest = substr(rest, RSTART + RLENGTH)
          if (ref ~ /\/[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+|@sha256:)/ && line !~ /--[A-Za-z0-9-]*image[A-Za-z0-9-]*=/) emit(ref)
        }
      }
      nl = 0; crd = 0
    }
    /^---/ { flush(); next }
    { lines[++nl] = $0; if ($0 ~ /^kind: CustomResourceDefinition/) crd = 1 }
    END { flush() }
  ' "$2"
}

if [ -n "$policy_only" ]; then
  # The rule of step 3 or 4 alone, on rendered files given as they are (the test of the policies' messages).
  if [ "$policy_only" = images-pinned ]; then
    pin_check "$PWD" "$@" >"$tmp/out" ||
      { printf 'FAIL  images without exactly one @sha256:<64 hex>:\n' >&2; cat "$tmp/out" >&2; exit 1; }
  else
    kyverno_apply "$PWD" no-lab-hosts "$@" >"$tmp/out" ||
      { printf 'FAIL  the lab host svp.localhost where traffic comes in or in a setting of a service:\n' >&2; cat "$tmp/out" >&2; exit 1; }
  fi
  echo "ok    policy $policy_only: $kyverno_checked resources pass"
  exit 0
fi

# --- 1. the tree
components=$tree/argocd/apps/components.json
for f in argocd/apps/Chart.yaml argocd/apps/values.yaml argocd/apps/templates/applications.yaml \
  argocd/apps/components.json argocd/project.yaml argocd/bootstrap.json; do
  [ -f "$tree/$f" ] || problem "$f is missing"
done
[ "$(readlink "$tree/argocd/apps/files/envs" 2>/dev/null)" = ../../../envs ] ||
  problem "argocd/apps/files/envs must be a symlink to ../../../envs, through which the root chart reads envs/"
step "the layout of $tree"
jq -e '.components | length > 0' "$components" >/dev/null || fail "argocd/apps/components.json lists no component"
# The release checks read the policy's settings from its chart's values and envs/<env>/svp-policy.yaml alone.
if jq -e '.components[] | select(.name == "svp-policy") | has("values")' "$components" >/dev/null; then
  problem "component svp-policy names a values file: its settings are the chart's values and envs/<env>/svp-policy.yaml, the only ones the release checks read"
fi

dirs=$(cd "$tree/envs" 2>/dev/null && for d in */; do [ -d "$d" ] && echo "${d%/}"; done | sort | paste -sd ' ' -) || dirs=
[ "$dirs" = "$envs" ] || problem "envs/ holds '$dirs': the environments are exactly prd and stg"
step "the environments of $tree"

# --- the platform layer (see the header): key platforms of components.json. targets: each environment with the
# platform the root is rendered for, <env>:<platform>, in the order of the map.
# The jq program of the check of key platforms, kept out of $(...), which bash 3.2 misreads with these quotes inside.
# Every value is tested for its type before it is read, so a malformed one is named, never a jq error.
platforms_jq='
  ($envs | split(" ")) as $e
  | if (.platforms | type) != "object" or (.platforms | length) == 0 then
      "has no key platforms, a map of each platform to {envs, localHosts}"
    else ([.platforms | to_entries[] | select((.key | test("^[a-z][a-z0-9]*$") | not)
        or (.value | type) != "object" or ((.value | keys) - ["envs", "localHosts"] | length) > 0
        or (.value.envs | type) != "array" or (.value.envs | length) == 0
        or (.value.envs | unique | length) != (.value.envs | length) or (.value.envs - $e | length) > 0
        or ((.value | has("localHosts")) and (.value.localHosts | type) != "boolean")) | .key] | join(" ")) as $bad
    | if $bad != "" then
        "platforms: \($bad) must each map a name of lowercase letters and digits to {envs: environments of \($envs), each once; localHosts: true or false, optional}"
      else ($e - [.platforms[].envs[]] | join(" ")) as $none
      | if $none != "" then "platforms: no platform runs \($none)" else "ok" end end end'
verdict=$(jq -r --arg envs "$envs" "$platforms_jq" "$components" 2>/dev/null) || verdict="cannot be read"
[ "$verdict" = ok ] || fail "argocd/apps/components.json: $verdict"
platform_names=$(jq -r '.platforms | keys | join(" ")' "$components")
targets=$(jq -r '[.platforms | to_entries[] | .key as $p | .value.envs[] | "\(.):\($p)"] | join(" ")' "$components")
# local_hosts PLATFORM: the renders of PLATFORM may name the lab's *.svp.localhost (its localHosts).
local_hosts() {
  jq -e --arg p "$1" '.platforms[$p].localHosts == true' "$components" >/dev/null
}
# runs_on NAME PLATFORM: component NAME runs on PLATFORM (no platforms in components.json: on every one).
runs_on() {
  jq -e --arg n "$1" --arg p "$2" \
    '.components[] | select(.name == $n) | select((has("platforms") | not) or (.platforms | index($p)) != null)' \
    "$components" >/dev/null
}
bad=$(jq -r '(.platforms | keys) as $k | .components[] | select(has("platforms"))
  | select(.platforms | if type != "array" then true
      else length == 0 or (unique | length) != length or (. - $k | length) > 0 end) | .name' "$components" | paste -sd ' ' -)
[ -z "$bad" ] ||
  problem "components.json: platforms of $bad must list platforms of '$platform_names', each once (no platforms: every platform)"
if [ ! -d "$tree/platforms" ]; then
  fail "platforms/ is missing: the tree is from before the platform layer, which the root chart and this check read"
fi
pdirs=$(cd "$tree/platforms" && for d in */; do [ -d "$d" ] && echo "${d%/}"; done | sort | paste -sd ' ' -) || pdirs=
[ "$pdirs" = "$platform_names" ] ||
  problem "platforms/ holds '$pdirs': the platforms are exactly those of key platforms of components.json, '$platform_names'"
[ "$(readlink "$tree/argocd/apps/files/platforms" 2>/dev/null)" = ../../../platforms ] ||
  problem "argocd/apps/files/platforms must be a symlink to ../../../platforms, through which the root chart reads platforms/"
for f in "$tree/platforms"/*; do
  if [ -e "$f" ] && [ ! -d "$f" ] && [ "${f##*/}" != README.md ]; then
    problem "platforms/${f##*/}: platforms/ holds a folder per platform (and README.md), the root reads nothing else there"
  fi
done
for plat in $platform_names; do
  for f in "$tree/platforms/$plat"/*; do
    [ -e "$f" ] || continue
    b=${f##*/}
    case $b in
    README.md | argo-cd.yaml) continue ;;
    *.values.tpl) name=${b%.values.tpl} ;;
    *.yaml) name=${b%.yaml} ;;
    *) name= ;;
    esac
    if [ -d "$f" ] || [ -z "$name" ] || ! jq -e --arg n "$name" '.components[] | select(.name == $n)' "$components" >/dev/null; then
      problem "platforms/$plat/$b: a file of a platform is README.md, <name>.yaml or <name>.values.tpl, <name> a component of components.json"
    elif ! runs_on "$name" "$plat"; then
      problem "platforms/$plat/$b: component $name does not run on $plat (its platforms in components.json)"
    fi
  done
done
step "the platforms of $tree"

# charts_field ENV KEY: the value of KEY in envs/ENV/charts.yaml.
charts_field() {
  sed -n "s/^$2: *//p" "$tree/envs/$1/charts.yaml"
}
# revision_of ENV: the revision of envs/ENV/charts.yaml, once step 1 has checked it; "worktree" with --worktree.
revision_of() {
  if [ -n "$worktree" ]; then echo worktree; else charts_field "$1" revision; fi
}
# code_of ENV: the folder that holds deploy/ of this repository as ENV runs it: the working tree with --worktree,
# otherwise its revision unpacked (below).
code_of() {
  if [ -n "$worktree" ]; then echo "$repo_root"; else echo "$tmp/code/$(revision_of "$1")"; fi
}
# label_of ENV: how messages name the charts of ENV.
label_of() {
  if [ -n "$worktree" ]; then echo "the working tree"; else revision_of "$1" | cut -c1-12; fi
}

# pr_login FIELD WHO: the login at FIELD (a jq path) of the event of the pull request this run checks, read from
# GITHUB_EVENT_PATH when GITHUB_EVENT_NAME is a pull_request event; nothing for a run of another event. On a machine
# (GITHUB_EVENT_NAME unset) the author is SVP_CHANGE_REQUEST_AUTHOR, and there is no sender. Status 1, naming the
# problem on stderr, for an event that cannot be read or a login that is no GitHub login (WHO names it).
pr_login() {
  local login
  case ${GITHUB_EVENT_NAME:-} in
  pull_request*)
    login=$(jq -r "$1"' // "" | tostring' "${GITHUB_EVENT_PATH:-}" 2>/dev/null) || {
      echo "FAIL  the $GITHUB_EVENT_NAME event in '${GITHUB_EVENT_PATH:-}' cannot be read" >&2
      return 1
    }
    ;;
  '')
    [ "$2" = author ] || return 0
    login=${SVP_CHANGE_REQUEST_AUTHOR:-}
    [ -n "$login" ] || return 0
    ;;
  *) return 0 ;;
  esac
  [[ $login =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\[bot\])?$ ]] || {
    echo "FAIL  the $2 of the pull request is '$login', not a GitHub login" >&2
    return 1
  }
  echo "$login"
}

# author_rule: the author of a pull request (step 1, see the header).
author_rule() {
  local author sender login status path env rev src name svc promoters who bad=0 n=0
  if [ -z "$base" ]; then
    echo "skip  the author of a pull request: no base, so no change of a pull request to check"
    return 0
  fi
  if ! author=$(pr_login .pull_request.user.login author); then
    problem "the author of the pull request cannot be read (above): the files a bot may change depend on which bot it is"
    return 0
  fi
  if [ -z "$author" ]; then
    echo "skip  the author of a pull request: this run checks no pull request (on a machine, SVP_CHANGE_REQUEST_AUTHOR names the author of one)"
    return 0
  fi
  if ! sender=$(pr_login .sender.login sender); then
    problem "the sender of the pull request's event cannot be read (above): a bot other than the author may have pushed onto it"
    return 0
  fi
  if [[ $sender == *'[bot]' ]] && [ "$sender" != "$author" ]; then
    problem "the commit checked was pushed by $sender onto the pull request of $author: a bot pushes onto its own pull requests only, since the files allowed are the author's"
    return 0
  fi
  if [[ $author != *'[bot]' ]]; then
    echo "ok    the pull request is by $author, a person: the files it changes are not limited by the author's rule"
    return 0
  fi
  # NUL-separated, so that a path git would quote (a byte outside ASCII, a tab) is read as it is.
  if [ "$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" != "$tree" ] ||
    ! git -C "$tree" diff --name-status -z --no-renames "$base" HEAD >"$tmp/changed" 2>/dev/null; then
    problem "list the files $author changed since $base in $tree (the top of a git repository that has that commit)"
    return 0
  fi
  login=${author%'[bot]'}
  # The table of release sources of each environment, at the revision it pins after the change.
  for env in $envs; do
    rev=$(charts_field "$env" revision 2>/dev/null) || rev=
    if ! [[ $rev =~ ^[0-9a-f]{40}$ ]] || ! (release_sources "$rev") >"$tmp/sources-$env.json"; then
      problem "the release sources of the charts of envs/$env cannot be read (above), so neither can which files $author may change"
      return 0
    fi
  done
  promoters=$(jq -r '.sources[] | select(has("promoter")) | .promoter' "$tmp"/sources-*.json | sort -u)
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    n=$((n + 1))
    if ! grep -qxF -- "$login" <<<"$promoters"; then
      case $path in
      envs/*)
        problem "$path: changed by $author, a bot that promotes no release source: such a bot changes nothing under envs/"
        bad=1
        ;;
      esac
      continue
    fi
    env= svc=
    case $path in
    envs/stg/charts.yaml | envs/prd/charts.yaml) env=${path:5:3} ;;
    envs/stg/images/*.yaml | envs/prd/images/*.yaml)
      env=${path:5:3}
      svc=${path#envs/???/images/}
      svc=${svc%.yaml}
      ;;
    esac
    if [ -z "$env" ]; then
      problem "$path: changed by $author, the bot of a release source: it changes envs/<env>/images/<service>.yaml of its own services only (the bot of $chart_source also envs/<env>/charts.yaml and envs/prd/images/)"
      bad=1
      continue
    fi
    rev=$(charts_field "$env" revision)
    src=$(jq -c --arg p "$login" '.sources[] | select(.promoter == $p)' "$tmp/sources-$env.json")
    if [ -z "$src" ]; then
      problem "$path: changed by $author, which promotes no release source of the charts envs/$env runs (${rev:0:12})"
      bad=1
      continue
    fi
    name=$(jq -r .name <<<"$src")
    who="$author, the bot of release source $name"
    if [ "$status" = D ]; then
      problem "$path: deleted by $who: a bot changes files under envs/, never deletes one"
      bad=1
    elif [ -z "$svc" ]; then
      if [ "$name" != "$chart_source" ]; then
        problem "$path: changed by $who: only the bot of $chart_source, whose repository holds the charts, changes charts.yaml"
        bad=1
      fi
    elif jq -e --arg s "$svc" '.services | index($s) != null' <<<"$src" >/dev/null; then
      :
    elif [ "$env" = prd ] && [ "$name" = "$chart_source" ] && [[ " ${svp_services[*]} " == *" $svc "* ]]; then
      : # The promote to prd copies every image file of stg, those of other sources too.
    else
      problem "$path: changed by $who, which publishes $(jq -r '.services | join(" ")' <<<"$src"): it changes the image files of those services only"
      bad=1
    fi
  done <"$tmp/changed"
  [ "$bad" -eq 0 ] || return 0
  if grep -qxF -- "$login" <<<"$promoters"; then
    echo "ok    the pull request of $author, the promoter of a release source: its $n changed files are all files that bot may change"
  else
    echo "ok    the pull request of $author, a bot that promotes no release source: none of its $n changed files is under envs/"
  fi
}

for env in $envs; do
  charts=$tree/envs/$env/charts.yaml
  if [ ! -f "$charts" ]; then
    problem "envs/$env/charts.yaml is missing: it pins the commit of this repository whose charts $env runs"
    continue
  fi
  keys=$(grep -Ev '^[[:space:]]*(#.*)?$' "$charts" | sed 's/:.*//' | sort | paste -sd ' ' -)
  if [ "$keys" != "collectorConfigSha256 podSecurityVersion revision" ]; then
    problem "envs/$env/charts.yaml holds '$keys': exactly revision, podSecurityVersion and collectorConfigSha256, one line each"
    continue
  fi
  rev=$(charts_field "$env" revision)
  if [ -n "$worktree" ]; then
    echo "ok    envs/$env/charts.yaml: revision, podSecurityVersion and collectorConfigSha256 (their values are svp-gitops's own check)"
  elif ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
    problem "envs/$env/charts.yaml: revision is '$rev', the full commit (40 hex) of this repository whose charts $env runs"
    continue
  elif ! git -C "$repo_root" cat-file -e "$rev^{commit}" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision $rev is no commit of this clone of the code repository (fetch its whole history)"
    continue
  elif ! git -C "$repo_root" merge-base --is-ancestor "$rev" "$main" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision ${rev:0:12} is not on $main of the code repository"
    continue
  else
    if ! (release_sources "$rev" >/dev/null); then
      problem "envs/$env/charts.yaml: the release sources of ${rev:0:12} cannot be read (above)"
      continue
    fi
    want=$(git -C "$repo_root" show "$rev:deploy/helm/svp-cluster/values.yaml" | sed -n 's/^podSecurityVersion: *//p')
    got=$(charts_field "$env" podSecurityVersion)
    [ "$got" = "$want" ] ||
      problem "envs/$env/charts.yaml: podSecurityVersion is '$got', deploy/helm/svp-cluster/values.yaml at ${rev:0:12} pins '$want'"
    want=$(git -C "$repo_root" show "$rev:deploy/observability/otelcol/k8s-config.yaml" | shasum -a 256 | cut -d' ' -f1)
    got=$(charts_field "$env" collectorConfigSha256)
    [ "$got" = "$want" ] ||
      problem "envs/$env/charts.yaml: collectorConfigSha256 is '$got', deploy/observability/otelcol/k8s-config.yaml at ${rev:0:12} has sha256 $want"
    echo "ok    envs/$env/charts.yaml: charts of ${rev:0:12} on $main, podSecurityVersion and collectorConfigSha256 as that commit gives them"
  fi

  images=$tree/envs/$env/images
  want=$(for svc in "${svp_services[@]}"; do echo "$svc.yaml"; done | sort | paste -sd ' ' -)
  got=$(cd "$images" 2>/dev/null && ls -A | sort | paste -sd ' ' -) || got=
  if [ "$got" != "$want" ]; then
    problem "envs/$env/images/ holds '$got': exactly one file per service, $want"
  fi
  for svc in "${svp_services[@]}"; do
    file=envs/$env/images/$svc.yaml
    [ -f "$tree/$file" ] || continue
    other=$(grep -Ev '^([[:space:]]|#|$)' "$tree/$file" | grep -vx 'image:' || true)
    if [ -n "$other" ]; then
      problem "$file holds $(sed 's/:.*//' <<<"$other" | paste -sd ' ' -) besides image: an image file holds the image block alone"
      continue
    fi
    if ! repo=$(values_field repository <"$tree/$file") || ! tag=$(values_field tag <"$tree/$file") ||
      ! digest=$(values_field digest <"$tree/$file"); then
      problem "$file: image.repository, tag and digest must each be one plain line in the image block"
      continue
    fi
    # The table of release sources of the charts env runs (the working tree's with --worktree).
    table_rev=$rev
    [ -z "$worktree" ] || table_rev=
    if ! release_source_of "$svc" "$repo" "$table_rev" >/dev/null || [ -z "$tag" ] || [ -z "$digest" ]; then
      problem "$file: the image must be a release of $(release_repositories "$svc" "$table_rev") with its tag and digest, not '$repo' '$tag' '$digest'"
    fi
  done
  if [ -n "$worktree" ]; then
    echo "ok    envs/$env/images/: seven releases, each of a release source the policy admits"
  else
    echo "ok    envs/$env/images/: seven releases, each of a release source the policy of ${rev:0:12} admits"
  fi
done
author_rule
step "the tree $tree"
[ -z "$tree_only" ] || exit 0

# The charts of this repository at each environment's revision, unpacked with git archive: neither the working tree
# nor the index of this clone is read. All of deploy/, since files of the charts are symlinks to files beside them
# (deploy/postgres/bootstrap.sql, the Collector's config, the Prometheus rules).
for env in $envs; do
  [ -z "$worktree" ] || break
  rev=$(revision_of "$env")
  [ -d "$tmp/code/$rev" ] && continue
  mkdir -p "$tmp/code/$rev"
  git -C "$repo_root" archive "$rev" deploy | tar -x -C "$tmp/code/$rev" ||
    fail "unpack deploy/ of ${rev:0:12} with git archive"
done

# --- 2. the root chart
mkdir -p "$tmp/render" "$tmp/values" "$tmp/plugins/templates" "$tmp/yj/templates"
printf 'apiVersion: v2\nname: plugins\nversion: 0.1.0\n' >"$tmp/plugins/Chart.yaml"
# The plugins of Argo Rollouts' values, one line each, as its chart reads them.
printf '%s\n' '{{- range .Values.controller.trafficRouterPlugins }}' \
  '# plugin {{ .name }} {{ .location }} {{ .sha256 }}' '{{- end }}' >"$tmp/plugins/templates/plugins.yaml"
# yaml_json FILE: prints each YAML document of FILE ("---" lines between them, as in a render) as one line of JSON,
# {"Error": "..."} for a document that is no YAML map; a document of comments alone is left out. Helm reads the YAML,
# as Argo CD's and the charts' own reading does, so the check needs no YAML tool of its own.
printf 'apiVersion: v2\nname: yj\nversion: 0.1.0\n' >"$tmp/yj/Chart.yaml"
printf '%s\n' '{{- range $doc := regexSplit `(?m)^---.*$` (.Files.Get "in/doc") -1 }}' \
  '{{- if regexMatch `(?m)^[^#\s]` $doc }}' '# json {{ fromYaml $doc | toJson }}' '{{- end }}' '{{- end }}' \
  >"$tmp/yj/templates/json.yaml"
yaml_json() {
  mkdir -p "$tmp/yj/in" && cp "$1" "$tmp/yj/in/doc" && helm template yj "$tmp/yj" | sed -n 's/^# json //p'
}
# One line per component: name, path, values, the values file of amd64 and of arm64 nodes (archValues), "" for none.
jq -r '.components[] | [.name, (.path // ""), (.values // ""), ((.archValues // {}).amd64 // ""),
  ((.archValues // {}).arm64 // "")] | join("\u001f")' "$components" >"$tmp/components" ||
  fail "read argocd/apps/components.json"
# component_field NAME FIELD: FIELD (path, values, amd64, arm64) of component NAME.
component_field() {
  awk -F $'\x1f' -v n="$1" -v f="$2" 'BEGIN { c["path"] = 2; c["values"] = 3; c["amd64"] = 4; c["arm64"] = 5 }
    $1 == n { print $c[f] }' "$tmp/components"
}
# values_files ENV PLATFORM NAME ARCH: the values files of component NAME that the root gives its Application in ENV
# on PLATFORM on ARCH nodes, relative to the tree, in the order Argo CD reads them:
# base/ and then archValues of ARCH (only with a base/ file), platforms/<platform>/<name>.yaml, envs/<env>/<name>.yaml,
# envs/<env>/images/<name>.yaml, those that exist.
values_files() {
  local v a
  v=$(component_field "$3" values)
  if [ -n "$v" ]; then
    echo "$v"
    a=$(component_field "$3" "$4")
    [ -z "$a" ] || echo "$a"
  fi
  [ ! -f "$tree/platforms/$2/$3.yaml" ] || echo "platforms/$2/$3.yaml"
  [ ! -f "$tree/envs/$1/$3.yaml" ] || echo "envs/$1/$3.yaml"
  [ ! -f "$tree/envs/$1/images/$3.yaml" ] || echo "envs/$1/images/$3.yaml"
}
# overlay_keys JSON: the keys of a release's values that only envs/<env>/images/ (image) and the base (canary,
# httpRoute.name, mirrored by canaryRoute of components.json) may set, those JSON sets.
overlay_keys() {
  jq -r '[if has("image") then "image" else empty end, if has("canary") then "canary" else empty end,
    if (.httpRoute | type) == "object" and (.httpRoute | has("name")) then "httpRoute.name" else empty end] | join(", ")' <<<"$1"
}

# The root's value cluster: the bootstrap's alone, from the values of the session (the infrastructure repository's
# output cluster_values), which never go to git.
json=$(yaml_json "$tree/argocd/apps/values.yaml" | head -n 1)
[ -n "$json" ] || json='{}'
if [ "$(jq -r 'has("Error")' <<<"$json")" = true ]; then
  problem "argocd/apps/values.yaml is no YAML map: $(jq -r .Error <<<"$json")"
elif [ "$(jq -c '.cluster // {}' <<<"$json")" != '{}' ]; then
  problem "argocd/apps/values.yaml sets cluster: the bootstrap alone sets it, from the values of the session, which never go to git (an empty map at most)"
fi
# The files of the platforms, held to an overlay's rules; what the templates render is held to them below.
for f in "$tree"/platforms/*/*.yaml; do
  [ -f "$f" ] || continue
  file=${f#"$tree"/}
  name=${f##*/}
  name=${name%.yaml}
  json=$(yaml_json "$f" | head -n 1)
  [ -n "$json" ] || json='{}'
  if [ "$(jq -r 'has("Error")' <<<"$json")" = true ]; then
    problem "$file is no YAML map: $(jq -r .Error <<<"$json")"
  elif [ "$(jq -r 'has("cluster")' <<<"$json")" = true ]; then
    problem "$file sets cluster: what depends on the cluster reaches a component through platforms/<platform>/$name.values.tpl from the root's value cluster, which the bootstrap alone sets"
  elif [ "$(component_field "$name" path)" = "$service_chart" ] && [ -n "$(overlay_keys "$json")" ]; then
    problem "$file sets $(overlay_keys "$json"): a release's image is envs/<env>/images/$name.yaml, and every platform runs the base's canary"
  fi
done
step "the values files of the platforms"

{ echo 'cluster:'; sed 's/^/  /' "$ci_dir/cluster-values.example.yaml"; } >"$tmp/cluster.yaml" ||
  fail "read deploy/ci/cluster-values.example.yaml"
for plat in $platform_names; do
  for env in $envs; do
    [[ " $targets " == *" $env:$plat "* ]] ||
      echo "skip  $env on $plat: $env is not in envs of platform $plat (key platforms of components.json), so its root is not rendered there"
  done
done
for target in $targets; do
  env=${target%%:*} plat=${target#*:}
  tag=$env-$plat label="$env on $plat"
  for arch in arm64 amd64; do
    root=$tmp/render/root-$tag-$arch.yaml
    set -- --namespace argocd --set-string "env=$env" --set "nodeArch=$arch" --set-string "platform=$plat"
    [ "$plat" != eks ] || set -- "$@" -f "$tmp/cluster.yaml"
    if ! helm lint --quiet "$tree/argocd/apps" "$@" >"$tmp/err" 2>&1 ||
      ! helm template svp-root "$tree/argocd/apps" "$@" >"$root" 2>"$tmp/err"; then
      grep -v 'found symbolic link in path' "$tmp/err" >&2 || true
      fail "helm lint and template of argocd/apps for $label on $arch nodes"
    fi
    # The targetRevision right after each repoURL of svp-gitops, as the chart writes a source.
    short=$(awk -v url="$gitops_url" '$0 ~ "repoURL: " url "$" { want = 1; next }
      want && /targetRevision:/ { v = $2; gsub(/"/, "", v)
        if (v !~ /^refs\/heads\/./ && !(v ~ /^[0-9a-f]+$/ && length(v) == 40)) print v; want = 0 }
      want && /^ *- / { want = 0 }' "$root" | sort -u | paste -sd ' ' -)
    [ "$(grep -c "repoURL: $gitops_url\$" "$root" || true)" -gt 0 ] ||
      fail "argocd/apps for $label on $arch nodes reads no values from $gitops_url"
    [ -z "$short" ] ||
      fail "argocd/apps for $label on $arch nodes: every source of $gitops_url must name a full ref (refs/heads/<branch>) or a commit as targetRevision, not $short (Argo CD may resolve a short name to a tag of that name)"
    # Each Application: its name, the values files of its source with helm, its valuesObject ("" for none).
    yaml_json "$root" | jq -r 'select(.kind == "Application") | [.spec.sources[] | select(.helm)][0].helm as $h
      | [.metadata.name, ([($h.valueFiles // [])[] | sub("^\\$values/"; "")] | join(" ")),
         (if $h | has("valuesObject") then $h.valuesObject | tojson else "" end)] | join("\u001f")' \
      >"$tmp/render/apps-$tag-$arch" || fail "read the Applications of argocd/apps for $label on $arch nodes"
    got=$(cut -d $'\x1f' -f1 "$tmp/render/apps-$tag-$arch" | sort | paste -sd ' ' -)
    want=$(cut -d $'\x1f' -f1 "$tmp/components" | while IFS= read -r name; do
      if runs_on "$name" "$plat"; then echo "$name"; fi
    done | sort | paste -sd ' ' -)
    [ "$got" = "$want" ] ||
      fail "argocd/apps for $label on $arch nodes makes the Applications '$got', want one per component of components.json that runs on $plat: '$want'"
    while IFS=$'\x1f' read -r name files object; do
      want=$(values_files "$env" "$plat" "$name" "$arch" | paste -sd ' ' -)
      [ "$files" = "$want" ] ||
        problem "argocd/apps for $label on $arch nodes: Application $name reads the values files '$files', want '$want' (base/ < platforms/<platform>/ < envs/<env>/ < envs/<env>/images/, those that exist)"
      if [ -f "$tree/platforms/$plat/$name.values.tpl" ]; then
        if [ "$(jq -r type <<<"${object:-null}")" != object ]; then
          problem "argocd/apps for $label on $arch nodes: Application $name has no helm.valuesObject, the render of platforms/$plat/$name.values.tpl"
        elif [ "$(component_field "$name" path)" = "$service_chart" ] && [ -n "$(overlay_keys "$object")" ]; then
          problem "platforms/$plat/$name.values.tpl renders $(overlay_keys "$object") for $label: a release's image is envs/<env>/images/$name.yaml, and every platform runs the base's canary"
        else
          echo "$object" >"$tmp/values/$tag-$name.json"
        fi
      elif [ -n "$object" ]; then
        problem "argocd/apps for $label on $arch nodes: Application $name has a helm.valuesObject, but no platforms/$plat/$name.values.tpl renders one"
      fi
    done <"$tmp/render/apps-$tag-$arch"
    step "the Applications of argocd/apps for $label on $arch nodes"
    files=()
    for f in $(awk -F $'\x1f' '$1 == "argo-rollouts" { print $2 }' "$tmp/render/apps-$tag-$arch"); do
      files+=(-f "$tree/$f")
    done
    [ ${#files[@]} -gt 0 ] || fail "Application argo-rollouts names no values file on $arch nodes for $label"
    helm template plugins "$tmp/plugins" "${files[@]}" | sed -n 's/^# plugin //p' >"$tmp/plugin-$arch" ||
      fail "read the plugins of Argo Rollouts on $arch nodes for $label"
    [ "$(grep -c . "$tmp/plugin-$arch")" = 1 ] &&
      grep -Eq "^[^ ]+ https://[^ ]+/[^ /]+-linux-$arch [0-9a-f]{64}$" "$tmp/plugin-$arch" ||
      fail "Argo Rollouts on $arch nodes for $label must get exactly one plugin, the asset built for linux-$arch: $(cat "$tmp/plugin-$arch")"
  done
  read -r arm_name arm_loc arm_sum <"$tmp/plugin-arm64"
  read -r amd_name amd_loc amd_sum <"$tmp/plugin-amd64"
  [ "$arm_name" = "$amd_name" ] && [ "${arm_loc%/*}" = "${amd_loc%/*}" ] && [ "$arm_sum" != "$amd_sum" ] ||
    fail "Argo Rollouts gets $arm_name of ${arm_loc%/*} on arm64 nodes, $amd_name of ${amd_loc%/*} on amd64 nodes for $label: pin the two assets of one release"
  echo "ok    argocd/apps for $label on arm64 and amd64 nodes: one Application per component that runs there, each with its values files in order; its sources of svp-gitops name full refs; Argo Rollouts gets plugin $arm_name of ${arm_loc%/*}, the asset built for each"
done
if [ -n "$root_only" ]; then
  echo "ok    $tree: the tree and its root chart"
  exit 0
fi

# target_values ENV PLATFORM NAME: the values files of component NAME as Argo CD reads them in ENV on PLATFORM, one
# absolute path per line: those of values_files (archValues of arm64 nodes: a chart of this repository has none), then
# the valuesObject the root renders from platforms/<platform>/<name>.values.tpl, when it does.
target_values() {
  local f
  values_files "$1" "$2" "$3" arm64 | while IFS= read -r f; do echo "$tree/$f"; done
  f=$tmp/values/$1-$2-$3.json
  [ ! -f "$f" ] || echo "$f"
}

# placeholder_repo SERVICE REV: the repository of SERVICE's release that a render with base/ alone gets: the first of
# the release sources that publish it in the table at REV (the working tree's for "worktree"), so the render's image is
# a service image of those charts, as an environment's would be.
placeholder_repo() {
  local rev=$2
  [ "$rev" != worktree ] || rev=
  release_repositories "$1" "$rev" | sed 's/ or .*//'
}

# --- 3. the charts of this repository
jq -r '.components[] | select(.path) | [.name, .namespace, .path, (.values // "")] | @tsv' "$components" >"$tmp/charts"
while IFS=$'\t' read -r name ns path values; do
  for env in $envs; do
    chart=$(code_of "$env")/$path
    [ -d "$chart" ] || fail "component $name: no chart $path at $(label_of "$env") (charts of envs/$env)"
    # base/ alone, as the dev path installs a component of k3d. Alone, base/ has no image for a release of chart
    # svp-service: a placeholder renders it as the dev path's does.
    if runs_on "$name" "$dev_platform"; then
      args=(--namespace "$ns")
      [ -z "$values" ] || args+=(-f "$tree/$values")
      [ "$path" != "$service_chart" ] || args+=(--set-string "image.repository=$(placeholder_repo "$name" "$(revision_of "$env")")"
        --set-string image.tag=000000000000 --set-string "image.digest=$zero_digest")
      if ! helm lint --quiet "$chart" "${args[@]}" >"$tmp/err" 2>&1 ||
        ! helm template "$name" "$chart" "${args[@]}" >"$tmp/render/base-$env-$name.yaml" 2>"$tmp/err"; then
        cat "$tmp/err" >&2
        fail "helm lint and template of $name ($path at $(label_of "$env")) with the values of base"
      fi
    fi
    for target in $targets; do
      [ "${target%%:*}" = "$env" ] || continue
      plat=${target#*:}
      runs_on "$name" "$plat" || continue
      args=(--namespace "$ns")
      while IFS= read -r f; do args+=(-f "$f"); done < <(target_values "$env" "$plat" "$name")
      if ! helm lint --quiet "$chart" "${args[@]}" >"$tmp/err" 2>&1 ||
        ! helm template "$name" "$chart" "${args[@]}" >"$tmp/render/t-$env-$plat-$name.yaml" 2>"$tmp/err"; then
        cat "$tmp/err" >&2
        fail "helm lint and template of $name ($path at $(label_of "$env")) with the values of $env on $plat"
      fi
    done
  done
  echo "ok    $name: $path with base/ alone and with the values of each environment on each platform"
done <"$tmp/charts"
# Real names in every render of a platform without localHosts.
real=() real_targets=
for target in $targets; do
  env=${target%%:*} plat=${target#*:}
  ! local_hosts "$plat" || continue
  real_targets+="${real_targets:+, }$env on $plat"
  for f in "$tmp/render/t-$env-$plat"-*.yaml "$tmp/render/root-$env-$plat"-*.yaml; do
    [ ! -f "$f" ] || real+=("$f")
  done
done
if [ ${#real[@]} -gt 0 ] && grep -n 'svp\.localhost' "${real[@]}" >"$tmp/leftover"; then
  sed "s|^$tmp/render/||" "$tmp/leftover" >&2
  fail "the render above still names svp.localhost on a platform without localHosts in components.json: override it in envs/<env>/ or platforms/<platform>/"
fi
# The same rule as a policy, where traffic comes in and in the settings of a service, on the charts' renders of each
# such environment on its platform (the grep above reads every byte; the policy reads the fields).
lab_checked=0
for target in $targets; do
  env=${target%%:*} plat=${target#*:}
  ! local_hosts "$plat" || continue
  set -- "$tmp/render/t-$env-$plat"-*.yaml
  [ -f "$1" ] || continue
  kyverno_apply "$tmp/render" no-lab-hosts "$@" >"$tmp/lab" ||
    { cat "$tmp/lab" >&2; fail "policy no-lab-hosts: the render of $env on $plat above names svp.localhost where traffic comes in or in a setting of a service"; }
  lab_checked=$((lab_checked + kyverno_checked))
done
echo "ok    ${real_targets:-no render}: no svp.localhost in the render of the root or of any chart of the code repository (no localHosts on their platform); policy no-lab-hosts passes on the $lab_checked resources of those charts"

# External Secrets of chart svp-cluster.
eso=$(jq -r '.components[] | select(.name == "external-secrets") | "\(.repo) \(.chart) \(.version) \(.values)"' \
  "$components")
[ -n "$eso" ] || fail "no component external-secrets in argocd/apps/components.json"
read -r eso_repo eso_chart eso_version eso_values <<<"$eso"
mkdir -p "$tmp/eso/crds" "$tmp/eso/schemas" "$tmp/eso/manifests" "$tmp/mv/templates"
helm template external-secrets "$eso_chart" --repo "$eso_repo" --version "$eso_version" --namespace external-secrets \
  -f "$tree/$eso_values" --show-only templates/crds/externalsecret.yaml --show-only templates/crds/secretstore.yaml \
  >"$tmp/eso/crds/crds.yaml" || fail "render the CRDs of external-secrets $eso_version"
kubeconform=$(tool_image KUBECONFORM_IMAGE)
docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$tmp/eso/crds:/crds:ro" -v "$tmp/eso/schemas:/schemas" \
  --workdir /schemas -e 'FILENAME_FORMAT={kind}-{fullgroup}-{version}' -e DENY_ROOT_ADDITIONAL_PROPERTIES=1 \
  --entrypoint /openapi2jsonschema "$kubeconform" /crds/crds.yaml >"$tmp/eso/o2j.log" 2>&1 ||
  { cat "$tmp/eso/o2j.log" >&2; fail "schemas from the CRDs of external-secrets $eso_version"; }
# openapi2jsonschema turns provider crd of SecretStore into a schema no manifest can pass; no store uses it.
ss_schema=$tmp/eso/schemas/secretstore-external-secrets.io-v1.json
jq -e '.properties.spec.properties.provider.properties.crd' "$ss_schema" >/dev/null ||
  fail "no provider crd in ${ss_schema##*/}: drop the step that removes it"
jq 'del(.properties.spec.properties.provider.properties.crd)' "$ss_schema" >"$tmp/eso/ss.json" &&
  mv "$tmp/eso/ss.json" "$ss_schema"
for env in $envs; do
  if [ -f "$tmp/render/base-$env-svp-cluster.yaml" ] &&
    grep -Eq '^kind: (ExternalSecret|SecretStore)$' "$tmp/render/base-$env-svp-cluster.yaml"; then
    fail "svp-cluster at $(label_of "$env") with base/ alone (the dev path's) renders an ExternalSecret or a SecretStore"
  fi
done
# The chart's merged values, read by a chart holding its values.yaml and printing them: s3.mode decides which entries of
# files/external-secrets.yaml exist (a chart from before s3.mode has one object store, in the cluster).
printf 'apiVersion: v2\nname: mv\nversion: 0.1.0\n' >"$tmp/mv/Chart.yaml"
printf '%s\n' '# json {{ toJson .Values }}' >"$tmp/mv/templates/values.yaml"
for target in $targets; do
  env=${target%%:*} plat=${target#*:}
  tag=$env-$plat label="$env on $plat"
  runs_on svp-cluster "$plat" || continue
  code=$(code_of "$env")
  args=(--namespace cert-manager)
  while IFS= read -r f; do args+=(-f "$f"); done < <(target_values "$env" "$plat" svp-cluster)
  cp "$code/deploy/helm/svp-cluster/values.yaml" "$tmp/mv/values.yaml"
  merged=$(helm template mv "$tmp/mv" "${args[@]}" | sed -n 's/^# json //p') && [ -n "$merged" ] ||
    fail "read the values of svp-cluster for $label"
  mode=$(jq -r '.s3.mode // "cluster"' <<<"$merged") || fail "read s3.mode of svp-cluster for $label"
  # The keys of externalSecrets that are true, which turn on the entries naming them in enabledBy.
  enabled=$(jq -r '.externalSecrets // {} | to_entries[] | select(.value == true) | .key' <<<"$merged" | paste -sd ' ' -) ||
    fail "read externalSecrets of svp-cluster for $label"
  list=$code/deploy/helm/svp-cluster/files/external-secrets.yaml
  # One ExternalSecret per entry, one SecretStore per namespace of the entries; with a managed object store
  # (s3.mode external) no entry with inClusterObjectStore: true; no entry whose enabledBy is not true.
  read -r want_es want_ss < <(awk -v external="$([ "$mode" = external ] && echo 1)" -v enabled=" $enabled " '
    function entry() { if (n && !(external && flagged) && (by == "" || index(enabled, " " by " "))) { es++; seen[ns] = 1 } }
    /^- namespace: / { entry(); n = 1; ns = $3; flagged = 0; by = ""; next }
    /^  inClusterObjectStore: true/ { flagged = 1 }
    /^  enabledBy: / { by = $2 }
    END { entry(); for (k in seen) ss++; print es + 0, ss + 0 }' "$list")
  f=$tmp/render/t-$tag-svp-cluster.yaml
  es=$(grep -c '^kind: ExternalSecret$' "$f" || true)
  ss=$(grep -c '^kind: SecretStore$' "$f" || true)
  [ "$es" = "$want_es" ] && [ "$ss" = "$want_ss" ] ||
    fail "svp-cluster for $label (object store $mode) renders $es ExternalSecrets and $ss SecretStores, want $want_es and $want_ss"
  provider=$(awk '/^kind: SecretStore$/ { s = 1 } s && /^    [a-z]+:$/ { sub(/:$/, ""); print $1; s = 0 }' "$f" |
    sort -u | paste -sd ' ' -)
  if [ "$env" = prd ]; then
    [ "$provider" = aws ] || fail "the SecretStores of $label use provider '$provider', want aws"
    if grep -n 'svp-secrets' "$f" >&2; then
      fail "the render of svp-cluster for $label above still names svp-secrets, the lab's source namespace"
    fi
  else
    [ "$provider" = kubernetes ] || fail "the SecretStores of $label use provider '$provider', want kubernetes"
  fi
  helm template svp-cluster "$code/deploy/helm/svp-cluster" "${args[@]}" --show-only templates/external-secrets.yaml \
    >"$tmp/eso/manifests/$tag.yaml" || fail "render the ExternalSecrets of svp-cluster for $label"
  docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$tmp/eso/manifests:/manifests:ro" \
    -v "$tmp/eso/schemas:/schemas:ro" "$kubeconform" -strict -summary \
    -skip ServiceAccount,Role,RoleBinding,ValidatingAdmissionPolicy,ValidatingAdmissionPolicyBinding \
    -schema-location '/schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json' "/manifests/$tag.yaml" \
    >"$tmp/eso/kubeconform.log" 2>&1 || { cat "$tmp/eso/kubeconform.log" >&2; fail "kubeconform on the ExternalSecrets and SecretStores for $label"; }
  grep -q "Valid: $((es + ss)), Invalid: 0, Errors: 0" "$tmp/eso/kubeconform.log" ||
    { cat "$tmp/eso/kubeconform.log" >&2; fail "kubeconform did not find $((es + ss)) valid ExternalSecrets and SecretStores for $label"; }
  echo "ok    svp-cluster for $label: $es ExternalSecrets, $ss SecretStores (provider $provider, object store $mode), valid against the CRDs of external-secrets $eso_version; none with base/ alone"
done

# --- 4. image digests, per folder of charts (one per revision, or the working tree): every component with its base/
# values and Argo CD as argocd/bootstrap.json installs it, then each component with values of a platform again with
# them, and each with an overlay of an environment of those charts again with it.
bootstrap=$tree/argocd/bootstrap.json
[ "$(jq -r '"\(.repo) \(.chart)"' "$bootstrap")" = "https://argoproj.github.io/argo-helm argo-cd" ] ||
  fail "argocd/bootstrap.json must install chart argo-cd of https://argoproj.github.io/argo-helm"
argocd_version=$(jq -r '.version' "$bootstrap")
argocd_values=$(jq -r '.values' "$bootstrap")
[ -f "$tree/$argocd_values" ] || fail "argocd/bootstrap.json: values file $argocd_values is missing"

# One line per component, fields separated by the ASCII unit separator so empty fields survive `read`; Argo CD last.
sep=$'\x1f'
list=$(jq -r '.components[] | [.name, .namespace, (.path // ""), (.repo // ""), (.chart // ""), (.version // ""),
  (.values // "")] | join("\u001f")' "$components") || fail "read argocd/apps/components.json"
list+=$'\n'"argocd${sep}argocd${sep}${sep}https://argoproj.github.io/argo-helm${sep}argo-cd${sep}$argocd_version${sep}$argocd_values"
digest_problems=
for rev in $(for env in $envs; do revision_of "$env"; done | sort -u); do
  out=$tmp/digests/$rev
  mkdir -p "$out/base"
  code=
  rev_targets=
  for target in $targets; do
    env=${target%%:*} plat=${target#*:}
    if [ "$(revision_of "$env")" = "$rev" ]; then
      code=$(code_of "$env") label=$(label_of "$env")
      rev_targets+=" $target"
      mkdir -p "$out/env/$env-$plat" "$out/platform/$plat"
    fi
  done
  rev_platforms=$(for target in $rev_targets; do echo "${target#*:}"; done | grep . | sort -u | paste -sd ' ' -) || true
  rendered=0 platformed=0 overlays=0
  while IFS=$sep read -r name namespace path repo chart version values; do
    args=(template "$name" --namespace "$namespace" --include-crds)
    if [ -n "$path" ]; then
      args+=("$code/$path")
    elif [[ $repo == oci://* ]]; then
      args+=("$repo/$chart" --version "$version")
    else
      args+=("$chart" --repo "$repo" --version "$version")
    fi
    if [ -n "$values" ]; then args+=(--values "$tree/$values"); fi
    # base/ has no image for a release of chart svp-service: the placeholder of step 3, a release's form with a zero
    # digest, which the pin check below holds to a digest like every other image.
    if [ "$path" = "$service_chart" ]; then
      args+=(--set-string "image.repository=$(placeholder_repo "$name" "$rev")" --set-string image.tag=000000000000
        --set-string "image.digest=$zero_digest")
    fi
    # base/ alone: Argo CD and every component of k3d, the platform of the dev path, which installs it so.
    if [ "$name" = argocd ] || runs_on "$name" "$dev_platform"; then
      helm "${args[@]}" >"$out/base/$name.yaml" 2>"$tmp/err" || { cat "$tmp/err" >&2; fail "helm template $name ($label)"; }
      rendered=$((rendered + 1))
    fi
    # Argo CD with the values of each platform that has some (platforms/<platform>/argo-cd.yaml after the bootstrap's),
    # as deploy/k8s/gitops.sh installs it on that platform.
    if [ "$name" = argocd ]; then
      for plat in $rev_platforms; do
        [ -f "$tree/platforms/$plat/argo-cd.yaml" ] || continue
        helm "${args[@]}" --values "$tree/platforms/$plat/argo-cd.yaml" >"$out/platform/$plat/$name.yaml" 2>"$tmp/err" ||
          { cat "$tmp/err" >&2; fail "helm template $name ($label) with the values of platform $plat"; }
        platformed=$((platformed + 1))
      done
      continue
    fi
    # With the values of each platform (its file, then what the root renders from its template for the first
    # environment on it): a component that has some, or none on k3d, whose base/ alone no cluster installs.
    for plat in $rev_platforms; do
      runs_on "$name" "$plat" || continue
      pargs=()
      [ ! -f "$tree/platforms/$plat/$name.yaml" ] || pargs+=(--values "$tree/platforms/$plat/$name.yaml")
      for target in $rev_targets; do
        [ "${target#*:}" = "$plat" ] || continue
        f=$tmp/values/${target%%:*}-$plat-$name.json
        [ ! -f "$f" ] || pargs+=(--values "$f")
        break
      done
      [ ${#pargs[@]} -gt 0 ] || [ ! -f "$out/base/$name.yaml" ] || continue
      helm "${args[@]}" ${pargs[@]+"${pargs[@]}"} >"$out/platform/$plat/$name.yaml" 2>"$tmp/err" ||
        { cat "$tmp/err" >&2; fail "helm template $name ($label) with the values of platform $plat"; }
      platformed=$((platformed + 1))
    done
    # With each environment's overlay, the values in the order Argo CD reads them, as step 3 renders them
    # (target_values): the file of its platform, the overlay, then what the root renders from the platform's template,
    # which a valuesObject puts after every values file. base/ is in args already; the image file is left out: base/
    # has the placeholder.
    for target in $rev_targets; do
      env=${target%%:*} plat=${target#*:}
      [ -f "$tree/envs/$env/$name.yaml" ] && runs_on "$name" "$plat" || continue
      eargs=()
      while IFS= read -r f; do
        case $f in "$tree/$values" | "$tree/envs/$env/images/$name.yaml") ;; *) eargs+=(--values "$f") ;; esac
      done < <(target_values "$env" "$plat" "$name")
      helm "${args[@]}" "${eargs[@]}" \
        >"$out/env/$env-$plat/$name.yaml" 2>"$tmp/err" ||
        { cat "$tmp/err" >&2; fail "helm template $name ($label) with envs/$env/$name.yaml on $plat"; }
      overlays=$((overlays + 1))
    done
  done <<<"$list"

  # Each render against the one it adds to, the service images included. An environment's overlay against its
  # platform's render (the base's where the platform has no values for the component): exactly the same images. A
  # platform's render against the base's (none for a component that does not run on k3d): no other version of an image
  # the base runs (another tag or digest of one of its repositories), while it may run fewer (an object store the cloud
  # provides) or others, which the pin check holds to their digests like every image.
  drift=
  for f in "$out"/platform/*/*.yaml "$out"/env/*/*.yaml; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .yaml)
    dir=$(basename "$(dirname "$f")")
    case $f in
    "$out"/platform/*)
      ref=$out/base/$name.yaml
      [ -f "$ref" ] || continue
      image_refs "$name" "$ref" | sort -u >"$tmp/ref-images"
      image_refs "$name" "$f" | sort -u >"$tmp/env-images"
      # The images of the platform's render whose repository the base runs at another reference, each with the
      # base's: a repository is the reference without its digest and without a tag after its last "/".
      other=$(awk -F '\t' 'function repo(r) { sub(/@.*/, "", r); if (match(r, /:[^\/]*$/)) r = substr(r, 1, RSTART - 1); return r }
        NR == FNR { have[$2] = 1; base[repo($2)] = base[repo($2)] " " $2; next }
        !($2 in have) && (repo($2) in base) { print "    > " $2 " (base:" base[repo($2)] ")" }' "$tmp/ref-images" "$tmp/env-images")
      [ -z "$other" ] || drift+="  the values of platform $dir for $name run another version of an image of the base:"$'\n'"$other"$'\n'
      continue
      ;;
    *)
      env=${dir%%-*} plat=${dir#*-}
      ref=$out/base/$name.yaml
      [ ! -f "$out/platform/$plat/$name.yaml" ] || ref=$out/platform/$plat/$name.yaml
      what="envs/$env/$name.yaml on $plat (< $plat or base, > $env on $plat)"
      ;;
    esac
    [ -f "$ref" ] || continue
    image_refs "$name" "$ref" | sort -u >"$tmp/ref-images"
    image_refs "$name" "$f" | sort -u >"$tmp/env-images"
    if ! diff=$(diff "$tmp/ref-images" "$tmp/env-images"); then
      drift+="  $what:"$'\n'"$(sed 's/^/    /' <<<"$diff")"$'\n'
    fi
  done

  # Every image of every render pinned by digest (pin_check), the CLI run once per folder: a folder holds each
  # resource once (the base, a platform, an environment on a platform).
  missing= checked=0
  for d in "$out"/base "$out"/platform/* "$out"/env/*; do
    set -- "$d"/*.yaml
    [ -f "$1" ] || continue
    pin_check "$out" "$@" >"$tmp/pin-out" || missing+=$(cat "$tmp/pin-out")$'\n'
    checked=$((checked + kyverno_checked))
  done

  echo "image digests with the charts of $label: charts rendered: $rendered, with a platform's values: $platformed, with an environment's overlay: $overlays; resources of their renders checked by policy images-pinned: $checked"
  if [ -n "$drift" ]; then
    printf 'FAIL  values of an environment or a platform whose render runs other images than the render they add to (charts of %s):\n%s' "$label" "$drift" >&2
  fi
  if [ -n "$missing" ]; then
    printf 'FAIL  images without exactly one @sha256:<64 hex> (charts of %s):\n%s' "$label" "$missing" >&2
  fi
  [ -z "$drift$missing" ] || digest_problems=1
done
[ -z "$digest_problems" ] || fail "image digests (above)"
echo "ok    every image is pinned by digest (policy images-pinned); every overlay runs the images of what it adds to"

# --- 5. the release images
if [ -n "$worktree" ]; then
  echo "skip  the release images: svp-gitops's own check"
else
  rc=0
  "$ci_dir/values-check.sh" --gitops "$tree" "$base" | tee "$tmp/values-check.out" || rc=$?
  [ "$rc" -eq 0 ] || fail "the release images (above)"
  # Each release checked in an environment that requires provenance must carry image.tag = the commit it names. Step 1
  # left envs/ holding exactly these environments.
  prov_envs=
  for e in $envs; do
    required=$(provenance_required "" "$e" "$tree") || fail "read whether $e requires provenance"
    [ "$required" != true ] || prov_envs="$prov_envs $e"
  done
  mismatch=$(tag_provenance_mismatch "$tree" "$tmp/values-check.out" "$prov_envs")
  if [ -n "$mismatch" ]; then
    sed 's/^/FAIL  /' <<<"$mismatch" >&2
    fail "the release images: image.tag must be the commit the release's provenance names, read from its check"
  fi
  echo "ok    every release with provenance checked has the image.tag of the commit its provenance names"
fi
echo "ok    $tree passes every check"
