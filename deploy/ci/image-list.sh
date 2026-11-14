#!/usr/bin/env bash
# image-list.sh GITOPS_DIR ENV: the third-party images ENV runs on eks, one line each on stdout:
# <upstream ref>:<tag>@sha256:<digest>, sorted, once. Release images (ghcr.io/anhnvcoder/) are left out; a Docker Hub
# name is written docker.io/<namespace>/<name>. An image pinned by digest alone has no tag to warm a cache with: error.
# Design notes: docs/reference/ci.md.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 2 ] || fail "usage: image-list.sh GITOPS_DIR ENV"
tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# The render is gitops-check.sh's, so the list holds what the check pins by digest; its progress goes to stderr.
"$ci_dir/gitops-check.sh" --images "$1" "$2" "$tmp/refs" >&2 || fail "render $2 on eks (above)"

untagged=
while IFS= read -r ref; do
  case $ref in ghcr.io/anhnvcoder/*) continue ;; esac
  name=${ref%@*} digest=${ref#"$name"}
  [[ $digest =~ ^@sha256:[0-9a-f]{64}$ ]] || fail "image $ref has no sha256 digest"
  # A tag is a ":" after the last "/"; a ":" before it is a registry port.
  tag=
  [[ ${name##*/} != *:* ]] || tag=:${name##*:}
  if [ -z "$tag" ]; then
    untagged+=" $name"
    continue
  fi
  repo=${name%"$tag"}
  # No registry host (a first path part with no "." or ":" and not localhost) is Docker Hub; an official image has the
  # namespace library.
  first=${repo%%/*}
  if [[ $first != *.* && $first != *:* && $first != localhost ]]; then repo=docker.io/$repo; fi
  case $repo in index.docker.io/* | registry-1.docker.io/*) repo=docker.io/${repo#*/} ;; esac
  case $repo in docker.io/*/*) ;; docker.io/*) repo=docker.io/library/${repo#docker.io/} ;; esac
  echo "$repo$tag$digest"
done <"$tmp/refs" >"$tmp/list"
[ -z "$untagged" ] || fail "images pinned by digest without a tag, which a cache warm-up needs:$untagged"
sort -u "$tmp/list"
