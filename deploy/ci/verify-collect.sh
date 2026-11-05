#!/usr/bin/env bash
# Builds the public artifact of a verification run: copies
# the files of an allow list into $SVP_VERIFY_ARTIFACT (default verify-artifact in $RUNNER_TEMP, /tmp on a machine),
# each only after a scan, and prints to the job's log a summary taken
# from the copies alone. Anyone can read the artifact and the log of a public repository, so it fails closed: a file
# it is unsure of is left out, with a warning (an annotation on GitHub) naming the file and
# the rule, never the text that matched.
#
# The allow list: results that machines read, never the output of a step (it may quote a service's or a third-party
# container's log, which no artifact may hold; it stays on the runner). From the run's results ($SVP_VERIFY_OUT,
# default verify in $RUNNER_TEMP; never uploaded as a whole):
#   written on the runner itself  results.tsv (the table of the steps, deploy/ci/verify-steps/steps.sh), scenario,
#                                 df-before.txt (deploy/ci/verify-host.sh)
#   read from the stack/cluster   logs/drill-obs-threats.log, of which only the verdict lines (ok, PASS, FAIL, SKIP,
#                                 WARN, and the closing "drill-obs-threats: all checks passed"; none of a JSON log record
#                                 or quoting an access log) reach the artifact, as logs/drill-obs-threats.verdicts.log;
#                                 logs/gitops-admission-metrics.log (the summary lines of
#                                 deploy/ci/verify-steps/admission-metrics.sh)
# Every other file there (the output of every other step) is listed in files.txt as not-allowed.
# From the checkout (all read from the stack/cluster): .k8s/drills/*.xml (the JUnit report of each Chainsaw drill),
# *-skips.tsv (its list of SKIPs and their reasons: the JUnit report counts a SKIP as passed), *.json and traffic-*.log (each line a time, a user, a route, a status and a duration). Everything else under that
# place is listed in files.txt as not-allowed: the log of each Chainsaw drill and every service log never get in; a
# hidden file is dropped with its own rule and a warning. Nothing else of the checkout (.env, kubeconfig, .k8s/ca.*,
# .k8s/helm/) is even looked at.
#
# Each candidate is refused when it is hidden, not a regular file (a link could point at .env), over 5 MiB, or when it
# matches (grep -a: binary files are read as text):
#   secret-value   a value of $SVP_VERIFY_SECRETS/env.values or cluster.values (deploy/ci/verify-mask.sh: every secret
#                  of .env and every value of the cluster's Secrets, raw and base64, 8 characters or more); both lists
#                  are read again here, the cluster's while it still runs
#   jwt            eyJ<8+>.eyJ<8+>. (header and payload of a JWT or JWS; eyJ alone also occurs in the base64 of the
#                  screenshots Lighthouse embeds, which have no dots)
#   session-cookie svp_sid (in the verdict lines of drill-obs-threats: svp_sid not followed by a space, see rule)
#   bearer "Bearer "; set-cookie "Set-Cookie"; private-key "-----BEGIN ... PRIVATE KEY-----"
# A file read from the stack or the cluster is copied only when every list it needs was read: .env's always, the
# cluster's too unless the scenario is compose-obs. A list that could not be read (an .env that breaks its rule, a
# cluster that died before its Secrets were read once) leaves only the files written on the runner itself
# (no-secret-list). The cluster's list keeps every value read while the cluster ran, so a cluster gone by now still
# has one.
#
# The artifact holds files.txt (every candidate: kept, or dropped with its rule), the results under their own names,
# and the checkout's files under k8s-drills/ (upload-artifact leaves hidden folders such as .k8s out). The job's log
# gets a count, and for each step that did not succeed the end of its verdict lines when they reached the artifact.
# Exits 0 whatever it dropped; 1 only when it cannot build the artifact folder.
#
# SVP_VERIFY_REPO (default: this checkout) points it at another tree, for deploy/ci/verify-collect-test.sh.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=${SVP_VERIFY_REPO:-$(cd "$here/../.." && pwd)}
# The job's own temp directory on GitHub Actions, emptied when the job ends; /tmp on a machine.
tmp_root=${RUNNER_TEMP:-/tmp}
# warning MESSAGE: a warning the run's page shows beside the log line (an annotation on GitHub Actions); a plain line
# on a machine.
warning() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::warning::%s\n' "$1"; else printf 'warning: %s\n' "$1"; fi
}
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
art=${SVP_VERIFY_ARTIFACT:-$tmp_root/verify-artifact}
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}
export SVP_VERIFY_REPO=$repo SVP_VERIFY_SECRETS=$secrets
max_bytes=$((5 * 1024 * 1024))
jwt_re='eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.'
# A line of a JSON log record (a "msg" or "level" key, the form of the services' slog and of most third-party
# servers), or one quoting an access log: never kept, even when it starts like a verdict.
service_log_re='"(msg|level)"[[:space:]]*:|access log of trace'
# The lines of drill-obs-threats that reach the artifact, each a fixed form with no probe output in it: a verdict, and
# the closing "drill-obs-threats: all checks passed".
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

# --- The value lists. verify-mask.sh also masks any value new since its last call.
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

# rule FILE [KIND]: prints the first scan rule FILE breaks, nothing when it is clean. KIND verdicts (the verdict lines
# of drill-obs-threats, the drill's own sentences) narrows session-cookie: the web client's items name the session
# cookie in prose, its name followed by a space ("session cookie __Host-Http-svp_sid in the drill's cookie jar"), and
# no form a cookie's value is written in puts the value after the name and a space (a header has name=value, a cookie
# jar name<TAB>value, JSON "name": ..., "value": ...). So there svp_sid followed by any other character, or ending a
# line, is still refused; in every other file svp_sid at all.
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

# consider FILE SRC DEST KIND: copies FILE (shown as SRC) to $art/DEST when it passes; KIND is runner (written
# on the runner itself), stack (read from the stack or the cluster) or verdicts (the verdict lines of drill-obs-threats,
# read from the stack, scanned by rule as such).
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

# --- The run's results.
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

# --- The checkout's results: the drills' files in .k8s/drills, under k8s-drills/ in the artifact.
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

# files.txt holds only paths this script chose and rule names; scanned all the same before it is published.
cp "$work/files" "$work/files.txt"
if [ -n "$(rule "$work/files.txt")" ]; then
  warning "files.txt: a file name matched a scan rule; files.txt left out"
else
  cp "$work/files.txt" "$art/files.txt"
fi

echo "verify-collect ($scenario): $kept file(s) kept, $dropped dropped (files.txt in the artifact lists both)"

# --- In the job's log, from the copies only: the end of the verdict lines of each step that did not succeed, when
# they reached the artifact (the table of the steps is in the log already, from steps.sh table).
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
