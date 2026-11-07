#!/usr/bin/env bash
# The dev path (`make k8s-up`): installs every component of argocd/apps/components.json of svp-gitops into cluster svp
# with helmfile (helmfile.yaml.gotmpl lists the releases) after building the images; also the hook helmfile runs per
# release. Run again, it only upgrades what changed.
# Design notes: docs/reference/k8s.md.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=deploy/k8s/rotate.sh
. "$(dirname "${BASH_SOURCE[0]}")/rotate.sh"
# The command that runs this script again, for the messages of rotate.sh.
again="make k8s-up"
# The components the dev path installs, a jq filter on an entry of components.json: as in helmfile.yaml.gotmpl.
dev_path='.gitopsOnly != true and ((has("platforms") | not) or (.platforms | index("k3d")) != null)'

# --- the hooks of the releases (deploy/k8s/helmfile.yaml.gotmpl).

# watch_migrate NAMESPACE JOB OLD_UID LOG HELMFILE: from the presync hook, copies the log of the migrate Job's latest
# failed attempt to LOG every 2 s while its pod exists, until the postsync hook stops it or process HELMFILE is gone.
# The Job controller deletes a failed Job's pod and its log (Helm reports only BackoffLimitExceeded). OLD_UID is the
# previous run's Job, which Helm replaces, and is not read.
watch_migrate() {
  local ns=$1 job=$2 old=$3 log=$4 parent=$5 state uid out
  while kill -0 "$parent" 2>/dev/null && sleep 2; do
    state=$(kc -n "$ns" get job "$job" -o jsonpath='{.metadata.uid} {.status.active}' 2>/dev/null) || continue
    uid=${state% *}
    # Only a pod that still runs or waits to restart keeps the log of its previous attempt.
    if [ "$uid" = "$old" ] || [ "${state#* }" != 1 ]; then continue; fi
    out=$(kc -n "$ns" logs -l "batch.kubernetes.io/controller-uid=$uid" --previous --tail=40 2>/dev/null) || continue
    # Once the pod is being deleted the kubelet answers with this line instead of the log; the copy already kept is
    # the one to print.
    case $out in "" | "unable to retrieve container logs"*) continue ;; esac
    printf '%s\n' "$out" >"$log"
  done
}

# way_out NAMESPACE NAME ABORTED: how to leave a canary wait_rollout gave up on, printed before it fails. A canary not
# aborted (ABORTED false) keeps its weight, and its pods their share of the requests, until it is. The lab pins no
# kubectl-argo-rollouts plugin: its abort and retry are these
# patches of the Rollout's status subresource, which kubectl makes as well.
way_out() {
  local patch="kubectl --context k3d-svp -n $1 patch rollout $2 --subresource status --type merge -p"
  if [ "$3" != true ]; then
    echo "      every request back to the stable pods (abort): $patch '{\"status\":{\"abort\":true}}'" >&2
  fi
  echo "      then fix the cause and run make k8s-up again (a new pod template is a new canary), or run this revision's" \
    "canary again (an analysis failed by noise): make k8s-traffic-start; $patch '{\"status\":{\"abort\":false}}';" \
    "make k8s-up; make k8s-traffic-stop" >&2
}

# wait_rollout NAMESPACE NAME: waits until the Rollout is Healthy (about 3 minutes when a canary runs: 25%, 60 s, 50%,
# 60 s, 100%). Fails, after way_out, when the canary is aborted or paused by an inconclusive AnalysisRun (which never
# promotes on its own), naming the AnalysisRun; also after 900 s, beyond the progress deadline of 600 s.
wait_rollout() {
  local ns=$1 name=$2 deadline=$((SECONDS + 900)) json gen obs phase abort reasons step weight run hash irun last=
  while :; do
    json=$(kc -n "$ns" get rollout "$name" -o json) || fail "read rollout $ns/$name"
    IFS=$'\t' read -r gen obs phase abort reasons step weight run hash irun <<<"$(jq -r '[
      .metadata.generation, (.status.observedGeneration // "-"), (.status.phase // "-"), (.status.abort // false),
      ([.status.pauseConditions[]?.reason] | join(",") | if . == "" then "-" else . end),
      (.status.currentStepIndex // "-"), (.status.canary.weights.canary.weight // 0),
      (.status.canary.currentBackgroundAnalysisRunStatus.name // "-"), (.status.currentPodHash // "-"),
      ([.status.canary.currentStepAnalysisRunStatus, .status.canary.currentBackgroundAnalysisRunStatus]
        | map(select(. != null)) | map(select(.status == "Inconclusive")) + . | .[0].name // "-")] | @tsv' <<<"$json")"
    if [ "$obs" = "$gen" ]; then
      [ "$phase" != Healthy ] || break
      if [ "$abort" = true ] || [ "$phase" = Degraded ]; then
        # An abort clears the Rollout's reference to its background AnalysisRun: the newest run of the canary's
        # template is the one that failed (or was stopped by a manual abort).
        if [ "$run" = - ]; then
          run=$(kc -n "$ns" get analysisruns -l "rollouts-pod-template-hash=$hash" --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null) || true
          run=${run:--}
        fi
        way_out "$ns" "$name" "$abort"
        fail "canary of rollout $ns/$name aborted ($(kc -n "$ns" get rollout "$name" -o jsonpath='{.status.message}')); AnalysisRun $run: kubectl --context k3d-svp -n $ns get analysisrun $run -o yaml"
      fi
      case ,$reasons, in
        *,InconclusiveAnalysisRun,*)
          way_out "$ns" "$name" false
          fail "canary of rollout $ns/$name paused by an inconclusive analysis at weight $weight%, never promoted: AnalysisRun $irun (kubectl --context k3d-svp -n $ns get analysisrun $irun -o yaml); too few responses reached the canary?"
          ;;
      esac
      if [ "$step/$weight" != "$last" ]; then
        echo "      canary of $name: step $step, weight $weight%, phase $phase, AnalysisRun $run"
        last="$step/$weight"
      fi
    fi
    if ((SECONDS >= deadline)); then
      way_out "$ns" "$name" "$abort"
      fail "rollout $ns/$name Healthy within 900s (now $phase)"
    fi
    sleep 5
  done
  ok "rollout $name Healthy"
}

# rollout_doc: the document of kind Rollout in the rendered manifest on stdin, whose documents start with a --- line.
# awk runs its END rule after exit too, so the document is printed once, there.
rollout_doc() {
  awk '/^---/ { if (r) exit; d = ""; next } { d = d $0 "\n" } /^kind: Rollout$/ { r = 1 } END { if (r) printf "%s", d }'
}

# pg_base_backup: after chart svp-data, that Postgres svp-pg archives WAL and its archive generation has a base backup.
# On the upgrade that adds the plugin to a Cluster made before it, the first Backup can start on the old primary,
# without the plugin's sidecar, and fails for good (CloudNativePG never retries one; the schedule's next run is at 03:00
# UTC): so a generation with no successful base backup gets one here once the primary runs the sidecar.
pg_base_backup() {
  local gen last name
  wait_until 600 "the primary of Postgres svp-pg Ready with the Barman Cloud plugin's sidecar (kubectl --context k3d-svp -n svp-data get cluster svp-pg)" \
    pg_primary_has_sidecar
  wait_until 600 "every Backup of svp-pg in progress completed or failed (kubectl --context k3d-svp -n svp-data get backups)" \
    pg_no_backup_running
  gen=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
    -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}') && [ -n "$gen" ] ||
    fail "read the archive generation of Cluster svp-data/svp-pg"
  last=$(kc -n svp-data get objectstores.barmancloud.cnpg.io svp-pg-backup -o json |
    jq -r --arg gen "$gen" '.status.serverRecoveryWindow[$gen].lastSuccessfulBackupTime // ""') ||
    fail "read the status of ObjectStore svp-data/svp-pg-backup"
  if [ -z "$last" ]; then
    name=svp-pg-base-$(date -u +%Y%m%d%H%M%S)
    pg_backup "$name"
    last="Backup $name, taken now: generation $gen had none"
  fi
  wait_until 300 "Postgres svp-pg archives WAL (condition ContinuousArchiving True; docs/runbooks/postgres-wal-archiving-failing.md)" \
    test_output True kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
    -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'
  ok "Postgres svp-pg archives WAL into generation $gen; last base backup: $last"
}

# pg_primary_has_sidecar: true when Cluster svp-pg is Ready and its current primary pod is Ready and has the plugin's
# sidecar (init container plugin-barman-cloud, restartPolicy Always), which the operator adds only to the pods it makes
# once the Cluster names the plugin. The Cluster's Ready alone may still be the one from before the upgrade.
pg_primary_has_sidecar() {
  local primary
  [ "$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] ||
    return 1
  primary=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg -o jsonpath='{.status.currentPrimary}') &&
    [ -n "$primary" ] || return 1
  [ "$(kc -n svp-data get pod "$primary" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.initContainers[?(@.name=="plugin-barman-cloud")].name}')" = \
    "True plugin-barman-cloud" ]
}

# pg_no_backup_running: true when no Backup of svp-pg is in a phase other than completed or failed (none yet, pending,
# started, running and the like).
pg_no_backup_running() {
  local phases
  phases=$(kc -n svp-data get backups.postgresql.cnpg.io \
    -o jsonpath='{range .items[?(@.spec.cluster.name=="svp-pg")]}[{.status.phase}]{end}') || return 1
  [ -z "$(printf '%s' "$phases" | sed -e 's/\[completed\]//g' -e 's/\[failed\]//g')" ]
}

# cnpg_ca_injected KIND: true when every webhook of KIND (mutating or validating) webhook configuration
# cnpg-KIND-webhook-configuration has a CA bundle. The chart renders none and the operator writes none
# (MANAGE_WEBHOOK_CONFIGURATIONS=false), so on a new cluster one there is cainjector's.
cnpg_ca_injected() {
  local bundles
  bundles=$(kc get "${1}webhookconfiguration" "cnpg-$1-webhook-configuration" \
    -o jsonpath='{range .webhooks[*]}[{.clientConfig.caBundle}]{end}') || return 1
  [ -n "$bundles" ] && [[ $bundles != *"[]"* ]]
}

# wait_hpa NAME: waits until HPA svp/NAME reads the CPU of its pods (condition ScalingActive) and its Deployment (the
# gateway: Rollout) has at least minReplicas ready pods. The chart renders no replicas for such a workload, so it
# starts with one pod and the HPA raises it; a cluster without metrics-server, or with its API not serving, fails here
# instead of leaving an HPA that never scales.
wait_hpa() {
  local name=$1 min kind
  kc wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s >/dev/null ||
    fail "metrics-server's API (apiservice v1beta1.metrics.k8s.io) Available within 120s"
  # metrics-server has a pod's CPU only after its first scrapes of a new pod, up to a minute.
  kc -n svp wait --for=condition=ScalingActive "hpa/$name" --timeout=180s >/dev/null ||
    fail "HPA svp/$name reads its pods' CPU within 180s (kubectl --context k3d-svp -n svp describe hpa $name)"
  min=$(kc -n svp get hpa "$name" -o jsonpath='{.spec.minReplicas}') || fail "read HPA svp/$name"
  kind=$(workload_kind svp "$name")
  wait_until 120 "$kind svp/$name with $min ready replicas" \
    test_ge "$min" kc -n svp get "$kind" "$name" -o jsonpath='{.status.readyReplicas}'
  ok "HPA $name reads CPU, $kind $name has at least $min ready replicas"
}

# test_ge MIN COMMAND...: true when COMMAND prints an integer of at least MIN.
test_ge() {
  local min=$1 got
  shift
  got=$("$@") || return 1
  [ "${got:-0}" -ge "$min" ]
}

# after_install NAME: what must hold after release NAME before the next wave may rely on it, beyond the pods helm's
# --wait already waited for.
after_install() {
  local cert webhook_kind
  case $1 in
    svp-cluster)
      # The two certificates of Gateway svp are issued asynchronously by cert-manager, and Envoy Gateway programs the
      # Gateway and creates its proxy Deployment after the release is applied.
      for cert in svp-wildcard svp-apex; do
        kc -n svp-edge wait --for=condition=Ready "certificate/$cert" --timeout=120s >/dev/null ||
          fail "certificate svp-edge/$cert Ready within 120s"
      done
      # The CloudNativePG operator (wave 2) serves its webhooks from this certificate's Secret; started without it, it
      # would make one of its own, which cert-manager then overwrites (templates/cnpg-webhook-certificate.yaml of
      # svp-cluster).
      kc -n cnpg-system wait --for=condition=Ready certificate/cnpg-webhook --timeout=120s >/dev/null ||
        fail "certificate cnpg-system/cnpg-webhook Ready within 120s"
      kc -n svp-edge wait --for=condition=Programmed gateway/svp --timeout=180s >/dev/null ||
        fail "gateway svp-edge/svp Programmed within 180s"
      wait_until 120 "Envoy proxy Deployment of gateway svp available" \
        kc -n envoy-gateway-system wait --for=condition=Available deployment \
        -l gateway.envoyproxy.io/owning-gateway-name=svp --timeout=5s
      ok "certificates svp-wildcard, svp-apex and cnpg-webhook Ready, gateway svp Programmed, Envoy proxy available"
      export_ca
      ;;
    cloudnative-pg)
      # cert-manager's cainjector writes the webhook's certificate into the operator's two webhook configurations soon
      # after this release made them (base/cloudnative-pg.yaml of svp-gitops); until then the API server cannot call
      # them, and the Cluster of svp-data (wave 4) would be refused.
      for webhook_kind in mutating validating; do
        wait_until 60 "cainjector writes the CA into cnpg-$webhook_kind-webhook-configuration" \
          cnpg_ca_injected "$webhook_kind"
      done
      ok "CloudNativePG's webhook configurations carry the CA of certificate cnpg-webhook"
      ;;
    kube-prometheus-stack)
      # Prometheus and Alertmanager are StatefulSets the operator makes from their custom resources, outside the
      # release, so --wait did not wait for them.
      kc -n svp-obs wait --for=condition=Available prometheus/kps-prometheus --timeout=300s >/dev/null ||
        fail "Prometheus svp-obs/kps-prometheus Available within 300s (kubectl --context k3d-svp -n svp-obs describe prometheus kps-prometheus)"
      kc -n svp-obs wait --for=condition=Available alertmanager/kps-alertmanager --timeout=300s >/dev/null ||
        fail "Alertmanager svp-obs/kps-alertmanager Available within 300s"
      ok "Prometheus and Alertmanager available"
      ;;
    kyverno)
      # Kyverno's admission controller registers its webhook configurations itself once it is ready, none of them in
      # the chart: kyverno-policy-validating-webhook-cfg checks the policy chart svp-policy installs next, and
      # kyverno-resource-validating-webhook-cfg will carry that policy's webhook.
      wait_until 120 "Kyverno registers its webhook configurations" kc get validatingwebhookconfigurations \
        kyverno-policy-validating-webhook-cfg kyverno-resource-validating-webhook-cfg
      ok "Kyverno's webhook configurations registered"
      ;;
    svp-policy)
      # The policy counts only once Kyverno has compiled it and registered its webhook, which takes the requests of
      # namespace svp only; the services (wave 7) start after that.
      wait_until 120 "ImageValidatingPolicy svp-images ready, its webhook registered for namespace svp" \
        image_policy_ready svp-images
      ok "ImageValidatingPolicy svp-images ready (Audit: violations go to PolicyReports), its webhook takes namespace svp only"
      ;;
    keda)
      # The HPA KEDA makes for a ScaledObject reads the lag through this API; until the metrics server behind it
      # answers, the HPA reports no metric and never scales.
      kc wait --for=condition=Available apiservice/v1beta1.external.metrics.k8s.io --timeout=120s >/dev/null ||
        fail "KEDA's metrics API (apiservice v1beta1.external.metrics.k8s.io) Available within 120s"
      ok "KEDA's metrics API available"
      ;;
    svp-data)
      pg_base_backup
      ;;
    svp-observability)
      # GlitchTip's DSN and API token go into Secrets once it runs (its init Job, a hook of this release, has run),
      # before the services (wave 7) start and read the DSN.
      "$repo_root/deploy/k8s/glitchtip-init.sh"
      ;;
    media-worker)
      # Ready once the operator has built the Kafka scaler (logged in as svp-keda, read the group) and its HPA.
      kc -n svp wait --for=condition=Ready scaledobject/media-worker --timeout=120s >/dev/null ||
        fail "ScaledObject svp/media-worker Ready within 120s (kubectl --context k3d-svp -n svp describe scaledobject media-worker)"
      ok "ScaledObject media-worker Ready"
      ;;
    gateway | feed-service)
      wait_hpa "$1"
      ;;
  esac
}

# hook EVENT NAME NAMESPACE KIND CANARY_ROUTE FAILED: the hooks of release NAME (deploy/k8s/helmfile.yaml.gotmpl).
# KIND is service for a release of chart svp-service, component otherwise; FAILED is failed when helm failed (postsync
# only). The watcher of a service's migrate Job keeps its pid and log in a folder of helmfile's process (the hooks'
# parent), removed once empty.
hook() {
  local event=$1 name=$2 namespace=$3 kind=$4 route=$5 failed=${6:-} dir migrate_log old pid i
  dir=${TMPDIR:-/tmp}/svp-helmfile-$PPID
  migrate_log=$dir/$name.log
  case $event in
    presync)
      [ "$kind" = service ] || return 0
      mkdir -p "$dir"
      old=$(kc -n "$namespace" get job "$name-migrate" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
      : >"$migrate_log"
      # Nothing of it on the hook's output, which helmfile reads to its end.
      watch_migrate "$namespace" "$name-migrate" "$old" "$migrate_log" "$PPID" </dev/null >/dev/null 2>&1 &
      echo "$!" >"$dir/$name.pid"
      ;;
    postsync)
      if [ "$kind" = service ] && [ -f "$dir/$name.pid" ]; then
        pid=$(cat "$dir/$name.pid")
        kill "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null && sleep 1 || break; done
      fi
      if [ "$failed" = failed ]; then
        if [ "$kind" = service ] && [ -s "$migrate_log" ] && [ "$(kc -n "$namespace" get job "$name-migrate" \
          -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)" = True ]; then
          echo "Job $namespace/$name-migrate failed; log of its last failed attempt, copied before its pod was deleted:" >&2
          # Marked as unready_report marks a log line (mark_log of deploy/k8s/lib.sh): the log of a service is shown on
          # the machine that runs this, and the public artifact of a verification run leaves out every log line of
          # namespace svp.
          mark_log "$namespace" <"$migrate_log" >&2
        fi
        rm -f "${dir:?}/$name.pid" "${migrate_log:?}"
        rmdir "$dir" 2>/dev/null || true
        unready_report "$namespace" || true
        fail "install $name"
      fi
      rm -f "${dir:?}/$name.pid" "${migrate_log:?}"
      rmdir "$dir" 2>/dev/null || true
      ok "$name"
      if [ "$kind" = service ] && [ "$(workload_kind "$namespace" "$name")" = rollout ]; then
        [ -n "$route" ] && kc -n "$namespace" get httproute "$route" >/dev/null 2>&1 ||
          fail "canaryRoute '$route' of component $name in argocd/apps/components.json names no HTTPRoute of release $name"
        wait_rollout "$namespace" "$name"
      fi
      after_install "$name"
      ;;
    *) fail "usage: install.sh hook presync|postsync NAME NAMESPACE KIND CANARY_ROUTE [failed] (got event '$event')" ;;
  esac
}

# --- the glue around helmfile.

# rollouts_plugin_check: Argo Rollouts' Gateway API plugin is a native binary, and base/argo-rollouts.yaml pins the
# linux-arm64 asset, which cannot run on amd64 nodes (the gateway never gets a pod). There archValues of components.json
# replaces it with the same release built for amd64; both files must name one release, so each holds exactly one
# plugin location and a new release cannot update only one pin.
rollouts_plugin_check() {
  local file loc release='' all
  all=$(jq -r '.components[] | select(.name == "argo-rollouts") | .values, ((.archValues // {})[])' "$components") ||
    fail "read the values files of argo-rollouts in $components"
  for file in $all; do
    loc=$(sed -n 's/^ *location: *//p' "$gitops/$file")
    [[ $loc =~ ^https://[^[:space:]]+/[^/[:space:]]+$ ]] ||
      fail "$file pins no single plugin location (got '$loc')"
    if [ -z "$release" ]; then
      release=${loc%/*}
    elif [ "${loc%/*}" != "$release" ]; then
      fail "$file pins the plugin of ${loc%/*}, the other values files of argo-rollouts that of $release: change every pin to one release"
    fi
  done
  ok "Argo Rollouts gets the Gateway API plugin built for $node_arch nodes (release ${release##*/})"
}

# canary_ahead NAMESPACE NAME: false only when the coming upgrade renders Rollout NAME exactly as the release's current
# revision does and it is Healthy: no canary will run, so no drill traffic is started (each start registers users and
# deletes the register rate limit keys). Anything else, or a Rollout that cannot be rendered or read, counts as ahead;
# `helmfile template` renders what the upgrade will (the chart reads nothing from the cluster).
canary_ahead() {
  local ns=$1 name=$2 new old
  [ "$(kc -n "$ns" get rollout "$name" -o jsonpath='{.status.phase}')" = Healthy ] || return 0
  new=$(dev_helmfile template -l "name=$name" --skip-deps 2>/dev/null | rollout_doc) || return 0
  old=$(hc get manifest "$name" --namespace "$ns" | rollout_doc) || return 0
  [ -z "$new" ] || [ "$new" != "$old" ]
}

# The gateway and the web client are Rollouts: an upgrade that changes the pod template is a new revision, which goes
# out as a canary only when Envoy has measured enough responses of it. So while a canary is ahead (canary_ahead), drill
# traffic (deploy/k8s/drills/traffic.sh) runs during each helmfile run of the waves after wave 1 and stops after it, a
# failure included (also the EXIT trap). Traffic already running (make k8s-traffic-start) is used and left running.
traffic=$repo_root/deploy/k8s/drills/traffic.sh
own_traffic=
start_canary_traffic() {
  local running
  if running=$("$traffic" status); then
    ok "drill traffic already running (pid ${running%% *}); used for the canary of $1 and left running"
    return 0
  fi
  SVP_STACK=k3d CURL_CA_BUNDLE="$repo_root/.k8s/ca.crt" "$traffic" start || fail "start drill traffic for the canary of $1"
  running=$("$traffic" status) || fail "drill traffic for the canary of $1 not running after its start"
  own_traffic=${running%% *}
}
stop_canary_traffic() {
  local running
  [ -n "$own_traffic" ] || return 0
  if running=$("$traffic" status) && [ "${running%% *}" = "$own_traffic" ]; then "$traffic" stop || true; fi
  own_traffic=
}

# image_values: prints, as JSON, state value images of helmfile.yaml.gotmpl: for each release of chart svp-service its
# dev image (build_dev_images: the local registry under the name the nodes resolve, the dev tag, no digest), or for the
# web client the release web_source chose (by digest).
image_values() {
  local svc tag_var lines=
  for svc in "${svp_services[@]}"; do
    if [ "$svc" = web ] && [ -n "$web_release" ]; then
      lines+="$svc ${web_release%@*} - ${web_release#*@}"$'\n'
      continue
    fi
    tag_var="dev_tag_${svc//-/_}"
    [ -n "${!tag_var:-}" ] || fail "no image was built for $svc (not in svp_services of deploy/k8s/lib.sh)"
    lines+="$svc k3d-svp-registry:5111/svp/$svc ${!tag_var} -"$'\n'
  done
  jq -Rn '{images: ([inputs | split(" ") | {key: .[0], value: {repository: .[1],
    tag: (if .[2] == "-" then "" else .[2] end), digest: (if .[3] == "-" then "" else .[3] end)}}] | from_entries)}' \
    <<<"${lines%$'\n'}"
}

# sync_later [WHAT]: helmfile sync of waves 2 and later (WHAT says more of this run in its messages), with drill
# traffic from before it until it is over, a failure included, while a canary of a Rollout of components.json is ahead
# (canary_ahead): every run of these waves upgrades the gateway and the web client.
sync_later() {
  local what=${1:-} rollouts ns name ahead='' rc=0
  rollouts=$(jq -r ".components[] | select($dev_path) | select(.canaryRoute) | \"\(.namespace) \(.name)\"" \
    "$components") || fail "read the components with canaryRoute in $components"
  while read -r ns name; do
    [ -n "$name" ] && [ "$(workload_kind "$ns" "$name")" = rollout ] || continue
    if canary_ahead "$ns" "$name"; then ahead="$ahead $name"; fi
  done <<<"$rollouts"
  if [ -n "$ahead" ]; then start_canary_traffic "${ahead# }"; fi
  echo "helmfile sync: waves 2 and later$what"
  dev_helmfile sync -l 'wave!=0,wave!=1' || rc=$?
  stop_canary_traffic
  [ "$rc" = 0 ] || fail "helmfile sync of waves 2 and later$what (the release above)"
}

# install_releases: helmfile in the order of the dev path: waves 0 and 1 (svp-cluster makes the namespaces the Secrets
# go into), then the Secrets (deploy/k8s/secrets.sh), then the later waves, which read them. A cluster not ready for a
# change of credentials (rotate_unready of rotate.sh) gets the later waves once before the Secrets: Reloader restarts a
# workload when a Secret it names changes, not when it starts or when the annotation arrives.
install_releases() {
  echo "helmfile sync: waves 0 and 1 (chart svp-cluster makes the project's namespaces and the gateway)"
  dev_helmfile sync -l wave=0 -l wave=1 || fail "helmfile sync of waves 0 and 1 (the release above)"
  if rotate_unready dev; then
    echo "note  cluster svp is not ready for a change of credentials: $unready_why. Every later wave first, with the Secrets as they are, so that Reloader and each workload's annotation are in place before a credential changes"
    sync_later ", with the Secrets as they are"
  fi
  "$repo_root/deploy/k8s/secrets.sh"
  sync_later
  ! rotate_unready dev ||
    fail "every release installed, but cluster svp is not ready for a change of credentials: $unready_why; run $again again"
  ok "Reloader runs and may restart each workload that opts in, each naming the Secrets its chart does"
}

main() {
  gitops=$(gitops_dir) || exit 1
  components="$gitops/argocd/apps/components.json"
  command -v jq >/dev/null || fail "jq not found (brew install jq)"
  command -v helmfile >/dev/null || fail "helmfile not found: run make tools (HELMFILE_VERSION of the Makefile)"
  kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"
  # A cluster made by `make k8s-gitops-up` belongs to Argo CD: Helm releases installed over its Applications would be
  # reverted by its self-heal, or fight it on every sync. It changes through git; a changed .env reaches it through
  # make k8s-secrets.
  if kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1; then
    fail "cluster svp is managed by Argo CD (Application argocd/svp-root): change it through git, or start over on the dev path with make k8s-down && make k8s-up"
  fi

  # The services' images first, so a build that fails stops the run before anything is installed.
  web_source
  if [ -n "$web_release" ]; then
    build_dev_images "${built_services[@]}"
    ok "web runs release $web_release (WEB_FROM=${WEB_FROM:-stg}), with the build id CI gave it: make k8s-web-sourcemaps does not apply to it"
  else
    build_dev_images
  fi
  work=$(mktemp -d)
  trap 'rm -rf "${work:?}"; stop_canary_traffic' EXIT
  dev_helmfile_images=$work/images.json
  image_values >"$dev_helmfile_images" || fail "write the images of the releases of chart svp-service"

  # Pod Security "restricted" on the namespaces of wave 0 and the project's before any chart's first pod: svp-cluster
  # comes after the charts whose CRDs it needs, and Envoy Gateway (wave 0) binds a Role in each project namespace, which
  # Helm cannot create in a namespace that does not exist. Applied server-side under their own field manager, so no
  # release removes the labels (none creates a namespace); svp-cluster takes over the project's namespaces.
  wave0=$(jq -c "[.components[] | select(.wave == 0 and $dev_path) | {name: .namespace}] | unique" "$components") ||
    fail "read the namespaces of wave 0 in $components"
  hc template svp-cluster "$repo_root/deploy/helm/svp-cluster" --show-only templates/namespaces.yaml \
    --set-json "platformNamespaces=$wave0" |
    kc apply --server-side --field-manager=svp-pod-security -f - >/dev/null ||
    fail "create and label the namespaces of wave 0 and the project's with Pod Security restricted"
  ok "namespaces of wave 0 ($(jq -r 'map(.name) | join(", ")' <<<"$wave0")) and the project's enforce Pod Security restricted"

  # The architecture of the nodes (ensure_cluster checked they all run the host's): a component with archValues in
  # components.json gets the values file named there after its values, as on the GitOps path (rollouts_plugin_check says
  # why).
  node_arch=$(kc get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/arch}') ||
    fail "read the architecture of the nodes of svp"
  case $node_arch in
    amd64 | arm64) ;;
    *) fail "nodes of svp run '$node_arch': the release images and the plugin of Argo Rollouts exist for amd64 and arm64 only" ;;
  esac
  rollouts_plugin_check

  install_releases
  ok "every component of components.json installed"
}

# Run as a script: main, or a hook of helmfile; sourced (deploy/k8s/rotate-test.sh), it only defines the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = hook ]; then
    shift
    hook "$@"
  else
    [ $# = 0 ] || fail "usage: deploy/k8s/install.sh (make k8s-up), or deploy/k8s/install.sh hook ... (helmfile)"
    main
  fi
fi
