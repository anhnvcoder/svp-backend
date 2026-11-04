#!/usr/bin/env bash
# Tests for the rules on the table of release sources (deploy/helm/svp-policy/files/sources.json), written once, in the
# template of chart svp-policy, which fails the render of a table the policy would get wrong; the scripts read the
# table (release_sources of deploy/k8s/lib.sh) without checking those rules again. Each broken table below must fail
# the render with the template's own message:
#   - an imagePrefix that starts with another source's, or equals it;
#   - a service in three sources (one of them a retired source too);
#   - a quote, a backslash or white space in a value (they go into CEL string literals);
#   - two sources with one name, or one promoter (a retired source given another's promoter too);
#   - a promoter that is empty, a number or null (a retired source leaves the key out);
#   - a file that is not JSON, a list sources that is empty, an entry that is not an object, a field left out;
#   - an imagePrefix that does not end in /, a provenanceRef that is not a refs/... ref, an issuer that is not an
#     https:// URL, a name that is not a lowercase letter then letters and digits;
#   - an empty list services, an image name with a /.
# The table of the working tree renders, every source of it has a promoter (the retired sources, without one, were
# dropped from it), and its render selects exactly two globs per published name (matchImageReferences) and has one
# attestor per source, named after it. A source without promoter, retired, still renders, as the tables of older
# commits an environment may pin have such sources. Each case renders a copy of the chart with its own table, under
# Helm homes in a temporary directory, so no cache or repository of the machine is read or written.
# Then the lookups of deploy/k8s/lib.sh that pick a source by the prefix of an image, the one rule the scripts keep:
# source_of_repository and release_source_of fail when more than one source matches, and release_sources fails on a
# file that is not JSON. Last, web_clone of deploy/k8s/lib.sh, which reads the table: without WEB_REF it checks out the
# commit of the web release stg runs when it is a release of source web, and refuses one under another prefix before
# anything is cloned.
# Needs bash, git, jq and helm: no network, no cluster.
#
# Usage, from anywhere: deploy/ci/sources-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
table=$src/deploy/helm/svp-policy/files/sources.json

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

# render FILE: helm template of a copy of the chart whose files/sources.json is FILE; output and errors in $work/out.
render() {
  rm -rf "$work/chart"
  cp -R "$src/deploy/helm/svp-policy" "$work/chart"
  cp "$1" "$work/chart/files/sources.json"
  HELM_CACHE_HOME=$work/helm/cache HELM_CONFIG_HOME=$work/helm/config HELM_DATA_HOME=$work/helm/data \
    helm template svp-policy "$work/chart" >"$work/out" 2>&1
}

# case_table JQ FILE: writes to FILE the table of the working tree changed by the jq filter JQ (raw text, not JSON,
# when JQ starts with "raw:").
case_table() {
  if [[ $1 == raw:* ]]; then
    printf '%s\n' "${1#raw:}" >"$2"
  else
    jq "$1" "$table" >"$2"
  fi
}

# refused NAME JQ MESSAGE: the table of the working tree changed by JQ (case_table) fails the render with MESSAGE.
refused() {
  local name=$1 file=$work/case.json
  case_table "$2" "$file"
  if render "$file"; then
    fail "$name: helm template renders the table"
  elif grep -qF -- "$3" "$work/out"; then
    ok "$name: helm template refuses it ($3)"
  else
    fail "$name: helm template fails without \"$3\": $(tail -n 1 "$work/out")"
  fi
}

# --- The table of the working tree renders the policy.
if render "$table" && grep -q 'kind: ImageValidatingPolicy' "$work/out"; then
  ok "the table of the working tree renders the policy"
else
  fail "the table of the working tree: helm template fails: $(tail -n 3 "$work/out")"
fi
# matchImageReferences: exactly <imagePrefix><name>@* and <imagePrefix><name>:* for every name of every source, no glob
# of a whole prefix (an image under a prefix with a name nobody publishes would make Kyverno ask the registry first).
want=$(jq -r '.sources[] | .imagePrefix as $p | (.services + .drillImages)[] | ($p + . + "@*"), ($p + . + ":*")' \
  "$table" | sort)
got=$(sed -n '/^  matchImageReferences:$/,/^  [^ ]/p' "$work/out" | sed -n 's/^    - glob: "\(.*\)"$/\1/p' | sort)
if [ -n "$got" ] && [ "$got" = "$want" ] && ! grep -q '/\*$' <<<"$got"; then
  ok "matchImageReferences is one @* and one :* glob per published name ($(grep -c . <<<"$got") globs), none of a whole prefix"
else
  fail "matchImageReferences: want $(tr '\n' ' ' <<<"$want")got $(tr '\n' ' ' <<<"$got")"
fi

# attestors: one per source, named after it, with that source's identity.
want=$(jq -r '.sources[] | "\(.name) \(.issuer) \(.subject)"' "$table")
got=$(sed -n '/^  attestors:$/,/^  [^ ]/p' "$work/out" | awk '
  /^    - name: / { name = $3 } /- issuer: / { issuer = $3 } /^ *subject: / { gsub(/"/, "", issuer); gsub(/"/, "", $2)
    print name, issuer, $2 }')
if [ -n "$got" ] && [ "$got" = "$want" ]; then
  ok "attestors: one per source, named after it, with its identity ($(grep -c . <<<"$got") attestors)"
else
  fail "attestors: want $(tr '\n' ';' <<<"$want") got $(tr '\n' ';' <<<"$got")"
fi
retired=$(jq -r '[.sources[] | select(has("promoter") | not) | .name] | join(", ")' "$table")
if [ -z "$retired" ]; then
  ok "every source of the table of the working tree has a promoter"
else
  fail "the table of the working tree has sources without promoter (retired: nothing would build or promote for them): $retired"
fi

# accepted NAME JQ: the table of the working tree changed by the jq filter JQ renders the policy.
accepted() {
  local file=$work/case.json
  case_table "$2" "$file"
  if render "$file" && grep -q 'kind: ImageValidatingPolicy' "$work/out"; then
    ok "$1: helm template renders the policy"
  else
    fail "$1: helm template fails: $(tail -n 1 "$work/out")"
  fi
}
accepted "a source without promoter (retired)" 'del(.sources[1].promoter)'
# A retired source, as in the table of an older commit: web's repository under another name, no promoter.
retired_web='.sources += [.sources[1] | .name = "oldweb" | .imagePrefix = "ghcr.io/anhnvcoder/oldweb/" | del(.promoter)]'
accepted "a retired source next to the source that took its services over" "$retired_web"

# --- Broken tables, each from the working tree's (source 0 backend, 1 web).
web_under_backend='.sources[1].imagePrefix = .sources[0].imagePrefix + "web/"'
refused "imagePrefix under another source's" "$web_under_backend" \
  "starts with ghcr.io/anhnvcoder/svp-backend/ of source backend"
refused "imagePrefix equal to another source's" '.sources[1].imagePrefix = .sources[0].imagePrefix' \
  "starts with ghcr.io/anhnvcoder/svp-backend/ of source"
third='.sources += [.sources[1] | .name = "third" | .imagePrefix = "ghcr.io/anhnvcoder/third/" | .promoter = "third-promoter"]'
fourth='.sources += [.sources[1] | .name = "fourth" | .imagePrefix = "ghcr.io/anhnvcoder/fourth/" | .promoter = "fourth-promoter"]'
refused "a service in three sources" "$third | $fourth" \
  "service web is in more than two sources"
refused "web in three sources, one of them retired" "$retired_web | $third" \
  "service web is in more than two sources"
refused "a quote in a value" '.sources[1].subject += "\""' \
  "subject of source web goes into CEL string literals"
refused "a single quote in a value" '.sources[1].issuer += "'"'"'"' \
  "issuer of source web goes into CEL string literals"
refused "a backslash in a value" '.sources[0].provenanceRef += "\\x"' \
  "provenanceRef of source backend goes into CEL string literals"
refused "white space in a value" '.sources[1].repository = "https://github.com/anhnvcoder/svp web"' \
  "repository of source web goes into CEL string literals"
refused "two sources with one name" '.sources[1].name = "backend"' \
  "two sources are named backend"
refused "two sources with one promoter" '.sources[1].promoter = .sources[0].promoter' \
  "two sources are promoted by svp-gitops-promoter"
refused "a retired source given the promoter of another" "$retired_web | .sources[2].promoter = .sources[1].promoter" \
  "two sources are promoted by svp-web-promoter"
refused "an empty promoter" '.sources[1].promoter = ""' \
  "source web has no promoter string"
refused "a promoter that is a number" '.sources[1].promoter = 5' \
  "source web has no promoter string"
refused "a promoter that is null" '.sources[1].promoter = null' \
  "source web has no promoter string"
refused "white space in a promoter" '.sources[1].promoter = "svp web"' \
  "promoter of source web goes into CEL string literals"
refused "a file that is not JSON" 'raw:{"sources": [' \
  "files/sources.json must be a JSON object whose key sources lists at least one release source"
refused "an empty list sources" '.sources = []' \
  "files/sources.json must be a JSON object whose key sources lists at least one release source"
refused "an entry of sources that is not an object" '.sources += ["web"]' \
  "files/sources.json: every entry of sources is an object"
refused "a field left out" 'del(.sources[1].subject)' \
  "source web has no subject string"
refused "an imagePrefix without the trailing /" '.sources[1].imagePrefix |= rtrimstr("/")' \
  "imagePrefix of source web must end in /"
refused "a provenanceRef that is not a refs/... ref" '.sources[1].provenanceRef = "heads/main"' \
  "provenanceRef of source web must be a refs/... ref"
refused "an issuer that is not an https:// URL" '.sources[1].issuer = "http://token.actions.githubusercontent.com"' \
  "issuer of source web must be an https:// URL"
refused "a name with a capital letter" '.sources[1].name = "Web"' \
  'source name "Web" must be a lowercase letter then letters and digits'
refused "an empty list services" '.sources[1].services = []' \
  "source web needs a non-empty list services and a list drillImages"
refused "an image name with a /" '.sources[1].drillImages = ["drill/x"]' \
  "source web lists drill/x, not an image name"

# --- The lookups of deploy/k8s/lib.sh that pick a source by the prefix of an image, in a copy of lib.sh beside a table
# of each case's own: exactly one source, or a failure that names every source that matched.
lk=$work/lookup
mkdir -p "$lk/deploy/k8s" "$lk/deploy/helm/svp-policy/files"
cp "$src/deploy/k8s/lib.sh" "$lk/deploy/k8s/"
# lookup NAME JQ WANT_RC WANT FUNCTION ARGS...: FUNCTION of lib.sh with ARGS on the table of the working tree changed
# by JQ (case_table) exits WANT_RC and prints WANT (stdout and stderr).
lookup() {
  local name=$1 filter=$2 want_rc=$3 want=$4 rc=0
  shift 4
  case_table "$filter" "$lk/deploy/helm/svp-policy/files/sources.json"
  # shellcheck disable=SC2016 # expanded by the inner shell
  bash -c '. "$1/deploy/k8s/lib.sh" && shift && "$@"' _ "$lk" "$@" >"$work/out" 2>&1 || rc=$?
  if [ "$rc" = "$want_rc" ] && grep -qF -- "$want" "$work/out"; then
    ok "$name (exit $rc)"
  else
    fail "$name (exit $rc, want $want_rc and \"$want\"): $(tail -n 1 "$work/out")"
  fi
}
lookup "release_sources prints the table of the working tree" . 0 "$(jq -c . "$table")" release_sources
lookup "release_sources: a file that is not JSON" 'raw:{"sources": [' 1 \
  "release sources of the working tree: deploy/helm/svp-policy/files/sources.json is not readable JSON" release_sources
lookup "source_of_repository: web's image is of source web" . 0 web \
  source_of_repository ghcr.io/anhnvcoder/svp-frontend/web
# A table in which one prefix starts another is refused as it is read, before any lookup can pick from it.
lookup "source_of_repository: a table in which one prefix starts another" "$web_under_backend" 1 \
  "imagePrefix ghcr.io/anhnvcoder/svp-backend/web/ starts with imagePrefix ghcr.io/anhnvcoder/svp-backend/" \
  source_of_repository ghcr.io/anhnvcoder/svp-backend/web/web
lookup "release_source_of: a table in which one prefix starts another" "$web_under_backend" 1 \
  "imagePrefix ghcr.io/anhnvcoder/svp-backend/web/ starts with imagePrefix ghcr.io/anhnvcoder/svp-backend/" \
  release_source_of web ghcr.io/anhnvcoder/svp-backend/web/web
lookup "release_sources: an imagePrefix that does not end in /" '.sources[1].imagePrefix = "ghcr.io/anhnvcoder/svp-frontend"' 1 \
  "is not a registry path ending in /" release_sources
lookup "release_source_of: web's image is of source web" . 0 '"name":"web"' \
  release_source_of web ghcr.io/anhnvcoder/svp-frontend/web
lookup "release_source_of: two sources with one prefix" \
  '.sources[1].imagePrefix = .sources[0].imagePrefix | .sources[0].services += ["web"]' 1 \
  "imagePrefix ghcr.io/anhnvcoder/svp-backend/ starts with imagePrefix ghcr.io/anhnvcoder/svp-backend/" \
  release_source_of web ghcr.io/anhnvcoder/svp-backend/web

# --- web_clone of deploy/k8s/lib.sh without WEB_REF: the commit of the web release stg runs, when that release is
# <imagePrefix>web of a source of the table: web. A release under another prefix is refused before anything is cloned.
# In a copy of lib.sh and the policy's chart files; the clone of svp-frontend comes from a repository on disk
# (url.insteadOf of a git config of its own), the clone of svp-gitops is a repository on disk too.
wc=$work/webclone
mkdir -p "$wc/deploy/k8s" "$wc/deploy/helm/svp-policy"
cp "$src/deploy/k8s/lib.sh" "$wc/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$wc/deploy/helm/svp-policy/"
wg=$work/webclone-gitops
fe=$work/frontend
mkdir -p "$wg/envs/stg/images"
git_() {
  env -u GIT_DIR -u GIT_WORK_TREE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
git_ init -q -b main "$wg" && git_ -C "$wg" remote add origin https://github.com/anhnvcoder/svp-gitops.git
git_ init -q -b main "$fe" && git_ -C "$fe" commit -q --allow-empty -m web
fe_head=$(git_ -C "$fe" rev-parse HEAD)
printf '[url "%s"]\n\tinsteadOf = https://github.com/anhnvcoder/svp-frontend.git\n' "$fe/.git" >"$work/webclone.gitconfig"
digest=sha256:$(printf 'a%.0s' $(seq 64))
# web_clone_case NAME WANT_RC REPOSITORY: web_clone with envs/stg/images/web.yaml naming REPOSITORY at the commit of
# $fe, its output in wc.out; the clone is removed first.
web_clone_case() {
  local rc=0
  rm -rf "$wc/.web"
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' "$3" "${fe_head:0:12}" "$digest" \
    >"$wg/envs/stg/images/web.yaml"
  # shellcheck disable=SC2016 # expanded by the inner shell
  env -u GIT_DIR -u GIT_WORK_TREE -u WEB_REF GIT_CONFIG_GLOBAL="$work/webclone.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    SVP_GITOPS_DIR="$wg" bash -c '. "$1/deploy/k8s/lib.sh" && web_clone' _ "$wc" >"$work/wc.out" 2>&1 || rc=$?
  if [ "$rc" = "$2" ]; then ok "web_clone: $1 (exit $2)"; else fail "web_clone: $1 (exit $rc, want $2): $(cat "$work/wc.out")"; fi
}
# wc_has NAME TEXT: ok when the output of the last case holds TEXT.
wc_has() { if grep -qF -- "$2" "$work/wc.out"; then ok "web_clone: $1"; else fail "web_clone: $1: $(cat "$work/wc.out")"; fi; }
web_clone_case "stg runs a release of source web" 0 ghcr.io/anhnvcoder/svp-frontend/web
wc_has "a release of web: its commit checked out" "svp-frontend at ${fe_head:0:12} (${fe_head:0:12}) in .web/svp-frontend"
web_clone_case "stg runs web under a prefix no source publishes it under" 1 ghcr.io/anhnvcoder/svp-backend/web
wc_has "under another prefix: names the admitted repositories" \
  "staging runs web from ghcr.io/anhnvcoder/svp-backend/web (envs/stg/images/web.yaml), not a release of a source that publishes web (ghcr.io/anhnvcoder/svp-frontend/web): set WEB_REF"
[ ! -e "$wc/.web" ] && ok "web_clone: under another prefix: nothing cloned" ||
  fail "web_clone: under another prefix: nothing cloned"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
