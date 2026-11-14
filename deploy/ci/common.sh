# shellcheck shell=bash
# Release pipeline helpers; sourcing only defines functions and variables and loads deploy/k8s/lib.sh. Bash 3.2 too.
# Invariants: docker without DOCKER_DEFAULT_PLATFORM, pinned tool images, no secrets printed.
# Design notes: docs/reference/ci.md.

ci_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/k8s/lib.sh
. "$ci_dir/../k8s/lib.sh"

# step_output KEY VALUE: hands VALUE to later steps ($GITHUB_OUTPUT); prints KEY=VALUE on a machine.
# Not >>/dev/stdout on a machine: on Linux that reopens stdout's file and the next line overwrites it.
step_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; else printf '%s=%s\n' "$1" "$2"; fi
}
# step_summary [LINE...]: adds LINEs (stdin when none) to the summary page of the job ($GITHUB_STEP_SUMMARY).
step_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if [ $# -gt 0 ]; then printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"; else cat >>"$GITHUB_STEP_SUMMARY"; fi
  elif [ $# -gt 0 ]; then
    printf '%s\n' "$@"
  else
    cat
  fi
}
# step_summary_tee: copies stdin to stdout and, in a job, to its summary page too.
step_summary_tee() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then tee -a "$GITHUB_STEP_SUMMARY"; else cat; fi; }
# run_repo_url: prints repository URL on GitHub (from $GITHUB_REPOSITORY, or remote origin of SVP_CODE_ROOT).
# Strips userinfo from error messages: URLs may carry credentials (user:token@host).
run_repo_url() {
  local url shown
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    echo "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"
  elif [ -z "${SVP_CODE_ROOT:-}" ]; then
    echo https://github.com/anhnvcoder/svp-backend
  else
    url=$(git -C "$SVP_CODE_ROOT" remote get-url origin 2>/dev/null) || url=
    if [[ $url =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
      url=${BASH_REMATCH[2]}
      echo "https://github.com/${url%.git}"
    else
      shown=$url
      [[ ! $url =~ ^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@(.*)$ ]] || shown=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
      fail "SVP_CODE_ROOT=$SVP_CODE_ROOT has no remote origin on github.com (got '${shown:-none}'): its repository cannot be named"
    fi
  fi
}
# run_builder_id: prints workflow URL at its ref; builder in attestations and subject in keyless certificates.
run_builder_id() {
  if [ -n "${GITHUB_WORKFLOW_REF:-}" ]; then
    echo "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_WORKFLOW_REF"
  else
    echo local
  fi
}

# script_root is this repo (lib.sh, tools, sources table); code_root is the tree built (SVP_CODE_ROOT when set).
# Separate roots let external repositories run these scripts from a pinned checkout of this repository.
# shellcheck disable=SC2034 # read by the scripts that source this file
script_root=$repo_root
if [ -n "${SVP_CODE_ROOT:-}" ]; then
  code_root=$(cd "$SVP_CODE_ROOT" 2>/dev/null && pwd) || fail "SVP_CODE_ROOT=$SVP_CODE_ROOT is not a folder"
else
  code_root=$repo_root
fi

# require_code_files PATH...: fails if PATH is missing in code_root when building another repository.
# Stops before build/scan if external tree is wrong or lacks Dockerfile, lockfile, or .trivyignore.yaml.
require_code_files() {
  local path
  [ "$code_root" != "$script_root" ] || return 0
  for path in "$@"; do
    [ -f "$code_root/$path" ] || fail "$code_root has no file $path: SVP_CODE_ROOT must be the checkout whose code is built"
  done
}

# use_build_source [IMAGE]: sets build_source, build_source_name, and build_prefix for this run's repository.
# Fails if repository is not in sources table, or if IMAGE is not in services/drillImages of that source.
# Policy only admits an image under its source prefix matching that source's identity.
use_build_source() {
  local url table found
  url=$(run_repo_url) || exit 1
  table=$(release_sources) || exit 1
  found=$(jq -c --arg u "$url" '[.sources[] | select(.repository == $u)]' <<<"$table")
  [ "$(jq length <<<"$found")" = 1 ] ||
    fail "this run is of $url, which is the repository of $(jq length <<<"$found") release sources of $release_sources_file, not one: nothing of it is built, pushed or signed"
  build_source=$(jq -c '.[0]' <<<"$found")
  build_source_name=$(jq -r .name <<<"$build_source")
  build_prefix=$(jq -r .imagePrefix <<<"$build_source")
  if [ -n "${1:-}" ]; then
    jq -e --arg i "$1" '.services + .drillImages | index($i)' <<<"$build_source" >/dev/null ||
      fail "$1 is not an image of release source $build_source_name ($(jq -r '.services + .drillImages | join(" ")' <<<"$build_source")): nothing is built, pushed or signed under $build_prefix"
  fi
}

# check_code_tree: fails unless HEAD of code_root matches $GITHUB_SHA.
# Prevents another repository from building and labeling this checkout if SVP_CODE_ROOT was forgotten.
check_code_tree() {
  local commit head
  head=$(git -C "$code_root" rev-parse --verify HEAD) || fail "read the commit at HEAD of $code_root"
  commit=${GITHUB_SHA:-$head}
  [ "$head" = "$commit" ] ||
    fail "HEAD of $code_root is $head, but this run builds $commit of $(run_repo_url): set SVP_CODE_ROOT to the checkout of that commit"
}

# drill_images: images built only to drill admission, never run by charts or listed in svp-gitops (no rescan).
# Must match drillImages in release source backend; admitted under its prefix.
# shellcheck disable=SC2034 # read by the scripts that source this file
drill_images=(drill-vulnerable drill-unsigned drill-no-provenance)
# use_release_source SOURCE: sets source_name, sign_issuer, sign_subject, provenance_repository, provenance_ref.
# Kyverno checks the same values; files/sources.json of chart svp-policy is the one place to change them.
use_release_source() {
  local fields
  fields=$(jq -r '[.name, .issuer, .subject, .repository, .provenanceRef] | map(. // "") | join("\t")' <<<"$1") ||
    fail "read the release source $1"
  IFS=$'\t' read -r source_name sign_issuer sign_subject provenance_repository provenance_ref <<<"$fields"
  [[ ${sign_issuer:-} =~ ^https://[^[:space:]]+$ && ${sign_subject:-} =~ ^https://[^[:space:]]+$ ]] ||
    fail "issuer and subject of release source ${source_name:-?} must each be one plain https:// URL"
  [[ ${provenance_repository:-} =~ ^https://[^[:space:]]+$ && ${provenance_ref:-} =~ ^refs/[^[:space:]]+$ ]] ||
    fail "repository and provenanceRef of release source ${source_name:-?} must be one https:// URL and one refs/... each"
}
# sign_identity [SOURCE]: sets sign_issuer and sign_subject for SOURCE (default backend) from working tree.
# Loaded on demand because most scripts never verify signatures.
sign_identity() {
  local src
  src=$(release_source "${1:-backend}") || exit 1
  use_release_source "$src"
}
# provenance_source [SOURCE]: sets provenance_repository and provenance_ref for SOURCE (default backend).
provenance_source() { sign_identity "$@"; }

# _config_file DIR REV PATH: prints PATH from gitops tree DIR at REV (or on disk if REV empty); status 1 if missing.
_config_file() {
  if [ -n "$2" ]; then
    git -C "$1" cat-file -e "$2:$3" 2>/dev/null || return 1
    git -C "$1" show "$2:$3"
  else
    [ -f "$1/$3" ] || return 1
    cat "$1/$3"
  fi
}

# _require_provenance WHERE [OVERLAY]: reads svp-policy values on stdin, prints requireProvenance boolean.
# Strict parser: fails on unexpected shapes or overlay keys to avoid guessing Kyverno behavior.
_require_provenance() {
  local value rc=0
  value=$(awk -v overlay="${2:-}" '
    /^[ ]*(#.*)?$/ { next }
    /^imageVerification:[ ]*$/ { block = 1; next }
    /^[^ ]/ { block = 0; if (overlay) bad = 1; next }
    /requireProvenance/ {
      if (block && $0 ~ /^  requireProvenance: (true|false)$/) {
        v = $0
        sub(/^  requireProvenance: /, "", v)
        found++
      } else bad = 1
      next
    }
    overlay { bad = 1 }
    END {
      if (bad || found > 1) exit 5
      if (found) print v
    }') || rc=$?
  if [ "$rc" != 0 ]; then
    if [ -n "${2:-}" ]; then
      echo "FAIL  $1: the overlay of svp-policy holds exactly 'imageVerification:' then '  requireProvenance: true' (or false), nothing else" >&2
    else
      echo "FAIL  $1: imageVerification.requireProvenance must be one line '  requireProvenance: true' (or false) in the imageVerification block" >&2
    fi
    return 1
  fi
  echo "$value"
}

# provenance_required [REV [ENV [DIR]]]: prints true when svp-policy requires build provenance in ENV (any env when
# empty), false otherwise: values.yaml at the commit charts.yaml pins, then the svp-policy.yaml overlay.
# Fails printing nothing on stdout when a file is malformed or the pinned commit is missing: callers must stop then,
# not read it as false.
provenance_required() {
  local rev=${1:-} env=${2:-} dir=${3:-} at=${1:+ at ${1:0:12}} file content base value envs e charts chart
  chart=deploy/helm/svp-policy/values.yaml
  if [ -z "$dir" ]; then
    dir=$(gitops_dir) || return 1
  fi
  if [ -n "$env" ]; then
    envs=$env
  elif [ -n "$rev" ]; then
    envs=$(git -C "$dir" ls-tree --name-only "$rev:envs" 2>/dev/null) || envs=
  else
    envs=$(cd "$dir/envs" 2>/dev/null && for e in */; do [ -d "$e" ] && echo "${e%/}"; done) || envs=
  fi
  if [ -z "$envs" ]; then
    content=$(cat "$repo_root/$chart") || return 1
    base=$(_require_provenance "$chart" <<<"$content") || return 1
    echo "${base:-false}"
    return 0
  fi
  for e in $envs; do
    charts=$(_config_file "$dir" "$rev" "envs/$e/charts.yaml" | sed -n 's/^revision: *//p')
    if ! [[ $charts =~ ^[0-9a-f]{40}$ ]] || ! content=$(git -C "$repo_root" show "$charts:$chart" 2>/dev/null); then
      echo "FAIL  envs/$e/charts.yaml$at names no commit of this clone holding $chart (got '$charts')" >&2
      return 1
    fi
    base=$(_require_provenance "$chart at ${charts:0:12}" <<<"$content") || return 1
    file=envs/$e/svp-policy.yaml
    value=
    if content=$(_config_file "$dir" "$rev" "$file"); then
      value=$(_require_provenance "$file$at" overlay <<<"$content") || return 1
    fi
    if [ "${value:-${base:-false}}" = true ]; then
      echo true
      return 0
    fi
  done
  echo false
}

# release_source_in REPOSITORY [REV [ENV [DIR]]]: prints release source JSON for REPOSITORY at pinned commit.
# When ENV is omitted, every environment must admit REPOSITORY with identical source and identity.
release_source_in() {
  local repo=$1 rev=${2:-} env=${3:-} dir=${4:-} at=${2:+ at ${2:0:12}} svc=${1##*/} envs e charts src found= first= key
  if [ -z "$dir" ]; then
    dir=$(gitops_dir) || return 1
  fi
  if [ -n "$env" ]; then
    envs=$env
  elif [ -n "$rev" ]; then
    envs=$(git -C "$dir" ls-tree --name-only "$rev:envs" 2>/dev/null) || envs=
  else
    envs=$(cd "$dir/envs" 2>/dev/null && for e in */; do [ -d "$e" ] && echo "${e%/}"; done) || envs=
  fi
  if [ -z "$envs" ]; then
    release_source_of "$svc" "$repo" && return 0
    echo "FAIL  $repo is not a release of $svc of any release source (the policy admits $(release_repositories "$svc"))" >&2
    return 1
  fi
  for e in $envs; do
    charts=$(_config_file "$dir" "$rev" "envs/$e/charts.yaml" | sed -n 's/^revision: *//p')
    if ! [[ $charts =~ ^[0-9a-f]{40}$ ]]; then
      echo "FAIL  envs/$e/charts.yaml$at names no commit of this repository (got '$charts')" >&2
      return 1
    fi
    if ! src=$(release_source_of "$svc" "$repo" "$charts"); then
      echo "FAIL  $repo is not a release of $svc that the policy of $e admits (at ${charts:0:12}: $(release_repositories "$svc" "$charts"))" >&2
      return 1
    fi
    key=$(jq -c '{name, imagePrefix, issuer, subject, repository, provenanceRef}' <<<"$src")
    if [ -z "$found" ]; then
      found=$src first=$key
    elif [ "$key" != "$first" ]; then
      echo "FAIL  the environments of $dir$at give $repo different release sources or identities: check it with --env" >&2
      return 1
    fi
  done
  echo "$found"
}

# tag_provenance_mismatch TREE CHECKED PROVENANCE_ENVS: prints one problem per line, nothing when every release agrees.
# Guard: image.tag drives "no image newer than charts", so manual tag edits must not disguise builds.
# In provenance-required environments, missing provenance commit in ok lines is rejected.
tag_provenance_mismatch() {
  awk -v tree="$1" -v envs=" $3 " '
    /^check / { file = $2; next }
    /^ok / && file != "" {
      env = file; sub(/^envs\//, "", env); sub(/\/.*/, "", env)
      if (match($0, /provenance of [0-9a-f]+ by /)) {
        commit = substr($0, RSTART + 14, RLENGTH - 18)
        tag = ""
        while ((getline l < (tree "/" file)) > 0) if (l ~ /^  tag:/) { tag = l; gsub(/^  tag: *"?|"?$/, "", tag) }
        close(tree "/" file)
        if (tag != commit) print file ": image.tag is " tag ", but its provenance says it was built from " commit
      } else if (index(envs, " " env " ")) {
        print file ": " env " requires provenance, but the check of its release names no provenance commit"
      }
      file = ""
    }' "$2"
}

# Gitops paths that decide release requirements; changes trigger checking every release in that environment.
# shellcheck disable=SC2034 # read by the scripts that source this file
policy_values_paths=('envs/*/svp-policy.yaml' 'envs/*/charts.yaml')

# Deployment repository owner/name and bot branch rebuilt by stg promote.
# shellcheck disable=SC2034 # read by the scripts that source this file
gitops_repo=${gitops_url#https://github.com/}
gitops_repo=${gitops_repo%.git}
# shellcheck disable=SC2034
gitops_promote_branch=bot/promote-stg
# Bot branch rebuilt by promote-prd of backend; it names the releases of every source.
# shellcheck disable=SC2034
gitops_promote_prd_branch=bot/promote-prd

# promote_not_behind COMMIT REVISION: guard of promote to stg (job promote in images.yml).
# Fails when COMMIT is a proper ancestor of REVISION (prevents rolling stg back); same or newer commit passes.
# Also fails when REVISION is not a full commit this clone has.
promote_not_behind() {
  [[ $2 =~ ^[0-9a-f]{40}$ ]] || fail "stg's charts name revision '$2', not a full commit of this repository"
  git -C "$repo_root" cat-file -e "$2^{commit}" 2>/dev/null ||
    fail "revision ${2:0:12} of stg's charts is no commit of this clone: cannot tell whether this run is older"
  [ "$1" = "$2" ] || ! git -C "$repo_root" merge-base --is-ancestor "$1" "$2" ||
    fail "this run's commit ${1:0:12} is older than ${2:0:12}, whose charts stg runs: promoting it would take stg back"
}

# promote_stg_ref REF CLONE: guard of promote-prd; prints full commit of svp-gitops REF.
# Blocks refs not on main of svp-gitops (short SHAs, other branches, PRs): only commits held by stg main reach prd.
promote_stg_ref() {
  local commit
  if [ "$1" = main ]; then
    commit=$(git -C "$2" rev-parse --verify --quiet "refs/remotes/origin/main^{commit}") ||
      fail "the clone of svp-gitops has no main"
  else
    [[ $1 =~ ^[0-9a-f]{40}$ ]] || fail "stg_ref '$1' must be main or a full commit (40 hex digits) of svp-gitops"
    commit=$(git -C "$2" rev-parse --verify --quiet "$1^{commit}") || fail "stg_ref $1 is no commit of svp-gitops"
  fi
  git -C "$2" merge-base --is-ancestor "$commit" refs/remotes/origin/main ||
    fail "stg_ref $1 is not on main of svp-gitops: only a set that main of stg held goes to prd"
  echo "$commit"
}

# promote_stg_evidence COMMIT: guard of promote-prd; verifies COMMIT in svp-gitops has argocd/stg status success.
# Blocks promoting sets that stg never synced and found Healthy; paginates all statuses via gh.
promote_stg_evidence() {
  local pages state
  pages=$(gh api --paginate --slurp "repos/$gitops_repo/commits/$1/statuses?per_page=100") ||
    fail "read the commit statuses of ${1:0:12} in $gitops_repo"
  state=$(jq -er --arg context "argocd/stg" 'if type == "array" and all(.[]; type == "array") then
    [add // [] | .[] | select(.context == $context)] | max_by(.id) | .state // "" else error("no list of pages") end' \
    <<<"$pages" 2>/dev/null) || fail "read the commit statuses of ${1:0:12} in $gitops_repo: the answer is no list of pages of statuses"
  [ -n "$state" ] ||
    fail "${1:0:12} of $gitops_repo has no commit status argocd/stg: stg never ran that set, so it does not go to prd"
  [ "$state" = success ] ||
    fail "the newest commit status argocd/stg of ${1:0:12} in $gitops_repo is $state, not success: only a set stg ran healthy goes to prd"
}

# promote_open_pr REPO BRANCH APP: prints open PR number created by GitHub App APP from BRANCH into main of REPO.
# Guards against forks/personal PRs matching branch name; fails if list reaches 500 rather than dropping releases.
promote_open_pr() {
  local list
  list=$(gh pr list --repo "$1" --head "$2" --base main --state open --limit 500 \
    --json number,isCrossRepository,author) || fail "list the open pull requests of $2 in $1"
  [ "$(jq length <<<"$list")" -lt 500 ] ||
    fail "500 or more open pull requests from a branch $2 in $1: close the forks' before promoting"
  jq -r --arg author "app/$3" \
    '[.[] | select(.isCrossRepository == false and .author.login == $author)][0].number // empty' <<<"$list"
}

# promote_image_row SERVICE REPOSITORY TAG DIGEST: prints Markdown table row for promote PR with links and short digest.
promote_image_row() {
  [[ $2 =~ ^ghcr\.io/([^/]+)/([^/]+)/([^/]+)$ ]] || fail "image '$2' of $1 is no ghcr.io/<owner>/<repo>/<name>"
  local owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} name=${BASH_REMATCH[3]}
  # shellcheck disable=SC2016 # backticks of the markdown
  printf '| `%s` | [`%s`](https://github.com/%s/%s/commit/%s) | [`%s@%s…`](https://github.com/%s/%s/pkgs/container/%s%%2F%s) |\n' \
    "$1" "$3" "$owner" "$repo" "$3" "$2" "${4:0:19}" "$owner" "$repo" "$repo" "$name"
}

# yq_ [NAME=VALUE...] ARGS...: runs pinned yq without network as calling user with PWD as workdir.
# Passes NAME=VALUE into container env for strenv(); never run inside loops reading stdin.
yq_() {
  local image env=()
  image=$(tool_image YQ_IMAGE) || return 1
  while [[ ${1:-} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    env+=(--env "$1")
    shift
  done
  docker_ run --rm -i --network none --user "$(id -u):$(id -g)" -v "$PWD:/workdir" -w /workdir \
    ${env[@]+"${env[@]}"} "$image" "$@"
}

# provenance_absent ISSUER SUBJECT IMAGE: status 0 if verified attestations lack provenance, 1 if present, 2 on error.
# Only cosign's specific predicate mismatch message counts as absent provenance; errors never pass.
provenance_absent() {
  local err rc=0
  err=$(cosign_ verify-attestation --type slsaprovenance1 --certificate-oidc-issuer "$1" --certificate-identity "$2" \
    "$3" 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || return 1
  case $err in *"none of the attestations matched the predicate type"*) return 0 ;; esac
  printf '%s\n' "${err:-cosign exited $rc}" | tail -n 1 >&2
  return 2
}

# check_provenance_statement DIGEST: checks in-toto statement on stdin against Kyverno requireProvenance rules.
# Validates SLSA v1, subject DIGEST, builder ID, workflow repo/ref, and single source gitCommit; prints the commit,
# or the first problem (status 1). Needs the image's release source set first (sign_identity and provenance_source,
# or use_release_source): Kyverno checks each image against its own source.
check_provenance_statement() {
  local verdict
  verdict=$(jq -r --arg d "${1#sha256:}" --arg builder "$sign_subject" --arg repo "$provenance_repository" \
    --arg ref "$provenance_ref" '
    def wf: .predicate.buildDefinition.externalParameters.workflow;
    [.predicate.buildDefinition.resolvedDependencies[]?.digest.gitCommit] as $commits
    | if .predicateType != "https://slsa.dev/provenance/v1" then "not a SLSA v1 provenance"
    elif ([.subject[]?.digest.sha256] | index($d)) == null then "the attestation is not about this digest"
    elif .predicate.runDetails.builder.id != $builder then "builder.id is \(.predicate.runDetails.builder.id), not \($builder)"
    elif wf.repository != $repo then "workflow repository is \(wf.repository), not \($repo)"
    elif wf.ref != $ref then "workflow ref is \(wf.ref), not \($ref)"
    elif ($commits | length) != 1 or ($commits[0] | type) != "string" or ($commits[0] | test("^[0-9a-f]{40}$") | not)
      then "resolvedDependencies does not name exactly one commit (gitCommit, 40 hex)"
    else "ok \($commits[0])" end' 2>/dev/null) || verdict="is not readable JSON"
  case $verdict in
  "ok "*) echo "${verdict#ok }" ;;
  *)
    echo "$verdict"
    return 1
    ;;
  esac
}
# Vulnerability DB order for trivy (mirror.gcr.io, then GHCR on 429 or 5xx), recorded in vuln attestations.
trivy_db_repository=mirror.gcr.io/aquasec/trivy-db:2,ghcr.io/aquasecurity/trivy-db:2
# Accepted risks for code_root; each repository maintains its own package exceptions.
trivyignore=$code_root/.trivyignore.yaml
# Grype exceptions read directly by grype_sbom; scan-gate.sh checks each matches an entry in trivyignore.
grypeignore=$code_root/.grype.yaml

# tool_image NAME: prints pinned image reference with digest from env or Makefile, ensuring identical CI and local runs.
tool_image() {
  local ref=${!1:-}
  [ -n "$ref" ] || ref=$(sed -n "s/^$1[[:space:]]*:=[[:space:]]*//p" "$repo_root/Makefile")
  case $ref in
  *@sha256:*) echo "$ref" ;;
  *) fail "$1 is neither in the environment nor pinned by digest in the Makefile" ;;
  esac
}

# runner_arch: prints Docker server architecture as amd64 or arm64.
runner_arch() {
  case $(docker_ version --format '{{.Server.Arch}}') in
  amd64 | x86_64) echo amd64 ;;
  arm64 | aarch64) echo arm64 ;;
  *) fail "docker runs on an architecture the pipeline does not build" ;;
  esac
}

# now_utc: prints current time in RFC 3339 UTC to the second, matching cosign vuln predicate requirements.
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# trivy_cache: prints trivy DB directory ($SVP_TRIVY_CACHE or ${TMPDIR:-/tmp}/svp-trivy-cache).
trivy_cache() {
  local dir=${SVP_TRIVY_CACHE:-${TMPDIR:-/tmp}/svp-trivy-cache}
  mkdir -p "$dir" || fail "create the trivy cache $dir"
  echo "$dir"
}

# trivy_ ARGS...: runs the pinned trivy as the calling user (files it writes stay readable for the cache and the
# artifacts), with its cache and DB repositories set. Callers add their own volumes through the array trivy_mounts.
trivy_mounts=()
trivy_() {
  local image
  image=$(tool_image TRIVY_IMAGE) || return 1
  # The odd expansion keeps an empty array from tripping `set -u` in bash 3.2.
  docker_ run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$(trivy_cache):/cache" \
    ${trivy_mounts[@]+"${trivy_mounts[@]}"} "$image" "$@" --cache-dir /cache
}

# trivy_scan_args: prints shared scan flags for gate and rescan (vuln, secret, JSON, ignorefile if present).
trivy_scan_args() {
  printf '%s\n' --scanners vuln,secret --db-repository "$trivy_db_repository" --format json
  [ -f "$trivyignore" ] && printf '%s\n' --ignorefile /ignore.yaml
  return 0
}

# trivy_db_updated_at: prints DB UpdatedAt in RFC 3339 seconds for vuln predicates.
trivy_db_updated_at() {
  # Cuts nanoseconds so every timestamp in the predicate uses uniform RFC 3339 second precision.
  trivy_ version --format json | jq -er '.VulnerabilityDB.UpdatedAt | sub("\\.[0-9]+"; "")' ||
    fail "read the trivy DB version"
}

# grype_cache: prints grype DB cache directory.
grype_cache() {
  local dir=${SVP_GRYPE_CACHE:-${TMPDIR:-/tmp}/svp-grype-cache}
  mkdir -p "$dir" || fail "create the grype cache $dir"
  echo "$dir"
}

# grype_sbom DIR [ARGS...]: runs pinned grype on DIR/sbom.spdx.json, writing grype.json and grype.sarif.raw.
# Network only for DB fetch; fails if DB >5 days old; isolated with empty tmpfs HOME/workdir so only -c config is read.
grype_sbom() {
  local dir=$1 image mounts=() config=()
  shift
  image=$(tool_image GRYPE_IMAGE) || return 1
  [ -s "$dir/sbom.spdx.json" ] || fail "no SBOM at $dir/sbom.spdx.json"
  rm -f "$dir/grype.json" "$dir/grype.sarif.raw"
  if [ -f "$grypeignore" ]; then
    mounts=(-v "$grypeignore:/ignore/grype.yaml:ro")
    config=(-c /ignore/grype.yaml)
  fi
  docker_ run --rm --user "$(id -u):$(id -g)" --tmpfs /tmp:mode=1777 -e HOME=/tmp --workdir /tmp \
    -e GRYPE_CHECK_FOR_APP_UPDATE=false -e GRYPE_DB_CACHE_DIR=/cache -e GRYPE_DB_REQUIRE_UPDATE_CHECK=true \
    -v "$(grype_cache):/cache" -v "$dir:/out" ${mounts[@]+"${mounts[@]}"} "$image" \
    sbom:/out/sbom.spdx.json ${config[@]+"${config[@]}"} "$@" -o json=/out/grype.json -o sarif=/out/grype.sarif.raw -q
}

# grype_sarif DIR CATEGORY: filters DIR/grype.sarif.raw to HIGH/CRITICAL matches, matching trivy SARIF format.
grype_sarif() {
  local dir=$1 category=$2
  jq --slurpfile g "$dir/grype.json" --arg c "$category" '
    ([$g[0].matches[] | select(.vulnerability.severity == "Critical" or .vulnerability.severity == "High")
      | "\(.vulnerability.id)-\(.artifact.name)"] | unique) as $keep
    | .runs[] |= (.automationDetails.id = $c
      | .results |= map(select(.ruleId | IN($keep[])))
      | ([.results[].ruleId] | unique) as $used
      | .tool.driver.rules |= map(select(.id | IN($used[]))))' \
    "$dir/grype.sarif.raw" >"$dir/grype.sarif" || fail "write the SARIF of grype in $dir"
  rm -f "$dir/grype.sarif.raw"
}

# sbom_binaries FILE: prints comma-separated packages from SPDX FILE without package managers (pkg:generic/...).
sbom_binaries() {
  jq -r '[.packages[]? | .versionInfo as $v | select(any(.externalRefs[]?; .referenceType == "purl"
    and (.referenceLocator | startswith("pkg:generic/")))) | "\(.name)@\($v)"] | unique | join(", ")' "$1"
}

# grype_check SBOM IMAGE ARCH: runs grype gate locally on an SPDX file or digest-pinned image via syft.
grype_check() {
  local sbom=$1 image=$2 arch=${3:-amd64} tmp label syft_image
  tmp=$(mktemp -d) || fail "create a temporary directory"
  # shellcheck disable=SC2064 # the directory is known now; the trap runs after this function has returned
  trap "rm -rf '$tmp'" EXIT
  if [ -n "$sbom" ] && [ -z "$image" ]; then
    case $sbom in /*) ;; *) fail "SBOM=$sbom is not an absolute path" ;; esac
    [ -f "$sbom" ] || fail "SBOM=$sbom is not a file"
    cp "$sbom" "$tmp/sbom.spdx.json" || fail "copy $sbom"
    jq -e '.spdxVersion' "$tmp/sbom.spdx.json" >/dev/null 2>&1 || fail "$sbom is not an SPDX JSON document"
    label=$sbom
  elif [ -n "$image" ] && [ -z "$sbom" ]; then
    [[ $image =~ @sha256:[0-9a-f]{64}$ ]] || fail "IMAGE=$image is not pinned by digest (<ref>@sha256:<64 hex>)"
    case $arch in amd64 | arm64) ;; *) fail "ARCH=$arch is neither amd64 nor arm64" ;; esac
    syft_image=$(tool_image SYFT_IMAGE)
    echo "syft: SBOM of $image for linux/$arch, read from its registry"
    docker_ run --rm --user "$(id -u):$(id -g)" --tmpfs /tmp:mode=1777 -e HOME=/tmp -e SYFT_CHECK_FOR_APP_UPDATE=false \
      -v "$tmp:/out" "$syft_image" "registry:$image" --platform "linux/$arch" -o spdx-json=/out/sbom.spdx.json -q ||
      fail "write the SBOM of $image"
    label="$image linux/$arch"
  else
    fail "set either SBOM=<absolute path of an SPDX JSON document> or IMAGE=<ref>@sha256:<digest> [ARCH=amd64|arm64]"
  fi
  echo "$(jq '.packages | length' "$tmp/sbom.spdx.json") packages in the SBOM; binaries outside a package manager:" \
    "$(sbom_binaries "$tmp/sbom.spdx.json" | sed 's/^$/none/')"
  "$ci_dir/scan-gate.sh" --grype "$label" "$tmp"
}

# oci_labels [SOURCE]: prints OCI labels (source, revision, created) for HEAD of code_root in UTC.
oci_labels() {
  local rev created src
  src=$(release_source "${1:-backend}") || exit 1
  rev=$(git -C "$code_root" rev-parse HEAD) || fail "read the commit at HEAD"
  created=$(TZ=UTC git -C "$code_root" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ HEAD) ||
    fail "read the commit time of HEAD"
  echo "org.opencontainers.image.source=$(jq -r .repository <<<"$src")"
  echo "org.opencontainers.image.revision=$rev"
  echo "org.opencontainers.image.created=$created"
}

# is_digest VALUE: true when VALUE is sha256:<64 lowercase hex>.
is_digest() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }

# fetch_manifest REF FILE: writes raw manifest for REF to FILE byte-for-byte and prints its sha256 digest.
# Avoids shell variables which drop trailing newlines and alter digests.
fetch_manifest() {
  docker_ buildx imagetools inspect --raw "$1" >"$2" || return 1
  echo "sha256:$(shasum -a 256 "$2" | cut -d' ' -f1)"
}

# values_field reader is defined in deploy/k8s/lib.sh.

# cosign_ ARGS...: executes cosign from PATH or pinned COSIGN_IMAGE (local: verification only, never signing).
cosign_() {
  if command -v cosign >/dev/null 2>&1; then
    cosign "$@"
  else
    local image
    image=$(tool_image COSIGN_IMAGE) || return 1
    docker_ run --rm "$image" "$@"
  fi
}

# verify_signature REPOSITORY DIGEST: true if REPOSITORY@DIGEST is signed by its release source keyless identity.
verify_signature() {
  local name
  name=$(source_of_repository "$1") || return 1
  sign_identity "$name"
  cosign_ verify --certificate-oidc-issuer "$sign_issuer" --certificate-identity "$sign_subject" "$1@$2" >/dev/null
}

# Sigstore bundles: OCI referrers stored via fallback tag sha256-<hex> (GHCR lacks referrers API).
# Releases have either bundles or legacy .sig/.att, never both: once a bundle exists, Kyverno/cosign require bundles.
# shellcheck disable=SC2034 # read by the scripts that source this file
bundle_artifact_type=application/vnd.dev.sigstore.bundle.v0.3+json
# Predicate types for release bundles: cosign signature, SBOM, vuln scan, and SLSA provenance.
# shellcheck disable=SC2034
sign_predicate_type=https://sigstore.dev/cosign/sign/v1
# shellcheck disable=SC2034
sbom_predicate_type=https://spdx.dev/Document
vuln_predicate_type=https://cosign.sigstore.dev/attestation/vuln/v1
# shellcheck disable=SC2034
provenance_predicate_type=https://slsa.dev/provenance/v1

# oras_run ARGS...: runs pinned ORAS with docker login credentials mounted read-only at /auth/config.json.
oras_run() {
  local image config
  image=$(tool_image ORAS_IMAGE) || return 1
  config=${DOCKER_CONFIG:-$HOME/.docker}/config.json
  [ -f "$config" ] || {
    echo "FAIL  no $config: docker login to the registry first" >&2
    return 1
  }
  docker_ run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$config:/auth/config.json:ro" "$image" "$@"
}
# registry_oras ARGS...: oras_run of a command that reads one registry (not cp, which takes one config per side).
registry_oras() { oras_run "$@" --registry-config /auth/config.json; }

# bundle_referrers IMAGE: prints "<digest> <predicate type>" per bundle referrer of IMAGE (unverified listing).
# Reads predicateType annotation or inspects bundle layer directly (GHCR cosign bundles lack annotations).
bundle_referrers() {
  local out list digest type
  out=$(registry_oras discover --format json --artifact-type "$bundle_artifact_type" "$1") || {
    echo "FAIL  list the referrers of $1" >&2
    return 1
  }
  list=$(jq -r 'if (.referrers | type) == "array"
    then .referrers[] | "\(.digest) \(.annotations["dev.sigstore.bundle.predicateType"] // "" | if . == "" then "-" else . end)"
    else error("no referrers") end' <<<"$out" 2>/dev/null) || {
    echo "FAIL  read the referrers of $1 from what oras answered" >&2
    return 1
  }
  while read -r digest type; do
    [ -n "$digest" ] || continue
    if [ "$type" = - ]; then
      type=$(bundle_type "${1%@*}@$digest" </dev/null) || return 1
    fi
    echo "$digest $type"
  done <<<"$list"
}

# bundle_type REFERRER: prints predicate type from bundle payload (in-toto statement or messageSignature).
bundle_type() {
  local manifest layer bundle type
  manifest=$(registry_oras manifest fetch "$1") || {
    echo "FAIL  read the manifest of the bundle $1" >&2
    return 1
  }
  layer=$(jq -r --arg t "$bundle_artifact_type" '[.layers[]? | select(.mediaType == $t) | .digest]
    | if length == 1 and (.[0] | test("^sha256:[0-9a-f]{64}$")) then .[0]
      else error("not one bundle layer") end' <<<"$manifest" 2>/dev/null) || {
    echo "FAIL  $1 is not a manifest of one Sigstore bundle layer" >&2
    return 1
  }
  bundle=$(registry_oras blob fetch --output - "${1%@*}@$layer") || {
    echo "FAIL  read the bundle $layer of $1" >&2
    return 1
  }
  type=$(jq -r --arg sign "$sign_predicate_type" '
    if .dsseEnvelope != null then
      if .dsseEnvelope.payloadType != "application/vnd.in-toto+json" then error("not an in-toto statement")
      else .dsseEnvelope.payload | @base64d | fromjson | .predicateType
        | if type == "string" and test("^\\S+$") then . else error("no predicate type") end end
    elif .messageSignature != null then $sign
    else error("neither a DSSE envelope nor a message signature") end' <<<"$bundle" 2>/dev/null) || {
    echo "FAIL  read the predicate type of the bundle $1 ($layer)" >&2
    return 1
  }
  echo "$type"
}

# bundles_of TYPE: reads lines of bundle_referrers on stdin and prints the digest of each bundle of predicate type TYPE.
bundles_of() { awk -v t="$1" '$2 == t { print $1 }'; }

# release_format IMAGE: prints signing format (bundle, legacy, none); fails if both are present or registry errors.
release_format() {
  local bundles err tag=${1%@*}:sha256-${1##*@sha256:}.sig legacy=false
  bundles=$(bundle_referrers "$1") || return 1
  if err=$(registry_oras manifest fetch --descriptor "$tag" 2>&1 >/dev/null); then
    legacy=true
  else
    case $err in
    *": not found"*) ;;
    *)
      printf '%s\n' "$err" | tail -n 1 >&2
      echo "FAIL  read whether $1 has a signature in cosign's older format ($tag)" >&2
      return 1
      ;;
    esac
  fi
  if [ -n "$bundles" ] && [ "$legacy" = true ]; then
    echo "FAIL  $1 carries Sigstore bundles and cosign's older format ($tag): verifiers read the bundles only" >&2
    return 1
  fi
  if [ -n "$bundles" ]; then echo bundle; elif [ "$legacy" = true ]; then echo legacy; else echo none; fi
}

# replace_vuln_bundle REPOSITORY DIGEST PREDICATE: attests new vuln bundle and removes older ones via ORAS.
# GHCR sorts referrers by digest not age; leaves exactly one vuln bundle so Kyverno reads the fresh attestation.
# Keeps the bundle this call wrote, never one picked by an unverified bundle's content; takes off only vuln bundles.
# Needs sign_issuer and sign_subject set first; cosign must verify exactly one vuln attestation of that identity.
replace_vuln_bundle() {
  local ref=$1@$2 before after new d left count
  before=$(bundle_referrers "$ref") || fail "list the bundles of $ref"
  cosign attest --yes --new-bundle-format=true --type vuln --predicate "$3" "$ref" || fail "attest $ref"
  after=$(bundle_referrers "$ref") || fail "list the bundles of $ref after the attestation"
  new=$(comm -13 <(bundles_of "$vuln_predicate_type" <<<"$before" | sort) \
    <(bundles_of "$vuln_predicate_type" <<<"$after" | sort))
  [ "$(grep -c . <<<"$new")" -eq 1 ] ||
    fail "$ref: not exactly one new vuln bundle after the attestation (${new:-none}); nothing taken off"
  for d in $(bundles_of "$vuln_predicate_type" <<<"$after"); do
    [ "$d" != "$new" ] || continue
    registry_oras manifest delete --force "$1@$d" >/dev/null 2>&1 ||
      echo "note  oras manifest delete $1@$d did not exit 0 (GHCR answers unsupported); the list is read again below"
  done
  left=$(bundle_referrers "$ref") || fail "list the bundles of $ref after taking the older ones off"
  [ "$(bundles_of "$vuln_predicate_type" <<<"$left")" = "$new" ] ||
    fail "$ref: the vuln bundles left are $(bundles_of "$vuln_predicate_type" <<<"$left" | tr '\n' ' ')not only $new"
  count=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" "$ref" 2>/dev/null | grep -c . || true)
  [ "$count" = 1 ] || fail "$ref: cosign verifies $count vuln attestations of $sign_subject, not exactly one"
  echo "ok    $ref: one vuln bundle, $new"
}

# check_index REPOSITORY DIGEST DIR DIR: guard that what is signed and attested is exactly what was scanned.
# Verifies remote index matches scanned amd64 and arm64 manifest digests.
check_index() {
  local raw want got
  raw=$(mktemp) || return 1
  if [ "$(fetch_manifest "$1@$2" "$raw")" = "$2" ]; then
    want=$(for d in "$3" "$4"; do echo "$(cat "$d/platform") $(cat "$d/digest")"; done | sort)
    got=$(jq -r 'select(.mediaType == "application/vnd.oci.image.index.v1+json"
        or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json")
      | .manifests[] | "\(.platform.os)/\(.platform.architecture) \(.digest)"' "$raw" | sort)
  fi
  rm -f "$raw"
  [ -n "${want:-}" ] && [ "$want" = "$got" ]
}

# attest_max_age: max vuln attestation age entering main (default 48h, leaves 24h margin for Kyverno 72h limit).
# SVP_ATTEST_MAX_AGE overrides for drills only (never set in .env).
attest_max_age() {
  local age=${SVP_ATTEST_MAX_AGE:-48h}
  [[ $age =~ ^[0-9]+[smh]$ ]] || fail "SVP_ATTEST_MAX_AGE must look like 48h, 15m or 90s, not '$age'"
  case $age in
  *s) echo "${age%s}" ;;
  *m) echo $((${age%m} * 60)) ;;
  *h) echo $((${age%h} * 3600)) ;;
  esac
}

# check_vuln_statement DIGEST MAX_AGE_SECONDS: checks in-toto vuln statement against Kyverno rules and age limit.
# Validates vuln predicate type, subject DIGEST, amd64/arm64 platforms, zero CRITICALs, and scanFinishedOn age.
check_vuln_statement() {
  local verdict
  verdict=$(jq -r --arg d "${1#sha256:}" --argjson max "$2" '
    def platforms: .predicate.scanner.result.platforms;
    if .predicateType != "https://cosign.sigstore.dev/attestation/vuln/v1" then "not a vuln attestation"
    elif ([.subject[]?.digest.sha256] | index($d)) == null then "the attestation is not about this digest"
    elif ([platforms[]?.platform] != ["linux/amd64", "linux/arm64"])
      then "does not cover exactly linux/amd64 and linux/arm64"
    elif ([platforms[]?.digest | test("^sha256:[0-9a-f]{64}$")] | all | not) then "a platform digest is malformed"
    elif ([platforms[]?.report.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length) > 0
      then "lists CRITICAL vulnerabilities"
    elif ((.predicate.metadata.scanFinishedOn // "")
      | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not)
      then "scanFinishedOn is not RFC 3339"
    elif (now - (.predicate.metadata.scanFinishedOn | fromdateiso8601)) > $max
      then "scan finished \(.predicate.metadata.scanFinishedOn), more than \($max) seconds ago"
    else "ok" end' 2>/dev/null) || verdict="is not readable JSON"
  [ "$verdict" = ok ] && return 0
  echo "$verdict"
  return 1
}
