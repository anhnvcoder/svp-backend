#!/usr/bin/env bash
# Tests for the artifact filter of the verification runs, deploy/ci/verify-collect.sh, and for deploy/ci/verify-mask.sh
# it calls. Everything is a fixture in a temporary directory: a fake checkout with a fake .env (the repository's .env is
# never read), a fake results folder, and a fake kubectl first on PATH that lists made-up Secrets or fails. The fake
# secrets, the JWT and the private key header are made at run time, so no file of the repository holds one. Before the
# filter, unready_report of deploy/k8s/lib.sh, with the same fake kubectl listing made-up pods and their logs; its
# output is one of the fake results, as is a migrate Job's log marked by mark_log of the same file. verify-mask.sh
# cluster on a binary value of 200 KiB, timed, and on small ones against the cut it made before.
# Then deploy/ci/verify-run.sh with a fake make: the scenarios compose-obs and gitops, and made-up scenario files for
# what a scenario file can get wrong. Then gitops_stale of deploy/ci/verify/gitops.sh with a fake cosign.
# Last, that deploy/ci/changed-services.sh builds no image for a change of these scripts, in a throwaway git repository
# holding a copy of it. Runs on macOS and Linux, no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/verify-collect-test.sh
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
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# --- The fake secrets: three of .env (one with special characters), one of a cluster Secret, one line of a cluster
# Secret of several lines; values that are not secrets, or too short to count; a JWT and a private key header.
env_secret=$(openssl rand -hex 16)
quoted_secret="p!a#s%s&w*o(r)d-$(openssl rand -hex 4)"
dsn_secret="http://$(openssl rand -hex 16)@127.0.0.1:8000/1"
cluster_secret=$(openssl rand -hex 20)
kafka_secret=$(openssl rand -hex 20)
line_secret="token-$(openssl rand -hex 12)"
helm_payload="H4sIAAAAAAAC$(openssl rand -hex 12)"
# A binary value of a cluster Secret: secrets between a carriage return, other control characters, a newline and bytes
# that are not UTF-8. Each must be masked on a line of its own, and no mask line may hold a control character.
cr_secret="cr-$(openssl rand -hex 8)"
ctl_secret="ctl-$(openssl rand -hex 8)"
nl_secret="nl-$(openssl rand -hex 8)"
bin_secret="bin-$(openssl rand -hex 8)"
binary_value="$cr_secret"$'\r'"$ctl_secret"$'\x01\x1b'"$nl_secret"$'\n'"$bin_secret"$'\xff\xfe'"$cr_secret"
role_name=svp_video_app_user
jwt="eyJ$(openssl rand -hex 8).eyJ$(openssl rand -hex 8).$(openssl rand -hex 8)"
private_key_header="-----BEGIN ""RSA PRIVATE KEY-----"
printf '%s\n' "$env_secret" "$quoted_secret" "$dsn_secret" "$jwt" "$(b64 "$env_secret")" >"$work/env-secrets"
{
  cat "$work/env-secrets"
  printf '%s\n' "$cluster_secret" "$kafka_secret" "$line_secret" "$(b64 "$cluster_secret")"
  printf '%s\n' "$cr_secret" "$ctl_secret" "$nl_secret" "$bin_secret" "$(b64 "$binary_value")"
} >"$work/all-secrets"

repo=$work/repo
mkdir -p "$repo/.k8s/drills" "$repo/.k6/local-1" "$repo/.web/svp-frontend/test-results/lighthouse" "$work/bin"
cat >"$repo/.env" <<EOF
# a comment
SVP_FAKE_APP_DB_PASSWORD=$env_secret
SVP_QUOTED_PASSWORD='$quoted_secret'
SVP_SHORT_TOKEN=abc12
GLITCHTIP_ADMIN_EMAIL=admin@svp.local
SENTRY_ORG=svp
SENTRY_DSN=$dsn_secret
JWT_SIGNING_KID=kid-of-the-signing-key
EOF

# The fake kubectl: kubectl --context k3d-svp --request-timeout=10s -n NS get secrets -o json. FAKE_KUBECTL_FAIL=1
# makes it fail, as for a cluster that no longer answers. For unready_report: kubectl --context k3d-svp -n NS get pods
# -o json prints pods-NS.json; kubectl --context k3d-svp -n NS logs POD -c CONTAINER [--previous] --tail=N prints
# logs/NS.POD.CONTAINER[.previous]; both are recorded in calls. For gitops_timeout_report, kubectl --context k3d-svp
# [-n NS] get TYPE [NAME...] [flags] prints the list of TYPE-NS.json (cluster.TYPE.json without -n), or fails as for a
# resource type the server does not have; given names, as kubectl with --ignore-not-found: the one object for one name,
# a List for several, nothing when none is there. Recorded in calls too.
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_KUBECTL_FAIL:-}" = 1 ] && { echo "The connection to the server was refused" >&2; exit 1; }
if [ "$1 $2" = "--context k3d-svp" ] && { [ "$3" = get ] || [ "$3 $5" = "-n get" ]; }; then
  echo "$*" >>"$FAKE_KUBECTL_DIR/calls"
  if [ "$3" = get ]; then type=$4 f=cluster.$4 && shift 4; else type=$6 f=$6-$4 && shift 6; fi
  f=$FAKE_KUBECTL_DIR/$f.json
  [ -f "$f" ] || { echo "error: the server doesn't have a resource type \"$type\"" >&2; exit 1; }
  names=()
  while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do names+=("$1") && shift; done
  [ ${#names[@]} = 0 ] && { cat "$f"; exit; }
  jq '[.items[] | select(.metadata.name | IN($ARGS.positional[]))]
    | if ($ARGS.positional | length) > 1 then {kind: "List", items: .} else .[] end' --args "${names[@]}" <"$f"
  exit
fi
if [ "$1 $2 $3" = "--context k3d-svp -n" ]; then
  echo "$*" >>"$FAKE_KUBECTL_DIR/calls"
  [ "$5 $7" = "logs -c" ] || exit 2
  f=$FAKE_KUBECTL_DIR/logs/$4.$6.$8
  case " $* " in *" --previous "*) f=$f.previous ;; esac
  if [ -f "$f" ]; then cat "$f"; else echo "Error from server (NotFound): no log" >&2; exit 1; fi
  exit
fi
[ "$1 $2 $3" = "--context k3d-svp --request-timeout=10s" ] && [ "$4" = -n ] &&
  [ "$6 $7 $8 $9" = "get secrets -o json" ] || exit 2
f=$FAKE_KUBECTL_DIR/$5.json
if [ -f "$f" ]; then cat "$f"; else echo '{"items":[]}'; fi
EOF
chmod 755 "$work/bin/kubectl"
mkdir -p "$work/kube"
# b64v NAME=VALUE...: a Secret's data, each VALUE in base64.
b64v() {
  local kv
  for kv in "$@"; do jq -n --arg k "${kv%%=*}" --arg v "$(b64 "${kv#*=}")" '{($k): $v}'; done | jq -s 'add'
}
# Shaped like deploy/k8s/secrets.sh: next to each secret, the identifiers it stores under keys of their own (user
# names, an email, a key id, a SASL mechanism), which the drills print and must stay unmasked and searchable.
jq -n --argjson backup "$(b64v ACCESS_KEY_ID=svp-pg-backup "ACCESS_SECRET_KEY=$cluster_secret" "username=$role_name")" \
  --argjson s3root "$(b64v S3_ROOT_USER=svp-admin "S3_ROOT_PASSWORD=$cluster_secret")" \
  --argjson keda "$(b64v sasl=scram_sha256 tls=disable username=svp-keda "password=$kafka_secret")" \
  --arg multi "$(b64 "route:
  receiver: telegram
  $line_secret
")" --arg helm "$(b64 "$helm_payload")" '{items: [
    {type: "Opaque", metadata: {name: "pg-backup-s3"}, data: $backup},
    {type: "Opaque", metadata: {name: "s3-root"}, data: $s3root},
    {type: "Opaque", metadata: {name: "keda-kafka"}, data: $keda},
    {type: "Opaque", metadata: {name: "alertmanager-svp"}, data: {"alertmanager.yaml": $multi}},
    {type: "helm.sh/release.v1", metadata: {name: "sh.helm.release.v1.svp-data.v1"}, data: {release: $helm}}]}' \
  >"$work/kube/svp-data.json"
jq -n --argjson feed "$(b64v KAFKA_SASL_USERNAME=svp-feed-service "KAFKA_SASL_PASSWORD=$kafka_secret")" \
  --argjson user "$(b64v JWT_SIGNING_KID=kid-of-the-signing-key "KAFKA_SASL_USERNAME=svp-user-service")" '{items: [
    {type: "Opaque", metadata: {name: "feed-service-env"}, data: $feed},
    {type: "Opaque", metadata: {name: "user-service-env"}, data: $user}]}' >"$work/kube/svp.json"
jq -n --argjson admin "$(b64v GLITCHTIP_ADMIN_EMAIL=admin@svp.local "GLITCHTIP_ADMIN_PASSWORD=$cluster_secret")" \
  --argjson grafana "$(b64v admin-user=admin-of-grafana "admin-password=$kafka_secret")" \
  --arg binary "$(b64 "$binary_value")" '{items: [
    {type: "Opaque", metadata: {name: "glitchtip-admin"}, data: $admin},
    {type: "Opaque", metadata: {name: "grafana-admin"}, data: $grafana},
    {type: "Opaque", metadata: {name: "operator-config"}, data: {"config.gz": $binary}}]}' >"$work/kube/svp-obs.json"
identifiers="svp-pg-backup svp-admin scram_sha256 svp-keda svp-feed-service svp-user-service admin@svp.local
admin-of-grafana kid-of-the-signing-key"
export FAKE_KUBECTL_DIR=$work/kube

# --- unready_report of deploy/k8s/lib.sh: which containers it reports, and whose log it prints. In svp-data a Redpanda
# broker in a crash loop (its log, and the attempt before, printed), its ready sidecar (not reported), a Postgres pod
# of CloudNativePG and a completed Job; in svp-obs GlitchTip; in svp two services. Every log the fake kubectl could
# print is a marker, so what reaches the output shows.
# unready_pods ITEMS NAMESPACE: the pods NAMESPACE lists, ITEMS a jq expression of their array.
unready_pods() {
  jq -n "{items: $1}" >"$work/kube/pods-$2.json"
}
unready_pods '[
  {metadata: {name: "redpanda-0", labels: {"app.kubernetes.io/name": "redpanda"}},
   spec: {containers: [{name: "redpanda", terminationMessagePolicy: "FallbackToLogsOnError"}, {name: "sidecar"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "redpanda", ready: false, restartCount: 2, state: {waiting: {reason: "CrashLoopBackOff"}},
      lastState: {terminated: {reason: "Error", exitCode: 1, message: "INFRA-MESSAGE-MARKER"}}},
     {name: "sidecar", ready: true, restartCount: 0, state: {running: {}}}]}},
  {metadata: {name: "svp-pg-1", labels: {"cnpg.io/cluster": "svp-pg"}},
   spec: {containers: [{name: "postgres", terminationMessagePolicy: "FallbackToLogsOnError"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "postgres", ready: false, restartCount: 1, state: {running: {}},
      lastState: {terminated: {reason: "Error", exitCode: 1, message: "PG-MESSAGE-MARKER"}}}]}},
  {metadata: {name: "redpanda-init-x"}, spec: {containers: [{name: "init"}]},
   status: {phase: "Succeeded", containerStatuses: [
     {name: "init", ready: false, restartCount: 0, state: {terminated: {reason: "Completed", exitCode: 0}}}]}}]' \
  svp-data
unready_pods '[
  {metadata: {name: "glitchtip-abc", labels: {"app.kubernetes.io/name": "glitchtip"}},
   spec: {containers: [{name: "glitchtip"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "glitchtip", ready: false, restartCount: 0, state: {waiting: {reason: "CrashLoopBackOff"}}}]}}]' svp-obs
unready_pods '[
  {metadata: {name: "gateway-abc"}, spec: {containers: [{name: "gateway"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "gateway", ready: false, restartCount: 3, state: {waiting: {reason: "CrashLoopBackOff"}},
      lastState: {terminated: {reason: "Error", exitCode: 2, message: "TERM-FILE-MARKER"}}}]}},
  {metadata: {name: "media-worker-abc"},
   spec: {containers: [{name: "media-worker", terminationMessagePolicy: "FallbackToLogsOnError"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "media-worker", ready: false, restartCount: 1, state: {running: {}},
      lastState: {terminated: {reason: "Error", exitCode: 1, message: "APP-FALLBACK-MARKER"}}}]}}]' svp
mkdir -p "$work/kube/logs"
printf '%s\n' "Could not initialize seastar: std::runtime_error (insufficient physical memory: needed 1073741824" \
  "" INFRA-TAIL-MARKER >"$work/kube/logs/svp-data.redpanda-0.redpanda"
echo INFRA-PREVIOUS-MARKER >"$work/kube/logs/svp-data.redpanda-0.redpanda.previous"
echo SIDECAR-MARKER >"$work/kube/logs/svp-data.redpanda-0.sidecar"
echo 'ERROR: duplicate key, STATEMENT: INSERT ... PG-LOG-MARKER' >"$work/kube/logs/svp-data.svp-pg-1.postgres"
echo 'GET /api/1/envelope/?sentry_key=GLITCHTIP-MARKER' >"$work/kube/logs/svp-obs.glitchtip-abc.glitchtip"
for f in svp.gateway-abc.gateway svp.gateway-abc.gateway.previous svp.media-worker-abc.media-worker \
  svp.media-worker-abc.media-worker.previous; do
  echo "APP-LOG-MARKER of $f" >"$work/kube/logs/$f"
done
: >"$work/kube/calls"
unready=$work/unready.txt
(
  PATH=$work/bin:$PATH
  . "$here/../k8s/lib.sh"
  for ns in svp-data svp-obs svp; do unready_report "$ns"; done
) 2>"$unready" >/dev/null
has_line() { if grep -qxF -- "$2" "$unready"; then ok "unready: $1"; else fail "unready: $1"; fi; }
has_line "an infrastructure container's state, how it ended and its message" \
  "pod svp-data/redpanda-0, container redpanda: waiting CrashLoopBackOff, 2 restart(s); attempt before: terminated Error (exit 1): INFRA-MESSAGE-MARKER"
has_line "its log, each line marked with its namespace" "    [svp-data] INFRA-TAIL-MARKER"
has_line "an empty line of its log marked too" "    [svp-data] "
has_line "the log of its attempt before" "    [svp-data] INFRA-PREVIOUS-MARKER"
has_line "a service's state, how it ended and its message from the termination log file" \
  "pod svp/gateway-abc, container gateway: waiting CrashLoopBackOff, 3 restart(s); attempt before: terminated Error (exit 2): TERM-FILE-MARKER"
has_line "a service whose message falls back to its log: state and exit only" \
  "pod svp/media-worker-abc, container media-worker: running, 1 restart(s); attempt before: terminated Error (exit 1)"
has_line "GlitchTip's state" "pod svp-obs/glitchtip-abc, container glitchtip: waiting CrashLoopBackOff, 0 restart(s)"
has_line "Postgres' state, without its message" \
  "pod svp-data/svp-pg-1, container postgres: running, 1 restart(s); attempt before: terminated Error (exit 1)"
for m in APP-LOG-MARKER APP-FALLBACK-MARKER GLITCHTIP-MARKER PG-LOG-MARKER PG-MESSAGE-MARKER SIDECAR-MARKER \
  redpanda-init-x; do
  if grep -qF -- "$m" "$unready"; then fail "unready: no $m in its output"; else ok "unready: no $m in its output"; fi
done
if grep -E ' logs (gateway|media-worker|glitchtip|svp-pg)-' "$work/kube/calls" | grep -q .; then
  fail "unready: no log of a service, GlitchTip or Postgres is read"
else
  ok "unready: no log of a service, GlitchTip or Postgres is read"
fi
shown=$(. "$here/../k8s/lib.sh" && echo " $log_tail_namespaces ")
case $shown in
  *" svp "* | *" envoy-gateway-system "* | *" kube-system "* | "  ") fail "unready: log_tail_namespaces has neither svp, Envoy nor kube-system, and is not empty" ;;
  *) ok "unready: log_tail_namespaces has neither svp, Envoy nor kube-system, and is not empty" ;;
esac

# --- gitops_timeout_report of deploy/k8s/lib.sh, which deploy/k8s/gitops.sh prints when its wait for the Applications
# runs out. The Applications as Argo CD 3 writes them: no health on their resources. Two waited for that are not
# Healthy (one Healthy left out, one not waited for left out), their resources read from the cluster and judged: a
# Deployment not ready beside a ready one and a missing one (one call, a List), a DaemonSet of a generation not
# observed, a Prometheus object without status beside a ready Alertmanager (one object each), a cluster-scoped
# ClusterIssuer not Ready, an HTTPRoute whose parent has ResolvedRefs False, a PersistentVolumeClaim Pending, a failed
# Job, a kind the server does not have; a hook, a Secret, a ConfigMap and a CRD never read. Then the CRDs of the
# Prometheus and Alertmanager objects, by name (another group's left out, a missing one skipped), a Prometheus object
# no controller reconciled beside a reconciled Alertmanager, and the operator's log and its attempt before, marked with
# svp-obs (GlitchTip's pod beside it is not the operator's). Then the same with neither the CRDs nor any pod.
gk=$work/kube-gitops
mkdir -p "$gk/logs"
jq -n '{items: [
  {metadata: {name: "kube-prometheus-stack"}, status: {health: {status: "Progressing"}, resourceHealthSource: "appTree",
   resources: [
    {group: "apiextensions.k8s.io", kind: "CustomResourceDefinition", name: "prometheuses.monitoring.coreos.com", status: "Synced"},
    {kind: "ConfigMap", namespace: "svp-obs", name: "kps-dashboards", status: "Synced"},
    {kind: "Secret", namespace: "svp-obs", name: "alertmanager-kps", status: "Synced"},
    {group: "apps", kind: "Deployment", namespace: "svp-obs", name: "kps-operator", status: "Synced"},
    {group: "apps", kind: "Deployment", namespace: "svp-obs", name: "kps-kube-state-metrics", status: "Synced"},
    {group: "apps", kind: "Deployment", namespace: "svp-obs", name: "kps-gone", status: "OutOfSync"},
    {group: "apps", kind: "DaemonSet", namespace: "svp-obs", name: "kps-node-exporter", status: "Synced"},
    {group: "monitoring.coreos.com", kind: "Prometheus", namespace: "svp-obs", name: "kps-prometheus", status: "Synced"},
    {group: "monitoring.coreos.com", kind: "Alertmanager", namespace: "svp-obs", name: "kps-alertmanager", status: "Synced"},
    {group: "batch", kind: "Job", namespace: "svp-obs", name: "kps-hook", hook: true, status: "Synced"}]}},
  {metadata: {name: "svp-cluster"}, status: {health: {status: "Degraded"}, resourceHealthSource: "appTree", resources: [
    {group: "cert-manager.io", kind: "ClusterIssuer", name: "svp-ca", status: "Synced"},
    {kind: "PersistentVolumeClaim", namespace: "svp-data", name: "data-x", status: "Synced"},
    {group: "batch", kind: "Job", namespace: "svp-data", name: "pg-init", status: "Synced"},
    {group: "keda.sh", kind: "ScaledObject", namespace: "svp", name: "media-worker", status: "Synced"},
    {group: "gateway.networking.k8s.io", kind: "HTTPRoute", namespace: "svp", name: "gateway", status: "Synced"}]}},
  {metadata: {name: "svp-root"}, status: {health: {status: "Healthy"}, resources: [
    {group: "argoproj.io", kind: "Application", namespace: "argocd", name: "loki", status: "Synced"}]}},
  {metadata: {name: "not-waited-for"}, status: {health: {status: "Degraded"}, resources: [
    {group: "apps", kind: "Deployment", namespace: "other", name: "other-deploy", status: "Synced"}]}}]}' \
  >"$gk/applications.argoproj.io-argocd.json"
jq -n '{items: [
  {kind: "Deployment", metadata: {name: "kps-operator", generation: 1}, spec: {replicas: 1},
   status: {observedGeneration: 1, replicas: 1, updatedReplicas: 1, conditions: [
     {type: "Available", status: "False", reason: "MinimumReplicasUnavailable"},
     {type: "Progressing", status: "False", reason: "ProgressDeadlineExceeded", message: "line one\nline two"}]}},
  {kind: "Deployment", metadata: {name: "kps-kube-state-metrics", generation: 3}, spec: {replicas: 2},
   status: {observedGeneration: 3, replicas: 2, readyReplicas: 2, updatedReplicas: 2}}]}' >"$gk/Deployment.apps-svp-obs.json"
jq -n '{items: [{kind: "DaemonSet", metadata: {name: "kps-node-exporter", generation: 2},
  status: {observedGeneration: 1, desiredNumberScheduled: 1, numberReady: 1, updatedNumberScheduled: 1}}]}' \
  >"$gk/DaemonSet.apps-svp-obs.json"
jq -n '{items: [{kind: "Prometheus", metadata: {name: "kps-prometheus", generation: 1}}]}' \
  >"$gk/Prometheus.monitoring.coreos.com-svp-obs.json"
jq -n '{items: [{kind: "Alertmanager", metadata: {name: "kps-alertmanager", generation: 1},
  status: {conditions: [{type: "Available", status: "True"}, {type: "Reconciled", status: "True"}]}}]}' \
  >"$gk/Alertmanager.monitoring.coreos.com-svp-obs.json"
jq -n '{items: [{kind: "ClusterIssuer", metadata: {name: "svp-ca"},
  status: {conditions: [{type: "Ready", status: "False", reason: "ErrInitIssuer", message: "no CA"}]}}]}' \
  >"$gk/cluster.ClusterIssuer.cert-manager.io.json"
jq -n '{items: [{kind: "HTTPRoute", metadata: {name: "gateway"}, status: {parents: [{conditions: [
  {type: "Accepted", status: "True"}, {type: "ResolvedRefs", status: "False", reason: "BackendNotFound"}]}]}}]}' \
  >"$gk/HTTPRoute.gateway.networking.k8s.io-svp.json"
jq -n '{items: [{kind: "PersistentVolumeClaim", metadata: {name: "data-x"}, status: {phase: "Pending"}}]}' \
  >"$gk/PersistentVolumeClaim-svp-data.json"
jq -n '{items: [{kind: "Job", metadata: {name: "pg-init"}, status: {failed: 3, conditions: [
  {type: "Failed", status: "True", reason: "BackoffLimitExceeded", message: "Job has reached the specified backoff limit"}]}}]}' \
  >"$gk/Job.batch-svp-data.json"
jq -n '{items: [
  {metadata: {name: "prometheuses.monitoring.coreos.com", creationTimestamp: "2026-10-29T19:24:50Z"},
   spec: {group: "monitoring.coreos.com"},
   status: {conditions: [{type: "NamesAccepted", status: "True"},
     {type: "Established", status: "True", lastTransitionTime: "2026-10-29T19:25:20Z"}]}},
  {metadata: {name: "clusters.postgresql.cnpg.io", creationTimestamp: "2026-10-29T19:20:00Z"},
   spec: {group: "postgresql.cnpg.io"}}]}' >"$gk/cluster.customresourcedefinitions.apiextensions.k8s.io.json"
jq -n '{items: [
  {kind: "Prometheus", metadata: {namespace: "svp-obs", name: "kps-prometheus"}},
  {kind: "Alertmanager", metadata: {namespace: "svp-obs", name: "kps-alertmanager"},
   status: {conditions: [{type: "Available", status: "True"}, {type: "Reconciled", status: "True", reason: "Ok", message: "m"}]}}]}' \
  >"$gk/cluster.prometheuses.monitoring.coreos.com,alertmanagers.monitoring.coreos.com.json"
jq -n '{items: [
  {metadata: {name: "kps-operator-abc", labels: {"app.kubernetes.io/component": "prometheus-operator"}},
   status: {containerStatuses: [{name: "kube-prometheus-stack", restartCount: 1,
     state: {running: {startedAt: "2026-10-29T19:25:05Z"}}}]}},
  {metadata: {name: "glitchtip-abc", labels: {"app.kubernetes.io/name": "glitchtip"}},
   status: {containerStatuses: [{name: "glitchtip", restartCount: 0, state: {running: {}}}]}}]}' >"$gk/pods-svp-obs.json"
echo 'level=warn msg="resource \"prometheuses\" (group: \"monitoring.coreos.com/v1\") not installed in the cluster" OPERATOR-LOG-MARKER' \
  >"$gk/logs/svp-obs.kps-operator-abc.kube-prometheus-stack"
echo OPERATOR-PREVIOUS-MARKER >"$gk/logs/svp-obs.kps-operator-abc.kube-prometheus-stack.previous"
echo GLITCHTIP-MARKER >"$gk/logs/svp-obs.glitchtip-abc.glitchtip"
: >"$gk/calls"
timeout_report=$work/timeout-report.txt
(
  PATH=$work/bin:$PATH FAKE_KUBECTL_DIR=$gk
  . "$here/../k8s/lib.sh"
  gitops_timeout_report $'svp-root\nkube-prometheus-stack\nsvp-cluster\n'
) 2>"$timeout_report" >/dev/null && ok "timeout report: exit 0" || fail "timeout report: exit 0"
timeout_lines=$(sed -n '/^Applications not Healthy/,/^CRDs of/p' "$timeout_report")
want_lines='Applications not Healthy, and their resources that are not ready:
  kube-prometheus-stack: Progressing
    DaemonSet svp-obs/kps-node-exporter: generation 2 not observed yet
    Deployment svp-obs/kps-operator: 0/1 ready, 1 updated; Progressing=False ProgressDeadlineExceeded: line one line two
    Deployment svp-obs/kps-gone: missing
    Prometheus svp-obs/kps-prometheus: no status (no controller has reconciled it)
  svp-cluster: Degraded
    ClusterIssuer svp-ca: Ready=False ErrInitIssuer: no CA
    HTTPRoute svp/gateway: ResolvedRefs=False BackendNotFound
    cannot read ScaledObject.keda.sh in svp: error: the server doesn'"'"'t have a resource type "ScaledObject.keda.sh"
    PersistentVolumeClaim svp-data/data-x: phase Pending
    Job svp-data/pg-init: Failed=True BackoffLimitExceeded: Job has reached the specified backoff limit
CRDs of the Prometheus and Alertmanager objects:'
[ "$timeout_lines" = "$want_lines" ] &&
  ok "timeout report: only the waited-for Applications not Healthy, only their resources not ready, read live, one line each" ||
  fail "timeout report: only the waited-for Applications not Healthy, only their resources not ready, read live, one line each"
has_report() { if grep -qxF -- "$2" "$timeout_report"; then ok "timeout report: $1"; else fail "timeout report: $1"; fi; }
has_report "a CRD of monitoring.coreos.com, created and Established" \
  "  prometheuses.monitoring.coreos.com: created 2026-10-29T19:24:50Z, Established True since 2026-10-29T19:25:20Z"
has_report "a Prometheus object without conditions" \
  "  Prometheus svp-obs/kps-prometheus: no status conditions (no controller has reconciled it)"
has_report "an Alertmanager object's conditions" \
  "  Alertmanager svp-obs/kps-alertmanager: Available=True; Reconciled=True Ok: m"
has_report "the operator's container, when it started" \
  "  pod svp-obs/kps-operator-abc, container kube-prometheus-stack: started 2026-10-29T19:25:05Z, 1 restart(s); last lines of its log:"
has_report "the operator's log, marked with svp-obs" \
  '    [svp-obs] level=warn msg="resource \"prometheuses\" (group: \"monitoring.coreos.com/v1\") not installed in the cluster" OPERATOR-LOG-MARKER'
has_report "the operator's attempt before, marked with svp-obs" "    [svp-obs] OPERATOR-PREVIOUS-MARKER"
for m in clusters.postgresql.cnpg.io not-waited-for loki kps-kube-state-metrics GLITCHTIP-MARKER; do
  if grep -qF -- "$m" "$timeout_report"; then fail "timeout report: no $m"; else ok "timeout report: no $m"; fi
done
grep -qxF -- '--context k3d-svp -n svp-obs get Deployment.apps kps-operator kps-kube-state-metrics kps-gone --ignore-not-found -o json' \
  "$gk/calls" && grep -qxF -- '--context k3d-svp get ClusterIssuer.cert-manager.io svp-ca --ignore-not-found -o json' "$gk/calls" &&
  grep -qxF -- '--context k3d-svp get customresourcedefinitions.apiextensions.k8s.io prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com --ignore-not-found -o json' \
    "$gk/calls" &&
  ok "timeout report: one call per namespace and kind, cluster-scoped without -n, the two CRDs by name" ||
  fail "timeout report: one call per namespace and kind, cluster-scoped without -n, the two CRDs by name"
grep -q -- '-n svp-obs logs kps-operator-abc -c kube-prometheus-stack --tail=60$' "$gk/calls" &&
  grep -q -- '-n svp-obs logs kps-operator-abc -c kube-prometheus-stack --previous --tail=60$' "$gk/calls" &&
  ! grep -q 'logs glitchtip' "$gk/calls" && ! grep -qi secret "$gk/calls" &&
  ! grep -qE 'get (ConfigMap|CustomResourceDefinition)|kps-hook|other-deploy|get Application\.' "$gk/calls" &&
  ok "timeout report: reads the operator's logs only, no Secret, no hook, no kind it does not judge" ||
  fail "timeout report: reads the operator's logs only, no Secret, no hook, no kind it does not judge"
echo '{"items": []}' >"$gk/cluster.customresourcedefinitions.apiextensions.k8s.io.json"
rm "$gk/cluster.prometheuses.monitoring.coreos.com,alertmanagers.monitoring.coreos.com.json" \
  "$gk/Prometheus.monitoring.coreos.com-svp-obs.json"
echo '{"items": []}' >"$gk/pods-svp-obs.json"
(
  PATH=$work/bin:$PATH FAKE_KUBECTL_DIR=$gk
  . "$here/../k8s/lib.sh"
  gitops_timeout_report kube-prometheus-stack
) 2>"$work/timeout-report-bare.txt" >/dev/null && ok "timeout report without the CRDs: exit 0" ||
  fail "timeout report without the CRDs: exit 0"
grep -qxF '    cannot read Prometheus.monitoring.coreos.com in svp-obs: error: the server doesn'"'"'t have a resource type "Prometheus.monitoring.coreos.com"' \
  "$work/timeout-report-bare.txt" &&
  grep -A1 -xF 'CRDs of the Prometheus and Alertmanager objects:' "$work/timeout-report-bare.txt" | grep -qxF '  none' &&
  grep -qxF '  cannot list them: error: the server doesn'"'"'t have a resource type "prometheuses.monitoring.coreos.com,alertmanagers.monitoring.coreos.com"' \
    "$work/timeout-report-bare.txt" && grep -qxF '  no pod of the operator in svp-obs' "$work/timeout-report-bare.txt" &&
  ok "timeout report without the CRDs: says what it cannot read or find, and that the operator has no pod" ||
  fail "timeout report without the CRDs: says what it cannot read or find, and that the operator has no pod"
grep -qF 'gitops_timeout_report "$want_apps" || true' "$here/../k8s/gitops.sh" &&
  ok "timeout report: gitops.sh prints it when its wait runs out" ||
  fail "timeout report: gitops.sh prints it when its wait runs out"

# --- mark_log of deploy/k8s/lib.sh, which marks the log of a failed migrate Job in deploy/k8s/install.sh: every line
# marked, an empty one, one with control characters and bytes that are not UTF-8, and the last one without a newline
# (given one); an empty log prints nothing.
# mark_log_of NAMESPACE < LOG: mark_log of lib.sh itself.
mark_log_of() { (. "$here/../k8s/lib.sh" && mark_log "$1"); }
printf 'first\n\npanic: x\r\001y\377z\nlast' | mark_log_of svp >"$work/marked"
printf '    [svp] first\n    [svp] \n    [svp] panic: x\r\001y\377z\n    [svp] last\n' >"$work/marked.want"
cmp -s "$work/marked" "$work/marked.want" && ok "mark_log: every line marked, whatever its bytes, the last one ended" ||
  fail "mark_log: every line marked, whatever its bytes, the last one ended"
printf 'one\n' | mark_log_of svp >"$work/marked"
[ "$(cat "$work/marked")" = "    [svp] one" ] && ok "mark_log: one line, one marked line" || fail "mark_log: one line, one marked line"
mark_log_of svp </dev/null >"$work/marked"
[ ! -s "$work/marked" ] && ok "mark_log: an empty log prints nothing" || fail "mark_log: an empty log prints nothing"
grep -qF 'mark_log "$namespace" <"$migrate_log" >&2' "$here/../k8s/install.sh" &&
  ok "mark_log: install.sh marks a failed migrate Job's log with it" ||
  fail "mark_log: install.sh marks a failed migrate Job's log with it"

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
    . "$here/../k8s/lib.sh"
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

# --- deploy/k8s/gitops.sh follow BRANCH, with a fake kubectl of its own (bin-follow): Application argocd/svp-root at
# revision FROM (from), compared at the target its last patch gave (Synced), at revision NOW (now) once patched. The
# branch unchanged: one patch of both targetRevisions to refs/heads/main, the wait until Argo CD compares and syncs it
# there, an ok line. The branch moved: the note line with both commits and the canary, no wait for Synced (the fake
# stays OutOfSync then). A short or broken name is refused before any call to the cluster.
fk=$work/kube-follow
mkdir -p "$work/bin-follow"
cat >"$work/bin-follow/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_FOLLOW_DIR/calls"
[ "$1 $2 $3 $4" = "--context k3d-svp -n argocd" ] || exit 2
shift 4
patched=$(cat "$FAKE_FOLLOW_DIR/target" 2>/dev/null)
case "$*" in
  "get applications.argoproj.io svp-root") exit 0 ;;
  "patch applications.argoproj.io/svp-root --type merge -p "*)
    jq -r .spec.source.targetRevision <<<"$6" >"$FAKE_FOLLOW_DIR/target"
    echo "$6" >"$FAKE_FOLLOW_DIR/patch"
    ;;
  "get applications.argoproj.io/svp-root -o jsonpath={.status.sync.revision}")
    if [ -n "$patched" ]; then printf '%s' "$(cat "$FAKE_FOLLOW_DIR/now")"; else printf '%s' "$(cat "$FAKE_FOLLOW_DIR/from")"; fi
    ;;
  "get applications.argoproj.io/svp-root -o jsonpath={.status.sync.comparedTo.source.targetRevision}")
    printf '%s' "${patched:-$(cat "$FAKE_FOLLOW_DIR/from")}"
    ;;
  "get applications.argoproj.io/svp-root -o jsonpath={.status.sync.status}")
    if [ -n "$patched" ] && [ "$(cat "$FAKE_FOLLOW_DIR/now")" = "$(cat "$FAKE_FOLLOW_DIR/from")" ]; then
      printf Synced
    else printf OutOfSync; fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$work/bin-follow/kubectl"
built=0a9dec9fb641cd3fd0be6e1ce4ceb8e9d1be5380
newer=cb7ebf2fa0b6581c5c15b3010fcc6456eb007bda
# follow_case NAME FROM NOW ARG...: deploy/k8s/gitops.sh ARG... over the fake; output in NAME.out, exit status and
# seconds taken in NAME.rc, the calls in NAME.calls.
follow_case() {
  local name=$1 rc=0 start=$SECONDS
  rm -rf "$fk" && mkdir -p "$fk" && echo "$2" >"$fk/from" && echo "$3" >"$fk/now" && : >"$fk/calls"
  shift 3
  env -u GITHUB_ACTIONS -u CI -u GITLAB_CI -u JENKINS_URL -u TF_BUILD PATH="$work/bin-follow:$PATH" FAKE_FOLLOW_DIR="$fk" \
    "$here/../k8s/gitops.sh" "$@" >"$work/$name.out" 2>&1 </dev/null || rc=$?
  cp "$fk/calls" "$work/$name.calls"
  [ ! -f "$fk/patch" ] || cp "$fk/patch" "$work/$name.patch"
  echo "$rc $((SECONDS - start))" >"$work/$name.rc"
}
follow_case follow-same "$built" "$built" follow main
read -r rc took <"$work/follow-same.rc"
[ "$rc" = 0 ] && [ "$(jq -c . "$work/follow-same.patch")" = '{"spec":{"source":{"targetRevision":"refs/heads/main","helm":{"valuesObject":{"targetRevision":"refs/heads/main"}}}}}' ] &&
  grep -qxF "ok    Application svp-root follows refs/heads/main of svp-gitops, still at ${built:0:12}: nothing new to roll out" \
    "$work/follow-same.out" && grep -q 'jsonpath={.status.sync.status}$' "$work/follow-same.calls" &&
  [ "$(grep -c ' patch ' "$work/follow-same.calls")" = 1 ] &&
  ok "gitops.sh follow: the branch unchanged, both targetRevisions become refs/heads/main, waited for until Synced" ||
  fail "gitops.sh follow: the branch unchanged, both targetRevisions become refs/heads/main, waited for until Synced (exit $rc: $(cat "$work/follow-same.out"))"
follow_case follow-moved "$built" "$newer" follow main
read -r rc took <"$work/follow-moved.rc"
[ "$rc" = 0 ] && [ "$took" -lt 60 ] && ! grep -q 'jsonpath={.status.sync.status}$' "$work/follow-moved.calls" &&
  grep -qxF "note  Application svp-root follows refs/heads/main of svp-gitops, which moved from $built (the commit the cluster runs) to $newer: Argo CD deploys it now, a release like any other; a changed gateway or web goes out as a canary, whose analysis promotes it only under traffic (make k8s-traffic-start)" \
    "$work/follow-moved.out" && ! grep -q '^ok ' "$work/follow-moved.out" &&
  ok "gitops.sh follow: the branch moved, one note line with both commits and the canary, no wait for Synced" ||
  fail "gitops.sh follow: the branch moved, one note line with both commits and the canary, no wait for Synced (exit $rc in ${took}s: $(cat "$work/follow-moved.out"))"
follow_case follow-bad "$built" "$built" follow 'main..x'
follow_case follow-none "$built" "$built" follow
[ "$(cut -d' ' -f1 "$work/follow-bad.rc") $(cut -d' ' -f1 "$work/follow-none.rc")" = "1 1" ] &&
  grep -qxF "FAIL  'main..x' is not a branch name" "$work/follow-bad.out" &&
  grep -qxF 'FAIL  usage: deploy/k8s/gitops.sh follow BRANCH' "$work/follow-none.out" &&
  ! grep -q ' patch ' "$work/follow-bad.calls" && [ ! -s "$work/follow-none.calls" ] &&
  ok "gitops.sh follow: a broken branch name or none is refused, nothing patched" ||
  fail "gitops.sh follow: a broken branch name or none is refused, nothing patched"

# The bootstrap builds at the commit it checked and follows the branch only after its wait.
grep -qF 'argocd_root_app "$gitops_url" "$sha" "$env" "$chart_repo_url"' "$here/../k8s/gitops.sh" &&
  [ "$(grep -n -e '^ok "$want Applications Synced and Healthy' -e '^\[ -z "$branch" \] || follow_branch "$branch"$' \
    "$here/../k8s/gitops.sh" | cut -d: -f1 | awk 'NR == 1 { a = $1 } NR == 2 { print ($1 == a + 1) }')" = 1 ] &&
  ok "gitops.sh: the root is applied at the commit checked, follows the branch after the wait" ||
  fail "gitops.sh: the root is applied at the commit checked, follows the branch after the wait"

# --- The fake results of a k3d run.
out=$work/out
mkdir -p "$out/logs"
echo gitops >"$out/scenario"
printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$out/results.tsv"
printf '01\tk8s-up\tok\t0\t100\t160\t60\t\n02\tk8s-smoke\tfail\t1\t160\t170\t10\t\n' >>"$out/results.tsv"
printf '03\tdrill-k8s-keda\tfail\t1\t170\t180\t10\t\n04\tdrill-k8s-threats\tfail\t1\t180\t190\t10\t\n' >>"$out/results.tsv"
printf '05\tdrill-alert-to-sentry\tfail\t1\t190\t200\t10\t\n06\tdrill-obs-threats\tok\t0\t200\t210\t10\t\n' \
  >>"$out/results.tsv"
printf '12\tk8s-up\tfail\t1\t210\t220\t10\t\n13\tk8s-up\tfail\t1\t220\t230\t10\t\n' >>"$out/results.tsv"
# A target that quotes service logs: the log of a failed migrate Job (JSON records, one with a secret, and a panic),
# marked by mark_log as install.sh marks it, and the gateway's access log line of a trace, between lines of its own.
{
  echo "ok    cluster ready"
  echo "Job svp/feed-service-migrate failed; log of its last failed attempt, copied before its pod was deleted:"
  {
    echo '{"time":"2026-10-25T08:00:00Z","level":"WARN","msg":"database not reachable, retrying","attempt":1}'
    echo "{\"time\":\"2026-10-25T08:00:01Z\", \"level\": \"ERROR\", \"msg\":\"dsn $quoted_secret\"}"
    echo "panic: MIGRATE-PANIC-MARKER"
  } | mark_log_of svp
  echo "FAIL  install feed-service"
} >"$out/logs/01-k8s-up.log"
# A failed make k8s-up with the report of unready_report above, and two log lines of namespaces whose logs never get
# in, as a mistake of unready_report would print them; another whose broker log holds a cluster secret.
{
  echo "helm upgrade --install redpanda (wave 3, namespace svp-data)"
  cat "$unready"
  cat "$timeout_report"
  echo "    [svp] APP-FORGED-MARKER"
  echo "    [envoy-gateway-system] ENVOY-MARKER"
  echo "FAIL  install redpanda"
} >"$out/logs/12-k8s-up.log"
printf '    [svp-data] SECRET-TAIL-MARKER sasl password %s\nFAIL  install redpanda\n' "$kafka_secret" \
  >"$out/logs/13-k8s-up.log"
{
  echo "ok    T2 08:00:05Z: earliest error trace after T0 abc"
  echo 'ok    T3 08:00:09Z: gateway access log of trace abc: {"route":"/feed","status":"503","user_id":"USER-ID-MARKER"}'
  echo "FAIL  T4 GlitchTip has an event"
} >"$out/logs/05-drill-alert-to-sentry.log"
# A failed target that printed a secret on stdout and a JWT on stderr, both into its log as verify-run.sh sends them.
{
  echo "ok    step 1"
  echo "response body: password=$quoted_secret"
  echo "Authorization header seen: $jwt" >&2
  echo "FAIL  step 2"
} >"$out/logs/02-k8s-smoke.log" 2>&1
{
  for i in $(seq 1 60); do echo "sample $i lag 3"; done
  echo "FAIL  KEDA-TAIL-MARKER scale down took too long"
} >"$out/logs/03-drill-k8s-keda.log"
# The output of a threat model drill: item headings, verdicts, what the probes got back (in the forms the filter must
# not take for one of its own lines), the closing table.
{
  echo "== IN-2/IN-4"
  echo "ok    IN-4: svp-feed-service may only read its topics (svp-admin)"
  echo "probe answered: PROBE-BODY-MARKER"
  echo "== NP-1"
  echo "FAIL  NP-1: probe reached s3"
  # An item stopped under set -e: bash's own line is left out, the drill's line after it is kept.
  echo "deploy/k8s/drills/threats.sh: line 1742: BASH-ERROR-MARKER: unbound variable"
  echo "FAIL  NP-1: the item ended with exit status 1"
  echo "== PROBE-HEADING-MARKER: body"
  echo "  PROBE-INDENT-MARKER   PASS with more"
  echo "== WEB-7"
  echo "ok    user @drill_ab12 registered: 303, session cookie __Host-Http-svp_sid in the drill's cookie jar"
  echo
  echo "drill-k8s-threats (20261025T080000Z-ab12)"
  printf '  %-14s %s\n' ITEM RESULT IN-2/IN-4 PASS NP-1 FAIL
} >"$out/logs/04-drill-k8s-threats.log"
# Verdict lines of a threat drill holding the session cookie in a form its value is written in, one file each: a
# header, a cookie jar line, JSON, and the name ending a line. A plain target output that names the cookie in prose.
printf 'FAIL  WEB-2: sent Cookie: __Host-Http-svp_sid=SID-MARKER\n' >"$out/logs/07-drill-k8s-threats.log"
printf 'ok    jar: svp.localhost\tFALSE\t/\tTRUE\t0\t__Host-Http-svp_sid\tSID-MARKER\n' >"$out/logs/08-drill-k8s-threats.log"
printf 'FAIL  WEB-9: got {"name":"svp_sid","value":"SID-MARKER"}\n' >"$out/logs/09-drill-obs-threats.log"
printf 'FAIL  WEB-9: the cookie jar holds svp_sid\n' >"$out/logs/10-drill-obs-threats.log"
printf 'ok    session cookie __Host-Http-svp_sid in the jar\n' >"$out/logs/11-k8s-web-e2e.log"
printf 'ok    OPS-1: 8 loopback ports\nprobe answered: PROBE-OBS-MARKER\ndrill-obs-threats: all checks passed\n' \
  >"$out/logs/06-drill-obs-threats.log"
echo '{}' >"$out/.hidden.json"
# A file of the results folder that is not on the allow list.
echo '{"label":"start"}' >"$out/ram-rest-start.json"

# --- The fake checkout's results.
d=$repo/.k8s/drills
echo '{"result":"PASS","screenshot":"data:image/jpeg;base64,/9j/eyJabcdefghijklmnopqrstuvwxyz0123"}' >"$d/canary-drill-1.json"
echo "{\"restored\":true,\"s3\":\"$cluster_secret\"}" >"$d/backup-1.json"
echo "{\"blob\":\"$(b64 "$env_secret")\"}" >"$d/b64-1.json"
echo "{\"config\":\"$line_secret\"}" >"$d/multiline-1.json"
echo "{\"roles\":[\"$role_name\"],\"admin\":\"admin@svp.local\",\"org\":\"svp\",\"kid\":\"kid-of-the-signing-key\",\"release\":\"$helm_payload\"}" \
  >"$d/names-1.json"
printf '%s\n' "$identifiers" | jq -R -s '{identifiers: .}' >"$d/identifiers-1.json"
echo "{\"kafka\":\"$kafka_secret\"}" >"$d/kafka-1.json"
# A JWT and nothing else: the only file whose drop the jwt rule alone decides.
echo "{\"t\":\"$jwt\"}" >"$d/jwt-1.json"
echo "{\"frame\":\"$bin_secret\"}" >"$d/binary-piece-1.json"
echo "probe output" >"$d/threats-1.log"
echo "1792332629000 u1 explore 200 12" >"$d/traffic-1.log"
head -c 6000000 /dev/zero | tr '\0' a >"$d/big-1.json"
ln -s ../../.env "$d/link-1.json"
echo "CA" >"$repo/.k8s/ca.crt"
# Results of the checkout outside .k8s/drills, which the filter does not even look at.
echo '{"metrics":{"http_reqs":{"count":10}}}' >"$repo/.k6/local-1/summary.json"
echo '{"audits":{}}' >"$repo/.web/svp-frontend/test-results/lighthouse/b.report.json"

# job: the variables a GitHub Actions job runs the two scripts with (deploy/ci/platform.sh prints masks and warnings
# as the runner's commands only there), with the job's temp directory in $work.
job=(GITHUB_ACTIONS=true RUNNER_TEMP="$work")
# collect NAME SECRETS_DIR [VAR=VALUE...]: runs verify-collect.sh into $work/art-NAME, its stdout and stderr in
# $work/NAME.log.
collect() {
  local name=$1 secrets=$2
  shift 2
  rm -rf "$work/art-$name"
  env "${job[@]}" PATH="$work/bin:$PATH" SVP_VERIFY_REPO="$repo" SVP_VERIFY_OUT="$out" \
    SVP_VERIFY_ARTIFACT="$work/art-$name" \
    SVP_VERIFY_SECRETS="$secrets" "$@" "$here/verify-collect.sh" >"$work/$name.log" 2>&1 ||
    fail "$name: verify-collect.sh exits 0"
}
# expect NAME SRC kept|RULE: the line of SRC in files.txt of run NAME.
expect() {
  local got
  got=$(awk -F '\t' -v s="$2" '$2 == s { print ($1 == "kept" ? "kept" : $3) }' "$work/art-$1/files.txt")
  if [ "$got" = "$3" ]; then ok "$1: $2 $3"; else fail "$1: $2: want $3, got '${got:-not listed}'"; fi
}
# no_leak NAME [LIST]: no fake secret (of LIST, default all of them) in the output of run NAME outside the
# ::add-mask:: lines, none in its artifact.
no_leak() {
  local list=$work/${2:-all-secrets}
  if grep -v '^::add-mask::' "$work/$1.log" | grep -qF -f "$list"; then
    fail "$1: a secret reached the job's log outside ::add-mask::"
  else
    ok "$1: no secret in the job's log outside ::add-mask::"
  fi
  if grep -rqaF -f "$list" "$work/art-$1"; then
    fail "$1: a secret reached the artifact"
  else
    ok "$1: no secret in the artifact"
  fi
}
has() { if grep -qF -- "$3" "$work/$1.log"; then ok "$1: $2"; else fail "$1: $2"; fi; }
lacks() { if grep -qF -- "$3" "$work/$1.log"; then fail "$1: $2"; else ok "$1: $2"; fi; }
same() { if [ "$3" = "$2" ]; then ok "$1"; else fail "$1: want '$2', got '$3'"; fi; }

# --- verify-mask.sh env on its own: what it masks, what it keeps, and the marker only once.
mask() {
  env "${job[@]}" SVP_VERIFY_REPO="$repo" SVP_VERIFY_SECRETS="$work/mask-secrets" "$here/verify-mask.sh" env \
    >"$work/$1.log" 2>&1
}
mask mask1
# A % of a value goes out as %25, which the runner reads back as %.
for v in "$env_secret" "${quoted_secret//%/%25}" "$dsn_secret" "$(b64 "$quoted_secret")"; do
  grep -qxF "::add-mask::$v" "$work/mask1.log" || fail "mask: a secret of .env (or its base64) is masked"
done
ok "mask: the secrets of .env are masked, raw and base64, special characters included (% as %25)"
for v in abc12 admin@svp.local svp kid-of-the-signing-key; do
  if grep -qF "::add-mask::$v" "$work/mask1.log"; then fail "mask: '$v' is not masked"; fi
done
ok "mask: a short value, the admin email, the org and a key id are not masked"
[ "$(grep -c '^mask-check: ' "$work/mask1.log")" = 1 ] && ok "mask: one mask-check line" || fail "mask: one mask-check line"
marker=$(sed -n 's/^mask-check: //p' "$work/mask1.log")
grep -qxF "::add-mask::$marker" "$work/mask1.log" && ok "mask: the marker is masked before it is printed" ||
  fail "mask: the marker is masked before it is printed"
# GNU stat first: BSD stat rejects -c, while GNU stat takes -f too, for something else.
[ "$(stat -c %a "$work/mask-secrets/env.values" 2>/dev/null || stat -f %Lp "$work/mask-secrets/env.values")" = 600 ] &&
  ok "mask: env.values has mode 600" || fail "mask: env.values has mode 600"
mask mask2
if grep -q '::add-mask::\|^mask-check:' "$work/mask2.log"; then
  fail "mask: a second call masks nothing new and prints no marker"
else
  ok "mask: a second call masks nothing new and prints no marker"
fi

# --- verify-mask.sh cluster on binary values, each a Secret of namespace svp-obs of a cluster of its own. The cut it
# made with jq's splits() took minutes for 200 KiB (its time grows with the square of the value): a value that size is
# done in seconds now. On small values it keeps what that cut kept: random bytes, and text with CR, NUL, tab, the C1
# control NEL, U+FFFD itself, a byte that is not UTF-8, blanks around a line, several lines.
# mask_cluster NAME DIR FILE...: verify-mask.sh cluster with a fake kubectl listing one Secret per FILE (raw bytes), in a
# list of its own ($work/NAME.secrets/cluster.values); its output in $work/NAME.log.
mask_cluster() {
  local name=$1 dir=$2 f i=0
  shift 2
  mkdir -p "$dir"
  for f in "$@"; do
    i=$((i + 1))
    base64 <"$f" | tr -d '\n' | jq -R -s --arg k "v$i" '{($k): .}'
  done | jq -s '{items: [{type: "Opaque", metadata: {name: "binary"}, data: add}]}' >"$dir/svp-obs.json"
  env "${job[@]}" PATH="$work/bin:$PATH" FAKE_KUBECTL_DIR="$dir" SVP_VERIFY_SECRETS="$work/$name.secrets" \
    "$here/verify-mask.sh" cluster >"$work/$name.log" 2>&1 || fail "$name: verify-mask.sh cluster exits 0"
}
mb=$work/mask-bin
mkdir -p "$mb"
head -c 204800 /dev/urandom >"$mb/big"
started=$SECONDS
mask_cluster mask-big "$mb/kube-big" "$mb/big"
took=$((SECONDS - started))
[ "$took" -le 10 ] && ok "mask: a binary value of 200 KiB is cut in ${took} s (10 at most)" ||
  fail "mask: a binary value of 200 KiB is cut in ${took} s (10 at most)"
# comm, not grep -xF: BSD grep runs out of memory on a pattern that long.
{ base64 <"$mb/big" | tr -d '\n'; echo; } >"$mb/big.b64"
[ "$(LC_ALL=C comm -12 "$mb/big.b64" "$work/mask-big.secrets/cluster.values" | grep -c .)" = 1 ] &&
  ok "mask: the binary value of 200 KiB is kept whole in base64" || fail "mask: the binary value of 200 KiB is kept whole in base64"
for i in 1 2 3; do head -c 3000 /dev/urandom >"$mb/small-$i"; done
printf '%s' "$binary_value" >"$mb/small-4"
printf '  lead-and-trail-%s  \r\ncr-nul-%s\000tab-%s\tnel-%s\302\205fffd-%s\357\277\275bad-%s\377end-of-it\n\n' \
  "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" \
  "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" >"$mb/small-5"
mask_cluster mask-small "$mb/kube-small" "$mb"/small-*
# The cut as it was, with the length rule of verify-mask.sh, over the same values.
for f in "$mb"/small-*; do base64 <"$f" | tr -d '\n'; echo; done |
  jq -R -r '., (@base64d | [splits("[[:cntrl:]\ufffd]")][] | gsub("^\\s+|\\s+$"; ""))' |
  while IFS= read -r v || [ -n "$v" ]; do [ "${#v}" -lt 8 ] || printf '%s\n' "$v"; done | LC_ALL=C sort -u >"$mb/want"
cmp -s "$mb/want" "$work/mask-small.secrets/cluster.values" &&
  ok "mask: small binary and text values give the pieces the regex cut gave ($(wc -l <"$mb/want" | tr -d ' ') lines)" ||
  fail "mask: small binary and text values give the pieces the regex cut gave"

# --- k3d run, cluster readable.
collect k3d "$work/secrets-k3d"
for src in '$SVP_VERIFY_OUT/results.tsv' '$SVP_VERIFY_OUT/scenario' \
  '$SVP_VERIFY_OUT/logs/01-k8s-up.log' '$SVP_VERIFY_OUT/logs/03-drill-k8s-keda.log' \
  '$SVP_VERIFY_OUT/logs/04-drill-k8s-threats.log (verdict lines)' \
  '$SVP_VERIFY_OUT/logs/06-drill-obs-threats.log (verdict lines)' \
  '$SVP_VERIFY_OUT/logs/05-drill-alert-to-sentry.log' .k8s/drills/canary-drill-1.json .k8s/drills/names-1.json \
  .k8s/drills/identifiers-1.json .k8s/drills/traffic-1.log; do
  expect k3d "$src" kept
done
expect k3d .k8s/drills/kafka-1.json secret-value
expect k3d .k8s/drills/jwt-1.json jwt
expect k3d .k8s/drills/binary-piece-1.json secret-value
expect k3d '$SVP_VERIFY_OUT/logs/02-k8s-smoke.log' secret-value
expect k3d '$SVP_VERIFY_OUT/ram-rest-start.json' not-allowed
expect k3d '$SVP_VERIFY_OUT/.hidden.json' hidden
has k3d "a hidden file gets a warning" '.hidden.json: hidden'
expect k3d .k8s/drills/backup-1.json secret-value
expect k3d .k8s/drills/b64-1.json secret-value
expect k3d .k8s/drills/multiline-1.json secret-value
expect k3d .k8s/drills/threats-1.log not-allowed
expect k3d .k8s/drills/big-1.json too-large
expect k3d .k8s/drills/link-1.json not-regular
grep -qE '\.k6/|\.web/' "$work/art-k3d/files.txt" || [ -n "$(find "$work/art-k3d" -name 'summary.json' -o -name 'b.report.json')" ] &&
  fail "k3d: .k6 and the clone of svp-frontend are not read" || ok "k3d: .k6 and the clone of svp-frontend are not read"
for n in 07-drill-k8s-threats 08-drill-k8s-threats 09-drill-obs-threats 10-drill-obs-threats; do
  expect k3d "\$SVP_VERIFY_OUT/logs/$n.log (verdict lines)" session-cookie
done
expect k3d '$SVP_VERIFY_OUT/logs/11-k8s-web-e2e.log' session-cookie
grep -rqa SID-MARKER "$work/art-k3d" && fail "k3d: no session cookie value in the artifact" ||
  ok "k3d: no session cookie value in the artifact"
[ -f "$work/art-k3d/k8s-drills/canary-drill-1.json" ] && ok "k3d: the checkout's files under a visible folder" ||
  fail "k3d: the checkout's files under a visible folder"
[ -z "$(find "$work/art-k3d" -name '.*')" ] && ok "k3d: no hidden file in the artifact" || fail "k3d: no hidden file in the artifact"
[ ! -e "$work/art-k3d/ca.crt" ] && ! grep -q 'ca.crt' "$work/art-k3d/files.txt" && ok "k3d: .k8s/ca.crt not a candidate" ||
  fail "k3d: .k8s/ca.crt not a candidate"
grep -q 'PROBE-BODY-MARKER' "$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log" &&
  fail "k3d: the threat drill's probe output is left out" || ok "k3d: the threat drill's probe output is left out"
grep -q '^FAIL  NP-1' "$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log" && ok "k3d: the threat drill's verdicts kept" ||
  fail "k3d: the threat drill's verdicts kept"
grep -q '^ok    IN-4: svp-feed-service .*(svp-admin)' "$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log" &&
  ok "k3d: a verdict naming Kafka users and svp-admin is kept" || fail "k3d: a verdict naming Kafka users and svp-admin is kept"
v=$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log
want=$(printf '%s\n' "== IN-2/IN-4" "ok    IN-4: svp-feed-service may only read its topics (svp-admin)" "== NP-1" \
  "FAIL  NP-1: probe reached s3" "FAIL  NP-1: the item ended with exit status 1" "== WEB-7" \
  "ok    user @drill_ab12 registered: 303, session cookie __Host-Http-svp_sid in the drill's cookie jar" \
  "drill-k8s-threats (20261025T080000Z-ab12)" "$(printf '  %-14s %s' ITEM RESULT)" \
  "$(printf '  %-14s %s' IN-2/IN-4 PASS)" "$(printf '  %-14s %s' NP-1 FAIL)")
[ "$(cat "$v")" = "$want" ] &&
  ok "k3d: the threat drill keeps its item headings, verdicts (the session cookie named in prose) and closing table, nothing else" ||
  fail "k3d: the threat drill keeps its item headings, verdicts (the session cookie named in prose) and closing table, nothing else"
v=$work/art-k3d/logs/06-drill-obs-threats.verdicts.log
[ "$(cat "$v")" = "$(printf '%s\n' "ok    OPS-1: 8 loopback ports" "drill-obs-threats: all checks passed")" ] &&
  ok "k3d: the threat drill's closing line is kept, its probe output left out" ||
  fail "k3d: the threat drill's closing line is kept, its probe output left out"
masked=0
for v in $identifiers; do
  grep -qxF -e "::add-mask::$v" -e "::add-mask::$(b64 "$v")" "$work/k3d.log" && masked=1
done
[ "$masked" = 0 ] && ok "k3d: user names, emails, key ids and mechanisms of the Secrets are not masked" ||
  fail "k3d: user names, emails, key ids and mechanisms of the Secrets are not masked"
grep -qxF "::add-mask::$kafka_secret" "$work/k3d.log" && ok "k3d: a password beside a user name is masked" ||
  fail "k3d: a password beside a user name is masked"
# Service log lines quoted by a target are left out of its copy, and files.txt counts them.
a=$work/art-k3d/logs
if grep -qE '"(msg|level)"' "$a/01-k8s-up.log" || grep -q 'USER-ID-MARKER' "$a/05-drill-alert-to-sentry.log"; then
  fail "k3d: service log lines are left out of the targets' outputs"
else
  ok "k3d: service log lines are left out of the targets' outputs"
fi
grep -q '^FAIL  install feed-service' "$a/01-k8s-up.log" && grep -q '^FAIL  T4' "$a/05-drill-alert-to-sentry.log" &&
  ok "k3d: the targets' own lines around them are kept" || fail "k3d: the targets' own lines around them are kept"
grep -qF "$(printf 'kept\t$SVP_VERIFY_OUT/logs/01-k8s-up.log\tlogs/01-k8s-up.log\t3 service log line(s) left out')" \
  "$work/art-k3d/files.txt" && ok "k3d: files.txt counts the lines left out" || fail "k3d: files.txt counts the lines left out"
grep -q MIGRATE-PANIC-MARKER "$a/01-k8s-up.log" && fail "k3d: a migrate Job's log line that is no JSON is left out" ||
  ok "k3d: a migrate Job's log line that is no JSON is left out"
# The log tails of unready_report: an infrastructure container's kept, a line of namespace svp or of Envoy left out,
# in the artifact and in the end of the failed target printed to the job's log alike.
expect k3d '$SVP_VERIFY_OUT/logs/12-k8s-up.log' kept
expect k3d '$SVP_VERIFY_OUT/logs/13-k8s-up.log' secret-value
grep -qxF "    [svp-data] INFRA-TAIL-MARKER" "$a/12-k8s-up.log" && grep -qF INFRA-MESSAGE-MARKER "$a/12-k8s-up.log" &&
  grep -qF "    [svp-obs] OPERATOR-PREVIOUS-MARKER" "$a/12-k8s-up.log" &&
  grep -qxF "  Prometheus svp-obs/kps-prometheus: no status conditions (no controller has reconciled it)" "$a/12-k8s-up.log" &&
  grep -qxF "    Prometheus svp-obs/kps-prometheus: no status (no controller has reconciled it)" "$a/12-k8s-up.log" &&
  grep -qxF "    HTTPRoute svp/gateway: ResolvedRefs=False BackendNotFound" "$a/12-k8s-up.log" &&
  grep -q '^pod svp/gateway-abc, container gateway: ' "$a/12-k8s-up.log" &&
  ok "k3d: the log tail of an infrastructure container, every container's state and the timeout report are kept" ||
  fail "k3d: the log tail of an infrastructure container, every container's state and the timeout report are kept"
if grep -qE 'APP-FORGED-MARKER|ENVOY-MARKER' "$a/12-k8s-up.log"; then
  fail "k3d: a log line of namespace svp or envoy-gateway-system is left out"
else
  ok "k3d: a log line of namespace svp or envoy-gateway-system is left out"
fi
grep -qF "$(printf 'kept\t$SVP_VERIFY_OUT/logs/12-k8s-up.log\tlogs/12-k8s-up.log\t2 service log line(s) left out')" \
  "$work/art-k3d/files.txt" && ok "k3d: files.txt counts the log lines of other namespaces" ||
  fail "k3d: files.txt counts the log lines of other namespaces"
has k3d "the log tail of an infrastructure container of a failed target is printed" '    [svp-data] INFRA-TAIL-MARKER'
lacks k3d "a log line of namespace svp of a failed target is not printed" APP-FORGED-MARKER
lacks k3d "a log line of Envoy of a failed target is not printed" ENVOY-MARKER
lacks k3d "a log tail with a secret is not printed" SECRET-TAIL-MARKER
lacks k3d "a failed target's service log lines are not printed" 'USER-ID-MARKER'
no_leak k3d
has k3d "the end of a failed target's clean output is printed" KEDA-TAIL-MARKER
has k3d "the verdicts of a failed threat drill are printed" 'FAIL  NP-1'
has k3d "the closing table of a failed threat drill is printed" "$(printf '  %-14s %s' NP-1 FAIL)"
lacks k3d "the probe output of a threat drill is not printed" 'PROBE-'
lacks k3d "the output of a failed target with a secret is not printed" 'step 2'
has k3d "a dropped file gets a warning with its rule" '::warning::.k8s/drills/backup-1.json: secret-value'
lacks k3d "not-allowed files get no warning" '::warning::.k8s/drills/threats-1.log'
if grep -qF "::add-mask::$helm_payload" "$work/k3d.log" || grep -qF "::add-mask::$role_name" "$work/k3d.log"; then
  fail "k3d: Helm release payloads and user names are not masked"
else
  ok "k3d: Helm release payloads and user names are not masked"
fi
grep -qxF "::add-mask::$cluster_secret" "$work/k3d.log" && grep -qxF "::add-mask::$line_secret" "$work/k3d.log" &&
  ok "k3d: a cluster Secret and a line of a Secret of several lines are masked" ||
  fail "k3d: a cluster Secret and a line of a Secret of several lines are masked"
masked=1
for v in "$cr_secret" "$ctl_secret" "$nl_secret" "$bin_secret" "$(b64 "$binary_value")"; do
  grep -qxF "::add-mask::$v" "$work/k3d.log" || masked=0
done
[ "$masked" = 1 ] &&
  ok "k3d: each piece of a binary value between control characters or bytes not UTF-8 is masked, and the value whole" ||
  fail "k3d: each piece of a binary value between control characters or bytes not UTF-8 is masked, and the value whole"
# The replacement character U+FFFD in UTF-8: what a byte that is not UTF-8 becomes when decoded as text.
if grep -a '^::add-mask::' "$work/k3d.log" | LC_ALL=C grep -q -e '[[:cntrl:]]' -e $'\xef\xbf\xbd'; then
  fail "k3d: no mask line holds a control character or U+FFFD"
else
  ok "k3d: no mask line holds a control character or U+FFFD"
fi

# --- k3d run, the cluster never read: only the files written on the runner itself.
collect dead "$work/secrets-dead" FAKE_KUBECTL_FAIL=1
for src in '$SVP_VERIFY_OUT/results.tsv' '$SVP_VERIFY_OUT/scenario'; do
  expect dead "$src" kept
done
for src in '$SVP_VERIFY_OUT/logs/01-k8s-up.log' '$SVP_VERIFY_OUT/logs/03-drill-k8s-keda.log' \
  .k8s/drills/canary-drill-1.json .k8s/drills/backup-1.json; do
  expect dead "$src" no-secret-list
done
no_leak dead
lacks dead "no target output is printed" KEDA-TAIL-MARKER
has dead "the missing list is a warning" '::warning::verify-collect: a secret list could not be read'

# --- k3d run, cluster gone at the end but read while it ran: that list still counts.
collect late "$work/secrets-k3d" FAKE_KUBECTL_FAIL=1
expect late .k8s/drills/backup-1.json secret-value
expect late .k8s/drills/canary-drill-1.json kept
has late "it says the earlier list is used" 'the list read while it ran is used'
no_leak late

# --- k3d run, a Secret made again with a new value: both values are searched for.
rebuilt_secret=$(openssl rand -hex 20)
printf '%s\n' "$rebuilt_secret" >>"$work/all-secrets"
cp -R "$work/kube" "$work/kube.orig"
for ns in svp-data svp-obs; do
  jq --arg old "$(b64 "$cluster_secret")" --arg new "$(b64 "$rebuilt_secret")" \
    '.items[].data |= map_values(if . == $old then $new else . end)' "$work/kube.orig/$ns.json" >"$work/kube/$ns.json"
done
echo "{\"s3\":\"$rebuilt_secret\"}" >"$d/rebuilt-1.json"
collect rebuilt "$work/secrets-k3d"
expect rebuilt .k8s/drills/backup-1.json secret-value
expect rebuilt .k8s/drills/rebuilt-1.json secret-value
no_leak rebuilt
rm -rf "$work/kube" "$d/rebuilt-1.json"
mv "$work/kube.orig" "$work/kube"

# --- compose-obs run: no cluster list needed, .env's still applies.
echo compose-obs >"$out/scenario"
# The object store's tests of a compose-obs run, and a target's output that printed the store's root password (a value
# of .env).
printf '%s\n' '=== RUN   TestIntegrationPresignedPost' \
  '    integration_test.go:250: POST http://127.0.0.1:9000/media: status 400' \
  '--- PASS: TestIntegrationPresignedPost (0.20s)' \
  'object store tests: 39 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0' \
  >"$out/logs/14-test-stack-objstore.log"
printf 'make up: s3 root %s\n' "$env_secret" >"$out/logs/15-up.log"
collect compose "$work/secrets-compose" FAKE_KUBECTL_FAIL=1
expect compose '$SVP_VERIFY_OUT/logs/14-test-stack-objstore.log' kept
expect compose '$SVP_VERIFY_OUT/logs/15-up.log' secret-value
expect compose .k8s/drills/canary-drill-1.json kept
expect compose .k8s/drills/b64-1.json secret-value
expect compose '$SVP_VERIFY_OUT/logs/02-k8s-smoke.log' secret-value
# A compose run has no cluster, so a value only a cluster Secret would hold is no secret of that run.
expect compose .k8s/drills/backup-1.json kept
no_leak compose env-secrets

# --- An .env that breaks its rule: nothing masked, no value printed, nothing from the stack copied.
cp "$repo/.env" "$work/env.good"
printf 'SVP_BROKEN_PASSWORD=$%s\n' "$env_secret" >>"$repo/.env"
collect broken "$work/secrets-broken"
expect broken '$SVP_VERIFY_OUT/results.tsv' kept
expect broken .k8s/drills/canary-drill-1.json no-secret-list
has broken "the broken line is named" 'SVP_BROKEN_PASSWORD'
no_leak broken
cp "$work/env.good" "$repo/.env"

# --- verify-run.sh: the build target's failure skips the rest at once, SVP_VERIFY_TARGETS picks targets, every scenario
# clones svp-gitops first (make gitops-clone) and starts nothing when that fails. It runs from a copy in a throwaway
# tree with a fake .env, a fake make first on PATH (it logs its arguments and fails for the targets FAKE_MAKE_FAIL
# names) and the fake kubectl above (no cluster answers), so no target, no container, no cluster, no clone and no real
# .env is ever reached. verify-run.sh needs GNU timeout (and GNU date for its time lines: gdate on macOS).
vr=$work/verify-run
vb=$work/verify-run-bin
mkdir -p "$vr/deploy/ci" "$vr/deploy/k8s" "$vr/deploy/observability/glitchtip" "$vb"
cp "$here/verify-run.sh" "$here/verify-mask.sh" "$here/platform.sh" "$vr/deploy/ci/"
cp "$here/../k8s/lib.sh" "$vr/deploy/k8s/"
cp -R "$here/verify" "$vr/deploy/ci/"
cp "$here/../observability/glitchtip/dotenv.sh" "$vr/deploy/observability/glitchtip/"
cp "$repo/.env" "$vr/.env"
cat >"$vb/make" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_MAKE_LOG"
[ "$1" = -s ] && shift
[ -f "${FAKE_MAKE_DIR:-/nonexistent}/$1.out" ] && cat "$FAKE_MAKE_DIR/$1.out"
case " ${FAKE_MAKE_FAIL:-} " in *" $1 "*) exit 2 ;; esac
case " ${FAKE_MAKE_SLOW:-} " in *" $1 "*) sleep 60 ;; esac
EOF
printf '#!/bin/sh\ncommand -v gdate >/dev/null 2>&1 && exec gdate "$@"\nexec /bin/date "$@"\n' >"$vb/date"
chmod 755 "$vb/make" "$vb/date"
# The images drill-k8s-supplychain reads from GHCR, named after what it asks for instead.
printf '#!/bin/sh\necho "fake/$1${2:+-$2}@sha256:0"\n' >"$vr/deploy/ci/ghcr-digest.sh"
chmod 755 "$vr/deploy/ci/ghcr-digest.sh"
# The copy is a git checkout on a branch, which gitops does not give Argo CD: the cluster is built at main of
# svp-gitops whatever the branch of this repository, at the commit of origin/main in the clone where make gitops-clone
# leaves it (a fake one here, with one commit), given as that commit.
git -c init.defaultBranch=feat/stage6b-verify init -q "$vr"
fake_clone=$vr/.gitops/svp-gitops
git init -q "$fake_clone" &&
  git -C "$fake_clone" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -q --allow-empty -m base &&
  git -C "$fake_clone" update-ref refs/remotes/origin/main HEAD
fake_clone_sha=$(git -C "$fake_clone" rev-parse HEAD)
# run_verify NAME SCENARIO [VAR=VALUE...]: the copy of verify-run.sh (in run_tree, default $vr) for SCENARIO; its
# output in $work/run-NAME.log, the make calls in $work/run-NAME.make, its results in $work/run-NAME.out; prints its
# exit status. It runs as on a machine, without the variables of any CI: a runner sets CI=true, which alone makes
# platform.sh refuse to run.
run_verify() {
  local name=$1 scenario=$2 rc=0
  shift 2
  : >"$work/run-$name.make"
  env -u GITHUB_ACTIONS -u CI -u GITLAB_CI -u JENKINS_URL -u TF_BUILD PATH="$vb:$work/bin:$PATH" \
    SVP_VERIFY_OUT="$work/run-$name.out" SVP_VERIFY_SECRETS="$work/run-$name.secrets" \
    FAKE_MAKE_LOG="$work/run-$name.make" SVP_VERIFY_TARGETS= "$@" \
    "${run_tree:-$vr}/deploy/ci/verify-run.sh" "$scenario" >"$work/run-$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
# makes NAME: the make calls of run NAME.
makes() { cat "$work/run-$1.make"; }
# results NAME: "id name status note" of each target of run NAME, one per line.
results() { awk -F '\t' 'NR > 1 { print $1, $2, $3, $8 }' "$work/run-$1.out/results.tsv"; }
compose_names="up smoke drill-obs-threats test-stack-objstore"
gitops_names="k8s-gitops-up gitops-env gitops-external-secrets gitops-argocd-metrics gitops-admission-metrics k8s-smoke drill-k8s-supplychain
drill-k8s-threats"
gitops_build="k8s-gitops-up GITOPS_REV=$fake_clone_sha"
# want_rows NAMES STATUS_OF_FIRST NOTE_OF_REST [ID NAME STATUS NOTE]...: the rows of a run: the first of NAMES with
# STATUS_OF_FIRST and no note, every other skipped with NOTE_OF_REST, except the rows given whole after it.
want_rows() {
  local i=0 name line names=$1 first=$2 rest=$3
  shift 3
  for name in $names; do
    i=$((i + 1))
    line=$(printf '%02d %s' "$i" "$name")
    if [ "$i" = 1 ]; then line="$line $first "; else line="$line skipped $rest"; fi
    for over in "$@"; do [ "${over%% * * *}" = "$(printf '%02d' "$i")" ] && line=$over; done
    echo "$line"
  done
}
if timeout --version 2>/dev/null | grep -q GNU; then
  # Each scenario: its failed build target makes the run fail and skips every other target at once.
  rc=$(run_verify infra compose-obs FAKE_MAKE_FAIL=up)
  same "verify-run: a failed build target makes the run fail" 1 "$rc"
  same "verify-run: after the clone of svp-gitops and a failed build target no other target runs" \
    "$(printf -- '-s gitops-clone\nup OBS=lgtm')" "$(makes infra)"
  same "verify-run: every target after a failed build target is skipped for it" \
    "$(want_rows "$compose_names" fail 'infrastructure step failed')" "$(results infra)"
  rc=$(run_verify infra-gitops gitops FAKE_MAKE_FAIL=k8s-gitops-up)
  same "verify-run: gitops's failed build target makes the run fail" 1 "$rc"
  same "verify-run: gitops builds the cluster at the commit of main of svp-gitops, cloned first" \
    "$(printf -- '-s gitops-clone\n%s' "$gitops_build")" "$(makes infra-gitops)"
  same "verify-run: gitops skips every target after its failed build target for it" \
    "$(want_rows "$gitops_names" fail 'infrastructure step failed')" "$(results infra-gitops)"

  # A run stopped while a target runs (a cancel, the step's timeout-minutes): that target is cancelled.
  : >"$work/run-cut.make"
  env -u GITHUB_ACTIONS -u CI -u GITLAB_CI -u JENKINS_URL -u TF_BUILD PATH="$vb:$work/bin:$PATH" \
    SVP_VERIFY_OUT="$work/run-cut.out" SVP_VERIFY_SECRETS="$work/run-cut.secrets" FAKE_MAKE_LOG="$work/run-cut.make" \
    SVP_VERIFY_TARGETS=smoke FAKE_MAKE_SLOW=smoke "$vr/deploy/ci/verify-run.sh" compose-obs >"$work/run-cut.log" 2>&1 \
    </dev/null &
  cut_pid=$!
  for _ in $(seq 1 100); do
    grep -q '^smoke' "$work/run-cut.make" && break
    sleep 0.1
  done
  kill -TERM "$cut_pid"
  wait "$cut_pid" || :
  results cut | grep -qx '02 smoke cancelled the run was cancelled or the step timed out' &&
    ok "verify-run: a run stopped mid-target records it cancelled" ||
    fail "verify-run: a run stopped mid-target records it cancelled"

  # The narrow dispatch: the build target, then only the chosen ones, in the scenario's order.
  rc=$(run_verify one gitops 'SVP_VERIFY_TARGETS=k8s-smoke drill-k8s-supplychain')
  same "verify-run: a run of the chosen targets that pass passes" 0 "$rc"
  same "verify-run: gitops clones svp-gitops, then only the build target and the chosen ones run" \
    "$(printf -- '-s gitops-clone\n%s\nk8s-smoke\n%s' "$gitops_build" "drill-k8s-supplychain \
SUPPLYCHAIN_UNSIGNED=fake/newest-drill-unsigned@sha256:0 SUPPLYCHAIN_VULNERABLE=fake/newest-drill-vulnerable@sha256:0 \
SUPPLYCHAIN_NO_PROVENANCE=fake/newest-drill-no-provenance@sha256:0")" "$(makes one)"
  same "verify-run: the targets left out keep their ids and are skipped as not in targets" \
    "$(want_rows "$gitops_names" ok 'not in targets' '06 k8s-smoke ok ' '07 drill-k8s-supplychain ok ')" \
    "$(results one)"

  rc=$(run_verify one-fails gitops 'SVP_VERIFY_TARGETS=drill-k8s-threats  k8s-smoke' FAKE_MAKE_FAIL=k8s-smoke)
  same "verify-run: a chosen target that fails makes the run fail" 1 "$rc"
  same "verify-run: chosen targets run in the scenario's order, whatever the order given" \
    "$(printf -- '-s gitops-clone\n%s\nk8s-smoke\ndrill-k8s-threats' "$gitops_build")" "$(makes one-fails)"

  rc=$(run_verify clone-fails gitops FAKE_MAKE_FAIL=gitops-clone)
  same "verify-run: a failed clone of svp-gitops makes the run fail" 1 "$rc"
  [ "$(cat "$work/run-clone-fails.make")" = "-s gitops-clone" ] && [ ! -e "$work/run-clone-fails.out/results.tsv" ] &&
    ok "verify-run: after a failed clone of svp-gitops no target starts" ||
    fail "verify-run: after a failed clone of svp-gitops no target starts"
  has run-clone-fails "the failed clone is named" "make gitops-clone (the deployment configuration svp-gitops); nothing started"

  # test-stack-objstore over the output of a fake make test-stack: a unit test and the eight integration tests pass, one
  # with a subtest; then a subtest skipped, an integration test missing, go test failing.
  fm=$work/fake-make
  mkdir -p "$fm"
  # objstore NAME [LINE...]: test-stack-objstore over that output plus LINEs (DROP_TEST leaves a test out, FAKE_FAIL
  # makes make fail); prints the step's status and its summary line.
  objstore() {
    local name=$1 t
    shift
    {
      for t in TestNewRejectsMissingConfig TestIntegrationPresignedPost TestIntegrationWorkerPermissions \
        TestIntegrationVideoServicePermissions TestIntegrationDeletePrefix TestIntegrationMultipartChecksum \
        TestIntegrationCacheControl TestIntegrationCreateOnce TestIntegrationWorkerReadsMedia; do
        [ "${DROP_TEST:-}" = "$t" ] || printf '=== RUN   %s\n--- PASS: %s (0.10s)\n' "$t" "$t"
      done
      echo '    --- PASS: TestIntegrationPresignedPost/valid_form (0.01s)'
      [ "$#" = 0 ] || printf '%s\n' "$@"
      printf 'ok  \tgithub.com/anhnvcoder/svp-backend/internal/objstore\t1.2s\n'
    } >"$fm/test-stack.out"
    run_verify "objstore-$name" compose-obs SVP_VERIFY_TARGETS=test-stack-objstore FAKE_MAKE_DIR="$fm" \
      ${FAKE_FAIL:+FAKE_MAKE_FAIL=test-stack} >/dev/null
    printf '%s ' "$(results "objstore-$name" | awk '$2 == "test-stack-objstore" { print $3 }')"
    grep '^object store tests: ' "$work/run-objstore-$name.out/logs/04-test-stack-objstore.log"
  }
  same "verify-run: test-stack-objstore passes when every test passes" \
    "ok object store tests: 10 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0" "$(objstore pass)"
  makes objstore-pass | grep -qx 'test-stack PKGS=./internal/objstore/...' &&
    ok "verify-run: test-stack-objstore runs make test-stack on internal/objstore" ||
    fail "verify-run: test-stack-objstore runs make test-stack on internal/objstore"
  same "verify-run: a skipped subtest fails test-stack-objstore" \
    "fail object store tests: 10 passed, 0 failed, 1 skipped (tests and subtests); make test-stack exit 0" \
    "$(objstore skip '    --- SKIP: TestIntegrationMultipartChecksum/trailer (0.00s)')"
  same "verify-run: an integration test that did not run fails test-stack-objstore" \
    "fail object store tests: 9 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0" \
    "$(DROP_TEST=TestIntegrationMultipartChecksum objstore missing)"
  grep -qx 'FAIL  did not pass: TestIntegrationMultipartChecksum' \
    "$work/run-objstore-missing.out/logs/04-test-stack-objstore.log" &&
    ok "verify-run: the integration test that did not pass is named" ||
    fail "verify-run: the integration test that did not pass is named"
  same "verify-run: go test failing fails test-stack-objstore" \
    "fail object store tests: 10 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 2" \
    "$(FAKE_FAIL=1 objstore exit)"

  for scn in nope dev-k3d chaos; do
    rc=$(run_verify "no-scenario-$scn" "$scn")
    same "verify-run: $scn is no scenario and stops it" 2 "$rc"
    [ ! -s "$work/run-no-scenario-$scn.make" ] && [ ! -e "$work/run-no-scenario-$scn.out/results.tsv" ] &&
      ok "verify-run: $scn starts nothing" || fail "verify-run: $scn starts nothing"
  done

  # A second copy whose scenario files are made for the test: one missing, one that declares too little, one whose
  # first target is not its build target.
  vr2=$work/verify-run-2
  mkdir -p "$vr2/deploy"
  cp -R "$vr/deploy/ci" "$vr/deploy/k8s" "$vr/deploy/observability" "$vr2/deploy/"
  cp "$vr/.env" "$vr2/.env"
  rm "$vr2/deploy/ci/verify/compose-obs.sh"
  rc=$(run_tree=$vr2 run_verify no-file compose-obs)
  same "verify-run: a scenario without its file stops it" 2 "$rc"
  has run-no-file "the missing file is named" "no file deploy/ci/verify/compose-obs.sh for scenario compose-obs"
  printf 'build=k8s-gitops-up\njob_minutes_default=160\nscenario_targets() { step k8s-gitops-up 1 make k8s-gitops-up; }\n' \
    >"$vr2/deploy/ci/verify/gitops.sh"
  rc=$(run_tree=$vr2 run_verify no-k3d gitops)
  same "verify-run: a scenario file that does not set k3d stops it" 2 "$rc"
  [ ! -s "$work/run-no-k3d.make" ] && ok "verify-run: a scenario file that declares too little starts nothing" ||
    fail "verify-run: a scenario file that declares too little starts nothing"
  printf 'build=k8s-gitops-up\njob_minutes_default=160\nk3d=1\nscenario_targets() { step other 1 make other; step k8s-gitops-up 1 make k8s-gitops-up; }\n' \
    >"$vr2/deploy/ci/verify/gitops.sh"
  rc=$(run_tree=$vr2 run_verify build-second gitops)
  same "verify-run: a scenario whose first target is not its build target stops it" 2 "$rc"
  [ ! -s "$work/run-build-second.make" ] && ok "verify-run: a scenario whose first target is not its build starts nothing" ||
    fail "verify-run: a scenario whose first target is not its build starts nothing"

  rc=$(run_verify unknown gitops 'SVP_VERIFY_TARGETS=drill-k8s-threats drill-k8s-thraets')
  same "verify-run: a name that is no target of the scenario stops it" 2 "$rc"
  [ ! -s "$work/run-unknown.make" ] && [ ! -e "$work/run-unknown.out/results.tsv" ] &&
    ok "verify-run: an unknown name stops it before any target or results.tsv" ||
    fail "verify-run: an unknown name stops it before any target or results.tsv"
  # The error names the targets of the scenario: the list that the scenario's own steps make.
  has run-unknown "an unknown name is named, with the scenario's targets" \
    "not a target of gitops: drill-k8s-thraets (its targets: $(printf '%s' "$gitops_names" | tr '\n' ' '))"
  rc=$(run_verify unknown-compose compose-obs SVP_VERIFY_TARGETS=k8s-smoke)
  same "verify-run: a target of the other scenario is unknown" 2 "$rc"
  has run-unknown-compose "the compose-obs targets are listed" \
    "(its targets: $(printf '%s' "$compose_names" | tr '\n' ' '))"

  rc=$(run_verify bad gitops $'SVP_VERIFY_TARGETS=k8s-smoke\n::warning::BAD-TARGET-MARKER')
  same "verify-run: a target list with another character stops it" 2 "$rc"
  [ ! -s "$work/run-bad.make" ] && lacks run-bad "the rejected list is not printed back" BAD-TARGET-MARKER ||
    fail "verify-run: a rejected list starts no target"
else
  echo "skip  verify-run: no GNU timeout on PATH (Linux, or coreutils on macOS)"
fi

# --- gitops_stale of deploy/ci/verify/gitops.sh: on a scheduled run, the drill image of case c or l is left out only
# when the oldest vuln attestation cosign verifies is past the policy's maximum age (72h). A fake cosign first on PATH
# answers verify-attestation with one envelope scanned FAKE_SCAN_HOURS ago, or fails with FAKE_COSIGN_FAIL=1.
mkdir -p "$work/cosign-bin"
cat >"$work/cosign-bin/cosign" <<'EOF'
#!/usr/bin/env bash
[ "$1" = verify-attestation ] && [ "${FAKE_COSIGN_FAIL:-}" != 1 ] || exit 1
jq -nc --argjson h "$FAKE_SCAN_HOURS" \
  '{payload: ({predicate: {metadata: {scanFinishedOn: (now - $h * 3600 | floor | todate)}}} | tojson | @base64)}'
EOF
chmod 755 "$work/cosign-bin/cosign"
stale_image=ghcr.io/anhnvcoder/svp-backend/drill-vulnerable@sha256:$(printf '%064d' 0)
# stale NAME CASE [VAR=VALUE...]: gitops_stale CASE on stale_image; its output in $work/stale-NAME.log, prints its status.
stale() {
  local name=$1 case=$2 rc=0
  shift 2
  env -u GITHUB_ACTIONS -u CI -u GITLAB_CI -u JENKINS_URL -u TF_BUILD PATH="$work/cosign-bin:$PATH" here="$here" \
    "$@" bash -c '. "$1/verify/gitops.sh" && gitops_stale "$2" "$3"' _ "$here" "$case" "$stale_image" \
    >"$work/stale-$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
same "gitops_stale: an attestation older than 72h leaves case c out" 0 "$(stale old c FAKE_SCAN_HOURS=100)"
has stale-old "the NOTE names the case, the age and the build of the drill images" \
  "NOTE  case c left out on this scheduled run (it SKIPs): $stale_image was scanned at"
has stale-old "the age is in hours" ", 100 h ago, within an hour of 72h or more;"
same "gitops_stale: an attestation within the last hour before 72h leaves the case out too" 0 \
  "$(stale near c FAKE_SCAN_HOURS=71.5)"
has stale-old "case c names the build of the drill images" "-f drill=true"
same "gitops_stale: case l too" 0 "$(stale old-l l FAKE_SCAN_HOURS=80)"
has stale-old-l "case l (drill-no-provenance) names the build of the drill images too" "-f drill=true"
lacks stale-old-l "case l names no rescan" "rescan=true"
same "gitops_stale: an attestation within 72h keeps the case" 1 "$(stale fresh c FAKE_SCAN_HOURS=10)"
lacks stale-fresh "nothing is noted for a case kept" NOTE
same "gitops_stale: cosign without an answer keeps the case (the drill fails it)" 1 \
  "$(stale no-cosign c FAKE_COSIGN_FAIL=1 FAKE_SCAN_HOURS=100)"

# --- The summaries of gitops-admission-metrics (gitops_admission_apiserver, gitops_admission_kyverno) over a sample of
# /metrics with the real buckets: the apiserver's 10, 25 and +Inf (two series of the Kyverno webhook, rejected false and
# true, and one of another webhook that must not count), Kyverno's 20 and 30 (policy svp-images, and another policy).
admission_sample=$work/admission-sample.txt
cat >"$admission_sample" <<'SAMPLE'
# TYPE apiserver_admission_webhook_admission_duration_seconds histogram
apiserver_admission_webhook_admission_duration_seconds_bucket{le="10",name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="false",type="validating"} 7
apiserver_admission_webhook_admission_duration_seconds_bucket{le="25",name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="false",type="validating"} 9
apiserver_admission_webhook_admission_duration_seconds_bucket{le="+Inf",name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="false",type="validating"} 10
apiserver_admission_webhook_admission_duration_seconds_sum{name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="false",type="validating"} 50.5
apiserver_admission_webhook_admission_duration_seconds_count{name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="false",type="validating"} 10
apiserver_admission_webhook_admission_duration_seconds_bucket{le="10",name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="true",type="validating"} 1
apiserver_admission_webhook_admission_duration_seconds_bucket{le="25",name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="true",type="validating"} 2
apiserver_admission_webhook_admission_duration_seconds_bucket{le="+Inf",name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="true",type="validating"} 2
apiserver_admission_webhook_admission_duration_seconds_sum{name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="true",type="validating"} 9.5
apiserver_admission_webhook_admission_duration_seconds_count{name="ivpol.validate.kyverno.svc-ignore-finegrained-svp-images",operation="CREATE",rejected="true",type="validating"} 2
apiserver_admission_webhook_admission_duration_seconds_bucket{le="10",name="validate.kyverno.svc-fail",operation="CREATE",rejected="false",type="validating"} 100
apiserver_admission_webhook_admission_duration_seconds_bucket{le="25",name="validate.kyverno.svc-fail",operation="CREATE",rejected="false",type="validating"} 100
apiserver_admission_webhook_admission_duration_seconds_bucket{le="+Inf",name="validate.kyverno.svc-fail",operation="CREATE",rejected="false",type="validating"} 100
apiserver_admission_webhook_admission_duration_seconds_sum{name="validate.kyverno.svc-fail",operation="CREATE",rejected="false",type="validating"} 3
apiserver_admission_webhook_admission_duration_seconds_count{name="validate.kyverno.svc-fail",operation="CREATE",rejected="false",type="validating"} 100
kyverno_admission_review_duration_seconds_bucket{le="20",resource_kind="Pod"} 40
kyverno_admission_review_duration_seconds_bucket{le="30",resource_kind="Pod"} 44
kyverno_admission_review_duration_seconds_bucket{le="+Inf",resource_kind="Pod"} 45
kyverno_admission_review_duration_seconds_sum{resource_kind="Pod"} 90
kyverno_admission_review_duration_seconds_count{resource_kind="Pod"} 45
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="20",policy_name="svp-images"} 5
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="30",policy_name="svp-images"} 6
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="+Inf",policy_name="svp-images"} 6
kyverno_image_validating_policy_execution_duration_seconds_sum{policy_name="svp-images"} 60
kyverno_image_validating_policy_execution_duration_seconds_count{policy_name="svp-images"} 6
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="20",policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="30",policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="+Inf",policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_sum{policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_count{policy_name="other"} 900
SAMPLE
# admission NAME FUNCTION [ARG...]: the function over the sample (SAMPLE=FILE: another text) on stdin; output in $work/admission-NAME.log.
admission() {
  local name=$1
  shift
  bash -c '. "$1/verify/gitops.sh" && shift && "$@"' _ "$here" "$@" <"${SAMPLE:-$admission_sample}" \
    >"$work/admission-$name.log" 2>&1
}
apiserver_webhook=ivpol.validate.kyverno.svc-ignore-finegrained-svp-images
admission apiserver gitops_admission_apiserver "$apiserver_webhook"
has admission-apiserver "the line adds the series of the webhook (rejected false and true) and leaves the other webhook out" \
  "apiserver_admission_webhook_admission_duration_seconds{name=$apiserver_webhook}: _count 12, _sum 60.000 s, mean 5.000 s, <= 10 s: 8, <= 25 s: 11, > 25 s: 1"
has admission-apiserver "it says where 20 s and 30 s fall in the buckets" \
  "20 s lies between le=10 and le=25, the 30 s timeout of the webhook between le=25 and +Inf"
admission kyverno gitops_admission_kyverno
has admission-kyverno "the Kyverno admission review line" \
  "kyverno_admission_review_duration_seconds: _count 45, _sum 90.000 s, mean 2.000 s, <= 20 s: 40, <= 30 s: 44, > 30 s: 1"
has admission-kyverno "the line of policy svp-images leaves the other policy out" \
  'kyverno_image_validating_policy_execution_duration_seconds{policy_name="svp-images"}: _count 6, _sum 60.000 s, mean 10.000 s, <= 20 s: 5, <= 30 s: 6, > 30 s: 0'
admission apiserver-other gitops_admission_apiserver ivpol.validate.kyverno.svc-fail-finegrained-other
has admission-apiserver-other "a webhook with no series is a NOTE" \
  "NOTE  apiserver_admission_webhook_admission_duration_seconds{name=ivpol.validate.kyverno.svc-fail-finegrained-other}: no apiserver_admission_webhook_admission_duration_seconds_count and _sum series"
admission apiserver-none gitops_admission_apiserver ""
has admission-apiserver-none "no webhook of an image policy is a NOTE" "NOTE  apiserver: no webhook of an image policy (ivpol.*)"
sed '/le="25"/d' "$admission_sample" >"$work/admission-sample-nobucket.txt"
SAMPLE=$work/admission-sample-nobucket.txt admission apiserver-nobucket gitops_admission_apiserver "$apiserver_webhook"
has admission-apiserver-nobucket "a missing bucket is a NOTE that says which" "but no bucket le= 25"
: >"$work/admission-empty.txt"
SAMPLE=$work/admission-empty.txt admission kyverno-empty gitops_admission_kyverno
has admission-kyverno-empty "no Kyverno metrics is a NOTE for the review histogram" \
  "NOTE  kyverno_admission_review_duration_seconds: no kyverno_admission_review_duration_seconds_count and _sum series in what was read"
has admission-kyverno-empty "and for the policy histogram" \
  'NOTE  kyverno_image_validating_policy_execution_duration_seconds{policy_name="svp-images"}: no'

# --- changed-services.sh: a change of a verification script builds no image; one of verify-release.sh, which the image
# jobs run, still builds all seven. GIT_DIR is set for the throwaway repository, so git can never reach another one.
cs=$work/changed-services
mkdir -p "$cs/deploy/ci" "$cs/deploy/k8s"
cp "$here/changed-services.sh" "$here/common.sh" "$here/platform.sh" "$here/verify-run.sh" "$here/verify-release.sh" \
  "$cs/deploy/ci/"
cp -R "$here/verify" "$cs/deploy/ci/"
cp "$here/../k8s/lib.sh" "$cs/deploy/k8s/"
g() {
  GIT_DIR=$cs/.git GIT_WORK_TREE=$cs git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null "$@"
}
g init -q && g add -A && g commit -qm base
# changed_by PATH: commits a change of PATH, then prints what changed-services.sh builds for that commit.
changed_by() {
  echo "# changed" >>"$cs/$1"
  g commit -qam "change $1"
  "$cs/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null
}
got=$(changed_by deploy/ci/verify-run.sh)
[ -z "$got" ] && ok "changed-services: a change of verify-run.sh builds nothing" ||
  fail "changed-services: a change of verify-run.sh builds nothing (got '$got')"
got=$(changed_by deploy/ci/verify/compose-obs.sh)
[ -z "$got" ] && ok "changed-services: a change of a scenario file of verify-run.sh builds nothing" ||
  fail "changed-services: a change of a scenario file of verify-run.sh builds nothing (got '$got')"
# verify-release.sh runs in svp-gitops's check, make k8s-gitops-up and the drills only, no image job.
got=$(changed_by deploy/ci/verify-release.sh)
[ -z "$got" ] && ok "changed-services: a change of verify-release.sh builds nothing" ||
  fail "changed-services: a change of verify-release.sh builds nothing (got '$got')"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
