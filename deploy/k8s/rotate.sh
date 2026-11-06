# shellcheck shell=bash
# shellcheck disable=SC2154 # repo_root and kube_context come from deploy/k8s/lib.sh, again from the sourcing script
# The order of a change of credentials, shared by deploy/k8s/secrets.sh (make k8s-secrets, a lab cluster: the dev path,
# or the GitOps path's staging with External Secrets) and deploy/k8s/aws-secrets.sh (make eks-secrets, an EKS cluster
# whose Secrets External Secrets builds from AWS Secrets Manager), and dev_helmfile, through which the dev path runs
# helmfile (deploy/k8s/install.sh as well). Sourced after deploy/k8s/lib.sh; sourcing it only defines functions. Each
# script that sources it sets $again, the command that runs it again, for the messages.
#
# Reloader (component reloader of svp-gitops) restarts every workload that opts in by annotation when a Secret it
# names changes: the services, the web client, GlitchTip, Grafana, the KEDA operator, the object store and Redpanda
# (deploy/helm/*, base/ of svp-gitops). No script restarts anything. What the scripts keep is the order in which the
# new values may reach those workloads, servers first, then the init Jobs of chart svp-data that set the new passwords
# in the servers, then the clients:
#   1. the servers: a changed password of Redpanda's superuser goes into the running broker first (redpanda_admin of
#      lib.sh); then the Secrets of svp-data (or, with External Secrets, every source, and the ExternalSecrets of
#      svp-data built again from it: rotate_es_sync server); then the barrier (rotate_barrier): every running pod of
#      StatefulSet s3 (when the cluster has one) and redpanda runs with the value of .env and is Ready, which Reloader
#      brings about. The init Jobs log in to those servers with the new superuser password and give up at the first
#      failure (backoffLimit 0, after waiting only for the endpoint's readiness): started before Reloader's restart,
#      they would race it;
#   2. the init Jobs of svp-data (hooks of the chart, PostSync with Argo CD), which set each user's new password in
#      Postgres, the object store and Redpanda: rotate_init_dev (helmfile, release svp-data alone) or rotate_init_argocd
#      (an operation sync of Application svp-data). A failure stops the run before the clients' Secrets change, so no
#      client restarts with a password its server does not take yet;
#   3. the clients: the Secrets of svp, svp-obs and keda (with External Secrets: every other ExternalSecret built
#      again, rotate_es_sync clients). Reloader restarts the workloads whose Secret changed; nothing waits for them.
# Every run makes all three steps, whatever changed: applying the same values leaves the Secrets as they are, so
# Reloader restarts nothing, and a run after one that stopped half way makes up the init it missed.
#
# Reloader must run, and each workload must name its Secrets, before a credential changes on a cluster that runs the
# project's workloads, since Reloader reacts to a change of a Secret a workload names, not to its own start nor to the
# annotation's arrival (rotate_unready, rotate_guard). A Rollout that is in a canary when its Secret changes is left to
# Reloader and Argo Rollouts (a restart without a new revision), as any restart of it.

# The annotation by which a workload opts in, on the workload or else on its pod template, where Reloader reads it.
reload_key=secret.reloader.stakater.com/reload

# opt_in_render: prints "<namespace> <Kind> <name> <Secrets>" for each Deployment, StatefulSet and Rollout that the dev
# path's releases of waves 2 and later (deploy/k8s/helmfile.yaml.gotmpl) render with annotation $reload_key, <Secrets>
# its value: the charts of this working tree and base/ of the clone of svp-gitops are where a workload opts in, so no
# list of them is kept here. helmfile template asks no cluster; the releases of chart svp-service render with the
# images of make k8s-up ($dev_helmfile_images of install.sh) or, without them, a placeholder, since the image is not
# what is read here.
opt_in_render() {
  local dev_helmfile_images=${dev_helmfile_images:-} placeholder='' gitops err rendered rc=0 lines
  if [ -z "$dev_helmfile_images" ]; then
    gitops=$(gitops_dir) || exit 1
    placeholder=$(mktemp)
    jq '{images: ([.components[] | select(.path == "deploy/helm/svp-service")
      | {key: .name, value: {repository: "placeholder", tag: "placeholder", digest: ""}}] | from_entries)}' \
      "$gitops/argocd/apps/components.json" >"$placeholder" ||
      fail "read the releases of chart svp-service in $gitops/argocd/apps/components.json"
    dev_helmfile_images=$placeholder
  fi
  err=$(mktemp)
  rendered=$(dev_helmfile template -l 'wave!=0,wave!=1' --skip-deps 2>"$err") || rc=$?
  if [ "$rc" != 0 ]; then
    sed 's/^/      /' "$err" >&2
    rm -f "$err" ${placeholder:+"$placeholder"}
    fail "helmfile template of waves 2 and later (above), to know which workloads opt in to Reloader; run $again again"
  fi
  rm -f "$err" ${placeholder:+"$placeholder"}
  # One document at a time: its kind, the name and namespace under metadata, the first line of the annotation.
  lines=$(awk '
    function flush() {
      if (reload != "" && kind ~ /^(Deployment|StatefulSet|Rollout)$/) print (ns == "" ? "-" : ns), kind, name, reload
      kind = ""; name = ""; ns = ""; reload = ""; meta = 0
    }
    function value(s) { sub(/^[^:]*: */, "", s); gsub(/["'\'']/, "", s); return s }
    /^---/ { flush(); next }
    /^kind: / { kind = value($0) }
    /^metadata:/ { meta = 1; next }
    /^[^ ]/ { meta = 0 }
    meta && /^  name: / { name = value($0) }
    meta && /^  namespace: / { ns = value($0) }
    reload == "" && /^ +secret\.reloader\.stakater\.com\/reload: / { reload = value($0) }
    END { flush() }' <<<"$rendered")
  ! grep -q '^- ' <<<"$lines" ||
    fail "the dev path's releases render a workload that opts in to Reloader without a namespace: $(grep '^- ' <<<"$lines" | head -n 1 | cut -d' ' -f2,3)"
  printf '%s\n' "$lines"
}

# opt_in_gaps: reads the lines of opt_in_render and prints, joined by "; ", what keeps Reloader from restarting those
# workloads: each one that exists and names other Secrets in $reload_key (or none) than its chart does, and each
# namespace and kind of them whose objects Reloader's ServiceAccount may not patch, a restart being a patch. Reloader's
# chart grants that on Rollouts only when the cluster served their API as it rendered (hence the needs of release
# reloader in deploy/k8s/helmfile.yaml.gotmpl). A workload not made yet gets the annotation with its release. Nothing
# when there is nothing to fix.
opt_in_gaps() {
  local sa ns kind name want resource json have answer seen=" " gaps=
  sa=$(kc -n reloader get deployment reloader -o jsonpath='{.spec.template.spec.serviceAccountName}') && [ -n "$sa" ] ||
    fail "read the ServiceAccount of Deployment reloader/reloader; run $again again"
  while read -r ns kind name want; do
    [ -n "$name" ] || continue
    case $kind in
      Deployment) resource=deployments.apps ;;
      StatefulSet) resource=statefulsets.apps ;;
      *) resource=rollouts.argoproj.io ;;
    esac
    json=$(kc -n "$ns" get "$resource" "$name" --ignore-not-found -o json) || fail "read $kind $ns/$name; run $again again"
    if [ -n "$json" ]; then
      have=$(jq -r --arg k "$reload_key" '.metadata.annotations[$k] // .spec.template.metadata.annotations[$k] // ""' <<<"$json") ||
        fail "read the annotations of $kind $ns/$name"
      [ "$have" = "$want" ] || gaps="$gaps; $kind $ns/$name names ${have:-no Secret} in $reload_key, its chart $want"
    fi
    if [[ $seen != *" $ns/$resource "* ]]; then
      seen="$seen$ns/$resource "
      answer=$(kc -n "$ns" auth can-i patch "$resource" --as "system:serviceaccount:reloader:$sa" 2>&1) || true
      case $answer in
        yes) ;;
        no*) gaps="$gaps; Reloader (ServiceAccount reloader/$sa) may not patch $resource in namespace $ns" ;;
        *) fail "ask the cluster whether ServiceAccount reloader/$sa may patch $resource in namespace $ns ($answer); run $again again" ;;
      esac
    fi
  done
  printf '%s' "${gaps#; }"
}

# rotate_unready dev|argocd: true when the cluster runs the project's workloads (StatefulSet s3 or redpanda of
# svp-data: not a new cluster) and a change of credentials would not reach each of them yet, with what is missing in
# $unready_why: Deployment reloader/reloader has no available pod (a cluster made before Reloader, or with it down), or
# a workload does not opt in yet, or Reloader may not restart it. A credential changed before then reaches such a
# workload only at its next restart, and a server's makes the barrier fail. On the dev path (dev) every workload the
# releases render with the annotation is checked (opt_in_render, opt_in_gaps). With Argo CD (argocd), whose GitOps root
# is not rendered here, the servers the barrier waits for (StatefulSets s3 and redpanda, those that exist) must carry
# the annotation; the clients' comes with Argo CD's sync of their waves. A cluster that cannot be read stops the
# script.
rotate_unready() {
  local mode=$1 servers available sts json lines
  unready_why=
  servers=$(kc -n svp-data get statefulsets -o name) || fail "list the StatefulSets of namespace svp-data; run $again again"
  printf '%s\n' "$servers" | grep -qxE 'statefulset[.a-z]*/(s3|redpanda)' || return 1
  available=$(kc -n reloader get deployment reloader --ignore-not-found -o jsonpath='{.status.availableReplicas}') ||
    fail "read Deployment reloader/reloader; run $again again"
  if [ "${available:-0}" -lt 1 ]; then
    unready_why="it runs the project's workloads but no Reloader (Deployment reloader/reloader has no available pod)"
    return 0
  fi
  if [ "$mode" = dev ]; then
    lines=$(opt_in_render) || exit 1
    unready_why=$(opt_in_gaps <<<"$lines") || exit 1
  else
    for sts in s3 redpanda; do
      printf '%s\n' "$servers" | grep -qxE "statefulset[.a-z]*/$sts" || continue
      json=$(kc -n svp-data get statefulsets.apps "$sts" -o json) || fail "read StatefulSet svp-data/$sts; run $again again"
      [ -n "$(jq -r --arg k "$reload_key" '.metadata.annotations[$k] // .spec.template.metadata.annotations[$k] // ""' <<<"$json")" ] ||
        unready_why="${unready_why:+$unready_why; }StatefulSet svp-data/$sts names no Secret in $reload_key yet"
    done
  fi
  [ -n "$unready_why" ]
}

# rotate_guard dev|argocd WAY_IN: stops the script before anything is written when a change of credentials would not
# reach each of the cluster's workloads yet (rotate_unready): Reloader restarts each when a Secret it names changes, so
# a credential changed now would reach the others never, and a server restarted by nobody would make the barrier fail
# half way. WAY_IN says how this kind of cluster gets Reloader and the annotations.
rotate_guard() {
  ! rotate_unready "$1" ||
    fail "cluster ${kube_context#k3d-} is not ready for a change of credentials: $unready_why. Reloader restarts each workload when a Secret it names changes; nothing was changed. $2, then run $again again"
}

# server_current POD CONTAINER VAR VALUE: true when CONTAINER of pod svp-data/POD runs with environment variable VAR
# equal to VALUE and the pod is Ready; otherwise sets server_why to what is not so yet. VALUE goes to the container on
# stdin and is compared there, never printed nor on a command line. A pod that cannot be read stops the script; one
# whose container cannot be compared (it stops just then) is only not current yet.
server_current() {
  local pod=$1 container=$2 var=$3 value=$4 state err rc=0
  state=$(kc -n svp-data get pod "$pod" --ignore-not-found -o \
    jsonpath="{.status.containerStatuses[?(@.name==\"$container\")].state.running.startedAt} {.status.conditions[?(@.type==\"Ready\")].status}") ||
    fail "read pod svp-data/$pod (above), to know whether it runs with the value of .env; run $again again"
  case $state in
    "" | " "*)
      server_why="does not run"
      return 1
      ;;
  esac
  # Exit 3 inside the container means "differs", told apart from kubectl's own failures.
  err=$(printf '%s\n' "$value" | kc -n svp-data exec -i "$pod" -c "$container" -- \
    sh -c "IFS= read -r v; [ \"\$v\" = \"\$$var\" ] || exit 3" 2>&1) || rc=$?
  case $rc in
    0) ;;
    3)
      server_why="runs with another $var than .env"
      return 1
      ;;
    *)
      server_why="could not be compared with .env ($err)"
      return 1
      ;;
  esac
  [ "${state#* }" = True ] || {
    server_why="is not Ready"
    return 1
  }
}

# rotate_barrier STATEFULSET CONTAINER VAR VALUE: when StatefulSet svp-data/STATEFULSET exists, waits until every one
# of its pods runs with VAR of CONTAINER equal to VALUE and is Ready (server_current), 300 s per replica: the time
# Reloader takes to restart them one at a time, highest ordinal first, each Ready before the next. A server that
# takes its password from its environment at start (the object store's root password, the superuser password the
# broker's rpk and sidecar log in with) runs with the previous one until then. Fails naming the StatefulSet once that
# time is over.
rotate_barrier() {
  local sts=$1 container=$2 var=$3 value=$4 replicas limit deadline i pending
  replicas=$(kc -n svp-data get statefulset "$sts" --ignore-not-found -o jsonpath='{.spec.replicas}') ||
    fail "read StatefulSet svp-data/$sts; run $again again"
  [ -n "$replicas" ] || return 0
  limit=$((300 * replicas))
  deadline=$((SECONDS + limit))
  while :; do
    pending=
    for ((i = 0; i < replicas; i++)); do
      if ! server_current "$sts-$i" "$container" "$var" "$value"; then
        pending="pod $sts-$i $server_why"
        break
      fi
    done
    [ -n "$pending" ] || break
    ((SECONDS < deadline)) ||
      fail "StatefulSet svp-data/$sts: $pending ${limit}s after its Secret changed: Reloader did not restart it (kubectl --context $kube_context -n reloader logs deployment/reloader; its annotation secret.reloader.stakater.com/reload must name the Secret); the init Jobs of svp-data and the clients' Secrets wait for it. Run $again again once it runs with the value of .env"
    sleep 2
  done
  ok "StatefulSet $sts: each of its $replicas pod(s) runs with the $var of .env and is Ready"
}

# rotate_es_sync server|clients: has External Secrets Operator build again the ExternalSecrets of namespace svp-data
# (server), or every other one (clients), and waits for them (es_force_sync of lib.sh); a cluster with none of them
# yet (Argo CD makes them with chart svp-cluster) is skipped with a line.
rotate_es_sync() {
  local which=$1 crd ids=
  crd=$(kc get crd externalsecrets.external-secrets.io --ignore-not-found -o name) ||
    fail "look up the CRD of ExternalSecrets; run $again again"
  [ -z "$crd" ] || ids=$(kc get externalsecrets.external-secrets.io -A -o json |
    jq -r --arg which "$which" '.items[] | "\(.metadata.namespace)/\(.metadata.name)"
      | select((startswith("svp-data/")) == ($which == "server"))') ||
    fail "list the ExternalSecrets of the cluster; run $again again"
  if [ -z "$ids" ]; then
    echo "skip  ExternalSecrets of the $which: none yet; Argo CD creates them (chart svp-cluster), each built from its source then"
    return 0
  fi
  # shellcheck disable=SC2086 # one id per word
  es_force_sync $ids
  ok "ExternalSecrets of the $which built again from their source: $(printf '%s' "$ids" | paste -sd ' ' -)"
}

# rotate_init_dev: the init Jobs of chart svp-data on the dev path: release svp-data alone synced again with the chart
# of this working tree (helmfile, no needs; its post-upgrade hooks are the Jobs, and helm waits for them). A cluster
# without the release yet skips it: its Jobs run when make k8s-up installs it.
rotate_init_dev() {
  local found
  found=$(kc -n svp-data get secrets -l owner=helm,name=svp-data -o name) ||
    fail "look up Helm release svp-data; run $again again"
  if [ -z "$found" ]; then
    echo "skip  init Jobs of svp-data: release svp-data is not installed yet; they run when make k8s-up installs it"
    return 0
  fi
  echo "helmfile sync of release svp-data alone: its init Jobs set the new passwords in Postgres, the object store and Redpanda"
  dev_helmfile sync -l name=svp-data ||
    fail "the init Jobs of svp-data (helmfile sync of release svp-data, above) did not set the new passwords; the clients' Secrets were not changed. Run $again again once the cause is fixed"
  ok "init Jobs of svp-data done: the servers take the new passwords"
}

# rotate_init_argocd: the init Jobs of chart svp-data with Argo CD (PostSync hooks): one operation sync of Application
# argocd/svp-data, told apart from any other by a name of its own in initiatedBy, and a wait of up to 600 s until it
# Succeeded. An operation that Failed or ended in Error stops the script with Argo CD's message. A cluster without the
# Application yet skips it: Argo CD runs the Jobs when it first syncs svp-data.
rotate_init_argocd() {
  local app=applications.argoproj.io/svp-data found stamp state deadline=$((SECONDS + 600))
  # Before Argo CD is installed (deploy/k8s/gitops.sh writes the source first) neither the CRD nor the Application exists.
  found=$(kc get crd applications.argoproj.io --ignore-not-found -o name) ||
    fail "look up the CRD of Argo CD's Applications; run $again again"
  [ -z "$found" ] || found=$(kc -n argocd get applications.argoproj.io svp-data --ignore-not-found -o name) ||
    fail "read Application argocd/svp-data; run $again again"
  if [ -z "$found" ]; then
    echo "skip  init Jobs of svp-data: Application argocd/svp-data does not exist yet; Argo CD runs them at its first sync"
    return 0
  fi
  stamp=svp-rotate-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)
  kc -n argocd patch "$app" --type merge \
    -p "{\"operation\":{\"initiatedBy\":{\"username\":\"$stamp\"},\"sync\":{}}}" >/dev/null ||
    fail "start a sync of Application argocd/svp-data; run $again again"
  echo "sync of Application svp-data ($stamp): its PostSync Jobs set the new passwords in Postgres and Redpanda"
  while :; do
    state=$(kc -n argocd get "$app" -o json | jq -r --arg stamp "$stamp" '.status.operationState // {}
      | if .operation.initiatedBy.username == $stamp then "\(.phase // "Running") \(.message // "" | gsub("\n"; " "))"
        else "Waiting" end') || fail "read Application argocd/svp-data; run $again again"
    case $state in
      Succeeded*)
        ok "init Jobs of svp-data done (sync of Application svp-data Succeeded): the servers take the new passwords"
        return 0
        ;;
      Failed* | Error*)
        fail "sync of Application argocd/svp-data ended ${state%% *}: ${state#* }; the clients' Secrets were not changed. Fix the cause, then run $again again"
        ;;
    esac
    ((SECONDS < deadline)) ||
      fail "sync of Application argocd/svp-data Succeeded within 600s (now ${state%% *}); the clients' Secrets were not changed. See kubectl --context $kube_context -n argocd get applications.argoproj.io svp-data -o yaml, then run $again again"
    sleep 3
  done
}

# rotate_clients_note: the line that ends a change of credentials.
rotate_clients_note() {
  ok "Reloader restarts each workload whose Secret changed (none when nothing did); follow them with kubectl --context $kube_context get pods -A -w"
}

# pg_backup_sets: sets pg_server to the archive generation of the running Cluster svp-pg, for an upgrade of chart
# svp-data (state value pgServerName of deploy/k8s/helmfile.yaml.gotmpl). Each restore of svp-pg from its backups creates
# svp-pg again archiving into a new generation (value postgres.backup.serverName), and the chart's default is the
# first generation's: an upgrade without it would point the restored Cluster's WAL archiving back at the generation it
# was restored from, whose archive is not empty, and archiving would fail. A new cluster, or a Cluster made before the
# backups (no serverName yet), leaves it empty: the chart's default. A Cluster that is gone while Backups of it remain
# was deleted after it had data (a restore stopped half way): the chart would create an empty database in its place,
# so the script stops before chart svp-data is upgraded. So it does for a Cluster still being restored
# (bootstrap.recovery set and not Ready yet): the upgrade would remove bootstrap.recovery and externalClusters, which
# the chart renders only on the restore's own command line, while the restore still reads them. Prints nothing.
pg_backup_sets() {
  local found backups restoring origin
  pg_server=
  found=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg --ignore-not-found -o name 2>/dev/null) || found=
  if [ -n "$found" ]; then
    restoring=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
      -o jsonpath='{.spec.bootstrap.recovery.source} {.status.conditions[?(@.type=="Ready")].status}') ||
      fail "read Cluster svp-data/svp-pg"
    case $restoring in
      " "* | *" True") ;;
      *)
        # recovery.source names the entry of externalClusters; the generation is that entry's serverName.
        origin=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
          -o jsonpath="{.spec.externalClusters[?(@.name==\"${restoring%% *}\")].plugin.parameters.serverName}") || origin=
        fail "Cluster svp-data/svp-pg has bootstrap.recovery (restored from generation ${origin:-unknown}) and is not Ready: while the restore runs, installing svp-data would remove bootstrap.recovery, which it reads. Wait until it is Ready (kubectl --context k3d-svp -n svp-data wait --for=condition=Ready cluster/svp-pg --timeout=900s), then run $again again; a restore that fails: docs/runbooks/postgres-restore.md"
        ;;
    esac
    pg_server=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
      -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}') ||
      fail "read Cluster svp-data/svp-pg"
    return 0
  fi
  backups=$(kc -n svp-data get backups.postgresql.cnpg.io -o jsonpath='{range .items[?(@.spec.cluster.name=="svp-pg")]}{.metadata.name}{" "}{end}' 2>/dev/null) ||
    backups=
  [ -z "$backups" ] ||
    fail "Cluster svp-data/svp-pg is missing while Backups of it remain (${backups% }): it was deleted after it had data, a restore stopped half way? Installing svp-data would create an empty database in its place. Finish the restore as docs/runbooks/postgres-restore.md says, or start over with no data: make k8s-down && make k8s-up"
}

# dev_helmfile SUBCOMMAND [ARG...]: helmfile SUBCOMMAND (sync, template, list...) of the dev path's releases,
# deploy/k8s/helmfile.yaml.gotmpl, on cluster svp (the local one only: lib.sh's require_k3d), with ARG... (a selector
# -l, a flag of the subcommand) and the state values the file reads: the clone of svp-gitops (gitops_dir), the nodes'
# architecture, the archive generation of svp-pg (pg_backup_sets), and the images of make k8s-up when
# $dev_helmfile_images names a file of them (install.sh). sync installs one release at a time.
dev_helmfile() {
  local cmd=$1 gitops arch extra=()
  shift
  require_k3d "the helmfile of the dev path"
  command -v helmfile >/dev/null || fail "helmfile not found: run make tools (HELMFILE_VERSION of the Makefile)"
  gitops=$(gitops_dir) || exit 1
  arch=$(kc get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/arch}') && [ -n "$arch" ] ||
    fail "read the architecture of the nodes of svp"
  pg_backup_sets
  if [ -n "$pg_server" ]; then extra+=(--state-values-set "pgServerName=$pg_server"); fi
  if [ -n "${dev_helmfile_images:-}" ]; then extra+=(--state-values-file "$dev_helmfile_images"); fi
  if [ "$cmd" = sync ]; then set -- "$@" --concurrency 1; fi
  # helmfile keeps the charts it pulls from OCI repositories under .k8s/helmfile (gitignored), as lib.sh keeps Helm's.
  HELMFILE_CACHE_HOME="$repo_root/.k8s/helmfile" \
    helmfile --kube-context "$kube_context" --file "$repo_root/deploy/k8s/helmfile.yaml.gotmpl" \
    --state-values-set "gitopsDir=$gitops" --state-values-set "nodeArch=$arch" \
    ${extra[@]+"${extra[@]}"} "$cmd" "$@"
}
