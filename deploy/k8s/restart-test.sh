#!/usr/bin/env bash
# Tests for restart_workload of deploy/k8s/lib.sh, through which restart_on_secret_change (deploy/k8s/install.sh,
# glitchtip-init.sh) restarts a workload whose Secret changed: on a Rollout of Argo Rollouts and on a Deployment, with
# a fake kubectl in a temporary directory. Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/k8s/restart-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

# --- restart_workload of deploy/k8s/lib.sh on a Rollout, with a fake kubectl of its own (bin-rollout): it answers each
# `get rollout web` with the next of the states rollout-1.json, rollout-2.json, ... (the last one again once they run
# out), whose restartedAt AT is the time of the patch it got, and records every call. A canary before the restart stops
# it at once, without a patch; one that starts during the restart (a release arriving) stops it at its next read, not
# after 300 s; a Rollout running its stable revision alone is restarted and waited for; a Deployment (the drill of
# Postgres' backup restarts only those) goes through kubectl rollout restart and status as before.
rk=$work/kube-rollout
mkdir -p "$work/bin-rollout"
cat >"$work/bin-rollout/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_ROLLOUT_DIR/calls"
[ "$1 $2 $3 $4" = "--context k3d-svp -n svp" ] || exit 2
shift 4
case "$*" in
  "get rollouts.argoproj.io web") exit 0 ;;
  "get rollouts.argoproj.io "*) echo "Error from server (NotFound)" >&2; exit 1 ;;
  "patch rollout web --type merge -p "*) jq -r .spec.restartAt <<<"$7" >"$FAKE_ROLLOUT_DIR/at"; exit 0 ;;
  "rollout restart deployment user-service" | "rollout status deployment user-service --timeout=300s") exit 0 ;;
  "get rollout web -o "*)
    n=$(($(cat "$FAKE_ROLLOUT_DIR/n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_ROLLOUT_DIR/n"
    f=$FAKE_ROLLOUT_DIR/rollout-$n.json
    [ -f "$f" ] || f=$(ls "$FAKE_ROLLOUT_DIR"/rollout-*.json | sort -t- -k2 -n | tail -n 1)
    state=$(jq --arg at "$(cat "$FAKE_ROLLOUT_DIR/at" 2>/dev/null)" \
      'if .status.restartedAt == "AT" then .status.restartedAt = $at else . end' "$f")
    if [ "$5" = json ]; then echo "$state"; else jq -j '"\(.status.restartedAt // "") \(.status.phase // "")"' <<<"$state"; fi
    exit 0
    ;;
esac
exit 2
EOF
chmod 755 "$work/bin-rollout/kubectl"
stable='{"spec": {}, "status": {"phase": "Healthy", "currentPodHash": "7974b879c7", "stableRS": "7974b879c7"}}'
restarted='{"spec": {}, "status": {"phase": "Healthy", "currentPodHash": "7974b879c7", "stableRS": "7974b879c7",
  "restartedAt": "AT"}}'
canary='{"spec": {}, "status": {"phase": "Paused", "currentPodHash": "7f9dc67c4c", "stableRS": "7974b879c7",
  "restartedAt": "AT", "pauseConditions": [{"reason": "CanaryPauseStep"}], "canary": {"weights": {"canary": {"weight": 25}}}}}'
# restart_case NAME STATE...: restart_workload svp web (svp user-service when NAME starts with deployment) over the
# states, in a directory of its own; its output in NAME.out, its exit status and seconds taken in NAME.rc.
restart_case() {
  local name=$1 i=0 rc=0 start=$SECONDS target=web
  shift
  rm -rf "$rk" && mkdir -p "$rk"
  for state in "$@"; do i=$((i + 1)) && echo "$state" >"$rk/rollout-$i.json"; done
  case $name in deployment*) target=user-service ;; esac
  (
    PATH=$work/bin-rollout:$PATH FAKE_ROLLOUT_DIR=$rk
    export FAKE_ROLLOUT_DIR
    . "$here/lib.sh"
    restart_workload svp "$target"
    echo "restarted"
  ) >"$work/$name.out" 2>&1 || rc=$?
  cp "$rk/calls" "$work/$name.calls"
  echo "$rc $((SECONDS - start))" >"$work/$name.rc"
}
restart_case canary-before "$canary"
read -r rc took <"$work/canary-before.rc"
[ "$rc" = 1 ] && [ "$took" -lt 60 ] && ! grep -q patch "$work/canary-before.calls" &&
  grep -qxF "FAIL  rollout svp/web runs a canary (pod template 7f9dc67c4c rolling out beside the stable 7974b879c7, canary weight 25%; paused (CanaryPauseStep)): it turns Healthy only once the canary is over, so its restart is not waited for. Let the canary finish (its analysis promotes it only under traffic: make k8s-traffic-start) or abort it (kubectl --context k3d-svp -n svp patch rollout web --subresource status --type merge -p '{\"status\":{\"abort\":true}}'), then run this again" \
    "$work/canary-before.out" &&
  ok "restart_workload: a Rollout in a canary stops it at once, naming the canary and the ways out, before any patch" ||
  fail "restart_workload: a Rollout in a canary stops it at once, naming the canary and the ways out, before any patch (exit $rc in ${took}s: $(cat "$work/canary-before.out"))"
restart_case canary-during "$stable" "$canary"
read -r rc took <"$work/canary-during.rc"
[ "$rc" = 1 ] && [ "$took" -lt 60 ] && [ "$(grep -c '^--context k3d-svp -n svp patch rollout web' "$work/canary-during.calls")" = 1 ] &&
  grep -qF 'FAIL  rollout svp/web runs a canary (pod template 7f9dc67c4c rolling out beside the stable 7974b879c7' \
    "$work/canary-during.out" && ! grep -qF 'within 300s' "$work/canary-during.out" &&
  ok "restart_workload: a canary that starts during the restart stops it at the next read, not after 300 s" ||
  fail "restart_workload: a canary that starts during the restart stops it at the next read, not after 300 s (exit $rc in ${took}s: $(cat "$work/canary-during.out"))"
restart_case stable "$stable" "$restarted"
read -r rc took <"$work/stable.rc"
[ "$rc" = 0 ] && grep -qx restarted "$work/stable.out" &&
  grep -q '^--context k3d-svp -n svp patch rollout web --type merge -p {"spec":{"restartAt":"20[0-9-]*T[0-9:]*Z"}}$' \
    "$work/stable.calls" &&
  ok "restart_workload: a Rollout on its stable revision gets spec.restartAt and is waited for until Healthy" ||
  fail "restart_workload: a Rollout on its stable revision gets spec.restartAt and is waited for until Healthy (exit $rc: $(cat "$work/stable.out"))"
restart_case deployment "$stable"
read -r rc took <"$work/deployment.rc"
[ "$rc" = 0 ] && grep -qx -- '--context k3d-svp -n svp rollout restart deployment user-service' "$work/deployment.calls" &&
  grep -qx -- '--context k3d-svp -n svp rollout status deployment user-service --timeout=300s' "$work/deployment.calls" &&
  ! grep -q 'get rollout ' "$work/deployment.calls" &&
  ok "restart_workload: a Deployment is restarted with kubectl rollout restart and status, its canary never read" ||
  fail "restart_workload: a Deployment is restarted with kubectl rollout restart and status, its canary never read (exit $rc: $(cat "$work/deployment.out"))"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
