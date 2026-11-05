# shellcheck shell=bash
# Helpers of the drill tests that spend the gateway's login-ip bucket on cluster svp: rl-1 and web-8 of
# deploy/k8s/drills/threats/. A script of such a test sources this file from its test's folder (Chainsaw runs it there):
# `. ./ratelimit.sh` in rl-1, `. ../rl-1/ratelimit.sh` in web-8. Written for bash 3.2 (the macOS /bin/bash).
#
# Valkey (the gateway's db 10) is only read: SCAN, PTTL, MGET, TIME. Prometheus is read through the test's port-forward
# on 127.0.0.1:19090 (templates/port-forward.yaml). Every file the helpers write is private (umask 077) and lives in the
# test's own work directory, $work: .k8s/drills/<folder of the test> (ignored by git), made by the test's first step
# and removed by its cleanup.
#
# The script's environment needs CALLER_KUBECONFIG, the caller's kubeconfig (empty: ~/.kube/config): Chainsaw sets
# KUBECONFIG to its own copy of the cluster (templates/probe-up.yaml says why). kubectl always names context k3d-svp;
# curl takes the cluster's CA from CURL_CA_BUNDLE, which the make target sets.

umask 077
: "${CALLER_KUBECONFIG?the env of the script sets CALLER_KUBECONFIG to the caller KUBECONFIG}"
export KUBECONFIG="$CALLER_KUBECONFIG"

work="$(git rev-parse --show-toplevel)/.k8s/drills/$(basename "$PWD")"

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  exit 1
}
kc() { kubectl --context k3d-svp "$@"; }

# work_ready: the work directory exists (the test's first step made it); fails otherwise.
work_ready() { [[ -d $work ]] || fail "the test's work directory ${work#"$(git rev-parse --show-toplevel)"/} exists (made by its first step)"; }

# The limit of class login-ip (services/gateway/internal/ratelimit/ratelimit.go: 60 per minute, burst 30, so one
# request refilled per second).
rl1_burst=30
# An attempt in which a login decision fell back did not test the shared bucket alone: it is printed and does not
# count, and the test tries again once the login-ip bucket is full, up to this many attempts in all.
rl1_attempts=3
# The interval of class login-email (10 per hour): a new login-email key holds the time of its decision plus this.
login_email_interval_ms=360000
# The fallback login decisions of the gateway pods: one set of series per process, told apart by label instance.
rl1_fallback_series='svp_ratelimit_decisions_total{job="gateway",class=~"login-ip|login-email",store="fallback"}'
prom_port=19090

# valkey ARGS...: valkey-cli on the gateway's db 10 inside the Valkey pod (it has no address on the host); only reads.
valkey() { kc -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 10 "$@"; }

# valkey_now: the seconds of Valkey's clock, which is the clock of every pod of the cluster (one Docker VM), the
# gateway's and Prometheus' included.
valkey_now() { valkey TIME | sed -n 1p; }

# email_hash EMAIL: the part of the login-email key the gateway derives from EMAIL (ratelimit.LoginEmailID: first 32
# hex characters of the SHA-256 of the lower-cased email).
email_hash() { printf '%s' "$1" | tr 'A-Z' 'a-z' | shasum -a 256 | cut -c1-32; }

# buckets_full ID ATTEMPT: waits until no login-ip bucket is left in Valkey (GCRA: a key lives until its bucket is full
# again, at most 30 s; none is deleted), at most 45 s; prints the ok line of ID's attempt ATTEMPT, fails otherwise.
buckets_full() {
  local deadline=$((SECONDS + 45))
  until valkey --scan --pattern 'svp:gw:rl:login-ip:*' >"$work/ip-keys" && [[ ! -s $work/ip-keys ]]; do
    ((SECONDS < deadline)) || fail "$1: every login-ip bucket in Valkey db 10 expired within 45 s (still: $(tr '\n' ' ' <"$work/ip-keys"))"
    sleep 2
  done
  ok "$1: attempt $2: no login-ip bucket in Valkey db 10: the bucket of the address the gateway sees is full"
}

# promql QUERY [TIME]: .data.result of an instant query (at TIME, unix seconds, when given), compact JSON on stdout.
promql() {
  local args=(--data-urlencode "query=$1")
  [ -z "${2:-}" ] || args+=(--data-urlencode "time=$2")
  curl -sf --max-time 10 "http://127.0.0.1:$prom_port/api/v1/query" "${args[@]}" | jq -c '.data.result'
}

# gateway_pods: the gateway's server pods as one JSON line, sorted by name: name, uid, phase, whether being deleted, the
# restart count of each container. Pods that have ended (Succeeded, Failed: an evicted pod stays so) are left out, as
# no process of theirs runs. Each gateway process pushes its rate limit decisions under an instance label of its own
# (service.instance.id, random per process: internal/telemetry), which names no pod, so the processes of an attempt are
# told by their pods instead: the same line before and after the burst, every pod Running and none being deleted, means
# the same processes ran all along. A new pod, an ended, deleted or terminating one, or a restarted container changes it.
gateway_pods() {
  kc -n svp get pods -l app.kubernetes.io/name=gateway,app.kubernetes.io/component=server -o json |
    jq -c '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | {name: .metadata.name, uid: .metadata.uid, phase: .status.phase,
      deleting: (.metadata.deletionTimestamp != null), restarts: [.status.containerStatuses[]?.restartCount]}]
      | sort_by(.name)'
}

# pods_summary LINE: a line of gateway_pods for people: each pod's name, phase, restarts, and whether being deleted.
pods_summary() {
  jq -r 'map("\(.name) \(.phase) restarts \(.restarts | map(tostring) | join("/"))\(if .deleting then " being deleted" else "" end)")
    | join(", ")' <<<"${1:-[]}" 2>/dev/null || echo "not read"
}

# rl1_fallback: whether a login decision of the last burst (Valkey's time rl1_t_start before it, rl1_t_end after it;
# the gateway's pods as it started, rl1_pods_before) fell back to a gateway pod's in-memory limiter. Each pod counts its
# decisions in svp_ratelimit_decisions_total by store and pushes them every 15 s, each sample stamped with the time it
# was read. The attempt is judged only when the gateway's pods (gateway_pods) were the same before the burst and once
# every one of them has pushed after it, all Running and none being deleted: then exactly as many instances as pods
# have a sample stamped after the burst (a process that is gone pushes nothing new, and one more instance than pods is a
# process the pods do not account for), and the fallback login decisions of each in its latest sample are compared with
# those in its last sample before the burst (an instant query at rl1_t_start), instance by instance. Sets rl1_fell to 0
# when they are equal on every one (rl1_pods: how many), else to what grew or why it cannot be told.
rl1_fallback() {
  local pods deadline fresh n after before now i d grew=0 on=0 unknown=0
  local since=$((rl1_t_end + 1))
  if [[ -z $rl1_pods_before ]] ||
    ! jq -e 'length > 0 and all(.[]; .phase == "Running" and (.deleting | not))' <<<"$rl1_pods_before" >/dev/null; then
    rl1_fell="unknown: the gateway's pods as the burst started were not read, or not all Running and kept ($(pods_summary "$rl1_pods_before"))"
    return 0
  fi
  pods=$(jq length <<<"$rl1_pods_before")
  deadline=$((SECONDS + 90))
  while :; do
    fresh=$(promql "min by (instance) (timestamp($rl1_fallback_series))") || fresh='[]'
    n=$(jq --argjson since "$since" '[.[] | select((.value[1] | tonumber) > $since)] | length' <<<"$fresh") || n=0
    ((n >= pods)) && break
    if ((SECONDS >= deadline)); then
      rl1_fell="unknown: $n of the $pods gateway pods pushed their rate limit decisions after the burst within 90 s"
      return 0
    fi
    sleep 3
  done
  now=$(gateway_pods) || now=
  if [[ $now != "$rl1_pods_before" ]]; then
    rl1_fell="unknown: the gateway's pods changed during the attempt (before the burst: $(pods_summary "$rl1_pods_before"); after it: $(pods_summary "$now")), so their samples cannot stand for one another"
    return 0
  fi
  if ((n != pods)); then
    rl1_fell="unknown: $n instances pushed rate limit decisions after the burst, for $pods gateway pods that ran all along"
    return 0
  fi
  if ! after=$(promql "sum by (instance) ($rl1_fallback_series)") ||
    ! before=$(promql "sum by (instance) ($rl1_fallback_series)" "$rl1_t_start"); then
    rl1_fell="unknown: Prometheus did not answer the queries of the fallback decisions"
    return 0
  fi
  jq -rn --argjson f "$fresh" --argjson a "$after" --argjson b "$before" --argjson since "$since" '
    (reduce $b[] as $x ({}; .[$x.metric.instance] = ($x.value[1] | tonumber))) as $was |
    (reduce $a[] as $x ({}; .[$x.metric.instance] = ($x.value[1] | tonumber))) as $now |
    $f[] | select((.value[1] | tonumber) > $since) | .metric.instance as $i |
    "\($i) \(if $was[$i] == null or $now[$i] == null then "none" else $now[$i] - $was[$i] end)"' >"$work/rl1-fallback" ||
    {
      rl1_fell="unknown: read the fallback decisions per pod from Prometheus' answers"
      return 0
    }
  while read -r i d; do
    if [[ ! $d =~ ^[0-9]+$ ]]; then
      unknown=$((unknown + 1))
    elif ((d > 0)); then
      on=$((on + 1)) grew=$((grew + d))
    fi
  done <"$work/rl1-fallback"
  if ((unknown > 0)); then
    rl1_fell="unknown: $unknown of the $n gateway pods with a sample after the burst have no sample before it to compare with (a pod started within 15 s of it, or Prometheus missed its samples)"
  elif ((on > 0)); then
    rl1_fell="the fallback login decisions grew by $grew on $on of the $n gateway pods: Valkey answered after the gateway's 50 ms store timeout, so those logins were decided by that pod's own limiter, not the shared bucket"
  else
    rl1_fell=0 rl1_pods=$n
  fi
}

# node_of IP: "NODE (pod range CIDR)" of the node whose pod range (a /24 of k3s) holds IP, "" when none does; reads
# $work/nodes ("NAME CIDR" lines, written by nodes_read).
nodes_read() { kc get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{"\n"}{end}' >"$work/nodes"; }
node_of() {
  awk -v ip="$1" '{ split($2, c, "."); split(ip, a, "."); if (a[1] == c[1] && a[2] == c[2] && a[3] == c[3]) print $1 " (pod range " $2 ")" }' "$work/nodes"
}
