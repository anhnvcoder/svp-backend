#!/usr/bin/env bash
# The k6 load test of a cloud cluster: 20 pods of profile cloud, 1 000 feed requests a second (1 250 req/s in all) held
# at least 10 minutes. The learner runs it, with the cloud cluster's kubectl context; never from make. Needs kubectl and
# jq. A k3d-* context (the 16 GB laptop) is refused before any kubectl call.
# Design notes: docs/reference/compose.md.

# Usage: deploy/k6/cloud/run.sh --context <ctx> --domain <d> [--pods <n>] [--ramp <t>] [--hold <t>] start|logs|delete
#   --domain         the web's public host (the API is api.<domain>), as Envoy's listeners and certificates name them
#   --pods, --ramp, --hold  as in render.sh

# start: renders (render.sh, --ca-file the CA of Secret svp-edge/svp-edge-tls) and applies namespace svp-load, the
# scripts' ConfigMap and Job svp-k6; refuses while that Job exists. logs: after the Job ends, each pod's summary into
# .k6/cloud-<time>/pod-<i>.json and a table; exits 1 on a missing pod or summary, or a summary that looks like it holds
# a token, cookie or password (deleted). delete: deletes namespace svp-load (the Job, its pods and their logs).

# Before start: the stack runs on the cloud cluster with at least 30 READY videos (fewer and most views stop at the
# gateway's one-per-minute rule, RL-3), nothing else loads it, the gateway takes the client's address from
# CloudFront-Viewer-Address (RL-1, RL-7) and Envoy's NetworkPolicy admits namespace svp-load, as the eks platform sets.

# Pass: in every pod, every threshold passed and dropped_iterations 0; server-side p95/p99 read from Prometheus over
# the hold window are recorded with the pods' numbers as the run's result.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)

die() {
  echo "FAIL  $1" >&2
  exit 1
}
usage() {
  sed -n 's/^# Usage: //p' "$0" >&2
  exit 2
}

ctx='' domain='' render_args=() cmd=''
while [ $# -gt 0 ]; do
  case $1 in
    --context) [ $# -ge 2 ] || usage; ctx=$2; shift 2 ;;
    --domain) [ $# -ge 2 ] || usage; domain=$2; shift 2 ;;
    --pods | --ramp | --hold) [ $# -ge 2 ] || usage; render_args+=("$1" "$2"); shift 2 ;;
    start | logs | delete) cmd=$1; shift ;;
    *) usage ;;
  esac
done
[ -n "$cmd" ] || usage
# The guard comes before any kubectl call: an empty context would be kubectl's current one, which may be k3d's.
[ -n "$ctx" ] || die "no --context: name the cloud cluster's kubectl context"
case $ctx in
  k3d-*) die "context $ctx is a local k3d cluster; this load test runs on the cloud cluster only" ;;
esac
command -v jq >/dev/null || die "jq not found"
kubectl config get-contexts -o name | grep -qxF -- "$ctx" || die "no context $ctx in the kubeconfig"
kc() { kubectl --context "$ctx" "$@"; }

case $cmd in
  start)
    [ -n "$domain" ] || die "start needs --domain"
    if kc -n svp-load get job svp-k6 >/dev/null 2>&1; then
      die "Job svp-load/svp-k6 exists; read it (logs) and delete it first"
    fi
    envoy_ip=$(kc -n envoy-gateway-system get service -l gateway.envoyproxy.io/owning-gateway-name=svp \
      -o jsonpath='{.items[*].spec.clusterIP}')
    [[ $envoy_ip =~ ^[0-9a-f.:]+$ ]] || die "not exactly one Service of Gateway svp in envoy-gateway-system (got '$envoy_ip')"
    # Envoy's certificate comes from the cluster's internal CA. Only key ca.crt is read: the Secret also holds Envoy's
    # private key, which never leaves the cluster.
    ca_b64=$(kc -n svp-edge get secret svp-edge-tls -o jsonpath='{.data.ca\.crt}') ||
      die "cannot read Secret svp-edge/svp-edge-tls, Envoy's certificate (has cert-manager issued it?)"
    [ -n "$ca_b64" ] || die "Secret svp-edge/svp-edge-tls has no key ca.crt (not issued by the internal CA?)"
    ca_file=$(mktemp) || die "create a temporary file"
    trap 'rm -f "$ca_file"' EXIT
    base64 --decode <<<"$ca_b64" >"$ca_file" || die "key ca.crt of Secret svp-edge/svp-edge-tls is not base64"
    bash "$here/render.sh" --domain "$domain" --envoy-ip "$envoy_ip" --ca-file "$ca_file" \
      ${render_args[@]+"${render_args[@]}"} |
      kc apply -f -
    echo "ok    Job svp-load/svp-k6 started (Envoy $envoy_ip, https://api.$domain and https://$domain)"
    echo "watch: kubectl --context $ctx -n svp-load get pods -w"
    ;;
  logs)
    out=$repo/.k6/cloud-$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$out"
    pods=$(kc -n svp-load get pods -l batch.kubernetes.io/job-name=svp-k6 -o json |
      jq -r '.items[] | "\(.metadata.annotations["batch.kubernetes.io/job-completion-index"]) \(.metadata.name)"')
    [ -n "$pods" ] || die "no pod of Job svp-load/svp-k6"
    rc=0
    completions=$(kc -n svp-load get job svp-k6 -o jsonpath='{.spec.completions}')
    found=$(grep -c . <<<"$pods" || :)
    if [ "$found" != "$completions" ]; then
      echo "FAIL  Job has $found of $completions pod(s)" >&2
      rc=1
    fi
    while read -r i pod; do
      kc -n svp-load logs "$pod" | sed -n 's/^svp-k6-summary //p' >"$out/pod-$i.json"
      [ -s "$out/pod-$i.json" ] || {
        echo "FAIL  pod $i ($pod) printed no summary (still running, or k6 failed: kubectl --context $ctx -n svp-load logs $pod)" >&2
        rc=1
      }
    done <<<"$pods"
    # As deploy/k6/load.sh checks its summary.json: a JWT, the session cookie, the words a header or field of a secret
    # carries. handleSummary never writes setup's data, so a match means it changed; the file goes, never published.
    if leaks=$(grep -rIlE -i 'eyJ[A-Za-z0-9_-]{8,}|svp_sid|bearer|password|cookie|token|set-cookie' "$out"); then
      while IFS= read -r f; do rm -f "$f"; done <<<"$leaks"
      echo "FAIL  a summary holds a token, cookie or password; deleted: ${leaks//$repo\//}" >&2
      rc=1
    fi
    echo "summaries in ${out#"$repo"/}"
    for f in "$out"/pod-*.json; do
      [ -s "$f" ] || continue
      jq -r --arg f "$(basename "$f" .json)" '
        "\($f): thresholds \(if .thresholds_ok then "ok" else "FAILED" end), dropped_iterations \(.dropped_iterations), " +
        "429 \([.routes[].rate_limited] | add), explore p99 \(.routes[] | select(.route == "/feed/explore") | .p99_ms) ms"' "$f"
    done
    exit "$rc"
    ;;
  delete)
    kc delete namespace svp-load --ignore-not-found
    ;;
esac
