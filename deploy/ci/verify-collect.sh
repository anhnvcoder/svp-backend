#!/usr/bin/env bash
# verify-collect.sh: builds the public artifact from an allowlist of machine-readable test results.
# Scans candidates against known secrets and token patterns; drops suspicious or hidden files.
# Step logs stay on runner to prevent leaking secrets into public artifacts.
# Design notes: docs/reference/ci.md.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=${SVP_VERIFY_REPO:-$(cd "$here/../.." && pwd)}
# The job's own temp directory on GitHub Actions, emptied when the job ends; /tmp on a machine.
tmp_root=${RUNNER_TEMP:-/tmp}
# warning MESSAGE: prints an Actions ::warning:: annotation, or warning: on a local machine.
warning() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::warning::%s\n' "$1"; else printf 'warning: %s\n' "$1"; fi
}
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
art=${SVP_VERIFY_ARTIFACT:-$tmp_root/verify-artifact}
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}
export SVP_VERIFY_REPO=$repo SVP_VERIFY_SECRETS=$secrets
max_bytes=$((5 * 1024 * 1024))
jwt_re='eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.'
# Drops JSON log records and quoted access logs that might leak secrets even if starting like verdicts.
service_log_re='"(msg|level)"[[:space:]]*:|access log of trace'
# Only fixed verdict lines without probe output reach the artifact.
verdict_re='^(ok|PASS|FAIL|SKIP|WARN)[[:space:]]'
drill_end_re='^drill-obs-threats: all checks passed$'

scenario=$(cat "$out/scenario" 2>/dev/null) || scenario=unknown
rm -rf "$art" && mkdir -p "$art" || {
  echo "verify-collect: cannot create $art" >&2
  exit 1
}
umask 077
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

lists_ok=1
"$here/verify-mask.sh" env || lists_ok=0
if [ "$scenario" != compose-obs ]; then
  if ! "$here/verify-mask.sh" cluster && [ -f "$secrets/cluster.values" ]; then
    echo "verify-collect: the cluster's Secrets were not read now; the list read while it ran is used"
  fi
  [ -f "$secrets/cluster.values" ] || lists_ok=0
fi
[ -f "$secrets/env.values" ] || lists_ok=0
cat "$secrets/env.values" "$secrets/cluster.values" 2>/dev/null >"$work/values"
if [ "$lists_ok" = 1 ]; then
  echo "verify-collect: secret lists read; files from the stack or cluster are scanned and copied"
else
  warning "verify-collect: a secret list could not be read; only the files written on the runner itself are copied"
fi

: >"$work/files"
kept=0
dropped=0

# drop SRC RULE: records SRC as dropped; a rule other than not-allowed also gets a warning in the log.
drop() {
  printf 'dropped\t%s\t%s\n' "$1" "$2" >>"$work/files"
  dropped=$((dropped + 1))
  [ "$2" = not-allowed ] || warning "$1: $2"
}

# rule FILE [KIND]: prints the first scan rule FILE breaks, or empty if clean.
# For KIND=verdicts, permits prose naming "svp_sid " while rejecting values without trailing space.
rule() {
  local sid_re=svp_sid
  [ "${2:-}" = verdicts ] && sid_re='svp_sid([^ ]|$)'
  if [ -s "$work/values" ] && grep -qaF -f "$work/values" -- "$1"; then
    echo secret-value
  elif grep -qaE -- "$jwt_re" "$1"; then
    echo jwt
  elif grep -qaE -- "$sid_re" "$1"; then
    echo session-cookie
  elif grep -qaF -- 'Bearer ' "$1"; then
    echo bearer
  elif grep -qaF -- Set-Cookie "$1"; then
    echo set-cookie
  elif grep -qaE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$1"; then
    echo private-key
  fi
}

# consider FILE SRC DEST KIND: copies FILE to $art/DEST if it passes scanner and size checks.
# KIND is runner, stack, or verdicts.
consider() {
  local file=$1 src=$2 dest=$3 kind=$4 r size
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    drop "$src" not-regular
    return
  fi
  size=$(wc -c <"$file" | tr -d ' ')
  if [ "$size" -gt "$max_bytes" ]; then
    drop "$src" too-large
    return
  fi
  if [ "$kind" != runner ] && [ "$lists_ok" != 1 ]; then
    drop "$src" no-secret-list
    return
  fi
  r=$(rule "$file" "$kind")
  if [ -n "$r" ]; then
    drop "$src" "$r"
    return
  fi
  mkdir -p "$art/$(dirname "$dest")" && cp "$file" "$art/$dest" || {
    drop "$src" copy-failed
    return
  }
  printf 'kept\t%s\t%s\n' "$src" "$dest" >>"$work/files"
  kept=$((kept + 1))
}

# hidden SUB: true when a component of SUB starts with a dot.
hidden() {
  case /$1 in */.*) return 0 ;; *) return 1 ;; esac
}

if [ -d "$out" ]; then
  while IFS= read -r -d '' file; do
    sub=${file#"$out"/}
    src="\$SVP_VERIFY_OUT/$sub"
    if hidden "$sub"; then drop "$src" hidden; continue; fi
    case $sub in
      results.tsv | scenario | df-before.txt)
        consider "$file" "$src" "$sub" runner ;;
      logs/drill-obs-threats.log)
        grep -aE -e "$verdict_re" -e "$drill_end_re" "$file" | grep -avE -- "$service_log_re" >"$work/verdicts" || :
        consider "$work/verdicts" "$src (verdict lines)" logs/drill-obs-threats.verdicts.log verdicts ;;
      logs/gitops-admission-metrics.log)
        consider "$file" "$src" "$sub" stack ;;
      *) drop "$src" not-allowed ;;
    esac
  done < <(find "$out" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
fi

base=.k8s/drills
if [ -d "$repo/$base" ]; then
  while IFS= read -r -d '' file; do
    sub=${file#"$repo/$base"/}
    src=$base/$sub
    if hidden "$sub"; then drop "$src" hidden; continue; fi
    case $sub in
      */*) drop "$src" not-allowed ;;
      *.xml | *.json | *-skips.tsv | traffic-*.log) consider "$file" "$src" "k8s-drills/$sub" stack ;;
      *) drop "$src" not-allowed ;;
    esac
  done < <(find "$repo/$base" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
fi

# Scans files.txt before publishing to ensure candidate paths do not match secret rules.
cp "$work/files" "$work/files.txt"
if [ -n "$(rule "$work/files.txt")" ]; then
  warning "files.txt: a file name matched a scan rule; files.txt left out"
else
  cp "$work/files.txt" "$art/files.txt"
fi

echo "verify-collect ($scenario): $kept file(s) kept, $dropped dropped (files.txt in the artifact lists both)"

# Prints failed step verdict tails from copies only, never from raw runner logs.
if [ -f "$art/results.tsv" ]; then
  awk -F '\t' 'NR > 1 && $2 != "success" && $2 != "skipped" { print $1 }' "$art/results.tsv" |
    while IFS= read -r step; do
      log=$art/logs/$step.verdicts.log
      [ -f "$log" ] || continue
      echo "---- last 40 lines of ${log#"$art"/}"
      tail -n 40 "$log"
    done
fi
exit 0
