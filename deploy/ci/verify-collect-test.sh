#!/usr/bin/env bash
# Tests for the artifact filter of the verification runs, deploy/ci/verify-collect.sh, and for deploy/ci/verify-mask.sh
# it calls. Everything is a fixture in a temporary directory: a fake checkout with a fake .env (the repository's .env is
# never read), a fake results folder, and a fake kubectl first on PATH that lists made-up Secrets or fails. The fake
# secrets, the JWT and the private key header are made at run time, so no file of the repository holds one. Before the
# filter, unready_report and gitops_timeout_report of deploy/k8s/lib.sh, with the same fake kubectl listing made-up pods
# and their logs, mark_log of the same file, and deploy/k8s/gitops.sh follow with a fake kubectl of its own; their
# output is part of a fake step's output, which no artifact may hold. verify-mask.sh cluster on a binary value of
# 200 KiB, timed, and on small ones against the cut it made before. Then the filter over the results of a run of each
# scenario: what it keeps (the table of the steps, the verdict lines of drill-obs-threats, the admission figures, the
# JUnit reports and JSON of the drills, the drill traffic's log), what it refuses whole (every other step's output),
# and the scan of what it keeps (a secret value of .env or of the cluster, raw, in base64 or a piece of a binary value,
# a JWT, Bearer, Set-Cookie, a private key, the session cookie). Runs on macOS and Linux, no network, no Docker, no
# cluster.
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

# The root carries the label the subscriptions of Argo CD Notifications select, and gets a Telegram chat only through
# argocd_root_telegram, as a string, beside the annotations it had.
root=$(. "$here/../k8s/lib.sh" && argocd_root_app https://github.com/o/svp-gitops "$built" stg https://github.com/o/c)
root_tg=$(. "$here/../k8s/lib.sh" && argocd_root_telegram -1001234 <<<"$root")
[ "$(jq -r '.metadata.labels["svp.io/notify"]' <<<"$root")" = root ] &&
  [ "$(jq -c '.metadata.annotations | keys' <<<"$root")" = '["argocd.argoproj.io/compare-options"]' ] &&
  [ "$(jq -c '.metadata.annotations' <<<"$root_tg")" = '{"argocd.argoproj.io/compare-options":"ServerSideDiff=false","notifications.argoproj.io/subscribe.on-sync-failed.telegram":"-1001234","notifications.argoproj.io/subscribe.on-health-degraded.telegram":"-1001234"}' ] &&
  [ "$(jq -c 'del(.metadata.annotations)' <<<"$root_tg")" = "$(jq -c 'del(.metadata.annotations)' <<<"$root")" ] &&
  ok "argocd_root_app labels the root svp.io/notify=root; argocd_root_telegram adds only the chat's two subscriptions" ||
  fail "argocd_root_app labels the root svp.io/notify=root; argocd_root_telegram adds only the chat's two subscriptions ($root_tg)"
# gitops.sh subscribes the chat only with notifications on, and before it applies the root.
[ "$(grep -n -e '^if \[ "$notify" = on \]; then$' -e 'root_app=$(argocd_root_telegram "$telegram_chat"' \
  -e '^kc apply --server-side --field-manager=svp-gitops -f - <<<"$root_app"' "$here/../k8s/gitops.sh" |
  cut -d: -f1 | awk 'NR > 1 && $1 <= p { bad = 1 } { p = $1; n++ } END { print (n == 3 && !bad) }')" = 1 ] &&
  ok "gitops.sh: the Telegram chat is added with notifications on, before the root is applied" ||
  fail "gitops.sh: the Telegram chat is added with notifications on, before the root is applied"

# --- The fake results of a k3d run: the table of the steps, and the output of each step as the workflow writes it,
# $SVP_VERIFY_OUT/logs/<step>.log. Only the verdict lines of drill-obs-threats and the admission figures may reach the
# artifact; every other step's output is refused whole, whatever it holds.
out=$work/out
mkdir -p "$out/logs/sub"
echo gitops >"$out/scenario"
printf 'step\toutcome\tnote\n' >"$out/results.tsv"
printf '%s\t%s\t%s\n' k8s-gitops-up failure '' k8s-smoke failure '' drill-k8s-gitops failure '' \
  drill-k8s-threats failure '' drill-obs-threats failure '' gitops-admission-metrics success '' >>"$out/results.tsv"
# The build step's output: a failed migrate Job's log (JSON records, one with a secret, and a panic) marked by mark_log
# as install.sh marks it, the report of unready_report and the timeout report above (log tails of svp-data and
# svp-obs), and log lines of namespace svp and of Envoy, as a mistake of unready_report would print them.
{
  echo "ok    cluster ready"
  echo "Job svp/feed-service-migrate failed; log of its last failed attempt, copied before its pod was deleted:"
  {
    echo '{"time":"2026-10-25T08:00:00Z","level":"WARN","msg":"database not reachable, retrying","attempt":1}'
    echo "{\"time\":\"2026-10-25T08:00:01Z\", \"level\": \"ERROR\", \"msg\":\"dsn $quoted_secret\"}"
    echo "panic: MIGRATE-PANIC-MARKER"
  } | mark_log_of svp
  cat "$unready"
  cat "$timeout_report"
  echo "    [svp] APP-FORGED-MARKER"
  echo "    [envoy-gateway-system] ENVOY-MARKER"
  echo "FAIL  install redpanda"
} >"$out/logs/k8s-gitops-up.log"
# A failed step that printed a secret on stdout and a JWT on stderr, both into its file as the workflow sends them.
{
  echo "ok    step 1"
  echo "response body: password=$quoted_secret"
  echo "Authorization header seen: $jwt" >&2
  echo "FAIL  step 2"
} >"$out/logs/k8s-smoke.log" 2>&1
# A failed step's long output, nothing secret in it.
{
  for i in $(seq 1 60); do echo "sample $i lag 3"; done
  echo "FAIL  KEDA-TAIL-MARKER scale down took too long"
} >"$out/logs/drill-k8s-gitops.log"
# The output of a Chainsaw drill: what its scripts printed, a probe's answer among it.
{
  echo "    | 08:00:00 | in-2-in-4 | IN-2/IN-4: probe | SCRIPT | LOG |"
  echo "        === STDOUT"
  echo "        ok    IN-4: svp-feed-service may only read its topics (svp-admin)"
  echo "        probe answered: PROBE-BODY-MARKER"
} >"$out/logs/drill-k8s-threats.log"
# The output of drill-obs-threats: verdicts (one naming the session cookie in prose, one failed), what the probes got
# back, a JSON log record that starts like a verdict, bash's own error line, the closing line.
{
  echo "ok    OPS-1: 8 loopback ports"
  echo "probe answered: PROBE-OBS-MARKER"
  echo 'ok    {"level":"INFO","msg":"OBS-JSON-MARKER"}'
  echo "deploy/compose/drills/obs-threats.sh: line 42: BASH-ERROR-MARKER: unbound variable"
  echo "ok    WEB-9: session cookie __Host-Http-svp_sid in the drill's cookie jar"
  echo "FAIL  JWT-8: an email in a trace"
  echo "drill-obs-threats: all checks passed"
} >"$out/logs/drill-obs-threats.log"
printf '%s\n' "kyverno_admission_review_duration_seconds: _count 45, _sum 90.000 s, mean 2.000 s, <= 20 s: 40, <= 30 s: 44, > 30 s: 1" \
  "NOTE  kyverno: no free port on 127.0.0.1 between 19100 and 19120 for a port-forward" >"$out/logs/gitops-admission-metrics.log"
echo "nested" >"$out/logs/sub/x.log"
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
# JUnit reports of the Chainsaw drills: a clean one; one per token pattern; one naming the session cookie in prose
# (outside the verdict lines of drill-obs-threats, svp_sid at all is refused); one with a cluster secret.
junit() { printf '<testsuites><testsuite name="%s"><testcase name="%s">%s</testcase></testsuite></testsuites>\n' "$1" "$2" "$3"; }
junit threats in-2-in-4 "" >"$d/threats-20261105T000000Z.xml"
junit gitops gitops-env "<failure message=\"sent Bearer abc\"/>" >"$d/bearer-1.xml"
junit gitops gitops-env "<failure message=\"got Set-Cookie: x\"/>" >"$d/set-cookie-1.xml"
junit gitops gitops-env "<failure message=\"$private_key_header\"/>" >"$d/private-key-1.xml"
junit threats web-7-web-2 "<system-out>ok    session cookie __Host-Http-svp_sid in the jar</system-out>" >"$d/prose-1.xml"
junit supplychain case-l "<failure message=\"s3 $cluster_secret\"/>" >"$d/supplychain-1.xml"
# The list of the SKIPs of a Chainsaw drill (deploy/k8s/drills/run.sh): a clean one; one with a token pattern; one
# with a cluster secret.
printf 'case-b\tno drill-unsigned on GHCR\ntotal\t1\n' >"$d/threats-skips.tsv"
printf 'case-l\tsent Bearer abc\ntotal\t1\n' >"$d/supplychain-skips.tsv"
printf 'gitops-env\treason with %s\ntotal\t1\n' "$cluster_secret" >"$d/gitops-skips.tsv"
echo "probe output" >"$d/threats-1.log"
echo "1792332629000 u1 explore 200 12" >"$d/traffic-1.log"
head -c 6000000 /dev/zero | tr '\0' a >"$d/big-1.json"
ln -s ../../.env "$d/link-1.json"
mkdir -p "$d/sub" && echo '{}' >"$d/sub/nested-1.json"
echo "CA" >"$repo/.k8s/ca.crt"
# Results of the checkout outside .k8s/drills, which the filter does not even look at.
echo '{"metrics":{"http_reqs":{"count":10}}}' >"$repo/.k6/local-1/summary.json"
echo '{"audits":{}}' >"$repo/.web/svp-frontend/test-results/lighthouse/b.report.json"

# job: the variables a GitHub Actions job runs the two scripts with (they print masks and warnings as the runner's
# commands only there), with the job's temp directory in $work.
job=(GITHUB_ACTIONS=true RUNNER_TEMP="$work")
# collect NAME SECRETS_DIR [VAR=VALUE...]: runs verify-collect.sh into $work/art-NAME, its stdout and stderr in
# $work/NAME.log.
collect() {
  local name=$1 secrets=$2
  shift 2
  rm -rf "$work/art-$name"
  env "${job[@]}" PATH="$work/bin:$PATH" SVP_VERIFY_REPO="$repo" SVP_VERIFY_OUT="${collect_out:-$out}" \
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
  '$SVP_VERIFY_OUT/logs/drill-obs-threats.log (verdict lines)' '$SVP_VERIFY_OUT/logs/gitops-admission-metrics.log' \
  .k8s/drills/canary-drill-1.json .k8s/drills/names-1.json .k8s/drills/identifiers-1.json .k8s/drills/traffic-1.log \
  .k8s/drills/threats-20261105T000000Z.xml .k8s/drills/threats-skips.tsv; do
  expect k3d "$src" kept
done
# The output of every other step is refused whole: the build step's log tails of every namespace (third-party ones
# included) and the services' log records, a secret, a JWT, a long output, a Chainsaw drill's probe answers.
for step in k8s-gitops-up k8s-smoke drill-k8s-gitops drill-k8s-threats; do
  expect k3d "\$SVP_VERIFY_OUT/logs/$step.log" not-allowed
done
expect k3d '$SVP_VERIFY_OUT/logs/sub/x.log' not-allowed
expect k3d .k8s/drills/kafka-1.json secret-value
expect k3d .k8s/drills/jwt-1.json jwt
expect k3d .k8s/drills/binary-piece-1.json secret-value
expect k3d .k8s/drills/bearer-1.xml bearer
expect k3d .k8s/drills/set-cookie-1.xml set-cookie
expect k3d .k8s/drills/private-key-1.xml private-key
expect k3d .k8s/drills/prose-1.xml session-cookie
expect k3d .k8s/drills/supplychain-1.xml secret-value
expect k3d .k8s/drills/supplychain-skips.tsv bearer
expect k3d .k8s/drills/gitops-skips.tsv secret-value
expect k3d '$SVP_VERIFY_OUT/ram-rest-start.json' not-allowed
expect k3d '$SVP_VERIFY_OUT/.hidden.json' hidden
has k3d "a hidden file gets a warning" '.hidden.json: hidden'
expect k3d .k8s/drills/backup-1.json secret-value
expect k3d .k8s/drills/b64-1.json secret-value
expect k3d .k8s/drills/multiline-1.json secret-value
expect k3d .k8s/drills/threats-1.log not-allowed
expect k3d .k8s/drills/sub/nested-1.json not-allowed
expect k3d .k8s/drills/big-1.json too-large
expect k3d .k8s/drills/link-1.json not-regular
grep -qE '\.k6/|\.web/' "$work/art-k3d/files.txt" || [ -n "$(find "$work/art-k3d" -name 'summary.json' -o -name 'b.report.json')" ] &&
  fail "k3d: .k6 and the clone of svp-frontend are not read" || ok "k3d: .k6 and the clone of svp-frontend are not read"
[ -f "$work/art-k3d/k8s-drills/canary-drill-1.json" ] && [ -f "$work/art-k3d/k8s-drills/threats-20261105T000000Z.xml" ] &&
  [ -f "$work/art-k3d/k8s-drills/threats-skips.tsv" ] && [ ! -e "$work/art-k3d/k8s-drills/supplychain-skips.tsv" ] &&
  [ ! -e "$work/art-k3d/k8s-drills/gitops-skips.tsv" ] &&
  ok "k3d: the checkout's files under a visible folder" || fail "k3d: the checkout's files under a visible folder"
[ -z "$(find "$work/art-k3d" -name '.*')" ] && ok "k3d: no hidden file in the artifact" || fail "k3d: no hidden file in the artifact"
[ ! -e "$work/art-k3d/ca.crt" ] && ! grep -q 'ca.crt' "$work/art-k3d/files.txt" && ok "k3d: .k8s/ca.crt not a candidate" ||
  fail "k3d: .k8s/ca.crt not a candidate"
[ -z "$(find "$work/art-k3d" -name '*.log' ! -name 'drill-obs-threats.verdicts.log' ! -name 'gitops-admission-metrics.log' ! -name 'traffic-1.log')" ] &&
  ok "k3d: no step's output in the artifact but the verdicts of drill-obs-threats and the admission figures" ||
  fail "k3d: no step's output in the artifact but the verdicts of drill-obs-threats and the admission figures"
markers='INFRA-TAIL-MARKER INFRA-MESSAGE-MARKER OPERATOR-PREVIOUS-MARKER APP-FORGED-MARKER ENVOY-MARKER MIGRATE-PANIC-MARKER
KEDA-TAIL-MARKER PROBE-BODY-MARKER PROBE-OBS-MARKER OBS-JSON-MARKER BASH-ERROR-MARKER'
for m in $markers; do
  if grep -rqaF -- "$m" "$work/art-k3d"; then fail "k3d: no $m in the artifact"; else ok "k3d: no $m in the artifact"; fi
  lacks k3d "no $m in the job's log" "$m"
done
grep -qE '"(msg|level)"' -r "$work/art-k3d" && fail "k3d: no service log record in the artifact" ||
  ok "k3d: no service log record in the artifact"
v=$work/art-k3d/logs/drill-obs-threats.verdicts.log
[ "$(cat "$v")" = "$(printf '%s\n' "ok    OPS-1: 8 loopback ports" \
  "ok    WEB-9: session cookie __Host-Http-svp_sid in the drill's cookie jar" "FAIL  JWT-8: an email in a trace" \
  "drill-obs-threats: all checks passed")" ] &&
  ok "k3d: drill-obs-threats keeps its verdicts (the session cookie named in prose) and closing line, nothing else" ||
  fail "k3d: drill-obs-threats keeps its verdicts (the session cookie named in prose) and closing line, nothing else"
cmp -s "$out/logs/gitops-admission-metrics.log" "$work/art-k3d/logs/gitops-admission-metrics.log" &&
  ok "k3d: the admission figures are kept whole" || fail "k3d: the admission figures are kept whole"
cmp -s "$out/results.tsv" "$work/art-k3d/results.tsv" && ok "k3d: the table of the steps is kept whole" ||
  fail "k3d: the table of the steps is kept whole"
masked=0
for v in $identifiers; do
  grep -qxF -e "::add-mask::$v" -e "::add-mask::$(b64 "$v")" "$work/k3d.log" && masked=1
done
[ "$masked" = 0 ] && ok "k3d: user names, emails, key ids and mechanisms of the Secrets are not masked" ||
  fail "k3d: user names, emails, key ids and mechanisms of the Secrets are not masked"
grep -qxF "::add-mask::$kafka_secret" "$work/k3d.log" && ok "k3d: a password beside a user name is masked" ||
  fail "k3d: a password beside a user name is masked"
no_leak k3d
has k3d "the verdicts of a failed drill-obs-threats are printed" "FAIL  JWT-8: an email in a trace"
lacks k3d "the output of a failed step that is not in the artifact is not printed" 'step 2'
lacks k3d "a failed step's long output is not printed" 'sample 60 lag'
has k3d "a dropped file gets a warning with its rule" '::warning::.k8s/drills/backup-1.json: secret-value'
lacks k3d "not-allowed files get no warning" '::warning::.k8s/drills/threats-1.log'
lacks k3d "a refused step output gets no warning" '::warning::$SVP_VERIFY_OUT/logs/k8s-smoke.log'
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

# --- The verdict lines of drill-obs-threats holding the session cookie in a form its value is written in, one run
# each: a header, a cookie jar line, JSON, and the name ending a line.
cookie=0
for line in 'FAIL  WEB-2: sent Cookie: __Host-Http-svp_sid=SID-MARKER' \
  "$(printf 'ok    jar: svp.localhost\tFALSE\t/\tTRUE\t0\t__Host-Http-svp_sid\tSID-MARKER')" \
  'FAIL  WEB-9: got {"name":"svp_sid","value":"SID-MARKER"}' 'FAIL  WEB-9: the cookie jar holds svp_sid'; do
  cookie=$((cookie + 1))
  co=$work/out-cookie-$cookie
  mkdir -p "$co/logs" && echo gitops >"$co/scenario"
  printf '%s\n' "$line" >"$co/logs/drill-obs-threats.log"
  collect_out=$co collect "cookie-$cookie" "$work/secrets-k3d"
  expect "cookie-$cookie" '$SVP_VERIFY_OUT/logs/drill-obs-threats.log (verdict lines)' session-cookie
  grep -rqa SID-MARKER "$work/art-cookie-$cookie" && fail "cookie-$cookie: no session cookie value in the artifact" ||
    ok "cookie-$cookie: no session cookie value in the artifact"
done
# The admission figures and the verdict lines are scanned like any file from the cluster.
ao=$work/out-scanned
mkdir -p "$ao/logs" && echo gitops >"$ao/scenario"
printf 'kyverno: %s\n' "$kafka_secret" >"$ao/logs/gitops-admission-metrics.log"
printf 'FAIL  JWT-8: %s\n' "$jwt" >"$ao/logs/drill-obs-threats.log"
collect_out=$ao collect scanned "$work/secrets-k3d"
expect scanned '$SVP_VERIFY_OUT/logs/gitops-admission-metrics.log' secret-value
expect scanned '$SVP_VERIFY_OUT/logs/drill-obs-threats.log (verdict lines)' jwt
no_leak scanned

# --- k3d run, the cluster never read: only the files written on the runner itself.
collect dead "$work/secrets-dead" FAKE_KUBECTL_FAIL=1
for src in '$SVP_VERIFY_OUT/results.tsv' '$SVP_VERIFY_OUT/scenario'; do
  expect dead "$src" kept
done
for src in '$SVP_VERIFY_OUT/logs/drill-obs-threats.log (verdict lines)' '$SVP_VERIFY_OUT/logs/gitops-admission-metrics.log' \
  .k8s/drills/canary-drill-1.json .k8s/drills/backup-1.json .k8s/drills/threats-20261105T000000Z.xml; do
  expect dead "$src" no-secret-list
done
no_leak dead
lacks dead "no verdict line is printed" 'FAIL  JWT-8'
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
# The object store's tests and the build step of a compose-obs run (refused whole like every step's output), and the
# verdict lines of drill-obs-threats with the store's root password (a value of .env).
printf '%s\n' '--- PASS: TestIntegrationPresignedPost (0.20s)' \
  'object store tests: 39 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0' \
  >"$out/logs/test-stack-objstore.log"
printf 'make up: s3 root %s\n' "$env_secret" >"$out/logs/up.log"
cp "$out/logs/drill-obs-threats.log" "$work/obs.good"
printf 'FAIL  UP-8: s3 root %s in a log\n' "$env_secret" >>"$out/logs/drill-obs-threats.log"
collect compose "$work/secrets-compose" FAKE_KUBECTL_FAIL=1
expect compose '$SVP_VERIFY_OUT/logs/test-stack-objstore.log' not-allowed
expect compose '$SVP_VERIFY_OUT/logs/up.log' not-allowed
expect compose '$SVP_VERIFY_OUT/logs/drill-obs-threats.log (verdict lines)' secret-value
expect compose .k8s/drills/canary-drill-1.json kept
expect compose .k8s/drills/b64-1.json secret-value
# A compose run has no cluster, so a value only a cluster Secret would hold is no secret of that run.
expect compose .k8s/drills/backup-1.json kept
no_leak compose env-secrets
cp "$work/obs.good" "$out/logs/drill-obs-threats.log"

# --- An .env that breaks its rule: nothing masked, no value printed, nothing from the stack copied.
cp "$repo/.env" "$work/env.good"
printf 'SVP_BROKEN_PASSWORD=$%s\n' "$env_secret" >>"$repo/.env"
collect broken "$work/secrets-broken"
expect broken '$SVP_VERIFY_OUT/results.tsv' kept
expect broken .k8s/drills/canary-drill-1.json no-secret-list
has broken "the broken line is named" 'SVP_BROKEN_PASSWORD'
no_leak broken
cp "$work/env.good" "$repo/.env"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
