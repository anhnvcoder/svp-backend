#!/usr/bin/env bash
# Tests for uptime-cost.sh using fake kubectl, curl, nc and sleep on PATH: every condition missing or wrong, the wait.
# Runs on macOS and Linux: no network, no Docker, no cluster.
# Usage, from anywhere: deploy/ci/verify-steps/uptime-cost-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
has() { if grep -qF -- "$3" "$work/$1.log"; then ok "$1: $2"; else fail "$1: $2"; fi; }
lacks() { if grep -qF -- "$3" "$work/$1.log"; then fail "$1: $2"; else ok "$1: $2"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_CALLS"
[ "${FAKE_KUBECTL_FAIL:-}" != 1 ] || { echo "The connection to the server was refused" >&2; exit 1; }
case "$*" in
  "--context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus 191"[0-9][0-9]":9090")
    touch "$FAKE_FORWARDED" && exec sleep 30 ;;
  *) exit 2 ;;
esac
EOF
# Answers by the query's metric, or the rules' path, from $FAKE_DIR/<name>.json or $FAKE_DIR/r<round>/<name>.json.
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
out= query= url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    --data-urlencode) query=${2#query=}; shift ;;
    http://*) url=$1 ;;
  esac
  shift
done
echo "curl $url $query" >>"$FAKE_CALLS"
case $url in
  http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus/api/v1/query) ;;
  http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus/api/v1/rules) ;;
  http://127.0.0.1:191[0-9][0-9]/api/v1/query | http://127.0.0.1:191[0-9][0-9]/api/v1/rules)
    [ -f "$FAKE_FORWARDED" ] || exit 7 ;;
  http://127.0.0.1:191[0-9][0-9]/-/ready) [ -f "$FAKE_FORWARDED" ] && exit 0 || exit 7 ;;
  *) exit 7 ;;
esac
case $url,$query in
  */api/v1/rules,) name=rules ;;
  *,*probe_success*) name=success ;;
  *,*probe_ssl_earliest_cert_expiry*) name=cert ;;
  *,*cluster:svp_node_cost_usd_per_hour:sum*) name=node ;;
  *,*namespace:svp_compute_cost_usd_per_hour:sum*) name=ns ;;
  *,'slo:sli_error:ratio_rate5m{sloth_slo="public-uptime"}') name=sli ;;
  *,ALERTS*) name=alerts ;;
  *) exit 22 ;;
esac
round=$(cat "$FAKE_ROUND" 2>/dev/null || echo 1)
file=$FAKE_DIR/r$round/$name.json
[ -f "$file" ] || file=$FAKE_DIR/$name.json
[ -f "$file" ] || exit 22
cat "$file" >"$out"
EOF
cat >"$work/bin/nc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
# Waits nothing for the script: counts its pauses between rounds, each the start of the next round.
cat >"$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
[ "$1" != 1 ] || exit 0
[ "$1" = 15 ] || exec /bin/sleep "$@"
echo $(($(cat "$FAKE_ROUND" 2>/dev/null || echo 1) + 1)) >"$FAKE_ROUND"
EOF
chmod 755 "$work/bin/"*

# vector [LABELS VALUE]...: a Prometheus instant query answer with one sample per pair; LABELS is a JSON object.
vector() {
  local samples=()
  while [ $# -gt 0 ]; do
    samples+=("{\"metric\": $1, \"value\": [1700000000, \"$2\"]}")
    shift 2
  done
  local IFS=,
  echo "{\"status\": \"success\", \"data\": {\"resultType\": \"vector\", \"result\": [${samples[*]:-}]}}"
}

# rules [GROUP HEALTHS]...: a /api/v1/rules answer with one group per pair; HEALTHS is each rule's health, by commas.
rules() {
  local groups=()
  while [ $# -gt 0 ]; do
    groups+=("$(jq -cn --arg g "$1" --arg h "$2" '{name: $g, rules: [$h | split(",")[] | {health: .}]}')")
    shift 2
  done
  local IFS=,
  echo "{\"status\": \"success\", \"data\": {\"groups\": [${groups[*]:-}]}}"
}

slo='{"sloth_id": "svp-public-uptime", "sloth_service": "svp", "sloth_slo": "public-uptime", "sloth_window": "5m"}'
# fixture DIR: the answers under which every condition holds, into DIR. A group the step does not read is still
# unevaluated, and two alerts it does not check are firing.
fixture() {
  mkdir -p "$1"
  vector '{"probe": "web"}' 1 '{"probe": "api"}' 1 '{"probe": "media"}' 1 >"$1/success.json"
  vector '{"probe": "web"}' 7776000 '{"probe": "api"}' 7776000 '{"probe": "media"}' 2592000 >"$1/cert.json"
  vector '{}' 0.0832 >"$1/node.json"
  vector '{"namespace": "svp"}' 0.0121 >"$1/ns.json"
  vector "$slo" 0 >"$1/sli.json"
  rules sloth-slo-sli-recordings-svp-public-uptime unknown,unknown sloth-slo-alerts-svp-public-uptime ok,ok \
    svp-uptime ok,ok,ok >"$1/rules.json"
  vector '{"alertname": "TLSCertExpiringSoon", "alertstate": "firing", "severity": "ticket"}' 1 \
    '{"alertname": "PublicUptimeBudgetBurn", "alertstate": "firing", "severity": "page"}' 1 >"$1/alerts.json"
}

# run NAME MODE [DIR [VAR=VALUE...]]: runs uptime-cost.sh MODE with the fake tools and the answers of DIR ($work/NAME
# by default).
run() {
  local name=$1 mode=$2 dir=${3:-$work/$1} rc=0
  shift 2
  [ $# -eq 0 ] || shift
  rm -f "$work/forwarded" "$work/round"
  : >"$work/$name.calls"
  env PATH="$work/bin:$PATH" FAKE_DIR="$dir" FAKE_CALLS="$work/$name.calls" FAKE_FORWARDED="$work/forwarded" \
    FAKE_ROUND="$work/round" "$@" "$here/uptime-cost.sh" "$mode" >"$work/$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
same() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (want $2, got $3)"; fi; }
pauses() { echo $(($(cat "$work/round" 2>/dev/null || echo 1) - 1)); }
called() { if grep -qE -- "$3" "$work/$1.calls"; then ok "$1: $2"; else fail "$1: $2"; fi; }

fixture "$work/pass"
same "k8s: every condition holds: exit 0" 0 "$(run pass k8s)"
has pass "the table has each value" '  probe_success{probe="media"} = 1'
has pass "with the cost of namespace svp" '0.0121'
has pass "and the SLI of the last 5 minutes" 'slo:sli_error:ratio_rate5m{sloth_slo="public-uptime"} = 0'
has pass "and the health of the group of the burn alert" "rule health of group sloth-slo-alerts-svp-public-uptime = ok"
has pass "UptimeProbesAbsent is inactive" "no alert UptimeProbesAbsent firing"
has pass "a firing PublicUptimeBudgetBurn is shown with its severity, and the step passes" "firing page"
lacks pass "an alert that is not one of the two is left out" "TLSCertExpiringSoon"
lacks pass "a group the step does not read is left out" "sli-recordings"
has pass "it says every condition holds" "uptime-cost (k8s): every condition holds, round 1"
called pass "Prometheus is reached through a port-forward on context k3d-svp" \
  '^kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus 19190:9090$'
called pass "the rules are read through the port-forward" '^curl http://127.0.0.1:19190/api/v1/rules $'
lacks pass "no URL of a probe is printed" "http"
same "pass: no pause" 0 "$(pauses)"

same "compose: every condition holds: exit 0" 0 "$(run compose-pass compose "$work/pass")"
has compose-pass "it reads Prometheus through Grafana" "uptime-cost (compose): every condition holds"
has compose-pass "the SLI row is on compose too" 'slo:sli_error:ratio_rate5m{sloth_slo="public-uptime"} = 0'
has compose-pass "the rule health rows are on compose too" "rule health of group svp-uptime = ok"
lacks compose-pass "no cert row on compose" "cert expiry"
lacks compose-pass "no cost row on compose" "svp_node_cost"
if grep -q '^kubectl' "$work/compose-pass.calls"; then fail "compose-pass: kubectl is not called"; else
  ok "compose-pass: kubectl is not called"; fi
called compose-pass "the query goes to the datasource proxy of Grafana" \
  '^curl http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus/api/v1/query '
called compose-pass "the rules too" '^curl http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus/api/v1/rules $'

# shown NAME MODE ALERTS SHOWN: a run whose alerts are ALERTS passes and shows PublicUptimeBudgetBurn as SHOWN.
shown() {
  rm -rf "${work:?}/$1"
  fixture "$work/$1"
  echo "$3" >"$work/$1/alerts.json"
  same "$1: exit 0" 0 "$(run "$1" "$2")"
  if grep -qE "^  alert PublicUptimeBudgetBurn \(shown only\) +$4\$" "$work/$1.log"; then
    ok "$1: shown as $4"
  else
    fail "$1: shown as $4"
  fi
}
shown burn-both compose \
  "$(vector '{"alertname": "PublicUptimeBudgetBurn", "alertstate": "firing", "severity": "page"}' 1 \
    '{"alertname": "PublicUptimeBudgetBurn", "alertstate": "firing", "severity": "ticket"}' 1)" \
  "firing page, firing ticket"
shown burn-inactive k8s "$(vector)" inactive
shown absent-pending k8s \
  "$(vector '{"alertname": "UptimeProbesAbsent", "alertstate": "pending", "severity": "page"}' 1)" inactive
has absent-pending "a pending UptimeProbesAbsent is shown and does not fail the step" "pending page"

# broken NAME MODE WANT FILE CONTENT [VAR=VALUE...]: a run whose answer FILE is CONTENT (absent: the query fails)
# fails naming WANT.
broken() {
  rm -rf "${work:?}/$1"
  fixture "$work/$1"
  if [ "$5" = absent ]; then rm -f "$work/$1/$4"; else echo "$5" >"$work/$1/$4"; fi
  same "$1: exit 1" 1 "$(run "$1" "$2" "$work/$1" "${@:6}")"
  has "$1" "the failure names the condition" "FAIL  uptime-cost: $3"
  has "$1" "the last read is printed" "not every condition held within 10 minutes; the last read, round 40:"
  same "$1: it waited 39 pauses" 39 "$(pauses)"
}
for p in web api media; do
  others=()
  for o in web api media; do [ "$o" = "$p" ] || others+=("{\"probe\": \"$o\"}" 1); done
  broken "probe-$p-missing" k8s "probe_success{probe=\"$p\"} = 1: last read none" success.json \
    "$(vector "${others[@]}")"
  broken "probe-$p-down" compose "probe_success{probe=\"$p\"} = 1: last read 0" success.json \
    "$(vector "${others[@]}" "{\"probe\": \"$p\"}" 0)"
done
broken cert-missing k8s "seconds to the cert expiry of probe media > 21 days: last read none" cert.json \
  "$(vector '{"probe": "web"}' 7776000 '{"probe": "api"}' 7776000)"
broken cert-soon k8s "seconds to the cert expiry of probe api > 21 days: last read 1814400" cert.json \
  "$(vector '{"probe": "web"}' 7776000 '{"probe": "api"}' 1814400 '{"probe": "media"}' 7776000)"
broken cert-unread k8s "seconds to the cert expiry of probe web > 21 days: last read none" cert.json absent
broken node-missing k8s "cluster:svp_node_cost_usd_per_hour:sum > 0: last read none" node.json "$(vector)"
broken node-zero k8s "cluster:svp_node_cost_usd_per_hour:sum > 0: last read 0" node.json "$(vector '{}' 0)"
broken ns-missing k8s 'namespace:svp_compute_cost_usd_per_hour:sum{namespace="svp"} > 0: last read none' ns.json absent
broken ns-zero k8s 'namespace:svp_compute_cost_usd_per_hour:sum{namespace="svp"} > 0: last read 0' ns.json \
  "$(vector '{"namespace": "svp"}' 0)"
want_sli='slo:sli_error:ratio_rate5m{sloth_slo="public-uptime"} = 0: last read'
broken sli-missing k8s "$want_sli none" sli.json "$(vector)"
broken sli-errors compose "$want_sli 0.0333" sli.json "$(vector "$slo" 0.0333)"
broken sli-unread compose "$want_sli none" sli.json absent
broken group-alerts-missing k8s "rule health of group sloth-slo-alerts-svp-public-uptime = ok: last read none" \
  rules.json "$(rules svp-uptime ok,ok,ok)"
broken group-uptime-unevaluated compose "rule health of group svp-uptime = ok: last read ok,unknown" rules.json \
  "$(rules sloth-slo-alerts-svp-public-uptime ok,ok svp-uptime ok,unknown,ok)"
broken group-uptime-error k8s "rule health of group svp-uptime = ok: last read err,ok" rules.json \
  "$(rules sloth-slo-alerts-svp-public-uptime ok,ok svp-uptime ok,err,ok)"
broken group-uptime-empty k8s "rule health of group svp-uptime = ok: last read none" rules.json \
  "$(rules sloth-slo-alerts-svp-public-uptime ok,ok svp-uptime '')"
broken rules-unread compose "rule health of group sloth-slo-alerts-svp-public-uptime = ok: last read none" \
  rules.json absent
has rules-unread "both groups fail when the rules are not read" \
  "FAIL  uptime-cost: rule health of group svp-uptime = ok"
broken rules-error k8s "rule health of group svp-uptime = ok: last read none" rules.json '{"status": "error"}'
alert="no alert UptimeProbesAbsent firing: last read"
broken absent-firing k8s "$alert firing page" alerts.json \
  "$(vector '{"alertname": "UptimeProbesAbsent", "alertstate": "firing", "severity": "page"}' 1)"
broken alerts-unread compose "$alert no answer" alerts.json absent
if grep -qE '^  alert PublicUptimeBudgetBurn \(shown only\) +no answer$' "$work/alerts-unread.log"; then
  ok "alerts-unread: PublicUptimeBudgetBurn is shown as not read"; else
  fail "alerts-unread: PublicUptimeBudgetBurn is shown as not read"; fi
lacks alerts-unread "and does not fail the step" "FAIL  uptime-cost: alert PublicUptimeBudgetBurn"
broken prometheus-down compose "Prometheus answers a query: last read no answer" success.json absent
broken cluster-down k8s "Prometheus answers a query: last read no answer" success.json absent FAKE_KUBECTL_FAIL=1
same "cluster-down: the port-forward is started again in each round" 40 \
  "$(grep -c '^kubectl --context k3d-svp -n svp-obs port-forward ' "$work/cluster-down.calls")"
broken prometheus-error k8s "Prometheus answers a query: last read no answer" success.json '{"status": "error"}'
lacks node-zero "only the condition that does not hold fails" "FAIL  uptime-cost: probe_success"
lacks sli-errors "a failing SLI fails only its own row" "FAIL  uptime-cost: rule health"

# Right after the build the recording rules have no series and the rules are unevaluated: the step waits for them.
fixture "$work/late"
vector >"$work/late/node.json"
vector >"$work/late/sli.json"
fixture "$work/late/r2"
vector "$slo" 0.0167 >"$work/late/r2/sli.json"
fixture "$work/late/r3"
vector >"$work/late/r3/ns.json"
rules sloth-slo-alerts-svp-public-uptime unknown,ok svp-uptime ok,ok,ok >"$work/late/r3/rules.json"
fixture "$work/late/r4"
same "late: the cost series, the SLI and the rules coming in the fourth round: exit 0" 0 "$(run late k8s)"
has late "it says in which round" "every condition holds, round 4"
same "late: three pauses" 3 "$(pauses)"
lacks late "no FAIL line once it holds" "FAIL"

for arg in "" k3d; do
  rc=0
  env PATH="$work/bin:$PATH" "$here/uptime-cost.sh" $arg >"$work/usage.log" 2>&1 </dev/null || rc=$?
  same "usage: '$arg' exits 2" 2 "$rc"
  has usage "it says the usage" "FAIL  usage: uptime-cost.sh k8s|compose"
done

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
