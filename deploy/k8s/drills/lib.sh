# shellcheck shell=bash
# Helpers of the drill traffic on the local k3d cluster svp (deploy/k8s/drills/traffic.sh): the API helpers of
# deploy/compose/lib.sh through Envoy (SVP_STACK=k3d) and the kubectl/helm helpers of deploy/k8s/lib.sh. The drills
# themselves are Chainsaw tests (deploy/k8s/drills/run.sh).
# Written for bash 3.2 (the macOS /bin/bash).
#
# Source it after setting `base` (https://api.svp.localhost:8443); the make target sets SVP_STACK=k3d and
# CURL_CA_BUNDLE to the cluster's CA. kubectl names --context k3d-svp on every call.
#
# LOCAL LAB ONLY: deploy/compose/lib.sh deletes the gateway's register rate limit keys in the cluster's Valkey db 10.

[[ ${SVP_STACK:-} == k3d ]] || {
  echo "FAIL  SVP_STACK=k3d is not set; run the k8s drills through make" >&2
  exit 1
}
# shellcheck source=deploy/k8s/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# Sourced second: it creates $work and the EXIT trap that removes it.
# shellcheck source=deploy/compose/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../compose/lib.sh"

kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"

# now: seconds since the epoch with milliseconds (bash 3.2 has no EPOCHREALTIME).
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
