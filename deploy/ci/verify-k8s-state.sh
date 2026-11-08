#!/usr/bin/env bash
# verify-k8s-state.sh: writes the state of cluster k3d-svp to $SVP_VERIFY_OUT/k8s-state.json when a build step failed.
# Status fields only (pods, Jobs, Warning events, Helm releases), never a spec, log or termination message; values
# verify-mask.sh kept become *** in event messages, and verify-collect.sh scans the file again before publishing it.
# Design notes: docs/reference/ci.md.
set -euo pipefail

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
helm --kube-context k3d-svp list -A -a -o json >"$work/releases.json" ||
  fail "read the Helm releases of cluster k3d-svp"
cat "$secrets/env.values" "$secrets/cluster.values" 2>/dev/null | LC_ALL=C sort -u >"$work/values" || :

jq -n --slurpfile pods "$work/pods.json" --slurpfile jobs "$work/jobs.json" --slurpfile events "$work/events.json" \
  --slurpfile releases "$work/releases.json" --rawfile values "$work/values" '
  ($values | split("\n") | map(select(length > 0))) as $vals
  | def masked: reduce $vals[] as $v (.; split($v) | join("***"));
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
    releases: [$releases[0][] | {namespace, name, revision, status, chart, updated}]
  }' >"$out/k8s-state.json" || fail "write $out/k8s-state.json"
jq -r '"verify-k8s-state: \(.pods | length) pod(s), \(.jobs | length) Job(s), \(.warnings | length) warning event(s), "
  + "\(.releases | length) release(s)"' "$out/k8s-state.json"
