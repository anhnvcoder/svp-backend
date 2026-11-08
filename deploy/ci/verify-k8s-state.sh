#!/usr/bin/env bash
# verify-k8s-state.sh: writes the state of cluster k3d-svp to $SVP_VERIFY_OUT/k8s-state.json when a build step failed:
# status fields (pods, Jobs, Warning events, Helm releases), and only the last 40 lines before the crash of a crashing
# container in a log_tail_namespaces namespace, with values verify-mask.sh kept and secret-named pairs masked as ***.
# Design notes: docs/reference/ci.md.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# The job's own temp directory on GitHub Actions, emptied when the job ends; /tmp on a machine.
tmp_root=${RUNNER_TEMP:-/tmp}
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}

fail() {
  echo "verify-k8s-state: $1" >&2
  exit 1
}

umask 077
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# get KIND [ARG...]: KIND of every namespace as JSON into $work/KIND.json.
get() {
  local kind=$1
  shift
  kubectl --context k3d-svp get "$kind" -A "$@" -o json --request-timeout=10s >"$work/$kind.json" ||
    fail "read the $kind of cluster k3d-svp"
}
get pods
get jobs
get events --field-selector type=Warning
helm --kube-context k3d-svp list -A -o json >"$work/releases.json" ||
  fail "read the Helm releases of cluster k3d-svp"
# log_tail_namespaces: the namespaces whose container logs may be quoted (deploy/k8s/lib.sh).
# Read, not sourced: the file sets variables, among them out.
shown=$(sed -n 's/^log_tail_namespaces="\(.*\)"$/\1/p' "$here/../k8s/lib.sh")
[ -n "$shown" ] || fail "read log_tail_namespaces of deploy/k8s/lib.sh"

# Crashing containers (CrashLoopBackOff, or an earlier attempt that exited non-zero) as "namespace pod container",
# minus the pods whose log may quote data: CloudNativePG Postgres and GlitchTip, as in unready_report.
jq -r --arg shown " $shown " '
  .items[] | select((.metadata.labels // {}) | (has("cnpg.io/cluster") or .["app.kubernetes.io/name"] == "glitchtip") | not)
  | .metadata as $m | select($shown | contains(" " + $m.namespace + " "))
  | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
  | select(.state.waiting.reason == "CrashLoopBackOff" or (.lastState.terminated.exitCode // 0) != 0)
  | [$m.namespace, $m.name, .name] | @tsv' "$work/pods.json" >"$work/crashing" || fail "list the crashing containers"
# One JSON object per crashing container; a container whose log cannot be read is left out.
: >"$work/logs.jsonl"
while read -r ns pod container; do
  kubectl --context k3d-svp -n "$ns" logs "$pod" -c "$container" --previous --tail=40 --request-timeout=10s \
    </dev/null 2>/dev/null | tail -n 40 >"$work/log" || continue
  jq -Rs --arg ns "$ns" --arg pod "$pod" --arg container "$container" \
    '{namespace: $ns, pod: $pod, container: $container, lines: split("\n") | map(select(length > 0))}' \
    "$work/log" >>"$work/logs.jsonl" || fail "encode the log of $ns/$pod/$container"
done <"$work/crashing"
cat "$secrets/env.values" "$secrets/cluster.values" 2>/dev/null | LC_ALL=C sort -u >"$work/values" || :

jq -n --slurpfile pods "$work/pods.json" --slurpfile jobs "$work/jobs.json" --slurpfile events "$work/events.json" \
  --slurpfile releases "$work/releases.json" --slurpfile logs "$work/logs.jsonl" --rawfile values "$work/values" '
  ($values | split("\n") | map(select(length > 0))) as $vals
  | def masked: reduce $vals[] as $v (.; split($v) | join("***"));
  def masked_line: masked | gsub("(password|secret|token|credential)[^ ]*[=:] *\\S+"; "***"; "i");
  def ended: if . == null then null else {reason, exitCode} end;
  def container: {name, ready, restartCount,
    waiting: (.state.waiting.reason // null), terminated: (.state.terminated | ended),
    lastTerminated: (.lastState.terminated | ended)};
  {
    pods: [$pods[0].items[] | {namespace: .metadata.namespace, name: .metadata.name, phase: .status.phase,
      unmetConditions: [(.status.conditions // [])[] | select(.status != "True") | {type, reason}],
      initContainers: [(.status.initContainerStatuses // [])[] | container],
      containers: [(.status.containerStatuses // [])[] | container]}],
    jobs: [$jobs[0].items[] | {namespace: .metadata.namespace, name: .metadata.name,
      active: (.status.active // 0), succeeded: (.status.succeeded // 0), failed: (.status.failed // 0),
      conditions: [(.status.conditions // [])[] | {type, status, reason}]}],
    warnings: [$events[0].items[] | {namespace: .metadata.namespace, reason, count,
      lastTimestamp: (.lastTimestamp // .eventTime),
      object: {kind: .involvedObject.kind, namespace: .involvedObject.namespace, name: .involvedObject.name},
      message: ((.message // "") | masked)}],
    logs: [$logs[] | .lines |= map(masked_line)],
    releases: [$releases[0][] | {namespace, name, revision, status, chart, updated}]
  }' >"$out/k8s-state.json" || fail "write $out/k8s-state.json"
jq -r '"verify-k8s-state: \(.pods | length) pod(s), \(.jobs | length) Job(s), \(.warnings | length) warning event(s), "
  + "\(.releases | length) release(s)"' "$out/k8s-state.json"
