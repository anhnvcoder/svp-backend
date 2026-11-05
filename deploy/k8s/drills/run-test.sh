#!/usr/bin/env bash
# Tests for deploy/k8s/drills/run.sh (make drill-k8s-threats, drill-k8s-supplychain, drill-k8s-gitops), without a
# cluster, a network or Docker: a temporary copy of the repository's tree holds run.sh, deploy/k8s/lib.sh, made-up tests
# under deploy/k8s/drills/<drill>/ and a fake deploy/ci/ghcr-digest.sh; fake chainsaw and kubectl come first on PATH,
# each recording its arguments. The Secret values are made at run time, so no file of the repository holds one. Cases:
#   - the context: SVP_KUBE_CONTEXT other than k3d-svp, no context k3d-svp in the kubeconfig, its API not answering:
#     each stops before chainsaw, and the first two before any call to a cluster;
#   - threats: chainsaw gets context, configuration, folder, selector and --parallel 1, curl the CA; without External
#     Secrets Operator the tests labelled requires=external-secrets are left out with a skip line; a Secret value in the
#     output or the report fails the drill and is printed nowhere (the terminal gets the other lines); fewer than 10
#     values fail before chainsaw; the file of the values is mode 600, never an argument, removed at the end;
#   - every drill: chainsaw red, no report, a report with another number of tests than the folder, a folder without
#     tests, an unknown drill: each exits non-zero;
#   - the list of the SKIPs, .k8s/drills/<drill>-skips.tsv: one line per SKIP line of a script step's STDOUT with the
#     test chainsaw was running, a line "total<TAB>n" last (n = 0 too); the tests left out for want of External Secrets
#     Operator are in it; a SKIP line outside a STDOUT block is not counted; a Secret value in a reason is not in the
#     file; chainsaw red leaves the file and a non-zero exit;
#   - supplychain: the values chainsaw gets for each row "diễn tập" of the image table of the drill (an image looked up
#     when not given, a lookup that fails left empty, vulnerable never looked up, noProvenance=none as is), and the
#     values given passed as they are.
#
# Usage, from anywhere: deploy/k8s/drills/run-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# same NAME WANT GOT / has NAME HAYSTACK NEEDLE / lacks NAME HAYSTACK NEEDLE
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
has() {
  case $2 in *"$3"*) ok "$1" ;; *) fail "$1"$'\n'"      want in: $2"$'\n'"      the text: $3" ;; esac
}
lacks() {
  case $2 in *"$3"*) fail "$1"$'\n'"      not wanted: $3" ;; *) ok "$1" ;; esac
}
for tool in jq openssl awk; do
  command -v "$tool" >/dev/null || {
    echo "FAIL  $tool is not installed" >&2
    exit 1
  }
done

# --- the tree: run.sh and deploy/k8s/lib.sh of this checkout, made-up tests, a fake ghcr-digest.sh.
tree=$work/repo
mkdir -p "$tree/deploy/k8s/drills" "$tree/deploy/ci"
cp "$repo/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$repo/deploy/k8s/drills/run.sh" "$tree/deploy/k8s/drills/"
# a_test DRILL FOLDER [EXTRA LABEL LINE]
a_test() {
  mkdir -p "$tree/deploy/k8s/drills/$1/$2"
  printf 'apiVersion: chainsaw.kyverno.io/v1alpha1\nkind: Test\nmetadata:\n  name: %s-%s\n  labels:\n    drill: %s\n%s' \
    "$1" "$2" "$1" "${3:+$3$'\n'}" >"$tree/deploy/k8s/drills/$1/$2/chainsaw-test.yaml"
}
a_test threats in-2-in-4
a_test threats ops-2
a_test threats sec-5-6-7 '    requires: external-secrets'
a_test threats sec-6-reader '    requires: external-secrets'
for c in a b l; do a_test supplychain "case-$c"; done
cat >"$tree/deploy/ci/ghcr-digest.sh" <<'EOF'
#!/usr/bin/env bash
# fake: newest IMAGE prints $FAKE_STATE/ghcr/IMAGE, or fails with a line on stderr when it is missing.
printf '%s\n' "$*" >>"$FAKE_STATE/ghcr.log"
[ -s "$FAKE_STATE/ghcr/$2" ] || { echo "GHCR does not list the tags of $2 anonymously" >&2; exit 1; }
cat "$FAKE_STATE/ghcr/$2"
EOF
chmod +x "$tree/deploy/ci/ghcr-digest.sh"

# --- the fake tools. FAKE_STATE is the folder of their logs and answers.
bin=$work/bin
mkdir -p "$bin"
# kubectl: answers from FAKE_STATE (contexts, down, eso, secrets/<namespace>-<name>.json).
cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
printf '%s\n' "$*" >>"$s/kubectl.log"
[ "${1:-}" = --context ] && [ "${2:-}" = k3d-svp ] || { echo "fake kubectl: not --context k3d-svp first" >&2; exit 2; }
shift 2
ns=
[ "${1:-}" != -n ] || { ns=$2; shift 2; }
case "$*" in
  "config get-contexts -o name") cat "$s/contexts" ;;
  "get --raw /readyz") [ ! -e "$s/down" ] ;;
  "get crd externalsecrets.external-secrets.io") [ -e "$s/eso" ] ;;
  "get secret "*" -o json") f=$s/secrets/$ns-$3.json; [ -s "$f" ] && cat "$f" ;;
  *) echo "fake kubectl: unexpected call: $*" >&2; exit 3 ;;
esac
EOF
cat >"$bin/chainsaw" <<'EOF'
#!/usr/bin/env bash
# fake: records its arguments, CURL_CA_BUNDLE, the values file and the work files of run.sh; prints $FAKE_STATE/out;
# writes a JUnit report of $FAKE_STATE/tests testcases (plus $FAKE_STATE/report-extra); exits $FAKE_STATE/rc.
s=$FAKE_STATE
printf '%s\n' "$@" >"$s/chainsaw.args"
echo "${CURL_CA_BUNDLE:-}" >"$s/chainsaw.ca"
path= name= values=
while [ $# -gt 0 ]; do
  case $1 in
    --report-path) path=$2; shift ;;
    --report-name) name=$2; shift ;;
    --values) values=$2; shift ;;
  esac
  shift
done
[ -z "$values" ] || cp "$values" "$s/values.json"
find "$FAKE_TMP" -type f -name secrets -perm 600 >"$s/secrets-600" 2>/dev/null
[ ! -e "$s/out" ] || cat "$s/out"
if [ ! -e "$s/no-report" ]; then
  {
    echo '<testsuites name="chainsaw-report">'
    i=0
    while [ "$i" -lt "$(cat "$s/tests")" ]; do echo "  <testcase name=\"t$i\"></testcase>"; i=$((i + 1)); done
    [ ! -e "$s/report-extra" ] || cat "$s/report-extra"
    echo '</testsuites>'
  } >"$path/$name.xml"
fi
exit "$(cat "$s/rc")"
EOF
# mktemp: run.sh's work folder under $work/tmp, where the fake chainsaw looks for the file of the values.
real_mktemp=$(command -v mktemp)
# shellcheck disable=SC2016 # expanded by the fake, not here
printf '#!/usr/bin/env bash\n[ "$*" = -d ] || { echo "fake mktemp: unexpected call: $*" >&2; exit 3; }\nexec %s -d "$FAKE_TMP/run.XXXXXX"\n' \
  "$real_mktemp" >"$bin/mktemp"
chmod +x "$bin/kubectl" "$bin/chainsaw" "$bin/mktemp"
export PATH="$bin:$PATH"

# The Secret values: 6 Kafka users, the Grafana admin, the 3 object store users.
values=$work/values
mkdir -p "$values"
for i in 1 2 3 4 5 6; do openssl rand -hex 12; done >"$values/svp-data-kafka-users"
openssl rand -hex 12 >"$values/svp-obs-grafana-admin"
openssl rand -hex 12 >"$values/svp-data-pg-backup-s3"
{ openssl rand -hex 12; openssl rand -hex 12; } >"$values/svp-data-s3-users"
secret1=$(head -n 1 "$values/svp-data-kafka-users")
grafana=$(cat "$values/svp-obs-grafana-admin")

# secret_json NS NAME KEY...: Secret NS/NAME as kubectl -o json prints it, KEY i holding line i of its values file.
secret_json() {
  local ns=$1 name=$2 i=0 key
  shift 2
  for key; do
    i=$((i + 1))
    sed -n "${i}p" "$values/$ns-$name" | tr -d '\n' | jq -Rs --arg k "$key" '{($k): @base64}'
  done | jq -s '{data: add}' >"$work/secrets/$ns-$name.json"
}
mkdir -p "$work/secrets"
secret_json svp-data kafka-users K1 K2 K3 K4 K5 K6
secret_json svp-obs grafana-admin admin-password
secret_json svp-data pg-backup-s3 ACCESS_SECRET_KEY
secret_json svp-data s3-users SVP_VIDEO_S3_SECRET_KEY SVP_MEDIA_WORKER_S3_SECRET_KEY
# fresh [TESTS]: a new FAKE_STATE (cluster up with context k3d-svp, External Secrets Operator, the 10 values, chainsaw
# green with TESTS testcases, default 4) and a tree without logs or reports but .k8s/ca.crt.
fresh() {
  export FAKE_STATE=$work/state FAKE_TMP=$work/tmp
  rm -rf "$FAKE_STATE" "$tree/.k8s" "$work/tmp"
  mkdir -p "$FAKE_STATE/ghcr" "$FAKE_STATE/secrets" "$tree/.k8s" "$work/tmp"
  echo k3d-svp >"$FAKE_STATE/contexts"
  touch "$FAKE_STATE/eso" "$FAKE_STATE/kubectl.log" "$FAKE_STATE/ghcr.log"
  echo "fake CA" >"$tree/.k8s/ca.crt"
  cp "$work"/secrets/*.json "$FAKE_STATE/secrets/"
  echo "${1:-4}" >"$FAKE_STATE/tests"
  echo 0 >"$FAKE_STATE/rc"
}
# drill ARGS...: run.sh in the tree, from another folder; output in $out, exit status in $rc.
drill() {
  set +e
  out=$(cd "$work" && "$tree/deploy/k8s/drills/run.sh" "$@" 2>&1)
  rc=$?
  set -e
}
called() { [ -s "$FAKE_STATE/chainsaw.args" ]; }
# red NAME [before|untouched]: ok when the drill exited non-zero; before: and chainsaw never ran; untouched: and
# neither chainsaw nor kubectl ran.
red() {
  local why=
  [ "$rc" != 0 ] || why="exit status 0"
  case ${2:-} in
  before | untouched) ! called || why="${why:+$why, }chainsaw ran" ;;
  esac
  [ "${2:-}" != untouched ] || [ ! -s "$FAKE_STATE/kubectl.log" ] || why="${why:+$why, }kubectl ran"
  if [ -z "$why" ]; then ok "$1"; else fail "$1 ($why)"; fi
}

all_values=$(cat "$values"/*)
# no_value NAME TEXT: TEXT holds none of the Secret values.
no_value() {
  local v
  while read -r v; do
    case $2 in *"$v"*)
      fail "$1: holds a Secret value"
      return
      ;;
    esac
  done <<<"$all_values"
  ok "$1"
}

# --- the context guard.
fresh
SVP_KUBE_CONTEXT=svp-stg drill threats
red "context: SVP_KUBE_CONTEXT=svp-stg stops before chainsaw and any kubectl" untouched
has "context: says it must be k3d-svp" "$out" "it must be k3d-svp or unset"
fresh
SVP_KUBE_CONTEXT=kind-other drill supplychain
red "context: SVP_KUBE_CONTEXT=kind-other refused before chainsaw and any kubectl" untouched
fresh
: >"$FAKE_STATE/contexts"
drill threats
red "context: no context k3d-svp in the kubeconfig stops before chainsaw" before
has "context: names the missing context" "$out" "the kubeconfig has no context k3d-svp"
same "context: only the kubeconfig was read" "config get-contexts -o name" "$(sed 's/^--context k3d-svp //' "$FAKE_STATE/kubectl.log")"
fresh
touch "$FAKE_STATE/down"
drill gitops
red "context: API of k3d-svp not answering stops before chainsaw" before
has "context: says the cluster does not answer" "$out" "cluster svp does not answer on context k3d-svp"

# --- threats, green, with External Secrets Operator.
fresh 4
printf 'step one\nstep two\n' >"$FAKE_STATE/out"
drill threats
same "threats: green run exits 0" 0 "$rc"
args=$(cat "$FAKE_STATE/chainsaw.args")
for want in "--kube-context"$'\n'"k3d-svp" "--config"$'\n'"deploy/k8s/drills/.chainsaw.yaml" \
  "--test-dir"$'\n'"deploy/k8s/drills/threats" "--selector"$'\n'"drill=threats"$'\n' "--parallel"$'\n'"1" \
  "--report-format"$'\n'"JUNIT-TEST" "--report-path"$'\n'".k8s/drills"; do
  has "threats: chainsaw gets ${want//$'\n'/ }" "$args"$'\n' "$want"
done
lacks "threats: no values file" "$args" "--values"
same "threats: curl gets the cluster's CA" "$tree/.k8s/ca.crt" "$(cat "$FAKE_STATE/chainsaw.ca")"
has "threats: the search found nothing" "$out" "ok    SECRETS: none of the 10 Secret values"
has "threats: the output reaches the terminal" "$out" "step two"
log=$(ls "$tree"/.k8s/drills/threats-*.log 2>/dev/null || true)
if [[ $log =~ /threats-[0-9]{8}T[0-9]{6}Z\.log$ ]]; then ok "threats: log .k8s/drills/threats-<UTC>.log"; else
  fail "threats: log .k8s/drills/threats-<UTC>.log (got '$log')"
fi
[ -n "$log" ] && has "threats: the log holds the output" "$(cat "$log")" "step one"
report=$(ls "$tree"/.k8s/drills/threats-*.xml 2>/dev/null || true)
same "threats: report beside the log" "${log%.log}.xml" "$report"
same "threats: the values file is mode 600 while chainsaw runs" 1 "$(grep -c . "$FAKE_STATE/secrets-600" || true)"
same "threats: the values file is gone at the end" "" "$(find "$FAKE_TMP" -mindepth 1 2>/dev/null)"
no_value "threats: no Secret value in chainsaw's arguments" "$args"
no_value "threats: no Secret value in kubectl's arguments" "$(cat "$FAKE_STATE/kubectl.log")"

# --- threats without External Secrets Operator: two tests left out, with a line each.
fresh 2
rm "$FAKE_STATE/eso"
drill threats
same "threats, no ESO: exits 0 with 2 tests in the report" 0 "$rc"
has "threats, no ESO: selector leaves requires=external-secrets out" "$(cat "$FAKE_STATE/chainsaw.args")" \
  "drill=threats,requires!=external-secrets"
has "threats, no ESO: skip line of sec-5-6-7" "$out" "skip  sec-5-6-7: no External Secrets Operator"
has "threats, no ESO: skip line of sec-6-reader" "$out" "skip  sec-6-reader: no External Secrets Operator"
fresh 4
rm "$FAKE_STATE/eso"
drill threats
red "threats, no ESO: 4 tests in the report where 2 should run fails"

# --- the list of the SKIPs: chainsaw's output as v0.2.15 prints it, a STDOUT block per script step.
skips_file() { cat "$tree/.k8s/drills/$1-skips.tsv" 2>/dev/null || echo "no file"; }
fresh 3
cat >"$FAKE_STATE/out" <<'EOF'
=== RUN   chainsaw/case-a
    sink.go:61: | 00:15:53 | case-a | step #1 | SCRIPT | LOG |
        === COMMAND
        /bin/sh -c skip "not a verdict line"
        SKIP  (a) in the script, not in its output
        === STDOUT
        ok    (a) fine
=== RUN   chainsaw/case-b
    sink.go:61: | 00:15:54 | case-b | step #1 | SCRIPT | LOG |
        === STDOUT
        SKIP  (b) no drill-unsigned on GHCR; build it (make x)
        ok    (b) not run, the case is SKIP above
=== CONT  chainsaw/case-l
    sink.go:61: | 00:15:55 | case-l | step #1 | SCRIPT | LOG |
        === STDOUT
        PASS  (l) fine

        SKIP  (l) policy off: no provenance to check
--- PASS: chainsaw (1.00s)
EOF
drill supplychain
same "skips: two SKIP lines, chainsaw green, exit 0" 0 "$rc"
same "skips: two lines (test, reason) in order, then total 2" \
  "$(printf 'case-b\tno drill-unsigned on GHCR; build it (make x)\ncase-l\tpolicy off: no provenance to check\ntotal\t2')" \
  "$(skips_file supplychain)"
fresh 3
printf '=== RUN   chainsaw/case-a\n        === STDOUT\n        ok    (a) fine\n' >"$FAKE_STATE/out"
drill supplychain
same "skips: no SKIP gives the file with total 0" "$(printf 'total\t0')" "$(skips_file supplychain)"
fresh 3
echo 1 >"$FAKE_STATE/rc"
printf '=== RUN   chainsaw/case-b\n        === STDOUT\n        SKIP  (b) a reason\n' >"$FAKE_STATE/out"
drill supplychain
red "skips: chainsaw red still exits non-zero"
same "skips: chainsaw red still leaves the file" "$(printf 'case-b\ta reason\ntotal\t1')" "$(skips_file supplychain)"
fresh 4
printf '=== RUN   chainsaw/sec-5-6-7\n        === STDOUT\n        SKIP  (x) the reason names %s here\n' "$secret1" >"$FAKE_STATE/out"
drill threats
red "skips: a Secret value in a reason still fails the drill (the log holds it)"
no_value "skips: the Secret value of a reason is not in the file" "$(skips_file threats)"
same "skips: the reason is replaced and still counted" \
  "$(printf 'sec-5-6-7\t[the reason holds a Secret value: not shown]\ntotal\t1')" "$(skips_file threats)"
fresh 2
rm "$FAKE_STATE/eso"
drill threats
same "skips: the tests left out for want of ESO are in the file" \
  "$(printf 'sec-5-6-7\tno External Secrets Operator on this cluster (dev path: its Secrets come from .env)\nsec-6-reader\tno External Secrets Operator on this cluster (dev path: its Secrets come from .env)\ntotal\t2')" \
  "$(skips_file threats)"
fresh 4
drill threats
same "skips: threats with ESO and no SKIP gives total 0" "$(printf 'total\t0')" "$(skips_file threats)"

# --- a Secret value in the output, or in the report.
fresh 4
printf 'before\nthe password is %s here\nafter\n' "$secret1" >"$FAKE_STATE/out"
drill threats
red "threats: a Secret value in the output fails the drill"
has "threats: names the leak" "$out" "FAIL  SECRETS: 1 line(s) of the drill's log and report hold one of the 10 Secret values"
no_value "threats: the leaked value is not printed" "$out"
has "threats: the line is withheld from the terminal" "$out" "[a line of the output holds a Secret value: not shown]"
has "threats: the other lines still reach the terminal" "$out" "after"
fresh 4
printf '  <failure>%s</failure>\n' "$grafana" >"$FAKE_STATE/report-extra"
drill threats
red "threats: a Secret value in the report fails the drill"
has "threats: names the leak in the report" "$out" "FAIL  SECRETS: 1 line(s)"
no_value "threats: the value of the report is not printed" "$out"

# --- fewer than 10 values: red before chainsaw.
fresh 4
rm "$FAKE_STATE/secrets/svp-obs-grafana-admin.json"
drill threats
red "threats: 9 Secret values fail before chainsaw" before
has "threats: says how many it read" "$out" "(got 9)"
fresh 4
rm "$tree/.k8s/ca.crt"
drill threats
red "threats: no .k8s/ca.crt stops before chainsaw" before

# --- every drill: chainsaw red, no report, no test.
fresh 4
echo 1 >"$FAKE_STATE/rc"
drill threats
red "threats: chainsaw red fails the drill"
has "threats: says chainsaw failed" "$out" "chainsaw exited 1"
fresh 3
echo 1 >"$FAKE_STATE/rc"
drill supplychain
red "supplychain: chainsaw red fails the drill"
fresh 3
touch "$FAKE_STATE/no-report"
drill supplychain
red "supplychain: no report fails the drill"
fresh 2
drill supplychain
red "supplychain: 2 tests in the report where the folder has 3 fails"
fresh 0
drill gitops
red "gitops: a folder without tests fails before chainsaw" before
fresh
drill other
red "an unknown drill fails" before
a_test gitops env
fresh 1
drill gitops
same "gitops: green run exits 0" 0 "$rc"
has "gitops: selector drill=gitops" "$(cat "$FAKE_STATE/chainsaw.args")" "drill=gitops"
lacks "gitops: no Secret search" "$out" "SECRETS"

# --- supplychain: the values of each row "diễn tập" of the image table.
digest=@sha256:$(printf '%064d' 0)
unsigned_ghcr=ghcr.io/anhnvcoder/svp-backend/drill-unsigned$digest
noprov_ghcr=ghcr.io/anhnvcoder/svp-backend/drill-no-provenance$digest
# values_of [VAR=VALUE...]: runs the supplychain drill with VAR=VALUE set; got is the values chainsaw got, as one line.
values_of() {
  fresh 3
  [ "${both_on_ghcr:-}" != 1 ] || { echo "$unsigned_ghcr" >"$FAKE_STATE/ghcr/drill-unsigned"; echo "$noprov_ghcr" >"$FAKE_STATE/ghcr/drill-no-provenance"; }
  set +e
  out=$(cd "$work" && env -u SUPPLYCHAIN_UNSIGNED -u SUPPLYCHAIN_VULNERABLE -u SUPPLYCHAIN_NO_PROVENANCE -u SUPPLYCHAIN_ENFORCE_TMP "$@" "$tree/deploy/k8s/drills/run.sh" supplychain 2>&1)
  rc=$?
  set -e
  got=$(jq -c . "$FAKE_STATE/values.json" 2>/dev/null || echo "no values file")
}
both_on_ghcr=1
values_of SUPPLYCHAIN_UNSIGNED= SUPPLYCHAIN_VULNERABLE= SUPPLYCHAIN_NO_PROVENANCE= SUPPLYCHAIN_ENFORCE_TMP=
same "supplychain: nothing given, both drill images on GHCR: looked up" \
  "{\"unsigned\":\"$unsigned_ghcr\",\"vulnerable\":\"\",\"noProvenance\":\"$noprov_ghcr\",\"enforceTmp\":\"\"}" "$got"
same "supplychain: exits 0" 0 "$rc"
same "supplychain: vulnerable never looked up" "$(printf 'newest drill-unsigned\nnewest drill-no-provenance')" "$(cat "$FAKE_STATE/ghcr.log")"
has "supplychain: chainsaw gets the values file" "$(cat "$FAKE_STATE/chainsaw.args")" "--values"
both_on_ghcr=
# row b: unsigned not given, drill-unsigned not found: empty (case b SKIPs).
values_of SUPPLYCHAIN_NO_PROVENANCE="$noprov_ghcr"
same "supplychain row b: no drill-unsigned on GHCR leaves unsigned empty" \
  "{\"unsigned\":\"\",\"vulnerable\":\"\",\"noProvenance\":\"$noprov_ghcr\",\"enforceTmp\":\"\"}" "$got"
has "supplychain row b: says why" "$out" "info  unsigned: empty, no drill-unsigned found on GHCR (GHCR does not list the tags of drill-unsigned anonymously)"
same "supplychain row b: chainsaw still runs" 0 "$rc"
# row c: vulnerable not given: empty, no lookup.
values_of SUPPLYCHAIN_UNSIGNED="$unsigned_ghcr" SUPPLYCHAIN_NO_PROVENANCE=none
same "supplychain row c: vulnerable not given stays empty" "\"\"" "$(jq -c .vulnerable <<<"$got")"
same "supplychain row c, row l none: no lookup at all" "" "$(cat "$FAKE_STATE/ghcr.log")"
# row l, none: passed as is.
same "supplychain row l: noProvenance=none passed as is" "\"none\"" "$(jq -c .noProvenance <<<"$got")"
# row l, not given and drill-no-provenance not found: empty (case l FAILs in its test).
values_of SUPPLYCHAIN_UNSIGNED="$unsigned_ghcr"
same "supplychain row l: no drill-no-provenance on GHCR leaves noProvenance empty" "\"\"" "$(jq -c .noProvenance <<<"$got")"
has "supplychain row l: says why" "$out" "info  noProvenance: empty, no drill-no-provenance found on GHCR"
same "supplychain row l: only drill-no-provenance looked up" "newest drill-no-provenance" "$(cat "$FAKE_STATE/ghcr.log")"
# everything given: passed as is, nothing looked up.
vuln=ghcr.io/anhnvcoder/svp-backend/drill-vulnerable$digest
values_of SUPPLYCHAIN_UNSIGNED="$unsigned_ghcr" SUPPLYCHAIN_VULNERABLE="$vuln" SUPPLYCHAIN_NO_PROVENANCE="$noprov_ghcr" SUPPLYCHAIN_ENFORCE_TMP=1
same "supplychain: values given passed as they are" \
  "{\"unsigned\":\"$unsigned_ghcr\",\"vulnerable\":\"$vuln\",\"noProvenance\":\"$noprov_ghcr\",\"enforceTmp\":\"1\"}" "$got"
same "supplychain: values given, nothing looked up" "" "$(cat "$FAKE_STATE/ghcr.log")"
lacks "supplychain: no Secret search" "$out" "SECRETS"

if ((failures > 0)); then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
