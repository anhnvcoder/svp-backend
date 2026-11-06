#!/usr/bin/env bash
# The drills on the local cluster svp (make drill-k8s-threats, drill-k8s-supplychain, drill-k8s-gitops,
# drill-k8s-reloader): runs the Chainsaw tests of deploy/k8s/drills/<drill>/ (label drill=<drill>, configuration
# deploy/k8s/drills/.chainsaw.yaml), one at a time, in one call of chainsaw per drill, so the tests of two drills never
# run together. What each test checks is written in the test.
#
#   run.sh threats      the threat model rows (deploy/k8s/drills/threats/<ID>/). Needs .k8s/ca.crt, given to curl as
#                       CURL_CA_BUNDLE, and a video READY and the drill users of make k8s-smoke run before on the same
#                       cluster. On a cluster without External Secrets Operator (no CRD externalsecrets.external-secrets.io:
#                       the dev path, whose Secrets come from .env) the tests labelled requires=external-secrets
#                       (SEC-5/6/7, SEC-6-reader) are left out, each with a skip line.
#   run.sh supplychain  the image policy of namespace svp (deploy/k8s/drills/supplychain/case-<letter>/), with the
#                       Chainsaw values unsigned, vulnerable, noProvenance and enforceTmp from SUPPLYCHAIN_UNSIGNED,
#                       SUPPLYCHAIN_VULNERABLE, SUPPLYCHAIN_NO_PROVENANCE and SUPPLYCHAIN_ENFORCE_TMP. An image not given
#                       is looked up here, once for every case: unsigned the newest drill-unsigned, noProvenance the newest
#                       drill-no-provenance on GHCR (deploy/ci/ghcr-digest.sh newest, anonymous). A lookup that fails
#                       leaves the value empty and prints why: case b then SKIPs (h and i send the dev image) and case l
#                       FAILs, unless the running policy checks no provenance (SKIP "policy off"). vulnerable is never
#                       looked up (case c SKIPs without it), noProvenance=none is passed as is (case l SKIPs).
#   run.sh gitops       the checks of the GitOps cluster (deploy/k8s/drills/gitops/).
#   run.sh reloader     a change of credentials on the dev path or the GitOps path (deploy/k8s/drills/reloader/), which
#                       writes new values into .env and keeps them: the values the drill changes are read from .env
#                       first (oldValues), the new ones from the file SVP_DRILL_NEW_VALUES names (mode 600, written by
#                       deploy/k8s/drills/reloader/new-values.sh in an earlier step that masked them; required on GitHub
#                       Actions, where a value made here would reach the log only through the drill's own output) or,
#                       without it, made here by new-values.sh (newValues). Both files, of mode 600 in a private work
#                       folder with the test's own (stateDir), go to Chainsaw by path only, as the values oldValues,
#                       newValues and stateDir. Needs .k8s/ca.crt, given to curl as CURL_CA_BUNDLE, and a video READY of
#                       make k8s-smoke run before on the same cluster.
#
# Before chainsaw: the context of every call is k3d-svp (SVP_KUBE_CONTEXT unset or k3d-svp), the kubeconfig has that
# context and its API answers; otherwise the drill stops there, without a call to any other cluster. chainsaw gets
# --kube-context k3d-svp, and its tests name that context on every kubectl of their own.
#
# The output goes to .k8s/drills/<drill>-<UTC>.log, the JUnit report to .k8s/drills/<drill>-<UTC>.xml (ignored by git).
# The JUnit report counts a SKIP step as passed, so after every chainsaw call the list of the SKIPs goes to
# .k8s/drills/<drill>-skips.tsv: one line "<test><TAB><reason>" for each SKIP line a test printed (a line of the
# form "SKIP  (<id>) <reason>" in the STDOUT block of a script step, read from the log of chainsaw before any filter;
# <test> is the Chainsaw test running then) and for each test left out above, then "total<TAB><n>"; the file is there
# when n is 0 too, and when chainsaw failed. A reason that holds a Secret value of threats is replaced by a line saying so.
# A drill with no test, or whose report holds another number of tests than its folder (less those left out), fails.
# threats reads the Secret values its tests use first (the 6 Kafka users of svp-data/kafka-users, the Grafana admin of
# svp-obs/grafana-admin, the 3 object store users of svp-data/pg-backup-s3 and svp-data/s3-users), into a file of mode
# 600 that is removed on exit and never named a value on a command line: fewer than 10 values fail the drill before
# chainsaw. reloader puts in that file the old and the new value of each variable it changes and GlitchTip's API token
# of svp-obs/glitchtip-api, which one of its checks uses: one missing or empty fails the drill before chainsaw. The
# terminal then gets every line of the output but those that hold one of the values, and once chainsaw has ended the log
# and the report are searched for them: a line holding one fails the drill, which prints how many, never the value.
#
# Exits non-zero when a test failed, a check above failed, or a Secret value was found.
#
# Usage, from the repo root through make: deploy/k8s/drills/run.sh threats|supplychain|gitops|reloader
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/../lib.sh"

drill=${1:-}
case $drill in
threats | supplychain | gitops | reloader) ;;
*) fail "usage: deploy/k8s/drills/run.sh threats|supplychain|gitops|reloader (got '$drill')" ;;
esac
[ $# = 1 ] || fail "usage: deploy/k8s/drills/run.sh threats|supplychain|gitops|reloader (one drill per call)"

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- the context, before anything reads the cluster.
[ "$kube_context" = k3d-svp ] ||
  fail "drill-k8s-$drill runs on the local cluster only: SVP_KUBE_CONTEXT is '$kube_context', it must be k3d-svp or unset"
kc config get-contexts -o name 2>/dev/null | grep -qx k3d-svp ||
  fail "drill-k8s-$drill: the kubeconfig has no context k3d-svp (cluster svp is not created on this machine); run make k8s-up"
kc get --raw /readyz >/dev/null 2>&1 || fail "drill-k8s-$drill: cluster svp does not answer on context k3d-svp; run make k8s-up"

cd "$repo_root"
dir=deploy/k8s/drills/$drill
selector=drill=$drill
tests=$(find "$dir" -name chainsaw-test.yaml 2>/dev/null | sort)
[ -n "$tests" ] || fail "drill-k8s-$drill: no test under $dir/ (chainsaw-test.yaml)"
expected=$(grep -c . <<<"$tests")
chainsaw_args=()
secrets=
# What the line of the search names as the Secret values searched for.
searched=

case $drill in
threats)
  [ -s .k8s/ca.crt ] || fail "drill-k8s-threats: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)"
  export CURL_CA_BUNDLE=$repo_root/.k8s/ca.crt
  if ! kc get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # paths of the repository, without spaces
    left_out=$(grep -lE '^ +requires: external-secrets$' $tests || true)
    selector+=,requires!=external-secrets
    expected=$((expected - $(grep -c . <<<"$left_out" || true)))
    for f in $left_out; do
      echo "skip  $(basename "$(dirname "$f")"): no External Secrets Operator on this cluster (dev path: its Secrets come from .env)"
      printf '%s\t%s\n' "$(basename "$(dirname "$f")")" \
        "no External Secrets Operator on this cluster (dev path: its Secrets come from .env)" >>"$work/left-out.tsv"
    done
  fi
  # The Secret values the tests read, one per line, for the search: only ever in this file.
  secrets=$work/secrets
  {
    kc -n svp-data get secret kafka-users -o json | jq -r '.data[] | @base64d'
    kc -n svp-obs get secret grafana-admin -o json | jq -r '.data["admin-password"] | @base64d'
    kc -n svp-data get secret pg-backup-s3 -o json | jq -r '.data.ACCESS_SECRET_KEY | @base64d'
    kc -n svp-data get secret s3-users -o json |
      jq -r '.data.SVP_VIDEO_S3_SECRET_KEY, .data.SVP_MEDIA_WORKER_S3_SECRET_KEY | @base64d'
  } 2>/dev/null | grep -v '^$' >"$secrets" || true
  n=$(grep -c . "$secrets" || true)
  ((n >= 10)) ||
    fail "SECRETS: read the 10 Secret values the drill uses (6 Kafka users, Grafana admin, 3 object store users) to search its output (got $n)"
  searched="the drill read (6 Kafka users, Grafana admin, 3 object store users)"
  ;;
reloader)
  [ -s .k8s/ca.crt ] || fail "drill-k8s-reloader: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)"
  export CURL_CA_BUNDLE=$repo_root/.k8s/ca.crt
  [ -f .env ] || fail "drill-k8s-reloader: .env not found; the drill changes credentials of the cluster's .env (make env)"
  # shellcheck source=deploy/observability/glitchtip/dotenv.sh
  . deploy/observability/glitchtip/dotenv.sh
  # The variables the drill changes, as .env holds them now, and the lines of the file of the new values
  # (deploy/k8s/drills/reloader/new-values.sh says what each is).
  changed_vars="SVP_S3_ROOT_PASSWORD SVP_KAFKA_ADMIN_PASSWORD SVP_VIDEO_APP_DB_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD
    SVP_KAFKA_KEDA_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD SVP_GRAFANA_ADMIN_PASSWORD NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
    JWT_VERIFY_KEYS"
  new_vars="SVP_S3_ROOT_PASSWORD SVP_KAFKA_ADMIN_PASSWORD SVP_VIDEO_APP_DB_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD
    SVP_KAFKA_KEDA_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD SVP_GRAFANA_ADMIN_PASSWORD NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
    JWT_VERIFY_KEY_NEW JWT_DRILL_SIGNING_KEY"
  new=$work/new-values
  if [ -n "${SVP_DRILL_NEW_VALUES:-}" ]; then
    [ -f "$SVP_DRILL_NEW_VALUES" ] ||
      fail "drill-k8s-reloader: SVP_DRILL_NEW_VALUES names no file (write it with deploy/k8s/drills/reloader/new-values.sh)"
    [ -z "$(find "$SVP_DRILL_NEW_VALUES" \( -perm -040 -o -perm -004 \) 2>/dev/null)" ] ||
      fail "drill-k8s-reloader: the file SVP_DRILL_NEW_VALUES names can be read by others than its owner; it must be mode 600"
    cp "$SVP_DRILL_NEW_VALUES" "$new"
  elif [ "${GITHUB_ACTIONS:-}" = true ]; then
    fail "drill-k8s-reloader on GitHub Actions takes its new values from SVP_DRILL_NEW_VALUES, written and masked by an earlier step of the job (deploy/k8s/drills/reloader/new-values.sh): made here they would not be masked"
  else
    deploy/k8s/drills/reloader/new-values.sh "$new" ||
      fail "drill-k8s-reloader: make the new values (deploy/k8s/drills/reloader/new-values.sh, above)"
  fi
  # Both files keep the rule of .env; each variable once, none empty, nothing else in the file of the new values.
  secrets=$work/secrets
  old=$work/old-values
  : >"$secrets"
  : >"$old"
  missing=
  for v in $new_vars; do
    val=$(dotenv_value "$new" "$v") || fail "drill-k8s-reloader: the file of the new values breaks the rule of .env (above)"
    if [ -z "$val" ]; then missing="$missing $v"; else printf '%s\n' "$val" >>"$secrets"; fi
  done
  [ -z "$missing" ] || fail "drill-k8s-reloader: the file of the new values lacks or has empty:$missing"
  # shellcheck disable=SC2086 # names of variables, without spaces
  extra=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$new" | grep -vxF "$(printf '%s\n' $new_vars)" || true)
  [ -z "$extra" ] || fail "drill-k8s-reloader: the file of the new values has other lines than its variables: $(printf '%s' "$extra" | paste -sd ' ' -)"
  for v in $changed_vars; do
    val=$(dotenv_value .env "$v") || fail "drill-k8s-reloader: .env breaks its rule (above)"
    if [ -z "$val" ]; then missing="$missing $v"; else
      printf '%s=%s\n' "$v" "$val" >>"$old"
      printf '%s\n' "$val" >>"$secrets"
    fi
  done
  [ -z "$missing" ] || fail "drill-k8s-reloader: .env lacks or has empty:$missing; run make env"
  token=$(kc -n svp-obs get secret glitchtip-api -o json 2>/dev/null | jq -r '.data.SENTRY_AUTH_TOKEN // "" | @base64d') || token=
  [ -n "$token" ] ||
    fail "drill-k8s-reloader: read GlitchTip's API token from Secret svp-obs/glitchtip-api (make k8s-glitchtip-init writes it)"
  printf '%s\n' "$token" >>"$secrets"
  token=
  n=$(grep -c . "$secrets" || true)
  searched="of the drill (the old and the new of each value it changes, GlitchTip's API token)"
  mkdir -p "$work/state"
  jq -n --arg newValues "$new" --arg oldValues "$old" --arg stateDir "$work/state" \
    '{newValues: $newValues, oldValues: $oldValues, stateDir: $stateDir}' >"$work/values.json"
  chainsaw_args+=(--values "$work/values.json")
  ;;
supplychain)
  unsigned=${SUPPLYCHAIN_UNSIGNED:-}
  if [ -z "$unsigned" ]; then
    if unsigned=$(deploy/ci/ghcr-digest.sh newest drill-unsigned 2>"$work/unsigned.err"); then
      echo "info  unsigned: $unsigned (newest drill-unsigned on GHCR)"
    else
      unsigned=
      echo "info  unsigned: empty, no drill-unsigned found on GHCR ($(tail -n 1 "$work/unsigned.err"))"
    fi
  fi
  no_provenance=${SUPPLYCHAIN_NO_PROVENANCE:-}
  if [ -z "$no_provenance" ]; then
    if no_provenance=$(deploy/ci/ghcr-digest.sh newest drill-no-provenance 2>"$work/no-provenance.err"); then
      echo "info  noProvenance: $no_provenance (newest drill-no-provenance on GHCR)"
    else
      no_provenance=
      echo "info  noProvenance: empty, no drill-no-provenance found on GHCR ($(tail -n 1 "$work/no-provenance.err"))"
    fi
  fi
  jq -n --arg unsigned "$unsigned" --arg vulnerable "${SUPPLYCHAIN_VULNERABLE:-}" --arg noProvenance "$no_provenance" \
    --arg enforceTmp "${SUPPLYCHAIN_ENFORCE_TMP:-}" \
    '{unsigned: $unsigned, vulnerable: $vulnerable, noProvenance: $noProvenance, enforceTmp: $enforceTmp}' >"$work/values.json"
  chainsaw_args+=(--values "$work/values.json")
  ;;
esac

mkdir -p .k8s/drills
name=$drill-$(date -u +%Y%m%dT%H%M%SZ)
log=.k8s/drills/$name.log
report=.k8s/drills/$name.xml

# shown LINE...: the terminal's copy of the output, without the lines that hold a Secret value of $secrets (read from
# the file, never an argument).
shown() {
  if [ -z "$secrets" ]; then
    cat
  else
    awk 'NR == FNR { if ($0 != "") v[++n] = $0; next }
      { for (i = 1; i <= n; i++) if (index($0, v[i])) { print "[a line of the output holds a Secret value: not shown]"; fflush(); next } }
      { print; fflush() }' "$secrets" -
  fi
}

set +e
# tee and the filter ignore Ctrl-C (an ignored signal stays ignored across exec): they read on until chainsaw has run
# its cleanups, so its last lines are not lost to a broken pipe.
chainsaw test --kube-context k3d-svp --config deploy/k8s/drills/.chainsaw.yaml --test-dir "$dir" \
  --selector "$selector" --parallel 1 --no-color --report-format JUNIT-TEST --report-path .k8s/drills \
  --report-name "$name" ${chainsaw_args[@]+"${chainsaw_args[@]}"} 2>&1 | (
  trap '' INT
  tee "$log" | shown
)
rc=${PIPESTATUS[0]}
set -e

# The SKIPs: the lines a test printed ("SKIP  (<id>) <reason>" in the STDOUT block of a script step, indented), each
# with the test chainsaw was running ("=== RUN|CONT chainsaw/<test>"; tests run one at a time).
skips=.k8s/drills/$drill-skips.tsv
{
  cat "$work/left-out.tsv" 2>/dev/null || true
  awk -v secrets="${secrets:-}" '
    BEGIN { if (secrets != "") while ((getline l < secrets) > 0) if (l != "") v[++n] = l }
    /^=== (RUN|CONT) +chainsaw\// { cur = $0; sub(/^=== (RUN|CONT) +chainsaw\//, "", cur); next }
    /^ +=== STDOUT$/ { out = 1; next }
    $0 != "" && !/^        / { out = 0 }
    /^ +=== / { out = 0 }
    out && match($0, /^ +SKIP +\([a-z0-9]+\) +/) {
      reason = substr($0, RLENGTH + 1)
      gsub(/\t/, " ", reason)
      for (i = 1; i <= n; i++) if (index(reason, v[i])) { reason = "[the reason holds a Secret value: not shown]"; break }
      printf "%s\t%s\n", (cur == "" ? "unknown" : cur), reason
    }' "$log"
} >"$work/skips.body"
{
  cat "$work/skips.body"
  printf 'total\t%s\n' "$(grep -c . "$work/skips.body" || true)"
} >"$skips"

failed=
note() { echo "$1" | tee -a "$log" >&2; }
if [ ! -s "$report" ]; then
  note "FAIL  drill-k8s-$drill: chainsaw wrote no report $report"
  failed=1
else
  ran=$(grep -o '<testcase ' "$report" | grep -c . || true)
  [ "$ran" = "$expected" ] || {
    note "FAIL  drill-k8s-$drill: the report holds $ran test(s), $dir/ has $expected to run (a label drill=$drill missing?)"
    failed=1
  }
fi
if [ -n "$secrets" ]; then
  leaks=$(cat "$log" "$report" 2>/dev/null | grep -c -F -f "$secrets" || true)
  if [ "$leaks" != 0 ]; then
    note "FAIL  SECRETS: $leaks line(s) of the drill's log and report hold one of the $n Secret values it read ($log, $report)"
    failed=1
  else
    echo "ok    SECRETS: none of the $n Secret values $searched is in its log or report" | tee -a "$log"
  fi
fi
[ "$rc" = 0 ] || {
  note "FAIL  drill-k8s-$drill: chainsaw exited $rc (a test failed); log $log, report $report"
  failed=1
}
[ -z "$failed" ] || exit 1
echo "drill-k8s-$drill: $ran test(s) passed; log $log, report $report"
