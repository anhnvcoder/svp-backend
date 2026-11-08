#!/usr/bin/env bash
# Tests for deploy/k8s/drills/run.sh (make drill-k8s-threats, drill-k8s-supplychain, drill-k8s-gitops,
# drill-k8s-reloader), deploy/k8s/drills/reloader/new-values.sh and the snapshot helpers of
# deploy/k8s/drills/reloader/rotate/reloader.sh, without a cluster, a network or Docker.

# A temporary copy of the repository's tree holds run.sh, deploy/k8s/lib.sh, the rule of .env, new-values.sh, made-up
# tests under deploy/k8s/drills/<drill>/, a made-up .env and a fake deploy/ci/ghcr-digest.sh; fake chainsaw, kubectl and
# go (for go run ./tools/jwtkey) come first on PATH, each recording its arguments. The Secret values are made at run
# time, so no file of the repository holds one.
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
mkdir -p "$tree/deploy/k8s/drills/reloader" "$tree/deploy/ci" "$tree/deploy/observability/glitchtip"
cp "$repo/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$repo/deploy/docker-bake.json" "$tree/deploy/"
cp "$repo/deploy/k8s/drills/run.sh" "$tree/deploy/k8s/drills/"
cp "$repo/deploy/k8s/drills/reloader/new-values.sh" "$tree/deploy/k8s/drills/reloader/"
cp "$repo/deploy/observability/glitchtip/dotenv.sh" "$tree/deploy/observability/glitchtip/"
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
a_test reloader rotate
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
  # the lists and the Rollout revisions reloader.sh reads: lists/<namespace>-<resource>.json, lists/<namespace>-rollout-<name>
  "get replicasets.apps -o json" | "get pods -o json" | "get secrets -o json" | "get jobs.batch -o json")
    f=$s/lists/$ns-$2.json; [ -s "$f" ] && cat "$f" ;;
  "get rollouts.argoproj.io "*" -o jsonpath="*) f=$s/lists/$ns-rollout-$3; [ -s "$f" ] && cat "$f" ;;
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
# reloader: the files and the folder its values name, as they are while chainsaw runs; $FAKE_STATE/leak names a line
# (newValues NAME or oldValues NAME) whose value goes to the output.
if [ -n "$values" ] && [ -n "$(jq -r '.newValues // ""' "$values")" ]; then
  : >"$s/values-private"
  for k in newValues oldValues; do
    f=$(jq -r ".$k" "$values")
    cp "$f" "$s/$k.seen"
    find "$f" -type f -perm 600 >>"$s/values-private"
  done
  find "$(jq -r .stateDir "$values")" -type d -perm 700 >>"$s/values-private"
  if [ -e "$s/leak" ]; then
    read -r k name <"$s/leak"
    echo "the value is $(sed -n "s/^$name=//p" "$(jq -r ".$k" "$values")")"
  fi
fi
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
# go: go run ./tools/jwtkey prints a new key pair in the form of tools/jwtkey; any other call fails.
cat >"$bin/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/go.log"
[ "$*" = "run ./tools/jwtkey" ] || { echo "fake go: unexpected call: $*" >&2; exit 3; }
kid=20261106-$(openssl rand -hex 4)
printf 'JWT_SIGNING_KID=%s\nJWT_SIGNING_KEY=%s\nJWT_VERIFY_KEYS=%s:%s\n' "$kid" "$(openssl rand -base64 32)" "$kid" "$(openssl rand -base64 32)"
EOF
chmod +x "$bin/kubectl" "$bin/chainsaw" "$bin/mktemp" "$bin/go"
export PATH="$bin:$PATH"

# The Secret values: 7 Kafka users, the Valkey password of svp-feed-service (in its REDIS_URL), the Grafana admin, the
# 3 object store users.
values=$work/values
mkdir -p "$values"
for i in 1 2 3 4 5 6 7; do openssl rand -hex 12; done >"$values/svp-data-kafka-users"
valkey_feed=$(openssl rand -hex 12)
echo "rediss://svp-feed-service:$valkey_feed@valkey.svp-data.svc.cluster.local:6379/14" >"$values/svp-feed-service-env"
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
secret_json svp-data kafka-users K1 K2 K3 K4 K5 K6 K7
secret_json svp feed-service-env REDIS_URL
secret_json svp-obs grafana-admin admin-password
secret_json svp-data pg-backup-s3 ACCESS_SECRET_KEY
secret_json svp-data s3-users SVP_VIDEO_S3_SECRET_KEY SVP_MEDIA_WORKER_S3_SECRET_KEY
openssl rand -hex 12 >"$values/svp-obs-glitchtip-api"
secret_json svp-obs glitchtip-api SENTRY_AUTH_TOKEN
# fresh [TESTS]: a new FAKE_STATE (cluster up with context k3d-svp, External Secrets Operator, the 12 values, chainsaw
# green with TESTS testcases, default 4) and a tree without logs or reports but .k8s/ca.crt.
fresh() {
  export FAKE_STATE=$work/state FAKE_TMP=$work/tmp
  rm -rf "$FAKE_STATE" "$tree/.k8s" "$work/tmp"
  mkdir -p "$FAKE_STATE/ghcr" "$FAKE_STATE/secrets" "$tree/.k8s" "$work/tmp"
  echo k3d-svp >"$FAKE_STATE/contexts"
  touch "$FAKE_STATE/eso" "$FAKE_STATE/kubectl.log" "$FAKE_STATE/ghcr.log" "$FAKE_STATE/go.log"
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
has "threats: the search found nothing" "$out" "ok    SECRETS: none of the 12 Secret values"
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
has "threats: names the leak" "$out" "FAIL  SECRETS: 1 line(s) of the drill's log and report hold one of the 12 Secret values"
no_value "threats: the leaked value is not printed" "$out"
has "threats: the line is withheld from the terminal" "$out" "[a line of the output holds a Secret value: not shown]"
has "threats: the other lines still reach the terminal" "$out" "after"
fresh 4
printf '  <failure>%s</failure>\n' "$grafana" >"$FAKE_STATE/report-extra"
drill threats
red "threats: a Secret value in the report fails the drill"
has "threats: names the leak in the report" "$out" "FAIL  SECRETS: 1 line(s)"
no_value "threats: the value of the report is not printed" "$out"

# --- fewer than 12 values: red before chainsaw.
fresh 4
rm "$FAKE_STATE/secrets/svp-obs-grafana-admin.json"
drill threats
red "threats: 11 Secret values fail before chainsaw" before
has "threats: says how many it read" "$out" "(got 11)"

# --- the Valkey password of svp-feed-service is searched for alone, not only inside its REDIS_URL.
fresh 4
printf 'before\nthe Valkey password is %s here\nafter\n' "$valkey_feed" >"$FAKE_STATE/out"
drill threats
red "threats: the Valkey password of svp-feed-service in the log fails the drill"
has "threats: names that leak" "$out" "FAIL  SECRETS: 1 line(s) of the drill's log and report hold one of the 12 Secret values"
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

# --- reloader. A made-up .env of the tree with the variables the drill changes; the new values made by new-values.sh
# (fake go) or given in a file of SVP_DRILL_NEW_VALUES.
changed_vars="SVP_S3_ROOT_PASSWORD SVP_KAFKA_ADMIN_PASSWORD SVP_VIDEO_APP_DB_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD
  SVP_KAFKA_KEDA_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD SVP_GRAFANA_ADMIN_PASSWORD NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
  JWT_VERIFY_KEYS"
new_vars="SVP_S3_ROOT_PASSWORD SVP_KAFKA_ADMIN_PASSWORD SVP_VIDEO_APP_DB_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD
  SVP_KAFKA_KEDA_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD SVP_GRAFANA_ADMIN_PASSWORD NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
  JWT_VERIFY_KEY_NEW JWT_DRILL_SIGNING_KEY"
# env_of [SKIP]: the tree's .env, every variable the drill changes but SKIP, a value made now each, and one it keeps.
env_of() {
  local v
  {
    echo "# made by run-test.sh"
    echo "SVP_PG_SUPERUSER_PASSWORD=$(openssl rand -hex 12)"
    for v in $changed_vars; do [ "$v" = "${1:-}" ] || echo "$v=$(openssl rand -hex 12)"; done
  } >"$tree/.env"
  chmod 600 "$tree/.env"
}
# given_values FILE [SKIP] [EXTRA LINE]: a file of new values as new-values.sh writes it, mode 600.
given_values() {
  local v
  {
    for v in $new_vars; do [ "$v" = "${2:-}" ] || echo "$v=given-$(openssl rand -hex 12)"; done
    [ -z "${3:-}" ] || echo "$3"
  } >"$1"
  chmod 600 "$1"
}
# names FILE: the names of the lines of FILE, sorted, on one line.
names() { sed -n 's/=.*//p' "$1" | LC_ALL=C sort | paste -sd ' ' -; }
reloader_run() {
  set +e
  out=$(cd "$work" && env -u GITHUB_ACTIONS -u SVP_DRILL_NEW_VALUES "$@" "$tree/deploy/k8s/drills/run.sh" reloader 2>&1)
  rc=$?
  set -e
}
sorted() { printf '%s\n' $1 | LC_ALL=C sort | paste -sd ' ' -; }

fresh 1
env_of
cp "$tree/.env" "$work/env.before"
reloader_run
same "reloader: green run exits 0" 0 "$rc"
args=$(cat "$FAKE_STATE/chainsaw.args")
has "reloader: selector drill=reloader" "$args" "drill=reloader"
has "reloader: chainsaw gets the values file" "$args" "--values"
same "reloader: the values are newValues, oldValues and stateDir, paths only" "newValues oldValues stateDir" \
  "$(jq -r 'keys | join(" ")' "$FAKE_STATE/values.json")"
same "reloader: newValues has each new value, made by new-values.sh" "$(sorted "$new_vars")" "$(names "$FAKE_STATE/newValues.seen")"
same "reloader: tools/jwtkey ran once for the new key" "run ./tools/jwtkey" "$(cat "$FAKE_STATE/go.log")"
same "reloader: oldValues has each variable the drill changes" "$(sorted "$changed_vars")" "$(names "$FAKE_STATE/oldValues.seen")"
same "reloader: oldValues holds the values of .env" "$(grep -E "^($(printf '%s' "$changed_vars" | tr -s ' \n' '|' | sed 's/|$//'))=" "$work/env.before" | LC_ALL=C sort)" \
  "$(LC_ALL=C sort "$FAKE_STATE/oldValues.seen")"
same "reloader: run.sh leaves .env as it is (the test changes it)" "" "$(cmp "$work/env.before" "$tree/.env" 2>&1)"
same "reloader: the two files are mode 600 and the folder 700 while chainsaw runs" 3 "$(grep -c . "$FAKE_STATE/values-private" || true)"
same "reloader: the values files are gone at the end" "" "$(find "$FAKE_TMP" -mindepth 1 2>/dev/null)"
same "reloader: curl gets the cluster's CA" "$tree/.k8s/ca.crt" "$(cat "$FAKE_STATE/chainsaw.ca")"
has "reloader: the search counts 9 old, 10 new values and the token" "$out" "ok    SECRETS: none of the 20 Secret values of the drill"
new_values_all=$(cut -d= -f2- "$FAKE_STATE/newValues.seen")
no_new() {
  local v
  while IFS= read -r v; do case $2 in *"$v"*) fail "$1: holds a new value" && return ;; esac; done <<<"$new_values_all"
  ok "$1"
}
no_new "reloader: no new value in chainsaw's arguments" "$args"
no_new "reloader: no new value in kubectl's arguments" "$(cat "$FAKE_STATE/kubectl.log")"
fresh 1
env_of
echo "newValues SVP_GRAFANA_ADMIN_PASSWORD" >"$FAKE_STATE/leak"
reloader_run
red "reloader: a new value in the output fails the drill"
has "reloader: names the leak" "$out" "FAIL  SECRETS: 1 line(s) of the drill's log and report hold one of the 20 Secret values"
leaked=$(sed -n 's/^SVP_GRAFANA_ADMIN_PASSWORD=//p' "$FAKE_STATE/newValues.seen")
[ -n "$leaked" ] && lacks "reloader: the leaked new value is not printed" "$out" "$leaked"
has "reloader: the line is withheld from the terminal" "$out" "[a line of the output holds a Secret value: not shown]"
fresh 1
env_of
echo "oldValues JWT_VERIFY_KEYS" >"$FAKE_STATE/leak"
reloader_run
red "reloader: an old value in the output fails the drill"
leaked=$(sed -n 's/^JWT_VERIFY_KEYS=//p' "$tree/.env")
lacks "reloader: the leaked old value is not printed" "$out" "$leaked"
fresh 1
env_of
printf '  <failure>%s</failure>\n' "$(cat "$values/svp-obs-glitchtip-api")" >"$FAKE_STATE/report-extra"
reloader_run
red "reloader: GlitchTip's API token in the report fails the drill"
lacks "reloader: the token is not printed" "$out" "$(cat "$values/svp-obs-glitchtip-api")"

# SVP_DRILL_NEW_VALUES: taken as it is; refused when others may read it, a variable lacks or another is there.
fresh 1
env_of
given_values "$work/given"
reloader_run SVP_DRILL_NEW_VALUES="$work/given"
same "reloader, SVP_DRILL_NEW_VALUES: green" 0 "$rc"
same "reloader, SVP_DRILL_NEW_VALUES: newValues is that file" "$(cat "$work/given")" "$(cat "$FAKE_STATE/newValues.seen")"
same "reloader, SVP_DRILL_NEW_VALUES: nothing made (no tools/jwtkey)" "" "$(cat "$FAKE_STATE/go.log")"
fresh 1
env_of
chmod 644 "$work/given"
reloader_run SVP_DRILL_NEW_VALUES="$work/given"
red "reloader: SVP_DRILL_NEW_VALUES readable by others stops before chainsaw" before
has "reloader: says the mode" "$out" "it must be mode 600"
fresh 1
env_of
given_values "$work/given" JWT_DRILL_SIGNING_KEY
reloader_run SVP_DRILL_NEW_VALUES="$work/given"
red "reloader: SVP_DRILL_NEW_VALUES without JWT_DRILL_SIGNING_KEY stops before chainsaw" before
has "reloader: names the variable missing" "$out" "lacks or has empty: JWT_DRILL_SIGNING_KEY"
fresh 1
env_of
given_values "$work/given" "" "SVP_PG_SUPERUSER_PASSWORD=$(openssl rand -hex 12)"
reloader_run SVP_DRILL_NEW_VALUES="$work/given"
red "reloader: SVP_DRILL_NEW_VALUES with another variable stops before chainsaw" before
has "reloader: names the other variable" "$out" "other lines than its variables: SVP_PG_SUPERUSER_PASSWORD"
reloader_run SVP_DRILL_NEW_VALUES="$work/no-such-file"
red "reloader: SVP_DRILL_NEW_VALUES naming no file stops before chainsaw" before
fresh 1
env_of
reloader_run GITHUB_ACTIONS=true
red "reloader: GitHub Actions without SVP_DRILL_NEW_VALUES stops before chainsaw" before
has "reloader: says the values would not be masked" "$out" "made here they would not be masked"
same "reloader: GitHub Actions without SVP_DRILL_NEW_VALUES makes no value" "" "$(cat "$FAKE_STATE/go.log")"
fresh 1
env_of SVP_KAFKA_KEDA_PASSWORD
reloader_run
red "reloader: .env without SVP_KAFKA_KEDA_PASSWORD stops before chainsaw" before
has "reloader: names it" "$out" ".env lacks or has empty: SVP_KAFKA_KEDA_PASSWORD"
fresh 1
env_of
rm "$FAKE_STATE/secrets/svp-obs-glitchtip-api.json"
reloader_run
red "reloader: no GlitchTip API token stops before chainsaw" before
has "reloader: names the Secret" "$out" "Secret svp-obs/glitchtip-api"
fresh 1
env_of
rm "$tree/.k8s/ca.crt"
reloader_run
red "reloader: no .k8s/ca.crt stops before chainsaw" before
fresh 2
env_of
reloader_run
red "reloader: 2 tests in the report where the folder has 1 fails"

# --- new-values.sh.
fresh
nv=$tree/deploy/k8s/drills/reloader/new-values.sh
set +e
masks=$(env GITHUB_ACTIONS=true "$nv" "$work/nv1" 2>&1)
rc=$?
set -e
same "new-values: exits 0" 0 "$rc"
same "new-values: one line per variable" "$(sorted "$new_vars")" "$(names "$work/nv1")"
same "new-values: the file is mode 600" "$work/nv1" "$(find "$work/nv1" -type f -perm 600)"
same "new-values: GitHub Actions: two masks per value (it and its base64), nothing else" "20 0" \
  "$(grep -c '^::add-mask::' <<<"$masks") $(grep -vc '^::add-mask::' <<<"$masks" || true)"
missing_mask=
while IFS= read -r line; do
  v=${line#*=}
  grep -qxF "::add-mask::$v" <<<"$masks" || missing_mask="$missing_mask ${line%%=*}"
  grep -qxF "::add-mask::$(printf '%s' "$v" | base64 | tr -d '\n')" <<<"$masks" || missing_mask="$missing_mask ${line%%=*}(base64)"
done <"$work/nv1"
same "new-values: each value and its base64 masked" "" "$missing_mask"
same "new-values: the verify key is <kid>:<key> of the pair, its private key the seed" "ok" \
  "$(kid=$(sed -n 's/^JWT_VERIFY_KEY_NEW=//p' "$work/nv1" | cut -d: -f1); [[ $kid =~ ^[0-9]{8}-[0-9a-f]{8}$ ]] && grep -q '^JWT_DRILL_SIGNING_KEY=.' "$work/nv1" && echo ok)"
same "new-values: NEXT_SERVER_ACTIONS_ENCRYPTION_KEY is the base64 of 32 bytes" "ok" \
  "$(grep -qE '^NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=[A-Za-z0-9+/]{43}=$' "$work/nv1" && echo ok)"
env -u GITHUB_ACTIONS "$nv" "$work/nv2" >"$work/nv2.out" 2>&1
same "new-values: elsewhere nothing printed" "" "$(cat "$work/nv2.out")"
same "new-values: two runs give other values" "" "$(LC_ALL=C comm -12 <(cut -d= -f2- "$work/nv1" | sort) <(cut -d= -f2- "$work/nv2" | sort))"
cp "$work/nv1" "$work/nv1.copy"
set +e
env -u GITHUB_ACTIONS "$nv" "$work/nv1" >/dev/null 2>&1
rc=$?
set -e
same "new-values: an existing file is refused" 1 "$rc"
same "new-values: ... and left as it was" "" "$(cmp "$work/nv1" "$work/nv1.copy" 2>&1)"

# --- reloader.sh, sourced from its folder as the drill's steps do (it finds the repository with git and reads
# nothing of it but the rule of .env), on lists of a cluster bootstrapped once: the init Jobs of svp-data stay there
# after they Succeeded (hook policy before-hook-creation), beside a Job whose name only starts like one, pods of Jobs
# and a Helm release record.
fresh
lists=$FAKE_STATE/lists
mkdir -p "$lists" "$work/helper"
# list NS RESOURCE < JSON: what fake kubectl gives for kubectl -n NS get RESOURCE -o json.
list() { cat >"$lists/$1-$2.json"; }
for ns in svp svp-data svp-obs keda; do
  for r in replicasets.apps pods secrets; do echo '{"items":[]}' | list "$ns" "$r"; done
done
list svp replicasets.apps <<'EOF'
{"items":[
 {"metadata":{"name":"user-service-6b9","ownerReferences":[{"kind":"Deployment","name":"user-service","controller":true}]}},
 {"metadata":{"name":"gateway-7c4","ownerReferences":[{"kind":"Rollout","name":"gateway","controller":true}]}}]}
EOF
list svp pods <<'EOF'
{"items":[
 {"metadata":{"name":"user-service-6b9-a","uid":"p-user-a","ownerReferences":[{"kind":"ReplicaSet","name":"user-service-6b9","controller":true}]},
  "status":{"conditions":[{"type":"Ready","status":"True"}]}},
 {"metadata":{"name":"gateway-7c4-a","uid":"p-gw-a","ownerReferences":[{"kind":"ReplicaSet","name":"gateway-7c4","controller":true}]},
  "status":{"conditions":[{"type":"Ready","status":"False"}]}},
 {"metadata":{"name":"video-service-migrate-3-x","uid":"p-migrate","ownerReferences":[{"kind":"Job","name":"video-service-migrate-3","controller":true}]},
  "status":{}}]}
EOF
list svp-data pods <<'EOF'
{"items":[
 {"metadata":{"name":"s3-0","uid":"p-s3-0","deletionTimestamp":"2026-11-06T00:00:00Z","ownerReferences":[{"kind":"StatefulSet","name":"s3","controller":true}]},
  "status":{"conditions":[{"type":"Ready","status":"True"}]}},
 {"metadata":{"name":"kafka-0","uid":"p-kafka-0","ownerReferences":[{"kind":"StatefulSet","name":"kafka","controller":true}]},"status":{}},
 {"metadata":{"name":"svp-pg-1","uid":"p-pg-1","ownerReferences":[{"kind":"Cluster","name":"svp-pg","controller":true}]},
  "status":{"conditions":[{"type":"Ready","status":"True"}]}},
 {"metadata":{"name":"pg-bootstrap-k2x","uid":"p-pg-bootstrap","ownerReferences":[{"kind":"Job","name":"pg-bootstrap","controller":true}]},
  "status":{}}]}
EOF
list keda replicasets.apps <<'EOF'
{"items":[{"metadata":{"name":"keda-operator-5d","ownerReferences":[{"kind":"Deployment","name":"keda-operator","controller":true}]}}]}
EOF
list keda pods <<'EOF'
{"items":[{"metadata":{"name":"keda-operator-5d-a","uid":"p-keda-a","ownerReferences":[{"kind":"ReplicaSet","name":"keda-operator-5d","controller":true}]},
  "status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
secret_data=$(openssl rand -hex 12 | tr -d '\n' | openssl base64 -A)
list svp-data secrets <<EOF
{"items":[
 {"type":"Opaque","metadata":{"name":"s3-root","resourceVersion":"101"},"data":{"SVP_S3_ROOT_PASSWORD":"$secret_data"}},
 {"type":"helm.sh/release.v1","metadata":{"name":"sh.helm.release.v1.svp-data.v2","resourceVersion":"102"},"data":{"release":"$secret_data"}}]}
EOF
list svp secrets <<'EOF'
{"items":[{"type":"Opaque","metadata":{"name":"gateway-env","resourceVersion":"201"}}]}
EOF
list keda secrets <<'EOF'
{"items":[{"type":"Opaque","metadata":{"name":"keda-kafka","resourceVersion":"401"}}]}
EOF
# job_list UID_PG UID_KAFKA UID_S3 [S3_STATUS]: the Jobs of svp-data, the init Jobs Succeeded but s3-init, whose status
# is S3_STATUS when given; an empty UID leaves that init Job out.
job_list() {
  local succeeded='{"succeeded":1}'
  {
    echo '{"items":['
    echo "{\"metadata\":{\"name\":\"pg-bootstrap-manual\",\"uid\":\"j-manual\"},\"status\":$succeeded}"
    [ -z "$2" ] || echo ",{\"metadata\":{\"name\":\"kafka-init\",\"uid\":\"$2\"},\"status\":$succeeded}"
    [ -z "$1" ] || echo ",{\"metadata\":{\"name\":\"pg-bootstrap\",\"uid\":\"$1\"},\"status\":$succeeded}"
    [ -z "$3" ] || echo ",{\"metadata\":{\"name\":\"s3-init\",\"uid\":\"$3\"},\"status\":${4:-$succeeded}}"
    echo ']}'
  } | list svp-data jobs.batch
}
job_list j-pg-1 j-kafka-1 j-s3-1 '{"active":1}'
echo 7 >"$lists/svp-rollout-gateway"
echo 3 >"$lists/svp-rollout-web"
# helper COMMANDS: COMMANDS after sourcing reloader.sh in its folder; output in $out, exit status in $rc.
helper() {
  set +e
  out=$(cd "$here/reloader/rotate" &&
    env CALLER_KUBECONFIG= NEW_VALUES="$work/nv1" OLD_VALUES="$work/nv1" STATE_DIR="$work/helper" \
      bash -c "set -euo pipefail; . ./reloader.sh; $1" 2>&1)
  rc=$?
  set -e
}
helper "snapshot before"
same "reloader.sh: snapshot of a bootstrapped cluster exits 0" 0 "$rc"
same "reloader.sh: snapshot prints nothing" "" "$out"
same "reloader.sh: pods of Deployments, Rollouts, StatefulSets and Clusters, by workload, not those of Jobs" \
  "Cluster/svp-data/svp-pg p-pg-1 ready svp-pg-1
Deployment/keda/keda-operator p-keda-a ready keda-operator-5d-a
Deployment/svp/user-service p-user-a ready user-service-6b9-a
Rollout/svp/gateway p-gw-a starting gateway-7c4-a
StatefulSet/svp-data/kafka p-kafka-0 starting kafka-0
StatefulSet/svp-data/s3 p-s3-0 terminating s3-0" "$(cat "$work/helper/pods-before" 2>&1)"
same "reloader.sh: the Secrets' versions without Helm's release records" "keda/keda-kafka 401
svp-data/s3-root 101
svp/gateway-env 201" "$(cat "$work/helper/secrets-before" 2>&1)"
lacks "reloader.sh: no Secret data in the snapshot" "$(cat "$work/helper"/*-before)" "$secret_data"
same "reloader.sh: the init Jobs of svp-data, not a Job whose name only starts like one" "kafka-init j-kafka-1 1
pg-bootstrap j-pg-1 1
s3-init j-s3-1 0" "$(cat "$work/helper/jobs-before" 2>&1)"
same "reloader.sh: the revisions of Rollouts gateway and web" "gateway 7
web 3" "$(cat "$work/helper/revisions-before" 2>&1)"
job_list j-pg-2 j-kafka-2 j-s3-2
helper 'init_jobs "$state/jobs-after"; jobs_ran "$state/jobs-before" "$state/jobs-after"'
same "reloader.sh: init Jobs that ran again and Succeeded pass" 0 "$rc"
same "reloader.sh: ... one ok line each" 3 "$(grep -c '^ok    Job svp-data/.* ran again and Succeeded$' <<<"$out" || true)"
job_list j-pg-2 j-kafka-1 j-s3-2 '{"failed":1}'
helper 'init_jobs "$state/jobs-after"; jobs_ran "$state/jobs-before" "$state/jobs-after"'
same "reloader.sh: an init Job the same as before and one not Succeeded fail" 1 "$rc"
has "reloader.sh: names the one the same as before" "$out" "FAIL  Job svp-data/kafka-init: the same Job as before the change"
has "reloader.sh: names the one not Succeeded" "$out" "FAIL  Job svp-data/s3-init: ran again but has not Succeeded"
has "reloader.sh: passes the one that ran again" "$out" "ok    Job svp-data/pg-bootstrap ran again and Succeeded"
job_list j-pg-2 j-kafka-2 ""
helper 'init_jobs "$state/jobs-after"; jobs_ran "$state/jobs-before" "$state/jobs-after"'
same "reloader.sh: an init Job gone fails" 1 "$rc"
has "reloader.sh: names it" "$out" "FAIL  Job svp-data/s3-init: none after the change"
rm "$lists/svp-data-jobs.batch.json"
helper "snapshot again"
same "reloader.sh: a list that fails stops snapshot" 1 "$rc"
has "reloader.sh: names it" "$out" "FAIL  list the Jobs of namespace svp-data"

if ((failures > 0)); then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
