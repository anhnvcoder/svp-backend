#!/usr/bin/env bash
# Waits up to 10 minutes for the uptime probes, their rules and the compute cost series; prints names and numbers read.
# k8s reads kps-prometheus of cluster k3d-svp through a port-forward, compose the Prometheus of OBS=lgtm via Grafana.
# Usage, from anywhere: deploy/ci/verify-steps/uptime-cost.sh k8s|compose
# Design notes: docs/reference/ci.md.
set -uo pipefail

mode=${1:-}
case $mode in
  k8s | compose) ;;
  *)
    echo "FAIL  usage: uptime-cost.sh k8s|compose" >&2
    exit 2
    ;;
esac

# Ten minutes of rounds 15 s apart; queries take time too, so the clock bounds the wait as well as the count.
rounds=40
pause=15
deadline=$((SECONDS + 600))
probes="web api media"
# The 21 days of alert TLSCertExpiringSoon.
min_cert=$((21 * 86400))
groups="sloth-slo-alerts-svp-public-uptime svp-uptime"
sli='slo:sli_error:ratio_rate5m{sloth_slo="public-uptime"}'

work=$(mktemp -d)
pid=
cleanup() {
  [ -z "$pid" ] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  rm -rf "$work"
}
trap cleanup EXIT

kc() { kubectl --context k3d-svp "$@"; }

prom=http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus
# forward: a port-forward to Service kps-prometheus on a free loopback port, started again once it has ended.
forward() {
  local port=19190
  [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || return 0
  while nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1 && [ "$port" -lt 19210 ]; do port=$((port + 1)); done
  kc -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus "$port:9090" >/dev/null 2>&1 &
  pid=$!
  prom=http://127.0.0.1:$port
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf --max-time 2 -o /dev/null "$prom/-/ready" 2>/dev/null && return 0
    sleep 1
  done
}

# get NAME PATH [CURL_ARGS...]: a GET of the Prometheus API into $work/NAME.json; returns 1 unless it answers success.
get() {
  local name=$1 path=$2
  shift 2
  curl -sf -G --max-time 10 -o "$work/$name.json" "$@" "$prom$path" 2>/dev/null &&
    [ "$(jq -r '.status' "$work/$name.json" 2>/dev/null)" = success ]
}

# query NAME EXPR: an instant query into $work/NAME.json.
query() { get "$1" /api/v1/query --data-urlencode "query=$2"; }

# value NAME [PROBE]: the value of the sample of NAME (with label probe=PROBE when given); empty when there is none.
value() {
  jq -r --arg p "${2:-}" '[.data.result[] | select($p == "" or .metric.probe == $p) | .value[1]] | first // ""' \
    "$work/$1.json" 2>/dev/null
}

# states ALERT: the states of ALERT in $work/alerts.json with their severity ("firing page, pending ticket"); empty
# when it is inactive.
states() {
  jq -r --arg a "$1" '[.data.result[].metric | select(.alertname == $a) | [.alertstate, (.severity // empty)]
    | join(" ")] | unique | join(", ")' "$work/alerts.json" 2>/dev/null
}

# health GROUP: the health values of the rules of GROUP in $work/rules.json, "ok" once every rule is evaluated without
# error; empty when the group is absent.
health() {
  jq -r --arg g "$1" '[.data.groups[] | select(.name == $g) | .rules[].health] | unique | join(",")' \
    "$work/rules.json" 2>/dev/null
}

# above VALUE MIN: whether VALUE is a number greater than MIN.
above() { awk -v v="$1" -v m="$2" 'BEGIN { exit !(v ~ /^-?[0-9][0-9.e+-]*$/ && v + 0 > m + 0) }'; }

# zero VALUE: whether VALUE is a number equal to 0.
zero() { awk -v v="$1" 'BEGIN { exit !(v ~ /^-?[0-9][0-9.e+-]*$/ && v + 0 == 0) }'; }

# unfired STATES: whether STATES has no firing alert.
unfired() { case $1 in *firing*) return 1 ;; esac; }

# result CONDITION HOLDS VALUE: a row of the table; a condition that does not hold also goes to $work/failed.
result() {
  printf '  %-62s %s\n' "$1" "${3:-none}" >>"$work/table"
  [ "$2" = yes ] || printf '%s: last read %s\n' "$1" "${3:-none}" >>"$work/failed"
}

# holds TEST...: yes when TEST succeeds, no otherwise.
holds() { if "$@"; then echo yes; else echo no; fi; }

# check: one round of every condition into $work/table and $work/failed.
check() {
  local p v g
  : >"$work/table"
  : >"$work/failed"
  if ! query success 'min by (probe) (probe_success{job="blackbox-http"})'; then
    result "Prometheus answers a query" no "no answer"
    return
  fi
  for p in $probes; do
    v=$(value success "$p")
    result "probe_success{probe=\"$p\"} = 1" "$(holds [ "$v" = 1 ])" "$v"
  done
  if [ "$mode" = k8s ]; then
    query cert 'min by (probe) (probe_ssl_earliest_cert_expiry{job="blackbox-http"}) - time()' || : >"$work/cert.json"
    for p in $probes; do
      v=$(value cert "$p")
      result "seconds to the cert expiry of probe $p > 21 days" "$(holds above "$v" "$min_cert")" "$v"
    done
    query node 'cluster:svp_node_cost_usd_per_hour:sum' || : >"$work/node.json"
    v=$(value node)
    result "cluster:svp_node_cost_usd_per_hour:sum > 0" "$(holds above "$v" 0)" "$v"
    query ns 'namespace:svp_compute_cost_usd_per_hour:sum{namespace="svp"}' || : >"$work/ns.json"
    v=$(value ns)
    result "namespace:svp_compute_cost_usd_per_hour:sum{namespace=\"svp\"} > 0" "$(holds above "$v" 0)" "$v"
  fi
  query sli "$sli" || : >"$work/sli.json"
  v=$(value sli)
  result "$sli = 0" "$(holds zero "$v")" "$v"
  get rules /api/v1/rules || : >"$work/rules.json"
  for g in $groups; do
    v=$(health "$g")
    result "rule health of group $g = ok" "$(holds [ "$v" = ok ])" "$v"
  done
  if query alerts 'ALERTS{alertname=~"UptimeProbesAbsent|PublicUptimeBudgetBurn"}'; then
    v=$(states UptimeProbesAbsent)
    result "no alert UptimeProbesAbsent firing" "$(holds unfired "$v")" "${v:-inactive}"
    v=$(states PublicUptimeBudgetBurn)
    v=${v:-inactive}
  else
    result "no alert UptimeProbesAbsent firing" no "no answer"
    v="no answer"
  fi
  # Shown, not checked: probes that failed while the stack was built stay in the 30m to 3d windows of this alert for
  # the whole short life of the stack.
  result "alert PublicUptimeBudgetBurn (shown only)" yes "$v"
}

round=1
while :; do
  [ "$mode" = compose ] || forward
  check
  if [ ! -s "$work/failed" ]; then
    echo "uptime-cost ($mode): every condition holds, round $round"
    cat "$work/table"
    exit 0
  fi
  [ "$round" -lt "$rounds" ] && [ "$SECONDS" -lt "$deadline" ] || break
  round=$((round + 1))
  sleep "$pause"
done
echo "uptime-cost ($mode): not every condition held within 10 minutes; the last read, round $round:"
cat "$work/table"
while IFS= read -r line; do echo "FAIL  uptime-cost: $line"; done <"$work/failed"
exit 1
