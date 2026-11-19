#!/usr/bin/env bash
# ecr-copy.sh copy REPOSITORY DIGEST REGISTRY: copies the release REPOSITORY@DIGEST of GHCR (index, its manifests and
# every referrer) to the repository of the same name under the ECR host REGISTRY, verifies it there, prints where.
# ecr-copy.sh refresh REPOSITORY DIGEST REGISTRY: the rescan's step; puts GHCR's one vuln bundle in place of ECR's.

# Both sync and never take "the index is there" for done: a run cut off after the index copies what is missing next
# time. Only refresh deletes, and only vuln bundles: the release and promote roles have no delete. Docker config from
# DOCKER_CONFIG, AWS credentials from the caller (AWS_PROFILE); output passes a filter that hides the account ID.
# Design notes: docs/reference/ci.md.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage="usage: ecr-copy.sh copy|refresh REPOSITORY DIGEST REGISTRY"

# max_attestation_age: imageVerification.maxAttestationAge of chart svp-policy in seconds, the oldest scan admitted.
max_attestation_age() {
  local value
  value=$(sed -n 's/^  maxAttestationAge: *//p' "$script_root/deploy/helm/svp-policy/values.yaml")
  [[ $value =~ ^([0-9]+)([hms])$ ]] ||
    fail "maxAttestationAge of chart svp-policy is '$value', not one <number>h, <number>m or <number>s"
  case ${BASH_REMATCH[2]} in
  h) echo $((BASH_REMATCH[1] * 3600)) ;;
  m) echo $((BASH_REMATCH[1] * 60)) ;;
  s) echo "${BASH_REMATCH[1]}" ;;
  esac
}

# oras_copy SOURCE DESTINATION: copies one manifest by digest (an index with every manifest it lists). Never -r: a
# failure names its referrer. ECR is written through the referrers API: a fallback tag would hit its immutable tags.
oras_copy() {
  oras_run cp --no-tty --from-registry-config /auth/config.json --to-registry-config /auth/config.json \
    --from-distribution-spec v1.1-referrers-tag --to-distribution-spec v1.1-referrers-api "$1" "$2"
}

# ecr_has DIGEST: true when the ECR repository holds DIGEST, status 1 when ECR says it does not; fails otherwise.
ecr_has() {
  local err
  err=$(aws ecr describe-images --region "$region" --registry-id "$account" --repository-name "$name" \
    --image-ids "imageDigest=$1" 2>&1 >/dev/null) && return 0
  case $err in *ImageNotFoundException*) return 1 ;; esac
  printf '%s\n' "$err" | tail -n 1 >&2
  fail "ask ECR whether $dst holds $1"
}

# kind PREDICATE_TYPE: the name of a bundle in messages.
kind() {
  case $1 in
  "$sign_predicate_type") echo signature ;;
  "$vuln_predicate_type") echo vuln ;;
  "$sbom_predicate_type") echo SBOM ;;
  "$provenance_predicate_type") echo provenance ;;
  *) echo "bundle of $1" ;;
  esac
}

# read_graph: sets subjects (the index, then its linux/amd64 and linux/arm64 manifests, read from GHCR) and ghcr[i],
# GHCR's bundle referrers of subjects[i]: image-sign attests the signature, vuln and provenance on the index, an SBOM
# on each manifest.
read_graph() {
  local index arch child i
  index=$(registry_oras manifest fetch "$src@$digest") || fail "read the index $src@$digest"
  subjects=("$digest")
  for arch in amd64 arm64; do
    child=$(jq -r --arg a "$arch" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a)]
      | if length == 1 then .[0].digest else empty end' <<<"$index" 2>/dev/null) || child=
    is_digest "$child" || fail "$src@$digest is no index with a single linux/$arch manifest"
    subjects+=("$child")
  done
  for i in 0 1 2; do
    ghcr[i]=$(bundle_referrers "$src@${subjects[$i]}") || fail "list the referrers of $src@${subjects[$i]}"
  done
}

# sync_subject I: copies each bundle of subjects[I] that GHCR has and ECR lacks, but no vuln bundle when ECR has one
# (only refresh replaces it).
sync_subject() {
  local s=${subjects[$1]} have d t
  have=$(bundle_referrers "$dst@$s") || fail "list the referrers of $dst@$s"
  while read -r d t; do
    [ -n "$d" ] || continue
    case $'\n'"$have" in *$'\n'"$d "*) continue ;; esac
    if [ "$t" = "$vuln_predicate_type" ] && [ -n "$(bundles_of "$vuln_predicate_type" <<<"$have")" ]; then
      echo "keep  the vuln bundle of $s in ECR; GHCR's $d is not copied (the rescan replaces it)"
      continue
    fi
    echo "add   $(kind "$t") $d of $s"
    oras_copy "$src@$d" "$dst" || fail "copy the $(kind "$t") $d of $s to $dst"
  done <<<"${ghcr[$1]}"
}

# one TYPE SUBJECT: prints the one attestation of TYPE on SUBJECT in ECR that cosign verifies with the release's
# identity; fails on none or more than one (Kyverno would read either).
one() {
  local envelopes count
  envelopes=$(cosign_ verify-attestation --type "$1" --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" "$dst@$2" 2>/dev/null) ||
    fail "$dst@$2 has no $1 attestation of $sign_subject"
  count=$(printf '%s\n' "$envelopes" | grep -c . || true)
  [ "$count" -eq 1 ] || fail "$dst@$2 carries $count $1 attestations of $sign_subject, not exactly one"
  printf '%s\n' "$envelopes"
}

# verify: checks in ECR what Kyverno checks, with the identity of the release's source: the signature, one vuln
# attestation of both platforms scanned within maxAttestationAge, and the provenance and each SBOM GHCR carries.
verify() {
  local envelope problem commit i
  cosign_ verify --certificate-oidc-issuer "$sign_issuer" --certificate-identity "$sign_subject" "$dst@$digest" \
    >/dev/null || fail "$dst@$digest has no signature of $sign_subject"
  envelope=$(one vuln "$digest") || exit 1
  problem=$(jq -r '.payload | @base64d' <<<"$envelope" | check_vuln_statement "$digest" "$max_age") || {
    case $problem in
    "scan finished"*)
      fail "$dst@$digest: vuln attestation $problem: refresh it first, with gh workflow run images.yml --repo $code_repo --ref main -f rescan=true and -f values_ref=<the ref of svp-gitops naming this digest under envs/<env>/>, or, for a digest under no envs/, -f image=$svc -f digest=$digest -f env=<stg|prd>"
      ;;
    esac
    fail "$dst@$digest: vuln attestation $problem"
  }
  if [ -n "$(bundles_of "$provenance_predicate_type" <<<"${ghcr[0]}")" ]; then
    envelope=$(one slsaprovenance1 "$digest") || exit 1
    commit=$(jq -r '.payload | @base64d' <<<"$envelope" | check_provenance_statement "$digest") ||
      fail "$dst@$digest: provenance $commit"
  fi
  for i in 1 2; do
    [ -z "$(bundles_of "$sbom_predicate_type" <<<"${ghcr[$i]}")" ] || one spdxjson "${subjects[$i]}" >/dev/null
  done
  echo "ok    $dst@$digest verified: signature, one vuln within maxAttestationAge, provenance and SBOMs as on GHCR"
}

copy() {
  local i
  echo "copy    $src@$digest -> $dst"
  if ecr_has "$digest"; then
    echo "has   the index"
  else
    echo "add   the index $digest and its manifests"
    oras_copy "$src@$digest" "$dst" || fail "copy the index $digest to $dst"
  fi
  read_graph
  for i in 0 1 2; do sync_subject "$i"; done
  verify
  echo "$dst@$digest"
}

refresh() {
  local new have old d out i ids=()
  echo "refresh $src@$digest in $dst"
  if ! ecr_has "$digest"; then
    echo "skip  ECR has no $digest: a release enters ECR only by copy"
    return 0
  fi
  read_graph
  new=$(bundles_of "$vuln_predicate_type" <<<"${ghcr[0]}")
  [ "$(grep -c . <<<"$new")" -eq 1 ] ||
    fail "$src@$digest carries $(grep -c . <<<"$new") vuln bundles, not one: nothing refreshed"
  have=$(bundle_referrers "$dst@$digest") || fail "list the referrers of $dst@$digest"
  case $'\n'"$have" in
  *$'\n'"$new "*) ;;
  *)
    echo "add   vuln $new of $digest"
    oras_copy "$src@$new" "$dst" || fail "copy the vuln $new of $digest to $dst"
    ;;
  esac
  old=$(bundles_of "$vuln_predicate_type" <<<"$have" | grep -vx "$new" || true)
  for d in $old; do ids+=("imageDigest=$d"); done
  if [ ${#ids[@]} -gt 0 ]; then
    echo "del   vuln ${old//$'\n'/ } of $digest"
    out=$(aws ecr batch-delete-image --region "$region" --registry-id "$account" --repository-name "$name" \
      --image-ids "${ids[@]}") || fail "delete the older vuln bundles of $dst@$digest"
    [ "$(jq '.failures | length' <<<"$out" 2>/dev/null)" = 0 ] ||
      fail "ECR did not delete every older vuln bundle of $dst@$digest"
  fi
  have=$(bundle_referrers "$dst@$digest") || fail "list the referrers of $dst@$digest again"
  [ "$(bundles_of "$vuln_predicate_type" <<<"$have")" = "$new" ] ||
    fail "$dst@$digest: the vuln bundles left are $(bundles_of "$vuln_predicate_type" <<<"$have" | tr '\n' ' ')not only $new"
  for i in 0 1 2; do sync_subject "$i"; done
  verify
}

# setup REPOSITORY DIGEST: the release, its identity and where it goes; fails before any registry is asked.
setup() {
  local source
  src=$1 digest=$2 svc=${1##*/}
  is_digest "$digest" || fail "$digest is not sha256:<64 hex>"
  source=$(release_source_of "$svc" "$src") ||
    fail "$src is no release repository (<imagePrefix><service> of $release_sources_file): only those go to ECR"
  use_release_source "$source"
  name=${src#ghcr.io/anhnvcoder/}
  [ "$name" != "$src" ] || fail "$src is not under ghcr.io/anhnvcoder/, whose path ECR repositories keep"
  dst=$registry/$name
  code_repo=${provenance_repository#https://github.com/}
  max_age=$(max_attestation_age)
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [ $# -eq 4 ] || fail "$usage"
  case $1 in copy | refresh) ;; *) fail "$usage" ;; esac
  # The host is never printed here: it holds the account ID.
  [[ $4 =~ ^([0-9]{12})\.dkr\.ecr\.([a-z]{2}(-[a-z]+)+-[0-9]+)\.amazonaws\.com$ ]] ||
    fail "REGISTRY is no ECR host <account>.dkr.ecr.<region>.amazonaws.com: is the account ID secret of the job set?"
  account=${BASH_REMATCH[1]} region=${BASH_REMATCH[2]} registry=$4
  setup "$2" "$3"
  "$1" 2>&1 | awk -v a="$account" '{ gsub(a, "<account>"); print; fflush() }'
  exit "${PIPESTATUS[0]}"
fi
