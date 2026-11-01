# shellcheck shell=bash
# Helpers shared by the drills on the local k3d cluster svp (deploy/k8s/drills/): the API helpers of
# deploy/compose/lib.sh through Envoy (SVP_STACK=k3d), the kubectl/helm helpers of deploy/k8s/lib.sh, rpk inside the
# broker pod and Prometheus through a port-forward.
# Written for bash 3.2 (the macOS /bin/bash).
#
# Source it after setting `base` (https://api.svp.localhost:8443); the make target sets SVP_STACK=k3d and
# CURL_CA_BUNDLE to the cluster's CA. kubectl names --context k3d-svp on every call; rpk runs in container redpanda of
# pod redpanda-0 as svp-admin, with the login the container already has in its environment (RPK_USER, RPK_PASS), so no
# password passes through this machine. Topics and groups are only read.
#
# LOCAL LAB ONLY: deploy/compose/lib.sh deletes the gateway's register rate limit keys in the cluster's Valkey db 10.

[[ ${SVP_STACK:-} == k3d ]] || {
  echo "FAIL  SVP_STACK=k3d is not set; run the k8s drills through make" >&2
  exit 1
}
# shellcheck source=deploy/k8s/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# Sourced second: it creates $work and the EXIT trap that removes it. A caller that only reads (supplychain.sh) sets
# drill_read_only=1 first: deploy/compose/lib.sh deletes the register rate limit keys as it is sourced, so it is left
# out and only the private work directory is made.
if [[ ${drill_read_only:-} == 1 ]]; then
  umask 077
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
else
  # shellcheck source=deploy/compose/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../../compose/lib.sh"
fi

kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"

# now: seconds since the epoch with milliseconds (bash 3.2 has no EPOCHREALTIME).
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# rpk ARGS...: rpk inside the broker container, as svp-admin.
rpk() { kc -n svp-data exec redpanda-0 -c redpanda -- rpk "$@"; }

# Prometheus of svp-obs has no address on the host and its image no HTTP client to exec, so the drills that read it
# open a port-forward on a fixed loopback port for as long as they run: prometheus_forward starts it, prometheus_stop
# (from the caller's EXIT trap) stops it by the pid it recorded.
prom_port=19090
prom_pid=
prometheus_forward() {
  port_free "$prom_port" || fail "127.0.0.1:$prom_port is in use (another port-forward?); free it and run again"
  # kubectl itself, not the kc function: in the background a function runs in a subshell, $! would be that subshell's
  # pid, and killing it would leave kubectl running.
  kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus "$prom_port:9090" \
    >"$work/prom-forward.log" 2>&1 &
  prom_pid=$!
  wait_until 20 "port-forward to Prometheus on 127.0.0.1:$prom_port" curl -sf --max-time 2 "http://127.0.0.1:$prom_port/-/ready"
}
prometheus_stop() {
  if [ -n "$prom_pid" ]; then
    kill "$prom_pid" 2>/dev/null || true
    wait "$prom_pid" 2>/dev/null || true
    prom_pid=
  fi
}

# promql QUERY [TIME]: .data.result of an instant query (at TIME, unix seconds, when given), compact JSON on stdout.
promql() {
  local args=(--data-urlencode "query=$1")
  [ -z "${2:-}" ] || args+=(--data-urlencode "time=$2")
  curl -sf --max-time 10 "http://127.0.0.1:$prom_port/api/v1/query" "${args[@]}" | jq -c '.data.result'
}
