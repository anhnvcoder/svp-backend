#!/usr/bin/env bash
# rescan.sh: the daily rescan of released images. Kyverno accepts a vuln attestation for 72 hours only, so every
# released digest is scanned again with the newest DB and its vuln attestation replaced, in the format it was signed in:
# cosign's older format with --replace, Sigstore bundles with replace_vuln_bundle. Never the other: a digest with both
# is read by its bundles alone.

# rescan.sh scan-index REPOSITORY DIGEST OUT: scans each platform manifest of the index (trivy reads one per scan).
# rescan.sh run [--source NAME] OUT GITOPS_DIR [VALUES_REF]: attests the releases `list` prints (CI only).
# rescan.sh run-digest [--source NAME] OUT IMAGE DIGEST ENV: attests one release no svp-gitops ref names yet (CI only).
# rescan.sh list [--source NAME] GITOPS_DIR [VALUES_REF]: prints the releases of source NAME, one per line.

# run attests only digests signed on main by the images.yml of source NAME, the repository running the job: an old
# attestation is replaced whoever signed it, so another source's run would replace it with its own identity and Kyverno
# would refuse every new pod of those releases. A secret found today is never attested.

# A release read under envs/<env>/ of svp-gitops then gets the new vuln in env's ECR too (ecr-copy.sh refresh), with
# AWS profile svp-<env> and the host in SVP_ECR_REGISTRY_<ENV> (empty: no ECR, as in tests and on k3d).
# Design notes: docs/reference/ci.md.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# scan_index REPOSITORY DIGEST OUT: scans the index's two manifests from the registry with the gate's flags into
# OUT/amd64 and OUT/arm64 (the layout vuln-predicate.sh reads); prints the two manifest digests. Each on its own:
# trivy reads one platform per scan, so scanning the index would prove nothing about arm64.
scan_index() {
  local repo=$1 digest=$2 out=$3 index arch child dir args a
  mkdir -p "$out" || fail "create $out"
  index=$out/index.json
  [ "$(fetch_manifest "$repo@$digest" "$index")" = "$digest" ] || fail "read the index $repo@$digest, byte for byte"
  args=()
  while IFS= read -r a; do args+=("$a"); done < <(trivy_scan_args)
  trivy_mounts=(-v "$out:/out")
  [ -f "$trivyignore" ] && trivy_mounts+=(-v "$trivyignore:/ignore.yaml:ro")
  for arch in amd64 arm64; do
    child=$(jq -r --arg a "$arch" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a)]
      | if length == 1 then .[0].digest else empty end' "$index")
    is_digest "$child" || fail "$repo@$digest has no single linux/$arch manifest"
    dir=$out/$arch
    mkdir -p "$dir"
    echo "linux/$arch" >"$dir/platform"
    echo "$child" >"$dir/digest"
    [ "$(fetch_manifest "$repo@$child" "$dir/manifest.json")" = "$child" ] || fail "read $repo@$child, byte for byte"
    jq -r .config.digest "$dir/manifest.json" >"$dir/config-digest"
    now_utc >"$dir/scan-started"
    # A DB that cannot be downloaded fails the scan: never an attestation from a DB of unknown age.
    trivy_ image --image-src remote "${args[@]}" --output "/out/$arch/trivy.json" "$repo@$child" ||
      fail "scan $repo@$child"
    now_utc >"$dir/scan-finished"
    trivy_db_updated_at >"$dir/db-updated-at"
    echo "scanned linux/$arch $child"
  done
}

# image_line FILE REF WHERE (stdin: FILE at REF): prints "service<TAB>repository<TAB>digest<TAB>WHERE" of an image
# file; status 1, naming FILE at REF, when its image block cannot be read.
image_line() {
  local values svc repo digest
  values=$(cat)
  svc=$(basename "$1" .yaml)
  digest=$(values_field digest <<<"$values") || {
    echo "FAIL  $1 at $2: image.digest is not one plain line" >&2
    return 1
  }
  repo=$(values_field repository <<<"$values") || {
    echo "FAIL  $1 at $2: image.repository is not one plain line" >&2
    return 1
  }
  printf '%s\t%s\t%s\t%s\n' "$svc" "$repo" "$digest" "$3"
}

# source_args ARGS...: reads an optional --source NAME off ARGS; sets source (backend by default), source_branch and
# source_app (its promote branch and promoter app), and args to the rest.
source_args() {
  local src
  source=backend
  if [ "${1:-}" = --source ]; then
    source=${2:-}
    shift 2 || fail "--source needs a name"
  fi
  src=$(release_source "$source") || exit 1
  source_app=$(jq -r .promoter <<<"$src")
  source_branch=$gitops_promote_branch
  [ "$source" = backend ] || source_branch=$gitops_promote_branch-$source
  args=("$@")
}

# keep_own: reads the lines of list on stdin and prints those of source's releases and those of no source; one of
# another source's is named on stderr instead.
keep_own() {
  local line svc repo where owner
  # Split by hand: read with IFS=<tab> would merge the two tabs around an empty digest.
  while IFS= read -r line; do
    svc=${line%%$'\t'*}
    repo=${line#*$'\t'}
    repo=${repo%%$'\t'*}
    where=${line##*$'\t'}
    if owner=$(source_of_repository "$repo" 2>/dev/null) && [ "$owner" != "$source" ]; then
      echo "skip  $svc in $where: $repo is a release of source $owner, which its own CI rescans" >&2
      continue
    fi
    printf '%s\n' "$line"
  done
}

# list GITOPS_DIR [VALUES_REF]: prints the releases a run of the source rescans (source_args first), one per line:
# service, repository, digest and where it was read, tab-separated. Fails, after printing every release it could read,
# when a file cannot be read or the host does not say whether the promote pull request is open.
list() {
  local dir=$1 values_ref=${2:-} refs=() labels=() open prd_app i ref e svc file status=0 code=
  [ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$dir" 2>/dev/null && pwd -P)" ] ||
    fail "$dir is not a clone of svp-gitops (make gitops-clone)"
  # gf ARGS...: an anonymous fetch from svp-gitops into the clone.
  gf() { GIT_TERMINAL_PROMPT=0 git -C "$dir" -c credential.helper= fetch --quiet --no-tags origin "$@"; }
  gf "+refs/heads/main:refs/svp/rescan/main" || fail "fetch main of svp-gitops"
  refs+=(refs/svp/rescan/main) labels+=("main of svp-gitops")
  # Unanswered, the releases of main and of VALUES_REF are still listed (and rescanned) before the run fails: they are
  # what stg and prd run, whose attestations must not age out because the host did not answer. promote_open_pr runs in
  # a subshell here, so its fail ends that alone.
  if ! open=$(promote_open_pr "$gitops_repo" "$source_branch" "$source_app"); then
    echo "FAIL  ask the repository's host whether the promote pull request of $gitops_repo is open; $source_branch not read" >&2
    status=1
  elif [ -n "$open" ]; then
    gf "+refs/heads/$source_branch:refs/svp/rescan/promote" || fail "fetch $source_branch of svp-gitops"
    refs+=(refs/svp/rescan/promote) labels+=("$source_branch of svp-gitops (pull request #$open)")
  fi
  # prd's promote pull request, opened by backend's promoter, names the releases of every source; keep_own sorts them.
  prd_app=$(release_source backend | jq -r .promoter) || exit 1
  if ! open=$(promote_open_pr "$gitops_repo" "$gitops_promote_prd_branch" "$prd_app"); then
    echo "FAIL  ask the repository's host whether the promote pull request of $gitops_repo is open; $gitops_promote_prd_branch not read" >&2
    status=1
  elif [ -n "$open" ]; then
    gf "+refs/heads/$gitops_promote_prd_branch:refs/svp/rescan/promote-prd" ||
      fail "fetch $gitops_promote_prd_branch of svp-gitops"
    refs+=(refs/svp/rescan/promote-prd) labels+=("$gitops_promote_prd_branch of svp-gitops (pull request #$open)")
  fi
  if [ -n "$values_ref" ]; then
    if gf "+$values_ref:refs/svp/rescan/values-ref" 2>/dev/null; then
      refs+=(refs/svp/rescan/values-ref) labels+=("$values_ref of svp-gitops")
    elif [ "$source" = backend ] && [[ $values_ref =~ ^[0-9a-f]{40}$ ]]; then
      # A clone of the code repository may be shallow (CI's checkout): the commit is fetched when it is not there.
      git -C "$repo_root" cat-file -e "$values_ref^{commit}" 2>/dev/null ||
        git -C "$repo_root" fetch --quiet --no-tags --depth 1 origin "$values_ref" 2>/dev/null || true
      git -C "$repo_root" cat-file -e "$values_ref:deploy/k8s/values/services" 2>/dev/null ||
        fail "values_ref $values_ref is neither a commit of svp-gitops nor one of this repository with deploy/k8s/values/services/"
      code=$values_ref
    else
      fail "values_ref $values_ref is no ref of svp-gitops"
    fi
  fi
  for i in "${!refs[@]}"; do
    ref=${refs[$i]}
    for e in $(git -C "$dir" ls-tree --name-only "$ref:envs" 2>/dev/null); do
      for svc in "${svp_services[@]}"; do
        file=envs/$e/images/$svc.yaml
        if ! git -C "$dir" show "$ref:$file" 2>/dev/null | image_line "$file" "${labels[$i]}" "${labels[$i]}, $file" |
          keep_own; then
          status=1
        fi
      done
    done
  done
  if [ -n "$code" ]; then
    for svc in "${svp_services[@]}"; do
      file=deploy/k8s/values/services/$svc.yaml
      if ! git -C "$repo_root" show "$code:$file" 2>/dev/null |
        image_line "$file" "${code:0:12}" "commit ${code:0:12} of the code repository, $file" | keep_own; then
        status=1
      fi
    done
  fi
  return "$status"
}

# rescan_one SERVICE REPOSITORY DIGEST DIR SARIF_DIR: scans, gates secrets, attests, then fails on CRITICAL for one
# release; SARIF_DIR empty for a digest that is not main's. Run in a subshell, so a failure (fail exits) stops this
# digest only.
rescan_one() {
  local svc=$1 repo=$2 digest=$3 dir=$4 sarif=$5 arch blocked=0 critical format
  verify_signature "$repo" "$digest" || fail "$repo@$digest has no signature of its source's images.yml on main; not attested"
  echo "rescan $repo@$digest"
  scan_index "$repo" "$digest" "$dir"
  # The gate runs before anything is written, with --allow-critical: the rescan's exception covers CRITICAL only. A
  # secret (or a broken ignore file) blocks as at build time: the attestation is public and Rekor keeps its whole
  # envelope for good, so the report's secret findings would be published with it. The old attestation then ages out
  # and Kyverno refuses new pods after 72 hours; the red run mails the owner now.
  for arch in amd64 arm64; do
    "$ci_dir/scan-gate.sh" --allow-critical "$svc linux/$arch (rescan)" "$dir/$arch/trivy.json" || blocked=1
    [ -n "$sarif" ] || continue
    trivy_mounts=(-v "$dir/$arch:/in:ro" -v "$sarif:/out")
    trivy_ convert --format sarif --severity HIGH,CRITICAL --output "/out/$svc-$arch.sarif.tmp" /in/trivy.json ||
      fail "convert the report of $svc linux/$arch to SARIF"
    jq --arg c "trivy-image-$svc-$arch/" '.runs[].automationDetails.id = $c' "$sarif/$svc-$arch.sarif.tmp" \
      >"$sarif/$svc-$arch.sarif"
    rm -f "$sarif/$svc-$arch.sarif.tmp"
  done
  [ "$blocked" -eq 0 ] || fail "$repo@$digest is blocked by the scan gate; not attested"
  "$ci_dir/vuln-predicate.sh" --allow-critical "$dir/predicate.json" "$dir/amd64" "$dir/arm64" ||
    fail "build the vuln predicate of $repo@$digest"
  format=$(release_format "$repo@$digest") || fail "read how $repo@$digest is signed (above); not attested"
  case $format in
  legacy)
    # The two flags go together: --new-bundle-format=false alone is refused while the signing config is on.
    cosign attest --yes --new-bundle-format=false --use-signing-config=false --replace --type vuln \
      --predicate "$dir/predicate.json" "$repo@$digest" || fail "attest $repo@$digest"
    ;;
  bundle) replace_vuln_bundle "$repo" "$digest" "$dir/predicate.json" ;;
  *) fail "$repo@$digest has neither Sigstore bundles nor a signature in cosign's older format; not attested" ;;
  esac
  echo "ok    $repo@$digest attested with today's scan ($format format)"
  # Read by the caller: a new vuln is on GHCR, so ECR gets it too, even when a CRITICAL fails this digest below.
  : >"$dir/attested"
  # A CRITICAL is now recorded (Kyverno refuses new pods because of it, not because of an old attestation) and fails
  # the run.
  critical=$(jq -s '[.[].Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' \
    "$dir/amd64/trivy.json" "$dir/arm64/trivy.json") || fail "count CRITICAL of $repo@$digest"
  [ "$critical" -eq 0 ] || fail "$repo@$digest: $critical CRITICAL vulnerabilities, recorded in its vuln attestation"
}

# digest_envs DIGEST: reads the lines of list on stdin and prints, once each, the environment of every line of DIGEST
# read under envs/<env>/ (fields split by hand: read with IFS=<tab> would merge the tabs around an empty digest).
digest_envs() {
  local line d
  while IFS= read -r line; do
    d=${line#*$'\t'}
    d=${d#*$'\t'}
    [ "${d%%$'\t'*}" != "$1" ] || ecr_env "${d#*$'\t'}"
  done | sort -u
}

# ecr_env WHERE: prints the environment of a line of list read under envs/<env>/ of svp-gitops; nothing for a line of
# the code repository, whose digests no ECR holds.
ecr_env() {
  if [[ $1 =~ ,\ envs/([a-z0-9-]+)/images/[^/]+\.yaml$ ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# ecr_registry ENV: prints SVP_ECR_REGISTRY_<ENV>, the ECR host of ENV the job set (empty when it set none).
ecr_registry() {
  local var
  var=SVP_ECR_REGISTRY_$(tr '[:lower:]-' '[:upper:]_' <<<"$1")
  echo "${!var:-}"
}

# ecr_refresh REPOSITORY DIGEST ENV: ecr-copy.sh refresh into ENV's ECR as ENV's rescan role (AWS profile svp-ENV);
# nothing when the job set no ECR host for ENV.
ecr_refresh() {
  local registry
  registry=$(ecr_registry "$3")
  if [ -z "$registry" ]; then
    echo "skip  ECR of $3 for $1@$2: no SVP_ECR_REGISTRY_ for it in this job"
    return 0
  fi
  AWS_PROFILE=svp-$3 "$ci_dir/ecr-copy.sh" refresh "$1" "$2" "$registry"
}

# own_run: fails unless this is a CI run of the repository of source (source_args first), as its signing workflow.
own_run() {
  [ "${GITHUB_ACTIONS:-}" = true ] || fail "rescan.sh run attests with the workflow's identity: CI only"
  use_build_source
  [ "$build_source_name" = "$source" ] ||
    fail "rescan.sh run --source $source in a run of $(run_repo_url), the repository of release source $build_source_name: a run attests only the releases of its own source (--source $build_source_name)"
  local builder
  sign_identity "$source"
  builder=$(run_builder_id)
  [ "$builder" = "$sign_subject" ] ||
    fail "this run is $builder, but the releases of source $source are attested only as $sign_subject"
}

run() {
  [ "${GITHUB_ACTIONS:-}" = true ] || fail "rescan.sh run attests with the workflow's identity: CI only"
  source_args "$@"
  set -- ${args[@]+"${args[@]}"}
  [ $# -ge 2 ] && [ $# -le 3 ] || fail "usage: rescan.sh run [--source NAME] OUT GITOPS_DIR [VALUES_REF]"
  own_run
  local out=$1 lines line svc repo digest where key sarif n=0 failed=0 seen=" " own e
  mkdir -p "$out/sarif" || fail "create $out"
  out=$(cd "$out" && pwd)
  lines=$(list "$2" "${3:-}") || failed=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Split by hand, as keep_own does: an empty digest stays empty.
    svc=${line%%$'\t'*} repo=${line#*$'\t'}
    digest=${repo#*$'\t'} repo=${repo%%$'\t'*}
    where=${digest#*$'\t'} digest=${digest%%$'\t'*}
    if [ -z "$digest" ]; then
      step_summary "- $svc in $where: no digest, not released yet: skipped"
      continue
    fi
    key="$svc@$digest"
    case $seen in *" $key "*) continue ;; esac
    seen="$seen$key "
    n=$((n + 1))
    if ! own=$(release_source_of "$svc" "$repo") || [ "$(jq -r .name <<<"$own")" != "$source" ] || ! is_digest "$digest"; then
      echo "FAIL  $svc in $where: $repo@$digest is not a release of $svc of source $source; not attested" >&2
      failed=1
      continue
    fi
    sarif=
    case $where in "main of svp-gitops,"*) sarif=$out/sarif ;; esac
    (rescan_one "$svc" "$repo" "$digest" "$out/$n-$svc" "$sarif") || failed=1
    [ -e "$out/$n-$svc/attested" ] || continue
    # Every environment whose envs/ names the digest at any ref read, each its own ECR.
    for e in $(digest_envs "$digest" <<<"$lines"); do
      ecr_refresh "$repo" "$digest" "$e" || failed=1
    done
  done <<<"$lines"
  [ "$n" -gt 0 ] || step_summary "No released digest to rescan."
  return "$failed"
}

# run_digest IMAGE DIGEST ENV (source_args first): a release left in ENV's ECR that no ref of svp-gitops names under
# envs/ENV/ yet (a copy that failed, a promote-prd that stopped): attested again on GHCR, refreshed in that ECR and,
# in stg's, its missing bundles copied; the leg or promote-prd that stopped then passes when run again.
run_digest() {
  [ "${GITHUB_ACTIONS:-}" = true ] || fail "rescan.sh run-digest attests with the workflow's identity: CI only"
  source_args "$@"
  set -- ${args[@]+"${args[@]}"}
  [ $# -eq 4 ] || fail "usage: rescan.sh run-digest [--source NAME] OUT IMAGE DIGEST ENV"
  local out=$1 img=$2 digest=$3 target=$4 repo registry failed=0
  repo=$(release_source "$source" | jq -r .imagePrefix)$img || exit 1
  release_source_of "$img" "$repo" >/dev/null || fail "$img is no service of release source $source"
  is_digest "$digest" || fail "digest '$digest' is not sha256:<64 hex>"
  case $target in stg | prd) ;; *) fail "env '$target' is neither stg nor prd" ;; esac
  registry=$(ecr_registry "$target")
  [ -n "$registry" ] || fail "no ECR host of $target in this job (SVP_ECR_REGISTRY_$(tr '[:lower:]' '[:upper:]' <<<"$target"))"
  own_run
  mkdir -p "$out" || fail "create $out"
  out=$(cd "$out" && pwd)
  (rescan_one "$img" "$repo" "$digest" "$out/1-$img" "") || failed=1
  [ -e "$out/1-$img/attested" ] || return 1
  ecr_refresh "$repo" "$digest" "$target" || return 1
  # Only stg's: a release enters prd's ECR through promote-prd alone.
  if [ "$target" = stg ]; then
    AWS_PROFILE=svp-stg "$ci_dir/ecr-copy.sh" copy "$repo" "$digest" "$registry" || return 1
  fi
  return "$failed"
}

# Sourced (by deploy/ci/rescan-test.sh, which replaces what rescan_one calls), the functions above are all that is defined.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case ${1:-} in
  scan-index)
    [ $# -eq 4 ] || fail "usage: rescan.sh scan-index REPOSITORY DIGEST OUT"
    is_digest "$3" || fail "$3 is not sha256:<64 hex>"
    scan_index "$2" "$3" "$4"
    ;;
  run)
    shift
    run "$@"
    ;;
  run-digest)
    shift
    run_digest "$@"
    ;;
  list)
    shift
    source_args "$@"
    set -- ${args[@]+"${args[@]}"}
    [ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: rescan.sh list [--source NAME] GITOPS_DIR [VALUES_REF]"
    list "$1" "${2:-}"
    ;;
  *) fail "usage: rescan.sh scan-index REPOSITORY DIGEST OUT | rescan.sh run [--source NAME] OUT GITOPS_DIR [VALUES_REF] | rescan.sh run-digest [--source NAME] OUT IMAGE DIGEST ENV | rescan.sh list [--source NAME] GITOPS_DIR [VALUES_REF]" ;;
  esac
fi
