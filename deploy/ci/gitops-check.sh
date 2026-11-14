#!/usr/bin/env bash
# gitops-check.sh GITOPS_DIR [BASE]: validates the svp-gitops deployment tree across 5 steps.
# --worktree tests working charts; --tree step 1; --root steps 1-2; --policy images-pinned|no-lab-hosts one policy.
# --images GITOPS_DIR ENV OUT renders ENV on eks as steps 1-4 do and writes the images it runs to OUT.
# Design notes: docs/reference/ci.md.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

worktree='' tree_only='' root_only='' policy_only='' images_only='' images_env='' images_out=''
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
elif [ "${1:-}" = --images ]; then
  images_only=1
  shift
  [ $# -eq 3 ] || fail "usage: gitops-check.sh --images GITOPS_DIR ENV OUT"
  images_env=$2 images_out=$3
  set -- "$1"
fi
if [ -n "$policy_only" ]; then
  tools="jq docker"
else
  [ $# -ge 1 ] && [ $# -le 2 ] ||
    fail "usage: gitops-check.sh GITOPS_DIR [BASE] | gitops-check.sh --worktree GITOPS_DIR | gitops-check.sh --tree GITOPS_DIR [BASE] | gitops-check.sh --root GITOPS_DIR | gitops-check.sh --policy images-pinned|no-lab-hosts FILE... | gitops-check.sh --images GITOPS_DIR ENV OUT"
  tree=$(cd "$1" 2>/dev/null && pwd -P) || fail "$1 is not a directory"
  base=${2:-}
  tools="git jq helm docker"
  [ -z "$tree_only" ] || tools="git jq docker"
fi
for tool in $tools; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
main=origin/main
envs="prd stg"
[ -z "$images_only" ] || [[ " $envs " == *" $images_env "* ]] || fail "--images: environment $images_env is none of: $envs"
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
# kyverno_apply ROOT POLICY FILE...: applies Kyverno POLICY on resources of rendered FILEs; sets kyverno_checked.
# CLI fake cluster stops on duplicate resources; returns 1 on violation or missing result.
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

# --- 1. the tree: the policies of deploy/ci/gitops-tree-policies/ (conftest) on one JSON document (see their lib.rego),
# built here from the tree, from the code repository at the revision each environment pins and from the pull request.
components=$tree/argocd/apps/components.json
mkdir -p "$tmp/tree/in"

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
# collector_config_sha256 REV: the sha256 of the Collector's config files at REV, the shared one then each platform's
# destination file, concatenated; a file REV does not hold adds nothing (a commit from before the destination files
# gives the checksum of k8s-config.yaml alone, as it was then).
collector_config_sha256() {
  local f
  for f in k8s-config k8s-k3d k8s-eks; do
    if git -C "$repo_root" cat-file -e "$1:deploy/observability/otelcol/$f.yaml" 2>/dev/null; then
      git -C "$repo_root" show "$1:deploy/observability/otelcol/$f.yaml"
    fi
  done | shasum -a 256 | cut -d' ' -f1
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

# The tree: every entry but .git, by its path, with what it resolves to, the target of a link, the text of a file.
(cd "$tree" && find . -mindepth 1 -name .git -prune -o -print0) | while IFS= read -r -d '' path; do
  path=${path#./}
  args=(--arg p "$path" --arg link "$([ ! -L "$tree/$path" ] || readlink "$tree/$path")")
  if [ -d "$tree/$path" ]; then
    args+=(--arg type dir --arg text "")
  elif [ -f "$tree/$path" ]; then
    args+=(--arg type file --rawfile text "$tree/$path")
  else
    args+=(--arg type other --arg text "")
  fi
  jq -cn "${args[@]}" '{($p): ({type: $type}
    + if $type == "file" then {text: $text} else {} end + if $link == "" then {} else {link: $link} end)}' || exit 1
done | jq -cs 'add // {}' >"$tmp/tree/entries.json" || fail "list the tree $tree"

# Each environment's revision on main of this repository, what that commit derives (charts) and its table of release
# sources (sources); the working tree's table for every environment with --worktree. A revision that is not 40 hex is
# the policies' to name.
charts='{}' sources='{}'
if [ -n "$worktree" ] && ! table=$(release_sources); then
  problem "the release sources of the working tree cannot be read (above)"
fi
for env in $envs; do
  [ -f "$tree/envs/$env/charts.yaml" ] || continue
  if [ -n "$worktree" ]; then
    [ -z "${table:-}" ] || sources=$(jq -c --arg e "$env" --argjson t "$table" '. + {($e): ($t + {revision: ""})}' <<<"$sources")
    continue
  fi
  rev=$(charts_field "$env" revision)
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || continue
  if ! git -C "$repo_root" cat-file -e "$rev^{commit}" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision $rev is no commit of this clone of the code repository (fetch its whole history)"
    continue
  fi
  if ! table=$(release_sources "$rev"); then
    problem "envs/$env/charts.yaml: the release sources of ${rev:0:12} cannot be read (above)"
    continue
  fi
  sources=$(jq -c --arg e "$env" --arg r "$rev" --argjson t "$table" '. + {($e): ($t + {revision: $r})}' <<<"$sources")
  if ! git -C "$repo_root" merge-base --is-ancestor "$rev" "$main" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision ${rev:0:12} is not on $main of the code repository"
    continue
  fi
  charts=$(jq -c --arg e "$env" --arg r "$rev" \
    --arg psv "$(git -C "$repo_root" show "$rev:deploy/helm/svp-cluster/values.yaml" | sed -n 's/^podSecurityVersion: *//p')" \
    --arg sha "$(collector_config_sha256 "$rev")" \
    '. + {($e): {revision: $r, podSecurityVersion: $psv, collectorConfigSha256: $sha}}' <<<"$charts")
done

# The pull request: its author and sender, and for a bot's the files it changes from BASE (NUL-separated, so that a path
# git would quote, a byte outside ASCII or a tab, is read as it is). pr_ok: the line printed once the policies pass.
pull_request=null pr_ok=
if [ -z "$base" ]; then
  echo "skip  the author of a pull request: no base, so no change of a pull request to check"
elif ! author=$(pr_login .pull_request.user.login author); then
  problem "the author of the pull request cannot be read (above): the files a bot may change depend on which bot it is"
elif [ -z "$author" ]; then
  echo "skip  the author of a pull request: this run checks no pull request (on a machine, SVP_CHANGE_REQUEST_AUTHOR names the author of one)"
elif ! sender=$(pr_login .sender.login sender); then
  problem "the sender of the pull request's event cannot be read (above): a bot other than the author may have pushed onto it"
else
  pull_request=$(jq -cn --arg a "$author" --arg s "$sender" '{author: $a, sender: $s}')
  if [[ $author != *'[bot]' ]]; then
    pr_ok="ok    the pull request is by $author, a person: the files it changes are not limited by the author's rule"
  elif [ "$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" != "$tree" ] ||
    ! git -C "$tree" diff --name-status -z --no-renames "$base" HEAD >"$tmp/tree/changed" 2>/dev/null; then
    problem "list the files $author changed since $base in $tree (the top of a git repository that has that commit)"
  else
    pull_request=$(jq -cRs --argjson pr "$pull_request" \
      '$pr + {changes: (split("\u0000") | .[:-1] | [range(0; length; 2) as $i | {status: .[$i], path: .[$i + 1]}])}' \
      "$tmp/tree/changed")
    n=$(jq '.changes | length' <<<"$pull_request")
    if jq -e --arg p "${author%'[bot]'}" '[.[].sources[].promoter] | index($p) != null' <<<"$sources" >/dev/null; then
      pr_ok="ok    the pull request of $author, the promoter of a release source: its $n changed files are all files that bot may change"
    else
      pr_ok="ok    the pull request of $author, a bot that promotes no release source: none of its $n changed files is under envs/"
    fi
  fi
fi

# The commit of svp-gitops each environment pins (gitopsRevision of its charts.yaml, prd's alone: the policies),
# which must be a commit on main of svp-gitops (origin/main of GITOPS_DIR, a clone with that history) holding
# argocd/apps: the set of argocd/, base/ and platforms/ that stg ran, which the promote to prd copied. pins: one line
# "<env> <commit>" per environment that pins one.
pins=
for env in $envs; do
  [ -f "$tree/envs/$env/charts.yaml" ] || continue
  pin=$(charts_field "$env" gitopsRevision)
  [[ $pin =~ ^[0-9a-f]{40}$ ]] || continue
  if [ "$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" != "$tree" ] ||
    ! git -C "$tree" cat-file -e "$pin^{commit}" 2>/dev/null; then
    problem "envs/$env/charts.yaml: gitopsRevision $pin is no commit of $tree (the top of a clone of svp-gitops with its history)"
  elif ! git -C "$tree" merge-base --is-ancestor "$pin" "$main" 2>/dev/null; then
    problem "envs/$env/charts.yaml: gitopsRevision ${pin:0:12} is not on $main of svp-gitops: $env runs only a set that main held"
  elif ! git -C "$tree" cat-file -e "$pin:argocd/apps/Chart.yaml" 2>/dev/null; then
    problem "envs/$env/charts.yaml: gitopsRevision ${pin:0:12} holds no argocd/apps/Chart.yaml: there is no root for $env to render at it"
  else
    pins+="$env $pin"$'\n'
  fi
done
# pinned_commit ENV: the commit ENV pins, nothing when it pins none.
pinned_commit() {
  awk -v e="$1" '$1 == e { print $2 }' <<<"$pins"
}

jq -n --argjson worktree "$([ -n "$worktree" ] && echo true || echo false)" --slurpfile tree "$tmp/tree/entries.json" \
  --argjson charts "$charts" --argjson sources "$sources" --argjson pr "$pull_request" \
  '{worktree: $worktree, tree: $tree[0], charts: $charts, sources: $sources}
    + if $pr == null then {} else {pull_request: $pr} end' >"$tmp/tree/in/input.json" ||
  fail "write the input of the policies on the tree"
printf '%s\n' "${svp_services[@]}" | jq -cRn --arg envs "$envs" \
  '{gitops_check: {environments: ($envs | split(" ")), services: [inputs]}}' >"$tmp/tree/in/data.json" ||
  fail "write the data of the policies on the tree"

# conftest from CONFTEST_IMAGE of the Makefile, without network, as the caller, with a read-only root file system, the
# policies and the input mounted read-only. An answer that did not run every package (no result for one, or a result
# with neither a success nor a failure: a package renamed or empty) is no answer, nor is a run that gives none (a policy
# that does not compile).
tree_packages="gitops.layout gitops.envs gitops.platforms gitops.author"
args=()
for package in $tree_packages; do args+=(--namespace "$package"); done
image=$(tool_image CONFTEST_IMAGE)
rc=0
out=$(docker_ run --rm --network none --read-only --user "$(id -u):$(id -g)" \
  -v "$ci_dir/gitops-tree-policies:/policy:ro" -v "$tmp/tree/in:/in:ro" -w /in "$image" test --policy /policy \
  --data /in/data.json "${args[@]}" --output json --no-color input.json 2>"$tmp/tree/err") || rc=$?
jq -e --arg want "$tree_packages" 'type == "array" and ([.[] | select((.successes // 0) + (.failures // [] | length) > 0)
  | .namespace] | unique) == ($want | split(" ") | unique)' <<<"$out" >/dev/null 2>&1 || {
  sed 's/^/    /' "$tmp/tree/err" >&2
  fail "conftest could not check the tree with the policies of deploy/ci/gitops-tree-policies/ (above)"
}
jq -r '.[].failures[]?.msg' <<<"$out" >"$tmp/tree/broken"
while IFS= read -r msg; do problem "$msg"; done <"$tmp/tree/broken"
[ "$rc" -eq 0 ] || [ -s "$tmp/tree/broken" ] || fail "conftest failed on the tree without naming a rule: $(cat "$tmp/tree/err")"
step "the tree $tree"
echo "ok    the tree keeps the rules of deploy/ci/gitops-tree-policies/ (layout, environments, platform layer, author of a pull request)"
for env in $envs; do
  if [ -n "$worktree" ]; then
    echo "ok    envs/$env/charts.yaml: revision, podSecurityVersion and collectorConfigSha256 (their values are svp-gitops's own check)"
    echo "ok    envs/$env/images/: seven releases, each of a release source the policy admits"
  else
    rev=$(revision_of "$env")
    echo "ok    envs/$env/charts.yaml: charts of ${rev:0:12} on $main, podSecurityVersion and collectorConfigSha256 as that commit gives them"
    echo "ok    envs/$env/images/: seven releases, each of a release source the policy of ${rev:0:12} admits"
  fi
done
for env in $envs; do
  pin=$(pinned_commit "$env")
  [ -z "$pin" ] ||
    echo "ok    envs/$env/charts.yaml: gitopsRevision ${pin:0:12}, a commit on $main of svp-gitops holding argocd/apps"
done
[ -z "$pr_ok" ] || echo "$pr_ok"
[ -z "$tree_only" ] || exit 0
# The one environment whose images are listed is rendered alone, the tree having been checked with all of them.
if [ -n "$images_only" ]; then
  envs=$images_env
  : >"$images_out"
fi

# two_level: non-empty when tree has two-level root (argocd/root then argocd/apps with level 1 values).
two_level=
[ ! -f "$tree/argocd/root/Chart.yaml" ] || two_level=1

# at PATH: where the values file PATH of the tree (relative to its top) is read for the environments render_tree
# renders: envs/ in the tree, anything else in GTREE (the tree, or the commit an environment pins).
at() {
  case $1 in
  envs/*) echo "$tree/$1" ;;
  *) echo "$gtree/$1" ;;
  esac
}

# short_refs FILE...: the targetRevision of each source of svp-gitops in the rendered FILEs (the one right after its
# repoURL, as the charts write a source) that is neither a full ref (refs/heads/<branch>) nor a commit, once each.
short_refs() {
  awk -v url="$gitops_url" '$0 ~ "repoURL: " url "$" { want = 1; next }
    want && /targetRevision:/ { v = $2; gsub(/"/, "", v)
      if (v !~ /^refs\/heads\/./ && !(v ~ /^[0-9a-f]+$/ && length(v) == 40)) print v; want = 0 }
    want && /^ *- / { want = 0 }' "$@" | sort -u | paste -sd ' ' -
}

# level_one ENV PLATFORM ARCH ARG...: renders level 1 (argocd/root); writes level 2 valuesObject to JSON.
# Guards that level 1 yields exactly one Application svp-apps at the pinned commit (refs/heads/main if unpinned).
level_one() {
  local env=$1 plat=$2 arch=$3 want top got source
  shift 3
  want=$(pinned_commit "$env")
  want=${want:-refs/heads/main}
  top=$tmp/render/level1-$env-$plat-$arch.yaml
  if ! helm lint --quiet "$tree/argocd/root" "$@" >"$tmp/err" 2>&1 ||
    ! helm template svp-root "$tree/argocd/root" "$@" >"$top" 2>"$tmp/err"; then
    grep -v 'found symbolic link in path' "$tmp/err" >&2 || true
    fail "helm lint and template of argocd/root for $env on $plat on $arch nodes"
  fi
  yaml_json "$top" | jq -cs '[.[] | select(.kind == "Application")]' >"$tmp/render/level1-$env-$plat-$arch.json" ||
    fail "read the Applications of argocd/root for $env on $plat on $arch nodes"
  got=$(jq -r '[.[].metadata.name] | join(" ")' "$tmp/render/level1-$env-$plat-$arch.json")
  [ "$got" = svp-apps ] ||
    fail "argocd/root for $env on $plat on $arch nodes makes the Applications '$got', want svp-apps alone"
  got=$(short_refs "$top")
  [ -z "$got" ] ||
    fail "argocd/root for $env on $plat on $arch nodes: every source of $gitops_url must name a full ref (refs/heads/<branch>) or a commit as targetRevision, not $got (Argo CD may resolve a short name to a tag of that name)"
  source=$(jq -r '.[0].spec | if has("sources") then "several sources" else
    [.source.repoURL, .source.path, .source.targetRevision, .source.helm.valuesObject.targetRevision] | map(. // "") | join(" ") end' \
    "$tmp/render/level1-$env-$plat-$arch.json")
  [ "$source" = "$gitops_url argocd/apps $want $want" ] ||
    fail "argocd/root for $env on $plat on $arch nodes: svp-apps has '$source' (repoURL, path, targetRevision, valuesObject.targetRevision), want '$gitops_url argocd/apps $want $want': the commit envs/$env/charts.yaml pins as gitopsRevision, refs/heads/main without one"
  jq -e '.[0].spec.source.helm.valuesObject | objects' "$tmp/render/level1-$env-$plat-$arch.json" >"$tmp/render/level2-$env-$plat-$arch.json" ||
    fail "argocd/root for $env on $plat on $arch nodes: svp-apps has no valuesObject"
}

# render_tree GTREE ENVS PIN: steps 2 to 4 for the environments ENVS, whose argocd/, base/ and platforms/ are those of
# GTREE (the tree, or the commit PIN of svp-gitops the one environment of ENVS pins, unpacked), their envs/<env>/ the
# tree's.
render_tree() {
  local gtree=$1 envs=$2 pin=$3 apps=argocd/apps vt
  [ -z "$pin" ] || apps="argocd/apps at ${pin:0:12}"
  vt=$(mktemp -d "$tmp/view.XXXXXX") || fail "create a directory for the render of $envs"
  components=$gtree/argocd/apps/components.json

  # The platform layer, as the policies hold it: targets is each environment with the platform the root is rendered
  # for, <env>:<platform>, in the order of the map.
  platform_names=$(jq -r '.platforms | keys | join(" ")' "$components")
  targets=$(jq -r --arg envs " $envs " '[.platforms | to_entries[] | .key as $p | .value.envs[] as $e
    | select($envs | contains(" \($e) ")) | "\($e):\($p)"] | join(" ")' "$components")
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
    ((.archValues // {}).arm64 // "")] | join("\u001f")' "$components" >"$vt/components" ||
    fail "read argocd/apps/components.json"
  # component_field NAME FIELD: FIELD (path, values, amd64, arm64) of component NAME.
  component_field() {
    awk -F $'\x1f' -v n="$1" -v f="$2" 'BEGIN { c["path"] = 2; c["values"] = 3; c["amd64"] = 4; c["arm64"] = 5 }
      $1 == n { print $c[f] }' "$vt/components"
  }
  # values_files ENV PLATFORM NAME ARCH: the values files of component NAME in ENV on PLATFORM on ARCH nodes, relative
  # to the tree, in the order Argo CD reads them: base/ and then archValues of ARCH (only with a base/ file),
  # platforms/<platform>/<name>.yaml, envs/<env>/<name>.yaml, envs/<env>/images/<name>.yaml, those that exist.
  values_files() {
    local v a
    v=$(component_field "$3" values)
    if [ -n "$v" ]; then
      echo "$v"
      a=$(component_field "$3" "$4")
      [ -z "$a" ] || echo "$a"
    fi
    [ ! -f "$gtree/platforms/$2/$3.yaml" ] || echo "platforms/$2/$3.yaml"
    [ ! -f "$tree/envs/$1/$3.yaml" ] || echo "envs/$1/$3.yaml"
    [ ! -f "$tree/envs/$1/images/$3.yaml" ] || echo "envs/$1/images/$3.yaml"
  }
  # app_files ENV PLATFORM NAME ARCH: those the Application names as values files: on a two-level root all but the
  # files of envs/<env>/, whose content level 1 hands over and level 2 puts into the Application's valuesObject.
  app_files() {
    if [ -n "$two_level" ]; then values_files "$@" | grep -v '^envs/' || true; else values_files "$@"; fi
  }
  # env_values ENV FILE: envs/ENV/FILE of the tree as one line of JSON, {} if missing or comments-only.
  env_values() {
    local f=$tree/envs/$1/$2 c=$tmp/env-values/$1/${2//\//-}.json
    if [ ! -f "$c" ]; then
      mkdir -p "$tmp/env-values/$1"
      if [ -f "$f" ]; then yaml_json "$f"; fi | jq -cS 'select(type == "object")' >"$c" || fail "read envs/$1/$2"
      [ -s "$c" ] || echo '{}' >"$c"
    fi
    cat "$c"
  }
  # overlay_keys JSON: the keys of a release's values that only envs/<env>/images/ (image) and the base (canary,
  # httpRoute.name, mirrored by canaryRoute of components.json) may set, those JSON sets: the rule overlay_keys of
  # deploy/ci/gitops-tree-policies/lib.rego holds the files of platforms/ to, here on what the templates render.
  overlay_keys() {
    jq -r '[if has("image") then "image" else empty end, if has("canary") then "canary" else empty end,
      if (.httpRoute | type) == "object" and (.httpRoute | has("name")) then "httpRoute.name" else empty end] | join(", ")' <<<"$1"
  }

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
      # The values the bootstrap gives the root: on eks the GitOps Bridge sets cluster from the cluster Secret's
      # annotation, the fixture standing for it here.
      set -- --namespace argocd --set-string "env=$env" --set "nodeArch=$arch" --set-string "platform=$plat"
      [ "$plat" != eks ] || set -- "$@" -f "$tmp/cluster.yaml"
      if [ -n "$two_level" ]; then
        level_one "$env" "$plat" "$arch" "$@"
        set -- --namespace argocd -f "$tmp/render/level2-$tag-$arch.json"
      fi
      if ! helm lint --quiet "$gtree/argocd/apps" "$@" >"$tmp/err" 2>&1 ||
        ! helm template svp-root "$gtree/argocd/apps" "$@" >"$root" 2>"$tmp/err"; then
        grep -v 'found symbolic link in path' "$tmp/err" >&2 || true
        fail "helm lint and template of $apps for $label on $arch nodes"
      fi
      short=$(short_refs "$root")
      [ "$(grep -c "repoURL: $gitops_url\$" "$root" || true)" -gt 0 ] ||
        fail "$apps for $label on $arch nodes reads no values from $gitops_url"
      [ -z "$short" ] ||
        fail "$apps for $label on $arch nodes: every source of $gitops_url must name a full ref (refs/heads/<branch>) or a commit as targetRevision, not $short (Argo CD may resolve a short name to a tag of that name)"
      # On a two-level root, level 2 again with the content of every overlay and image file of envFiles emptied: the
      # valuesObject of an Application there is what the root renders from the platform's template alone. One line per
      # Application: its name and that valuesObject ("" for none).
      if [ -n "$two_level" ]; then
        jq '.envFiles.overlays |= map_values({}) | .envFiles.images |= map_values({})' "$tmp/render/level2-$tag-$arch.json" \
          >"$tmp/render/level2-$tag-$arch-tpl.json" || fail "empty envFiles of the values of $apps for $label on $arch nodes"
        helm template svp-root "$gtree/argocd/apps" --namespace argocd -f "$tmp/render/level2-$tag-$arch-tpl.json" \
          >"$tmp/render/root-$tag-$arch-tpl.yaml" 2>"$tmp/err" || {
          grep -v 'found symbolic link in path' "$tmp/err" >&2 || true
          fail "helm template of $apps for $label on $arch nodes with the overlays and image files emptied"
        }
        yaml_json "$tmp/render/root-$tag-$arch-tpl.yaml" | jq -r 'select(.kind == "Application")
          | [.metadata.name, ([.spec.sources[] | select(.helm)][0].helm | if has("valuesObject") then .valuesObject | tojson else "" end)]
          | join("\u001f")' >"$tmp/render/tpl-$tag-$arch" ||
          fail "read the Applications of $apps for $label on $arch nodes with the overlays and image files emptied"
      fi
      # Extracts each Application's values files, valuesObject, chart revision, and gitops source revisions.
      yaml_json "$root" | jq -r --arg url "$gitops_url" --arg pin "$pin" 'select(.kind == "Application")
        | ([.spec.sources[] | select(.repoURL == $url and .ref) | {(.ref): (.targetRevision // "")}] | add // {}) as $refs
        | [.spec.sources[] | select(.helm)][0] as $s | $s.helm as $h
        | [.metadata.name, ([($h.valueFiles // [])[] | sub("^\\$[^/]+/"; "")] | join(" ")),
           (if $h | has("valuesObject") then $h.valuesObject | tojson else "" end),
           (if $s.path then $s.targetRevision else "" end),
           (if $pin == "" then "" else [($h.valueFiles // [])[]
             | (capture("^\\$(?<ref>[^/]+)/(?<path>.*)$") // {ref: "", path: .})
             | (if .ref == "" then null else $refs[.ref] end) as $rev
             | select($rev != $pin) | "\(.path) at \($rev // "no source")"] | join(", ") end),
           ([.spec.sources[] | select(.repoURL == $url) | .targetRevision // ""] | unique | join(" "))] | join("\u001f")' \
        >"$tmp/render/apps-$tag-$arch" || fail "read the Applications of $apps for $label on $arch nodes"
      got=$(cut -d $'\x1f' -f1 "$tmp/render/apps-$tag-$arch" | sort | paste -sd ' ' -)
      want=$(cut -d $'\x1f' -f1 "$vt/components" | while IFS= read -r name; do
        if runs_on "$name" "$plat"; then echo "$name"; fi
      done | sort | paste -sd ' ' -)
      [ "$got" = "$want" ] ||
        fail "$apps for $label on $arch nodes makes the Applications '$got', want one per component of components.json that runs on $plat: '$want'"
      while IFS=$'\x1f' read -r name files object chart_rev misread revs; do
        want=$(app_files "$env" "$plat" "$name" "$arch" | paste -sd ' ' -)
        [ "$files" = "$want" ] ||
          problem "$apps for $label on $arch nodes: Application $name reads the values files '$files', want '$want' (base/ < platforms/<platform>/ < envs/<env>/ < envs/<env>/images/, those that exist; on a two-level root envs/<env>/ in its valuesObject)"
        # Argo CD's repo-server refuses values files whose ref sources name one repository at two revisions.
        if [[ $revs == *" "* ]]; then
          problem "$apps for $label on $arch nodes: Application $name has sources of $gitops_url at the revisions $revs; Argo CD refuses an Application whose values files reference one repository at two revisions (cannot reference multiple revisions for the same repository)"
        elif [ -n "$pin" ] && [ -n "$revs" ] && [ "$revs" != "$pin" ]; then
          problem "$apps for $label on $arch nodes: Application $name has a source of $gitops_url at $revs, want the pinned commit $pin"
        fi
        [ -z "$misread" ] ||
          problem "$apps for $label on $arch nodes: Application $name reads $misread; want every values file at the pinned commit $pin (\$values/, ref values)"
        [ -n "$worktree" ] || [ -z "$chart_rev" ] || [ "$chart_rev" = "$(revision_of "$env")" ] ||
          problem "$apps for $label on $arch nodes: Application $name takes its chart at $chart_rev, want the revision of envs/$env/charts.yaml, $(revision_of "$env")"
        # What the root renders from platforms/<platform>/<name>.values.tpl: the valuesObject itself on a root of one
        # level, that of the render without the content of envs/<env>/ on a two-level root.
        tpl_object=$object
        [ -z "$two_level" ] || tpl_object=$(awk -F $'\x1f' -v n="$name" '$1 == n { print $2 }' "$tmp/render/tpl-$tag-$arch")
        if [ -f "$gtree/platforms/$plat/$name.values.tpl" ]; then
          if [ "$(jq -r type <<<"${tpl_object:-null}")" != object ]; then
            problem "$apps for $label on $arch nodes: Application $name has no helm.valuesObject, the render of platforms/$plat/$name.values.tpl"
          elif [ "$(component_field "$name" path)" = "$service_chart" ] && [ -n "$(overlay_keys "$tpl_object")" ]; then
            problem "platforms/$plat/$name.values.tpl renders $(overlay_keys "$tpl_object") for $label: a release's image is envs/<env>/images/$name.yaml, and every platform runs the base's canary"
          else
            echo "$tpl_object" >"$tmp/values/$tag-$name.json"
          fi
        elif [ -n "$tpl_object" ]; then
          problem "$apps for $label on $arch nodes: Application $name has a helm.valuesObject, but no platforms/$plat/$name.values.tpl renders one"
        fi
        # On a two-level root the valuesObject holds the overlay and the image file of the tree's envs/<env>/ (main on a
        # cluster), then the template's render, merged as Helm merges values files: jq's * merges an object key by key
        # and replaces any other value, a list too, whole.
        if [ -n "$two_level" ]; then
          want=$(jq -cS -n --argjson o "$(env_values "$env" "$name.yaml")" --argjson i "$(env_values "$env" "images/$name.yaml")" \
            --argjson t "${tpl_object:-"{}"}" '$o * $i * $t') || fail "merge envs/$env/ of $name for $label"
          got=$(jq -cS . <<<"${object:-"{}"}") || fail "read the valuesObject of Application $name for $label"
          if [ "$got" != "$want" ]; then
            diff <(jq -S . <<<"$want") <(jq -S . <<<"$got") | sed 's/^/    /' >&2 || true
            problem "$apps for $label on $arch nodes: Application $name has the helm.valuesObject above (>), want envs/$env/$name.yaml < envs/$env/images/$name.yaml < the render of platforms/$plat/$name.values.tpl, those that exist, merged in that order (<)"
          fi
        fi
        [ -z "$object" ] || echo "$object" >"$tmp/values/$tag-$name.object.json"
      done <"$tmp/render/apps-$tag-$arch"
      step "the Applications of $apps for $label on $arch nodes"
      files=()
      for f in $(awk -F $'\x1f' '$1 == "argo-rollouts" { print $2 }' "$tmp/render/apps-$tag-$arch"); do
        files+=(-f "$(at "$f")")
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
    echo "ok    $apps for $label on arm64 and amd64 nodes: one Application per component that runs there, each with its values files in order${two_level:+ and envs/$env/ in its valuesObject}; its sources of svp-gitops name full refs, one revision each Application; Argo Rollouts gets plugin $arm_name of ${arm_loc%/*}, the asset built for each"
  done
  [ -z "$root_only" ] || return 0

  # target_values ENV PLATFORM NAME: the values of component NAME as Argo CD reads them in ENV on PLATFORM, one absolute
  # path per line: the values files its Application names (app_files; archValues of arm64 nodes: a chart of this
  # repository has none), then its valuesObject, when it has one.
  target_values() {
    local f
    app_files "$1" "$2" "$3" arm64 | while IFS= read -r f; do at "$f"; done
    f=$tmp/values/$1-$2-$3.object.json
    [ ! -f "$f" ] || echo "$f"
  }
  # layer_values ENV PLATFORM NAME: values one layer per file, with valuesObject from platform template if present.
  layer_values() {
    local f
    values_files "$1" "$2" "$3" arm64 | while IFS= read -r f; do at "$f"; done
    f=$tmp/values/$1-$2-$3.json
    [ ! -f "$f" ] || echo "$f"
  }

  # placeholder_repo SERVICE REV: repository of SERVICE's release for base/ renders from release sources at REV,
  # so the render's image is a service image of those charts, as an environment's would be.
  placeholder_repo() {
    local rev=$2
    [ "$rev" != worktree ] || rev=
    release_repositories "$1" "$rev" | sed 's/ or .*//'
  }

  # --- 3. the charts of this repository
  jq -r '.components[] | select(.path) | [.name, .namespace, .path, (.values // "")] | @tsv' "$components" >"$vt/charts"
  while IFS=$'\t' read -r name ns path values; do
    for env in $envs; do
      chart=$(code_of "$env")/$path
      [ -d "$chart" ] || fail "component $name: no chart $path at $(label_of "$env") (charts of envs/$env)"
      # base/ alone, as the dev path installs a component of k3d. Alone, base/ has no image for a release of chart
      # svp-service: a placeholder renders it as the dev path's does.
      if runs_on "$name" "$dev_platform"; then
        args=(--namespace "$ns")
        [ -z "$values" ] || args+=(-f "$gtree/$values")
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
  done <"$vt/charts"
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

  # External Secrets of chart svp-cluster (component external-secrets: policy layout of step 1).
  read -r eso_repo eso_chart eso_version eso_values < <(jq -r '.components[] | select(.name == "external-secrets")
    | "\(.repo) \(.chart) \(.version) \(.values)"' "$components")
  mkdir -p "$vt/eso/crds" "$vt/eso/schemas" "$vt/eso/manifests" "$vt/mv/templates"
  helm template external-secrets "$eso_chart" --repo "$eso_repo" --version "$eso_version" --namespace external-secrets \
    -f "$gtree/$eso_values" --show-only templates/crds/externalsecret.yaml --show-only templates/crds/secretstore.yaml \
    >"$vt/eso/crds/crds.yaml" || fail "render the CRDs of external-secrets $eso_version"
  kubeconform=$(tool_image KUBECONFORM_IMAGE)
  docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$vt/eso/crds:/crds:ro" -v "$vt/eso/schemas:/schemas" \
    --workdir /schemas -e 'FILENAME_FORMAT={kind}-{fullgroup}-{version}' -e DENY_ROOT_ADDITIONAL_PROPERTIES=1 \
    --entrypoint /openapi2jsonschema "$kubeconform" /crds/crds.yaml >"$vt/eso/o2j.log" 2>&1 ||
    { cat "$vt/eso/o2j.log" >&2; fail "schemas from the CRDs of external-secrets $eso_version"; }
  # openapi2jsonschema turns provider crd of SecretStore into a schema no manifest can pass; no store uses it.
  ss_schema=$vt/eso/schemas/secretstore-external-secrets.io-v1.json
  jq -e '.properties.spec.properties.provider.properties.crd' "$ss_schema" >/dev/null ||
    fail "no provider crd in ${ss_schema##*/}: drop the step that removes it"
  jq 'del(.properties.spec.properties.provider.properties.crd)' "$ss_schema" >"$vt/eso/ss.json" &&
    mv "$vt/eso/ss.json" "$ss_schema"
  for env in $envs; do
    if [ -f "$tmp/render/base-$env-svp-cluster.yaml" ] &&
      grep -Eq '^kind: (ExternalSecret|SecretStore)$' "$tmp/render/base-$env-svp-cluster.yaml"; then
      fail "svp-cluster at $(label_of "$env") with base/ alone (the dev path's) renders an ExternalSecret or a SecretStore"
    fi
  done
  # Reads merged chart values: s3.mode decides which entries of files/external-secrets.yaml exist
  # (a chart from before s3.mode has one object store, in the cluster).
  printf 'apiVersion: v2\nname: mv\nversion: 0.1.0\n' >"$vt/mv/Chart.yaml"
  printf '%s\n' '# json {{ toJson .Values }}' >"$vt/mv/templates/values.yaml"
  for target in $targets; do
    env=${target%%:*} plat=${target#*:}
    tag=$env-$plat label="$env on $plat"
    runs_on svp-cluster "$plat" || continue
    code=$(code_of "$env")
    args=(--namespace cert-manager)
    while IFS= read -r f; do args+=(-f "$f"); done < <(target_values "$env" "$plat" svp-cluster)
    cp "$code/deploy/helm/svp-cluster/values.yaml" "$vt/mv/values.yaml"
    merged=$(helm template mv "$vt/mv" "${args[@]}" | sed -n 's/^# json //p') && [ -n "$merged" ] ||
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
    if [ "$plat" = eks ]; then
      [ "$provider" = aws ] || fail "the SecretStores of $label use provider '$provider', want aws"
      if grep -n 'svp-secrets' "$f" >&2; then
        fail "the render of svp-cluster for $label above still names svp-secrets, the lab's source namespace"
      fi
    else
      [ "$provider" = kubernetes ] || fail "the SecretStores of $label use provider '$provider', want kubernetes"
    fi
    helm template svp-cluster "$code/deploy/helm/svp-cluster" "${args[@]}" --show-only templates/external-secrets.yaml \
      >"$vt/eso/manifests/$tag.yaml" || fail "render the ExternalSecrets of svp-cluster for $label"
    docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$vt/eso/manifests:/manifests:ro" \
      -v "$vt/eso/schemas:/schemas:ro" "$kubeconform" -strict -summary \
      -skip ServiceAccount,Role,RoleBinding,ValidatingAdmissionPolicy,ValidatingAdmissionPolicyBinding \
      -schema-location '/schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json' "/manifests/$tag.yaml" \
      >"$vt/eso/kubeconform.log" 2>&1 || { cat "$vt/eso/kubeconform.log" >&2; fail "kubeconform on the ExternalSecrets and SecretStores for $label"; }
    grep -q "Valid: $((es + ss)), Invalid: 0, Errors: 0" "$vt/eso/kubeconform.log" ||
      { cat "$vt/eso/kubeconform.log" >&2; fail "kubeconform did not find $((es + ss)) valid ExternalSecrets and SecretStores for $label"; }
    echo "ok    svp-cluster for $label: $es ExternalSecrets, $ss SecretStores (provider $provider, object store $mode), valid against the CRDs of external-secrets $eso_version; none with base/ alone"
  done

  # --- 4. image digests, per folder of charts (one per revision, or the working tree): every component with its base/
  # values and Argo CD as argocd/bootstrap.json installs it, then each component with values of a platform again with
  # them, and each with an overlay of an environment of those charts again with it. argocd/bootstrap.json installs chart
  # argo-cd of https://argoproj.github.io/argo-helm with a values file of the tree (policy layout of step 1).
  bootstrap=$gtree/argocd/bootstrap.json
  argocd_version=$(jq -r '.version' "$bootstrap")
  argocd_values=$(jq -r '.values' "$bootstrap")

  # One line per component, fields separated by the ASCII unit separator so empty fields survive `read`; Argo CD last.
  sep=$'\x1f'
  list=$(jq -r '.components[] | [.name, .namespace, (.path // ""), (.repo // ""), (.chart // ""), (.version // ""),
    (.values // "")] | join("\u001f")' "$components") || fail "read argocd/apps/components.json"
  list+=$'\n'"argocd${sep}argocd${sep}${sep}https://argoproj.github.io/argo-helm${sep}argo-cd${sep}$argocd_version${sep}$argocd_values"
  digest_problems=
  for rev in $(for env in $envs; do revision_of "$env"; done | sort -u); do
    out=$vt/digests/$rev
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
      if [ -n "$values" ]; then args+=(--values "$gtree/$values"); fi
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
      # Argo CD with platform values (platforms/<platform>/argo-cd.yaml), as deploy/k8s/gitops.sh installs it.
      if [ "$name" = argocd ]; then
        for plat in $rev_platforms; do
          [ -f "$gtree/platforms/$plat/argo-cd.yaml" ] || continue
          helm "${args[@]}" --values "$gtree/platforms/$plat/argo-cd.yaml" >"$out/platform/$plat/$name.yaml" 2>"$tmp/err" ||
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
        [ ! -f "$gtree/platforms/$plat/$name.yaml" ] || pargs+=(--values "$gtree/platforms/$plat/$name.yaml")
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
      # With each environment's overlay, the values in the order Argo CD reads them, one layer per file (layer_values):
      # the file of its platform, the overlay, then what the root renders from the platform's template, which comes
      # last. base/ is in args already; the image file is left out: base/ has the placeholder.
      for target in $rev_targets; do
        env=${target%%:*} plat=${target#*:}
        [ -f "$tree/envs/$env/$name.yaml" ] && runs_on "$name" "$plat" || continue
        eargs=()
        while IFS= read -r f; do
          case $f in "$gtree/$values" | "$tree/envs/$env/images/$name.yaml") ;; *) eargs+=(--values "$f") ;; esac
        done < <(layer_values "$env" "$plat" "$name")
        helm "${args[@]}" "${eargs[@]}" \
          >"$out/env/$env-$plat/$name.yaml" 2>"$tmp/err" ||
          { cat "$tmp/err" >&2; fail "helm template $name ($label) with envs/$env/$name.yaml on $plat"; }
        overlays=$((overlays + 1))
      done
    done <<<"$list"

    # Compares overlay images against platform render, and platform render against base.
    # Overlay keeps exact images; platform cannot change base image versions, but may omit or add images
    # (which the pin check holds to their digests like every image).
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

    # The images ENV runs on eks: per component the render of the environment's overlay, else of the platform, else
    # the base's (what Argo CD would install there; a component that does not run on eks has none).
    if [ -n "$images_only" ]; then
      while IFS=$sep read -r name _; do
        { [ "$name" = argocd ] || runs_on "$name" eks; } || continue
        for f in "$out/env/$images_env-eks/$name.yaml" "$out/platform/eks/$name.yaml" "$out/base/$name.yaml"; do
          [ -f "$f" ] || continue
          image_refs "$name" "$f" | cut -f2 >>"$images_out"
          break
        done
      done <<<"$list"
    fi

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
}

# Each environment that pins a commit renders on its own, at that commit unpacked with git archive (neither the
# working tree nor the index of GITOPS_DIR is read); the others together on the tree.
unpinned=
for env in $envs; do
  pin=$(pinned_commit "$env")
  if [ -z "$pin" ]; then
    unpinned+="${unpinned:+ }$env"
    continue
  fi
  mkdir -p "$tmp/gitops/$env"
  git -C "$tree" archive "$pin" | tar -x -C "$tmp/gitops/$env" || fail "unpack ${pin:0:12} of svp-gitops with git archive"
  render_tree "$tmp/gitops/$env" "$env" "$pin"
done
[ -z "$unpinned" ] || render_tree "$tree" "$unpinned" ""
if [ -n "$root_only" ]; then
  echo "ok    $tree: the tree and its root chart"
  exit 0
fi
if [ -n "$images_only" ]; then
  sort -u "$images_out" -o "$images_out"
  echo "ok    $(grep -c . "$images_out" || true) images of $images_env on eks in $images_out"
  exit 0
fi

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
