# shellcheck shell=bash
# Helpers shared by the scripts and make targets of the local Kubernetes cluster `svp` (deploy/k8s/, deploy/k8s/k8s.mk):
# the pinned docker/k3d/kubectl/helm calls, bounded waits, the registry and the cluster themselves, the CA export.
# Written for bash 3.2 (the macOS /bin/bash). Sourcing it only defines things, exports the variables below and reads
# the image table (deploy/docker-bake.json, with jq).
#
# Rules every helper keeps: docker and k3d run without DOCKER_DEFAULT_PLATFORM (the global shell sets linux/amd64 for
# another project; the nodes must run native arm64), kubectl and helm always name their context, k3d-svp unless
# SVP_KUBE_CONTEXT names a cloud cluster (below; the current context may be another cluster), every wait has a
# deadline, no Secret value is ever printed.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# k3d's own helper images, pinned by digest (multi-arch index): k3d otherwise picks them by its version tag.
# renovate: datasource=docker depName=ghcr.io/k3d-io/k3d-proxy
export K3D_IMAGE_LOADBALANCER=ghcr.io/k3d-io/k3d-proxy:5.9.0@sha256:7be40abfeb6ac9a81d0d4157a7cbf3aacc68a64a1780ca2efb160f1aea915177
# renovate: datasource=docker depName=ghcr.io/k3d-io/k3d-tools
export K3D_IMAGE_TOOLS=ghcr.io/k3d-io/k3d-tools:5.9.0@sha256:c57abce697e66feeb826922718738fe186b47779312d49d4e51e6fb9b8a6f34d
# The local registry: k3d prefixes the name, so the container is k3d-svp-registry; inside it listens on
# 5000, published on 127.0.0.1:5111 only.
# renovate: datasource=docker depName=docker.io/library/registry
registry_image=docker.io/library/registry:3.1.2@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3
# Deadline of `k3d cluster create` and `k3d cluster start`, which otherwise wait forever for a node's "up and running"
# log line (k3d v5.9.0 sets one only when --timeout > 0). k3d applies it to each step of a create (network, containers
# with their image pulls, start) on its own, so 300 s covers a first run that still pulls the k3s image on a slow link.
k3d_timeout=300s

# Helm keeps its repository list, index cache and plugins under .k8s/helm (gitignored) instead of the user's own
# directories: a repository on the machine with a missing index makes `helm --repo` fail, and the scripts must not add
# repositories to the user's configuration.
export HELM_CACHE_HOME="$repo_root/.k8s/helm/cache"
export HELM_CONFIG_HOME="$repo_root/.k8s/helm/config"
export HELM_DATA_HOME="$repo_root/.k8s/helm/data"

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  exit 1
}

# The context of every kubectl and helm call (kc, hc): k3d-svp, the local cluster, when SVP_KUBE_CONTEXT is unset;
# otherwise SVP_KUBE_CONTEXT, which may only name the local cluster or an EKS cluster of the project by the alias
# `aws eks update-kubeconfig --alias` gives it (svp-stg, svp-prd), never an ARN or another cluster of the kubeconfig.
# Checked as this file is sourced, before any command. A cloud cluster is reached only by the scripts written for it
# (deploy/k8s/aws-secrets.sh, glitchtip-init.sh), each of which sets kube_cloud_ok=1: kc and hc of any other
# script refuse it (the dev path, the drills, which build, reset or measure a local cluster), and so do the helpers of
# the local cluster alone (k3d_, ensure_registry, ensure_cluster, export_ca), whoever calls them.
kube_context=${SVP_KUBE_CONTEXT-k3d-svp}
if ! [[ $kube_context =~ ^(k3d-svp|svp-(stg|prd))$ ]]; then
  printf "FAIL  SVP_KUBE_CONTEXT is %q: it must be k3d-svp (the local cluster, also when unset) or svp-stg or svp-prd (an EKS cluster, by the alias aws eks update-kubeconfig --alias gives it)\n" "$kube_context" >&2
  exit 1
fi
# cloud_context: true when kube_context names an EKS cluster.
cloud_context() { [ "$kube_context" != k3d-svp ]; }
# require_k3d WHAT: fails, naming WHAT, unless kube_context is the local cluster.
require_k3d() {
  ! cloud_context || fail "$1 is for the local cluster k3d-svp only, not context $kube_context"
}
# require_kube_context: fails unless kube_context is the local cluster or the calling script was written for a cloud
# cluster too (kube_cloud_ok=1).
require_kube_context() {
  ! cloud_context || [ "${kube_cloud_ok:-}" = 1 ] ||
    fail "context $kube_context is an EKS cluster, which this script does not run against: only the eks-* targets of the Makefile reach one"
}

docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }
k3d_() {
  require_k3d k3d
  env -u DOCKER_DEFAULT_PLATFORM k3d "$@"
}
kc() {
  require_kube_context
  kubectl --context "$kube_context" "$@"
}
hc() {
  require_kube_context
  helm --kube-context "$kube_context" "$@"
}

# wait_until SECONDS DESCRIPTION COMMAND...: runs COMMAND every 2 s until it succeeds; fails naming DESCRIPTION once
# SECONDS have passed. For conditions `kubectl wait` cannot express, such as a resource that does not exist yet.
wait_until() {
  local limit=$1 what=$2 deadline=$((SECONDS + $1))
  shift 2
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "$what within ${limit}s"
    sleep 2
  done
}

# port_free PORT: true when nothing accepts connections on 127.0.0.1:PORT. The lab's ports are fixed, so a taken port is
# an error to report, never a reason to pick another.
port_free() { ! nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1; }

# ensure_registry: creates the registry k3d-svp-registry on 127.0.0.1:5111, starts it when it exists but is stopped,
# leaves it alone when it runs. Shared by every target that pushes images or creates the cluster.
ensure_registry() {
  local state
  require_k3d "the registry k3d-svp-registry"
  state=$(docker_ inspect --format '{{.State.Running}}' k3d-svp-registry 2>/dev/null || true)
  case $state in
    true) ok "registry k3d-svp-registry already running (127.0.0.1:5111)" ;;
    false)
      docker_ start k3d-svp-registry >/dev/null || fail "start the stopped registry k3d-svp-registry"
      ok "registry k3d-svp-registry started (127.0.0.1:5111)"
      ;;
    *)
      port_free 5111 || fail "127.0.0.1:5111 (registry) is already in use by another process; free it and run again"
      k3d_ registry create svp-registry --port 127.0.0.1:5111 --image "$registry_image" >/dev/null ||
        fail "create the registry k3d-svp-registry"
      ok "registry k3d-svp-registry created (127.0.0.1:5111)"
      ;;
  esac
  wait_until 30 "registry API on 127.0.0.1:5111" curl -sf --max-time 2 http://127.0.0.1:5111/v2/
}

# ensure_cluster: run after ensure_registry. Creates the cluster svp from deploy/k8s/k3d.yaml, starts its stopped nodes, or leaves a running one
# alone; then checks every node is Ready and runs the machine's own architecture (an amd64 node here would mean
# DOCKER_DEFAULT_PLATFORM leaked into k3d, and every pod would run emulated).
ensure_cluster() {
  local all running on_net port want archs node binds bind src psa psa_versions exists= recreate=
  # Where k3d.yaml mounts deploy/k8s/pod-security-admission.yaml in the server node, and the API server reads it.
  local psa_in_node=/etc/rancher/k3s/pod-security-admission.yaml
  require_k3d "creating or starting cluster svp"
  if k3d_ cluster get svp >/dev/null 2>&1; then
    exists=1
    # An existing cluster mounts the file and its API server reads it again each time the node starts, which Docker
    # may already have done with the broken file (see below): fixing the file alone is not enough, the cluster is
    # recreated once it is right.
    recreate="; cluster svp mounts this file and its API server reads it again each time the node starts: once the file is right, recreate the cluster from this checkout, which deletes its data: make k8s-down && make k8s-up"
  fi
  # The admission configuration's three versions must be the one every labelled namespace enforces
  # (podSecurityVersion of chart svp-cluster), or a namespace with labels and one without would be held to different
  # rules. Checked for an existing cluster too: its API server reads the file again each time its node starts.
  psa=$repo_root/deploy/k8s/pod-security-admission.yaml
  [ -f "$psa" ] || fail "$psa is missing; k3d.yaml mounts it into the server node$recreate"
  want=$(sed -n 's/^podSecurityVersion: *//p' "$repo_root/deploy/helm/svp-cluster/values.yaml")
  psa_versions=$(sed -nE 's/^ +(enforce|audit|warn)-version: *//p' "$psa" | tr '\n' ' ')
  [ -n "$want" ] && [ "$psa_versions" = "$want $want $want " ] ||
    fail "enforce-, audit- and warn-version of deploy/k8s/pod-security-admission.yaml (${psa_versions% }) must all equal podSecurityVersion of deploy/helm/svp-cluster/values.yaml ('$want')$recreate"
  if [ -n "$exists" ]; then
    # Pod Security "restricted" by default exists only in a cluster created with it: the argument and
    # mount k3d.yaml gives the server node at creation. A cluster made before them enforces nothing in namespaces
    # without PSA labels (default, kube-public, kube-node-lease) and is not changed in place.
    node=$(docker_ inspect --format '{{join .Config.Cmd " "}}' k3d-svp-server-0) &&
      binds=$(docker_ inspect --format '{{range .HostConfig.Binds}}{{println .}}{{end}}' k3d-svp-server-0) ||
      fail "read the arguments and mounts of node k3d-svp-server-0"
    # One bind per line ("SOURCE:TARGET[:OPTIONS]"), so a source path with spaces stays whole.
    src=
    while IFS= read -r bind; do
      case $bind in *":$psa_in_node" | *":$psa_in_node:"*) src=${bind%":$psa_in_node"*} ;; esac
    done <<<"$binds"
    case $node in
      *"admission-control-config-file=$psa_in_node"*) ;;
      *) src= ;;
    esac
    [ -n "$src" ] ||
      fail "cluster svp was created without the Pod Security admission configuration (deploy/k8s/pod-security-admission.yaml); recreate it, which deletes its data: make k8s-down && make k8s-up"
    # The mount is the file on the machine at the path the cluster was created from, and the API server reads it
    # again each time the node starts: on every `k3d cluster start`, and whenever Docker starts the node by itself
    # (restart policy unless-stopped, e.g. after Docker or the laptop restarts), so a running cluster is checked too.
    # Repository moved or renamed, or a checkout without the file: Docker creates an empty directory at the old
    # path, mounts it, and the API server never comes up (k3d cluster start would only time out after 300 s). A file
    # there that differs from this repository's would be read unchecked. Either way the cluster is recreated from
    # this checkout; another clone with the same content is fine.
    [ -f "$src" ] ||
      fail "node k3d-svp-server-0 mounts the Pod Security admission configuration from '$src', which is no longer a file (repository moved or renamed, or the file deleted): its API server would not start again; recreate the cluster from this checkout, which deletes its data: make k8s-down && make k8s-up"
    [ "$src" = "$psa" ] || cmp -s "$src" "$psa" ||
      fail "node k3d-svp-server-0 mounts the Pod Security admission configuration from '$src', which differs from $psa; recreate the cluster from this checkout, which deletes its data: make k8s-down && make k8s-up"
    all=$(docker_ ps -aq --filter label=k3d.cluster=svp | wc -l)
    running=$(docker_ ps -q --filter label=k3d.cluster=svp | wc -l)
    if [ "$running" -lt "$all" ]; then
      # Same address race as the create below: before starting the nodes, k3d recreates its tools container with the
      # network's first free address, which a running registry may hold, so the tools container takes the fixed
      # address of the server node and the server fails with "Address already in use" (k3d v5.9.0,
      # GatherEnvironmentInfo and GetHostIP). The registry is stopped meanwhile and started after the nodes.
      docker_ stop k3d-svp-registry >/dev/null || fail "stop the registry k3d-svp-registry before starting the cluster"
      if ! k3d_ cluster start svp --wait --timeout "$k3d_timeout" >/dev/null; then
        docker_ start k3d-svp-registry >/dev/null
        fail "k3d cluster start svp (k3d's log above gives the cause)"
      fi
      docker_ start k3d-svp-registry >/dev/null || fail "start the registry k3d-svp-registry"
      wait_until 30 "registry API on 127.0.0.1:5111" curl -sf --max-time 2 http://127.0.0.1:5111/v2/
      ok "cluster svp started"
    else
      ok "cluster svp already running"
    fi
    # A registry created again beside an existing cluster (deleted by hand, or broken) sits on Docker's default bridge
    # only: the nodes then cannot resolve k3d-svp-registry and every pull of k3d-svp-registry:5111/... fails. Connected
    # once the nodes run, so it cannot take the fixed address of a node that is still stopped (see the create below).
    on_net=$(docker_ inspect --format '{{if index .NetworkSettings.Networks "k3d-svp"}}yes{{end}}' k3d-svp-registry)
    if [ -z "$on_net" ]; then
      docker_ network connect k3d-svp k3d-svp-registry ||
        fail "connect the registry k3d-svp-registry to network k3d-svp"
      ok "registry k3d-svp-registry connected to network k3d-svp"
    fi
  else
    # k3d.yaml mounts the admission configuration from ${SVP_REPO_ROOT}, which k3d expands from the environment: Docker
    # refuses a relative bind source. A missing file only makes k3d warn, and Docker would mount an empty directory in
    # its place, which stops the API server; so it must exist (checked above, with its versions).
    export SVP_REPO_ROOT=$repo_root
    for port in 6550 8443; do
      port_free "$port" || fail "127.0.0.1:$port (cluster svp) is already in use by another process; free it and run again"
    done
    # k3d reserves the network's first free address for its tools container in memory only, while Docker hands that
    # same address to the running registry when k3d connects it; the server node may then be given the address the
    # tools container takes a moment later (always when its image is still being pulled) and fails to start with
    # "Address already in use" (k3d v5.9.0, ClusterPrepNetwork and ClusterRun in pkg/client/cluster.go). Connected
    # while stopped, the registry gets an address only when started again, after the nodes have theirs.
    docker_ stop k3d-svp-registry >/dev/null || fail "stop the registry k3d-svp-registry before creating the cluster"
    # On failure, a timeout included, k3d deletes what it had created (rollback), network k3d-svp too; the stopped
    # registry would still name that network and never start again ("network k3d-svp not found"), so it is detached
    # first (an error only means k3d already detached it). The next run then starts clean.
    # One step has no deadline: k3d creates its tools container (pulling k3d-tools when missing) on a context
    # without --timeout, so a pull that hangs keeps this command waiting. It is not killed from outside: k3d would
    # stop halfway without its rollback, leaving a half-made cluster that is harder to clean up than a hang the
    # user sees. When it hangs: Ctrl-C, then `make k8s-down` and `make k8s-up`.
    if ! k3d_ cluster create --config "$repo_root/deploy/k8s/k3d.yaml" --timeout "$k3d_timeout"; then
      docker_ network disconnect k3d-svp k3d-svp-registry >/dev/null 2>&1
      docker_ start k3d-svp-registry >/dev/null
      fail "k3d cluster create (k3d rolled back what it had created; its log above gives the cause)"
    fi
    docker_ start k3d-svp-registry >/dev/null || fail "start the registry k3d-svp-registry"
    wait_until 30 "registry API on 127.0.0.1:5111" curl -sf --max-time 2 http://127.0.0.1:5111/v2/
    ok "cluster svp created"
  fi
  kc wait --for=condition=Ready node --all --timeout=120s >/dev/null || fail "every node of svp Ready within 120s"
  case $(uname -m) in
    arm64 | aarch64) want=arm64 ;;
    *) want=amd64 ;;
  esac
  archs=$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}' | sort -u)
  [ "$archs" = "$want" ] || fail "nodes of svp run '$archs', expected $want only (DOCKER_DEFAULT_PLATFORM leaked?)"
  ok "nodes Ready, kubernetes.io/arch=$want"
}

# export_ca: writes the cluster CA (key ca.crt of Secret svp-local-ca, a public certificate) to .k8s/ca.crt for
# `curl --cacert .k8s/ca.crt`. Written through a private temporary file and checked to parse before it replaces the
# old one.
export_ca() {
  local tmp
  require_k3d "the CA of the cluster's self-signed certificates"
  mkdir -p "$repo_root/.k8s"
  tmp=$(mktemp "$repo_root/.k8s/ca.crt.XXXXXX")
  if ! kc -n cert-manager get secret svp-local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$tmp" ||
    ! openssl x509 -noout -in "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "read the CA certificate from Secret cert-manager/svp-local-ca"
  fi
  chmod 644 "$tmp"
  mv "$tmp" "$repo_root/.k8s/ca.crt"
  ok "CA written to .k8s/ca.crt"
}

# secret NAMESPACE NAME TYPE KEY=VALUE...: prints one Secret manifest, with the one label in $label ("key: value") when
# the call sets it (label=... secret ...). The values are base64-encoded through a pipe; none is an argument of any
# program. For `kc apply --server-side -f -` on stdin: no value goes through a file or a command line, and a
# server-side apply keeps them out of the last-applied-configuration annotation a client-side apply would copy them
# into. An empty value is written "", so its key is there all the same: an ExternalSecret that names it would
# otherwise fail on a key that does not exist.
secret() {
  local ns=$1 name=$2 type=$3 kv
  shift 3
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n' "$name" "$ns"
  if [ -n "${label:-}" ]; then printf '  labels:\n    %s\n' "$label"; fi
  printf 'type: %s\ndata:\n' "$type"
  for kv in "$@"; do
    printf '  %s: "%s"\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | base64 | tr -d '\n')"
  done
}

# es_force_sync [NAMESPACE/NAME...]: has External Secrets Operator build ExternalSecrets NAME (every ExternalSecret of
# the cluster when none is named) again from their store, and waits up to 120 s until each has. Their refreshPolicy is
# OnChange (chart svp-cluster, templates/external-secrets.yaml): a changed source reaches a Secret only through a
# change of its ExternalSecret, here a new value of annotation force-sync. ESO then syncs once and writes
# status.syncedResourceVersion (<generation>-<hash of labels and annotations>), new with the annotation, as soon as
# that sync succeeds, whether or not the Secret it builds differs from the one there: an unchanged Secret is left as it
# is (no new resourceVersion, so no pod restarts for it). Waiting for a new resourceVersion of every Secret would hang
# on each whose values did not change. An ExternalSecret whose generation changes meanwhile (Argo CD applied another
# revision) stops the wait, since the sync seen may be of that spec; so does one that is gone. Prints nothing but a
# failure: the reason and message of the Ready condition of each ExternalSecret not done, which ESO keeps to what is
# safe to show.
es_force_sync() {
  local want=" $* " stamp list before id left deadline=$((SECONDS + 120))
  list=$(kc get externalsecrets.external-secrets.io -A -o json) || fail "list the ExternalSecrets of the cluster"
  before=$(jq -c --arg want "$want" '[.items[] | {id: "\(.metadata.namespace)/\(.metadata.name)",
    gen: .metadata.generation, rv: (.status.syncedResourceVersion // "")}
    | .id as $id | select($want == "  " or ($want | contains(" " + $id + " ")))] | map({key: .id, value: .})
    | from_entries' \
    <<<"$list") || fail "read the ExternalSecrets of the cluster"
  for id in "$@"; do
    jq -e --arg id "$id" 'has($id)' <<<"$before" >/dev/null || fail "ExternalSecret $id not found"
  done
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)
  for id in $(jq -r 'keys[]' <<<"$before"); do
    kc -n "${id%%/*}" annotate externalsecrets.external-secrets.io "${id#*/}" --overwrite "force-sync=$stamp" \
      >/dev/null || fail "annotate ExternalSecret $id with force-sync"
  done
  while :; do
    list=$(kc get externalsecrets.external-secrets.io -A -o json) || fail "list the ExternalSecrets of the cluster"
    left=$(jq -r --argjson before "$before" '
      (.items | map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $now
      | $before | to_entries[] | .key as $id | .value as $b | $now[$id] as $es
      | if $es == null then "stop \($id): gone"
        elif $es.metadata.generation != $b.gen then "stop \($id): its spec changed (generation \($b.gen) to \($es.metadata.generation))"
        else (($es.status.conditions // []) | map(select(.type == "Ready")) | first // {}) as $r
          | if ($es.status.syncedResourceVersion // "") != $b.rv and $r.status == "True" then empty
            else "wait \($id): Ready \($r.status // "-") \($r.reason // "-"): \($r.message // "" | gsub("\n"; " "))" end
        end' <<<"$list") || fail "read the ExternalSecrets of the cluster"
    [ -n "$left" ] || return 0
    if grep -q '^stop ' <<<"$left"; then
      printf '%s\n' "$left" | sed -n 's/^stop /      /p' >&2
      fail "an ExternalSecret changed while it was being synced again (above): Argo CD applied a new revision? Run this again"
    fi
    if ((SECONDS >= deadline)); then
      printf '%s\n' "$left" | sed 's/^wait /      /' >&2
      fail "ExternalSecrets built again from their store within 120s (those above are not)"
    fi
    sleep 2
  done
}

# The values of .env that become Secrets, shared by deploy/k8s/secrets.sh (a lab cluster) and deploy/k8s/aws-secrets.sh
# (the entries of AWS Secrets Manager of an EKS cluster). The caller sources deploy/observability/glitchtip/dotenv.sh,
# whose strict rule they are read with.
#
# dotenv_read FILE VAR...: reads each VAR of FILE into a shell variable of the same name, and the names of those missing
# or empty into dotenv_missing (space first, empty when none). Fails on a FILE that breaks the rule; dotenv_value has
# then named the offending line (never a value) on stderr.
dotenv_read() {
  local file=$1 v val
  shift
  dotenv_missing=
  for v in "$@"; do
    val=$(dotenv_value "$file" "$v") || fail "read $file"
    [ -n "$val" ] || dotenv_missing="$dotenv_missing $v"
    printf -v "$v" '%s' "$val"
  done
}

# check_next_key: NEXT_SERVER_ACTIONS_ENCRYPTION_KEY, as read by dotenv_read. Next decodes the Server Action key with
# atob and imports it as a raw AES-GCM key the first time an action needs it; make env writes 32 bytes (AES-256) in
# standard base64. A value edited into another shape stops the script here, rather than failing in the web pods later,
# on some request. The check is on the text, not on what base64 -d makes of it: macOS base64 -d also decodes the
# URL-safe alphabet (- and _), on which atob throws.
check_next_key() {
  [[ $NEXT_SERVER_ACTIONS_ENCRYPTION_KEY =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
    fail "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY in .env is not the standard base64 of 32 bytes; empty it and run make env, then this again"
}

# check_notify_key FILE AGAIN: reads the GitHub App of Argo CD Notifications (it writes commit statuses on svp-gitops)
# from .env FILE into SVP_ARGOCD_NOTIFY_APP_ID, SVP_ARGOCD_NOTIFY_INSTALLATION_ID and SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64,
# and checks them; on a failure the message names AGAIN, the command to run once .env is fixed (make env cannot make a
# GitHub App's key, so it writes none of them). Its ids are integers; its private key is the standard base64 of the PEM
# file on one line, which the ExternalSecret decodes. The checks read the values without printing them.
check_notify_key() {
  dotenv_read "$1" SVP_ARGOCD_NOTIFY_APP_ID SVP_ARGOCD_NOTIFY_INSTALLATION_ID SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64
  [ -z "$dotenv_missing" ] ||
    fail ".env lacks or has empty:$dotenv_missing, which Argo CD Notifications needs (chart svp-cluster has externalSecrets.argocdNotifications on): set them from the GitHub App svp-argocd-notifier (.env.example), then run $2; no Secret was changed"
  [[ $SVP_ARGOCD_NOTIFY_APP_ID =~ ^[0-9]+$ && $SVP_ARGOCD_NOTIFY_INSTALLATION_ID =~ ^[0-9]+$ ]] ||
    fail "SVP_ARGOCD_NOTIFY_APP_ID and SVP_ARGOCD_NOTIFY_INSTALLATION_ID in .env must be the App's and its installation's numeric ids; no Secret was changed"
  # Whole groups of four characters, padded: b64dec of the ExternalSecret (Go's standard encoding) refuses anything
  # else and puts its error text in the Secret, where base64 -d here would decode a value cut short. Then the whole
  # key, its END line included, as openssl reads it from the pipe; one with a passphrase fails, as Argo CD has none.
  [[ $SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64 =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && ((${#SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64} % 4 == 0)) &&
    printf '%s' "$SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64" | base64 -d 2>/dev/null | openssl pkey -noout -passin pass: >/dev/null 2>&1 ||
    fail "SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64 in .env is not the standard base64 of a PEM private key on one line (base64 < key.pem | tr -d '\\n'); no Secret was changed"
}

# Redpanda, unlike the object store, keeps its superuser svp-admin with its password in its own data: it creates it
# from Secret redpanda-bootstrap once, when the cluster forms, and never reads that Secret again. Every container that
# logs in as svp-admin (the broker's rpk, the sidecar that keeps the superusers in step, the redpanda-init Job) takes
# the password from that Secret when it starts. A changed password applied to the Secret (or its source) alone would
# lock all of them out as soon as they start again, with the password Redpanda knows gone from everywhere.
#
# redpanda_admin: makes Redpanda take SVP_KAFKA_ADMIN_PASSWORD (as read from .env) for svp-admin before any Secret or
# source of one is written: first step of a changed secret, on a lab cluster (deploy/k8s/secrets.sh) and on EKS
# (deploy/k8s/aws-secrets.sh) alike. Inside the broker container it logs in with that password; when that fails, with
# the one of Secret redpanda-bootstrap, then with the one the container started with, and sets the new one. It stops
# the script, before anything is written, when the password changes and no broker runs to take it; the messages name
# $again, the command that runs the script again. The passwords go to the container on stdin; the new one is on rpk's
# command line inside that container only, as in the redpanda-init Job.
redpanda_admin() {
  local current ready err rc=0
  # No data volume yet: the cluster that forms takes svp-admin from the Secret written now.
  kc -n svp-data get pvc datadir-redpanda-0 >/dev/null 2>&1 || return 0
  current=$(kc -n svp-data get secret redpanda-bootstrap -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) ||
    current=
  # The broker container is ready once the Admin API reports it ready (its startup probe); the sidecar's readiness
  # needs svp-admin's login, so it is not waited for.
  ready=$(kc -n svp-data get pod redpanda-0 \
    -o jsonpath='{.status.containerStatuses[?(@.name=="redpanda")].ready}' 2>/dev/null) || true
  if [ "$ready" != true ]; then
    # Nothing changes for Redpanda when the Secret already holds this password. A missing Secret is written all the
    # same: without it the broker cannot start at all.
    if [ -z "$current" ] || [ "$current" = "$SVP_KAFKA_ADMIN_PASSWORD" ]; then return 0; fi
    fail "SVP_KAFKA_ADMIN_PASSWORD in .env differs from Secret redpanda-bootstrap and broker redpanda-0 is not running to take it; no Secret was changed. Wait until it runs (scaled to 0: kubectl --context $kube_context -n svp-data scale statefulset redpanda --replicas=1) and run $again again, or put the previous value back in .env"
  fi
  # Exit 10 inside the container means "set", 3 "no password logs in", 4 "the update failed", 5 "the Admin API gave
  # no answer on the password" (refused, timed out, anything but a rejected login); rpk's error, which holds no
  # password, comes back on stderr.
  err=$(printf '%s\n%s\n' "$SVP_KAFKA_ADMIN_PASSWORD" "$current" |
    kc -n svp-data exec -i redpanda-0 -c redpanda -- bash -c '
      IFS= read -r new; IFS= read -r secret
      # The Admin API answers a superuser only. A wrong password is the HTTP 401 rpk reports as "Unauthorized"; any
      # other failure says nothing about the password, so it stops here: trying the next password could not tell
      # more, and only exit 3 may suggest starting over with new data.
      login() {
        out=$(RPK_PASS=$1 rpk security user list 2>&1) && return 0
        case $out in *Unauthorized*) return 1 ;; esac
        printf "%s\n" "$out" >&2
        exit 5
      }
      login "$new" && exit 0
      for old in "$secret" "$RPK_PASS"; do
        if [ -n "$old" ] && login "$old"; then
          out=$(RPK_PASS=$old rpk security user update svp-admin --new-password "$new" --mechanism SCRAM-SHA-256 2>&1) &&
            login "$new" && exit 10
          printf "%s\n" "$out" >&2
          exit 4
        fi
      done
      printf "%s\n" "$out" >&2
      exit 3' 2>&1) || rc=$?
  case $rc in
    0) ;;
    10) ok "password of svp-admin set in Redpanda from .env (logged in with the previous one)" ;;
    3) fail "Redpanda takes none of these passwords for svp-admin: the one in .env, the one of Secret redpanda-bootstrap, the one redpanda-0 started with; no Secret was changed. Put the previous one back in .env, or start over with new data ($(if cloud_context; then echo "a new cluster $kube_context"; else echo "make k8s-down && make k8s-up"; fi)). rpk: $err" ;;
    4) fail "set svp-admin's password in Redpanda from .env; no Secret was changed. rpk: $err" ;;
    5) fail "Redpanda's Admin API in redpanda-0 did not answer whether svp-admin's password is right (not a rejected password); no Secret was changed. Run $again again once the broker answers. rpk: $err" ;;
    *) fail "log in to Redpanda as svp-admin inside redpanda-0: $err" ;;
  esac
}

# The source of the Secrets of an EKS cluster svp-<env>: entries svp/<env>/<entry> of AWS Secrets Manager in the
# region below, whose shells the infrastructure repository makes, with no value (its module external-secrets), and
# whose values deploy/k8s/aws-secrets.sh and glitchtip-init.sh write, as the learner, with the AWS profile of that
# environment's account. Every aws call names that profile and the region on its command line (aws_), so neither the
# profile's region nor credentials of the environment (AWS_ACCESS_KEY_ID...) take over, and no pager waits for a key
# (AWS_PAGER empty). No value is ever an argument:
# each entry's JSON goes to put-secret-value as file://<file> of a folder of mode 700 that the caller removes.
aws_region=ap-southeast-1
aws_() { AWS_PAGER= aws --profile "$AWS_PROFILE" --region "$aws_region" "$@"; }

# aws_setup: for the EKS cluster kube_context (svp-<env>), sets aws_env and aws_prefix (svp/<env>/), checks that
# AWS_PROFILE is set and that its account is the one of the environment, SVP_AWS_<ENV>_ACCOUNT_ID of the terminal of the
# session (SVP_AWS_STG_ACCOUNT_ID, SVP_AWS_PRD_ACCOUNT_ID: never in a file), before any entry is read or written, and
# makes aws_dir, the folder of the files of put-secret-value. The caller removes aws_dir on exit.
aws_setup() {
  local var want got
  aws_env=${kube_context#svp-}
  aws_prefix=svp/$aws_env/
  [ -n "${AWS_PROFILE:-}" ] ||
    fail "AWS_PROFILE is not set: the AWS profile of the account of $aws_env (AWS_PROFILE=anhnv-$aws_env make ...); nothing was written"
  var=SVP_AWS_$(printf '%s' "$aws_env" | tr '[:lower:]' '[:upper:]')_ACCOUNT_ID
  want=${!var:-}
  [[ $want =~ ^[0-9]{12}$ ]] ||
    fail "$var is not the 12-digit id of the account of $aws_env (export it in the terminal of the session); nothing was written"
  got=$(aws_ sts get-caller-identity --query Account --output text) ||
    fail "read the account of AWS profile $AWS_PROFILE (aws sso login --profile $AWS_PROFILE?); nothing was written"
  [ "$got" = "$want" ] ||
    fail "AWS profile $AWS_PROFILE is of account $got, not of $aws_env ($var=$want); nothing was written"
  ok "AWS profile $AWS_PROFILE: account of $aws_env ($var), region $aws_region"
  aws_dir=$(mktemp -d) && chmod 700 "$aws_dir" || fail "create a temporary directory"
}

# aws_put_entry ENTRY: writes a new value (version AWSCURRENT) of entry svp/<env>/ENTRY, a JSON map of the KEY and
# VALUE lines on stdin (KEY, then its VALUE, one line each; a value is never of several lines). jq builds the map from
# the lines it reads, so no value is on its command line either; the file is removed once written.
aws_put_entry() {
  local entry=$aws_prefix$1 file=$aws_dir/$1.json
  (umask 077 && jq -nR '[inputs] as $l | [range(0; $l | length; 2) | {key: $l[.], value: ($l[. + 1] // "")}]
    | from_entries' >"$file") || fail "write the value of entry $entry"
  aws_ secretsmanager put-secret-value --secret-id "$entry" --secret-string "file://$file" \
    --query VersionId --output text >/dev/null || fail "write entry $entry of AWS Secrets Manager"
  rm -f "$file"
}

# The deployment configuration lives in its own repository, svp-gitops: base/ (the values of every component, the only
# layer the dev path reads), envs/<env>/ (overlays, charts.yaml, images/) and argocd/ (components.json, the root chart,
# AppProject, Argo CD's own install). Every script reads it through gitops_dir; this repository holds the charts.
gitops_url=https://github.com/anhnvcoder/svp-gitops.git
# The clone CI jobs read (make gitops-clone), inside the checkout and gitignored. A machine reads its own (gitops_dir).
gitops_ci_clone=$repo_root/.gitops/svp-gitops

# gitops_is_clone DIR: true when DIR is the top of a git work tree whose remote origin is svp-gitops (over HTTPS or
# SSH): the check every reader of the configuration makes before it trusts a folder.
gitops_is_clone() {
  local top url
  [ -d "$1" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ "$top" = "$(cd "$1" && pwd -P)" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [[ $url =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)anhnvcoder/svp-gitops(\.git)?$ ]]
}

# gitops_dir: prints the absolute path of the clone of svp-gitops to read. SVP_GITOPS_DIR when set (CI sets it to the
# clone of make gitops-clone; on a machine it may name another clone, the one being edited); otherwise
# <workspace>/gitops, where <workspace> holds the main checkout of this repository: the parent of the folder of git's
# common directory (<workspace>/backend/.git, the same from the main checkout and from a worktree under
# <workspace>/.worktrees/, which --show-toplevel would not give). The dev path reads that clone's working tree as it is,
# uncommitted changes included, and never clones, fetches or switches a branch in it. Fails, printing the command that
# makes the clone, when the folder is not a clone of svp-gitops: no other copy of the configuration is ever read in its
# place.
gitops_dir() {
  local dir common
  if [ -n "${SVP_GITOPS_DIR:-}" ]; then
    dir=$SVP_GITOPS_DIR
    gitops_is_clone "$dir" ||
      fail "SVP_GITOPS_DIR=$dir is not a clone of svp-gitops: clone it there (git clone $gitops_url '$dir'), or in CI run make gitops-clone first, which sets it"
  else
    # --path-format=absolute: otherwise git prints the common directory relative to the current directory.
    common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
      fail "$repo_root is not a git checkout, so the workspace that holds the clone of svp-gitops is unknown; set SVP_GITOPS_DIR"
    dir=$(dirname "$(dirname "$common")")/gitops
    gitops_is_clone "$dir" ||
      fail "$dir is not a clone of svp-gitops, the deployment configuration this path reads: git clone $gitops_url '$dir' (or set SVP_GITOPS_DIR to a clone)"
  fi
  (cd "$dir" && pwd -P)
}

# gitops_clone: CI's copy of the configuration (make gitops-clone). Clones svp-gitops anonymously into $gitops_ci_clone
# (the whole history, which the bootstrap reads), or fetches it when it is there, then checks out
# GITOPS_REF (default main: a branch, as origin/<branch>, or a full commit SHA) detached, and exports SVP_GITOPS_DIR to
# that folder for what this shell runs next. Refuses a clone there with uncommitted changes, or a folder that is no
# clone of svp-gitops, instead of overwriting either. A clone with no index was never checked out (a run that stopped
# between the clone and the checkout, as on a GITOPS_REF that is no branch): it holds nothing to lose, so the next run
# checks it out instead of reading every file as deleted. Touches nothing outside .gitops/ of this checkout.
gitops_clone() {
  local dir=$gitops_ci_clone ref=${GITOPS_REF:-main} target sha
  # No credential helper and no prompt: the clone is anonymous, as Argo CD's is.
  local git_=(env GIT_TERMINAL_PROMPT=0 git -c credential.helper=)
  if [ -e "$dir" ]; then
    gitops_is_clone "$dir" ||
      fail "$dir is not a clone of svp-gitops; remove it (rm -rf .gitops) and run make gitops-clone again"
    [ ! -e "$(git -C "$dir" rev-parse --path-format=absolute --git-path index)" ] ||
      [ -z "$(git -C "$dir" status --porcelain)" ] ||
      fail "$dir has uncommitted changes, which make gitops-clone does not overwrite; commit or remove them first"
    "${git_[@]}" -C "$dir" fetch -q --prune origin || fail "git fetch of $gitops_url into $dir"
  else
    mkdir -p "$(dirname "$dir")" || fail "create $(dirname "$dir")"
    "${git_[@]}" clone -q --no-checkout "$gitops_url" "$dir" || fail "git clone $gitops_url into $dir"
  fi
  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    target=$ref
  else
    target=refs/remotes/origin/$ref
  fi
  sha=$(git -C "$dir" rev-parse --verify --quiet "$target^{commit}") ||
    fail "GITOPS_REF=$ref is neither a branch of $gitops_url nor a full commit SHA of it"
  git -C "$dir" checkout -q --detach "$sha" || fail "check out $ref ($sha) in $dir"
  export SVP_GITOPS_DIR=$dir
  ok "svp-gitops at ${sha:0:12} ($ref) in ${dir#"$repo_root"/}"
}

# The web client's source lives in its own repository, svp-frontend; this repository holds none of it.
web_url=https://github.com/anhnvcoder/svp-frontend.git
# The clone CI jobs build and test from (make web-clone), inside the checkout and gitignored. A machine reads its own
# (web_dir).
web_ci_clone=$repo_root/.web/svp-frontend

# web_is_clone DIR: true when DIR is the top of a git work tree whose remote origin is svp-frontend, as gitops_is_clone.
web_is_clone() {
  local top url
  [ -d "$1" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ "$top" = "$(cd "$1" && pwd -P)" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [[ $url =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)anhnvcoder/svp-frontend(\.git)?$ ]]
}

# web_dir: prints the absolute path of the web client's source that images are built from. SVP_WEB_DIR when set (CI
# sets it to the clone of make web-clone; on a machine it may name another clone), which must be a clone of
# svp-frontend;
# otherwise <workspace>/frontend (the workspace as for gitops_dir), which must be one too. The working tree is read as
# it is, uncommitted changes included; nothing is cloned, fetched or switched. No folder there, or one that is no clone
# of svp-frontend, fails, printing the command that makes the clone, instead of building something else in its place.
web_dir() {
  local dir common
  if [ -n "${SVP_WEB_DIR:-}" ]; then
    dir=$SVP_WEB_DIR
    web_is_clone "$dir" ||
      fail "SVP_WEB_DIR=$dir is not a clone of svp-frontend: clone it there (git clone $web_url '$dir'), or in CI run make web-clone first and set SVP_WEB_DIR to its folder"
  else
    # --path-format=absolute: otherwise git prints the common directory relative to the current directory.
    common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
      fail "$repo_root is not a git checkout, so the workspace that holds the clone of svp-frontend is unknown; set SVP_WEB_DIR"
    dir=$(dirname "$(dirname "$common")")/frontend
    web_is_clone "$dir" ||
      fail "$dir is not a clone of svp-frontend, the web client's source: git clone $web_url '$dir' (or set SVP_WEB_DIR to a clone)"
  fi
  (cd "$dir" && pwd -P)
}

# web_dockerfile DIR: the Dockerfile that builds the web image from DIR (printed by web_dir), at the top of the clone.
web_dockerfile() { echo "$1/Dockerfile"; }

# web_clone: CI's copy of the web client's source (make web-clone), as gitops_clone: clones svp-frontend anonymously
# into $web_ci_clone (the whole history), or fetches it when it is there, then checks out WEB_REF detached and exports
# SVP_WEB_DIR to that folder for what this shell runs next. WEB_REF is a branch (as origin/<branch>) or a full commit
# SHA; unset, it is the commit of the web release staging runs (image.tag of envs/stg/images/web.yaml in the
# clone of svp-gitops, gitops_dir), so the tests run the code of the image that runs there. That release must be
# <imagePrefix>web of a release source of the working tree's table (release_source_of): the source that publishes web
# is the web client's repository, and every tag of it is a commit of svp-frontend; a release under no such prefix has
# no commit there, and WEB_REF must then be given. Refuses a clone there with uncommitted changes, or a folder that is no clone of svp-frontend. Touches
# nothing outside .web/ of this checkout.
web_clone() {
  local dir=$web_ci_clone ref=${WEB_REF:-} target sha gitops file repo tag=
  local git_=(env GIT_TERMINAL_PROMPT=0 git -c credential.helper=)
  if [ -z "$ref" ]; then
    gitops=$(gitops_dir) || exit 1
    file=$gitops/envs/stg/images/web.yaml
    [ -f "$file" ] || fail "$file not found; set WEB_REF to a branch or a full commit SHA of svp-frontend"
    repo=$(values_field repository <"$file") || fail "cannot read image.repository in $file (above)"
    release_source_of web "$repo" >/dev/null ||
      fail "staging runs web from $repo (envs/stg/images/web.yaml), not a release of a source that publishes web ($(release_repositories web)): set WEB_REF to a branch or a full commit SHA of svp-frontend"
    tag=$(values_field tag <"$file") || fail "cannot read image.tag in $file (above)"
    [ -n "$tag" ] || fail "image.tag is empty in $file; set WEB_REF to a branch or a full commit SHA of svp-frontend"
    ref=$tag
  fi
  if [ -e "$dir" ]; then
    web_is_clone "$dir" ||
      fail "$dir is not a clone of svp-frontend; remove it (rm -rf .web) and run make web-clone again"
    [ ! -e "$(git -C "$dir" rev-parse --path-format=absolute --git-path index)" ] ||
      [ -z "$(git -C "$dir" status --porcelain)" ] ||
      fail "$dir has uncommitted changes, which make web-clone does not overwrite; commit or remove them first"
    "${git_[@]}" -C "$dir" fetch -q --prune origin || fail "git fetch of $web_url into $dir"
  else
    mkdir -p "$(dirname "$dir")" || fail "create $(dirname "$dir")"
    "${git_[@]}" clone -q --no-checkout "$web_url" "$dir" || fail "git clone $web_url into $dir"
  fi
  # A release's tag is the first 12 hex digits of its commit; WEB_REF itself is a branch or a full SHA.
  if [ -n "$tag" ] || [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    target=$ref
  else
    target=refs/remotes/origin/$ref
  fi
  sha=$(git -C "$dir" rev-parse --verify --quiet "$target^{commit}") ||
    fail "WEB_REF=$ref is neither a branch of $web_url nor a commit of it"
  git -C "$dir" checkout -q --detach "$sha" || fail "check out $ref ($sha) in $dir"
  export SVP_WEB_DIR=$dir
  ok "svp-frontend at ${sha:0:12} ($ref) in ${dir#"$repo_root"/}"
}

# argocd_root_app REPO_URL REVISION ENV CHART_REPO_URL: prints the root Application svp-root of the GitOps path, as
# JSON for `kc apply -f -`: chart argocd/root of svp-gitops (REPO_URL) at REVISION, the first of the two levels of the
# root. It reads envs/ENV/ (its value env, a directory of envs/) and renders Application svp-apps, chart argocd/apps at
# the commit gitopsRevision of envs/ENV/charts.yaml pins, or at REVISION when the environment pins none (its value
# targetRevision, which svp-apps hands to every Application it makes for its values files), with the charts of this
# repository from CHART_REPO_URL at the commit charts.yaml pins (its value chartRepoURL) and the overlays of ENV. The
# root of an EKS cluster is the same Application, made by the bootstrap of the infrastructure repository (an
# ApplicationSet over the cluster's Secret) at refs/heads/main. REVISION is a full ref (refs/heads/<branch>) or a
# commit, never a short name: Argo CD fetches every branch and tag and may resolve a short name to a tag of that name, so a tag named main
# pushed with a stolen token could be deployed. Built by jq from --arg values, so the revision and the environment are always JSON
# strings: a branch named 2026, true or 1e3 written into YAML as it is would be read as a number or a boolean, which the
# Application CRD refuses (targetRevision is a string).
#
# Label svp.io/notify=root is what the subscriptions of Argo CD Notifications select (platforms/eks/argo-cd.yaml of
# svp-gitops): the root alone reports, one commit status argocd/ENV per commit of svp-gitops for the whole environment.
# Where notifications are off (k3d) the label selects nothing.
#
# The root compares with Argo CD's default diff, not with the server-side diff the controller uses for every other
# Application (base/argo-cd.yaml of svp-gitops): the root applies its child Applications client-side (no
# ServerSideApply=true), so their fields belong to a field manager of operation Update. A server-side dry run is an
# Apply, which never removes a field another manager entry owns: a field deleted from chart argocd/root (an
# ignoreDifferences, a retry block, managedNamespaceMetadata) would stay in the predicted and the live Application
# alike, so the root would stay Synced and the child keep the field for good. The default diff compares with the
# kubectl.kubernetes.io/last-applied-configuration annotation of a client-side apply and sees the deletion. The
# children apply their own objects server-side (ServerSideApply=true), for which the server-side diff is right.
argocd_root_app() {
  jq -n --arg repo "$1" --arg rev "$2" --arg env "$3" --arg charts "$4" '{
    apiVersion: "argoproj.io/v1alpha1",
    kind: "Application",
    metadata: {
      name: "svp-root",
      namespace: "argocd",
      labels: {"svp.io/notify": "root"},
      annotations: {"argocd.argoproj.io/compare-options": "ServerSideDiff=false"}
    },
    spec: {
      project: "svp",
      source: {
        repoURL: $repo,
        targetRevision: $rev,
        path: "argocd/root",
        helm: {valuesObject: {targetRevision: $rev, env: $env, chartRepoURL: $charts}}
      },
      destination: {server: "https://kubernetes.default.svc", namespace: "argocd"},
      syncPolicy: {
        automated: {prune: true, selfHeal: true},
        retry: {limit: 10, backoff: {duration: "10s", factor: 2, maxDuration: "3m"}}
      }
    }
  }'
}

# argocd_root_telegram CHAT_ID: reads root Application svp-root (JSON, from argocd_root_app) on stdin and prints it
# subscribed to Telegram chat CHAT_ID for triggers on-sync-failed and on-health-degraded of Argo CD Notifications, which
# platforms/eks/argo-cd.yaml of svp-gitops defines with the telegram service. The chat is no value of that public
# repository, so the bootstrap adds it from .env as annotations of the root, the one object of Argo CD it writes itself.
argocd_root_telegram() {
  jq -c --arg chat "$1" '.metadata.annotations += {
    "notifications.argoproj.io/subscribe.on-sync-failed.telegram": $chat,
    "notifications.argoproj.io/subscribe.on-health-degraded.telegram": $chat
  }'
}

# image_policy_ready NAME [FAILURE_POLICY]: true when Kyverno has compiled ImageValidatingPolicy NAME
# (status.conditionStatus.ready) and kyverno-resource-validating-webhook-cfg holds a webhook for it: one of the
# policy's failurePolicy (FAILURE_POLICY when given: Fail or Ignore), objectSelector and rules whose namespaceSelector
# carries the policy's match on namespace svp (Kyverno ANDs it with the selector of its own ConfigMap). A policy with
# its own webhookConfiguration.timeoutSeconds (svp-images and every temporary policy of the drills) gets a webhook of
# its own, ivpol.validate.kyverno.svc-fail-finegrained-<policy> (-ignore- in Audit); the webhook is still found by what
# it selects, not by that name, which is Kyverno's to change.
image_policy_ready() {
  local name=$1 want=${2:-} pol
  pol=$(kc get imagevalidatingpolicies.policies.kyverno.io "$name" -o json 2>/dev/null) || return 1
  [ "$(jq -r '.status.conditionStatus.ready // false' <<<"$pol")" = true ] || return 1
  [ -n "$want" ] || want=$(jq -r '.spec.failurePolicy // "Fail"' <<<"$pol")
  kc get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json 2>/dev/null |
    jq -e --arg want "$want" --argjson sel "$(jq -c '.spec.matchConstraints.objectSelector // {}' <<<"$pol")" '
      [.webhooks[] | select(.name | startswith("ivpol."))
        | select(.failurePolicy == $want and (.objectSelector // {}) == $sel)
        | select(any(.rules[]?; .resources | index("pods")))
        | select((.namespaceSelector.matchLabels // {})["kubernetes.io/metadata.name"] == "svp")] | length > 0' >/dev/null
}

# workload_kind NAMESPACE NAME: rollout when NAME is an Argo Rollouts Rollout (the gateway, which chart svp-service
# renders as one for its canary), deployment otherwise. Before Argo Rollouts is
# installed the kind does not exist and the answer is deployment.
workload_kind() {
  if kc -n "$1" get rollouts.argoproj.io "$2" >/dev/null 2>&1; then echo rollout; else echo deployment; fi
}

# test_output WANT COMMAND...: true when COMMAND prints exactly WANT.
test_output() {
  local want=$1 got
  shift
  got=$("$@") || return 1
  [ "$got" = "$want" ]
}

# pg_backup NAME: creates Backup svp-data/NAME of Postgres svp-pg, a base backup by the Barman Cloud plugin into the
# archive generation the Cluster archives to, owned by nothing, so
# that deleting the Cluster leaves it, and waits up to 600 s until it is completed. CloudNativePG never retries a
# Backup: one that fails is final, so this fails at once with the error it recorded. Prints nothing.
pg_backup() {
  local name=$1 state deadline=$((SECONDS + 600))
  kc -n svp-data create -f - >/dev/null <<EOF || fail "create Backup svp-data/$name"
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $name
  namespace: svp-data
spec:
  cluster:
    name: svp-pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  while :; do
    state=$(kc -n svp-data get backups.postgresql.cnpg.io "$name" -o jsonpath='{.status.phase}' 2>/dev/null) || state=
    case $state in
      completed) return 0 ;;
      failed) fail "Backup svp-data/$name failed: $(kc -n svp-data get backups.postgresql.cnpg.io "$name" -o jsonpath='{.status.error}')" ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || fail "Backup svp-data/$name completed within 600s (phase '${state:-none}')"
    sleep 3
  done
}

# The namespaces whose containers' logs unready_report prints, and the only ones whose log lines
# deploy/ci/verify-collect.sh keeps in the public artifact (and job log) of a verification run: third-party servers,
# operators and controllers, whose logs speak of their own start, configuration and peers (Redpanda's startup checks and
# the memory error that stops it, an operator's reconcile errors). Left out: svp (the project's services, whose logs may
# hold user data), envoy-gateway-system (the Envoy proxies' access log holds request paths and query strings, the
# signatures of presigned uploads among them), kube-system and argocd. Within these, unready_report also skips
# GlitchTip (its access log holds the DSN's public key, its errors the events it received) and every Postgres pod of
# CloudNativePG (an error line quotes the statement that failed, values included).
log_tail_namespaces="argo-rollouts cert-manager cnpg-system keda kyverno svp-data svp-obs"

# mark_log NAMESPACE < LOG: prints each line of LOG as "    [NAMESPACE] LINE", the form verify-collect.sh tells a quoted
# container log by, and keeps only for the namespaces of log_tail_namespaces: a line left unmarked (a panic of a
# service, which is no JSON record) would reach the public artifact of a verification run. Every line is marked
# whatever its bytes (LC_ALL=C: sed refuses bytes that are not UTF-8 under a UTF-8 locale), the last one ends with a
# newline even when LOG's does not (else the next line printed would be glued to it), and an empty LOG prints nothing.
mark_log() {
  { cat; echo; } | LC_ALL=C sed -e '${' -e '/^$/d' -e '}' -e "s/^/    [$1] /"
}

# unready_report NAMESPACE: after a release that did not get ready, prints to stderr each container of NAMESPACE that
# is not ready, and each init container that has not exited 0: its state, how its last attempt ended, and, for a
# container whose log may be shown (log_tail_namespaces), the last lines of its log, and of the attempt before when it
# restarted. Helm says no more than "1 pods have failed", and the kubelet keeps the log of the current and the previous
# attempt only, so a container that crashes at every start is gone with its reason once the cluster is: a verification
# run on a machine that is thrown away right after has nothing else to show. Pods that completed (Jobs) are left out.
# Each log line is printed as "    [NAMESPACE] LINE", the form verify-collect.sh keeps only for these namespaces. The
# message of the last attempt is a log tail too when the container's terminationMessagePolicy is
# FallbackToLogsOnError, so it is printed only where the log may be.
unready_report() {
  local ns=$1 sep=$'\x1f' pod container restarts state last show
  kc -n "$ns" get pods -o json 2>/dev/null | jq -r --arg ns "$ns" --arg shown " $log_tail_namespaces " '
    def st: to_entries[0] // {key: "unknown", value: {}}
      | "\(.key)\(if .value.reason then " " + .value.reason else "" end)\(if .value.exitCode != null then " (exit \(.value.exitCode))" else "" end)";
    .items[] | select(.status.phase != "Succeeded") | .metadata.name as $pod
    | (($shown | contains(" " + $ns + " ")) and ((.metadata.labels // {})
        | (has("cnpg.io/cluster") or .["app.kubernetes.io/name"] == "glitchtip") | not)) as $show
    | ([.spec.initContainers[]?, .spec.containers[]?] | map({(.name): (.terminationMessagePolicy // "File")}) | add // {})
      as $policy
    | ((.status.initContainerStatuses // []) | map(select(.state.terminated.exitCode != 0)))
      + ((.status.containerStatuses // []) | map(select(.ready | not)))
    | .[]
    | ($show or $policy[.name] != "FallbackToLogsOnError") as $message
    | [$pod, .name, (.restartCount | tostring), (.state | st),
       (if .lastState.terminated then (.lastState | st)
          + (if $message then .lastState.terminated.message // "" | if . != "" then ": " + . else "" end else "" end)
        else "" end),
       (if $show then "yes" else "" end)]
    | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")' 2>/dev/null |
    while IFS=$sep read -r pod container restarts state last show; do
      echo "pod $ns/$pod, container $container: $state, $restarts restart(s)${last:+; attempt before: $last}" >&2
      if [ -z "$show" ]; then
        echo "  its log is not printed (see log_tail_namespaces of deploy/k8s/lib.sh)" >&2
        continue
      fi
      echo "  last lines of its log:" >&2
      { kc -n "$ns" logs "$pod" -c "$container" --tail=40 </dev/null 2>&1 || true; } | mark_log "$ns" >&2
      if [ "$restarts" != 0 ]; then
        echo "  last lines of the attempt before:" >&2
        { kc -n "$ns" logs "$pod" -c "$container" --previous --tail=40 </dev/null 2>&1 || true; } |
          mark_log "$ns" >&2
      fi
    done
}

# gitops_timeout_report APPS: when the GitOps path's wait for its Applications (APPS, one name per line) ran out,
# prints to stderr what Argo CD's own status line leaves out, so a run on a machine thrown away right after still
# shows why:
#   - each Application of APPS that is not Healthy, and each resource it tracks that is not ready, read from the
#     cluster: Argo CD 3 keeps the health of an Application's resources out of the Application (in its own cache,
#     unless its controller runs with --persist-resource-health), and its API needs a login. Only the kinds of
#     health_kinds below are read, each judged by a rule close to Argo CD's check of it: a Deployment, StatefulSet
#     or DaemonSet by its ready and updated pods and the generation it observed, a Job by its conditions Complete and
#     Failed, a PersistentVolumeClaim by its phase, any other kind by its conditions that say it is ready (Ready,
#     Available, ...) when they are not True, or by having no status at all. One that is not there is "missing";
#   - the CRDs of the Prometheus and Alertmanager objects, when they were created and when they became Established;
#   - the status conditions of every Prometheus and Alertmanager object, or that it has none: no controller has
#     reconciled it;
#   - each container of the Prometheus operator's pods in svp-obs (label app.kubernetes.io/component of chart
#     kube-prometheus-stack): when it started, and the last lines of its log, and of its attempt before when it
#     restarted, marked as unready_report marks them. The operator asks the API server once, at its start, which of
#     its CRDs it serves, and never starts the controller of a CRD that was missing then (it logs a warning "resource
#     ... not installed in the cluster"): a Prometheus object it then never turns into a StatefulSet, with no event.
# Nothing here reads a Secret. Each step that cannot read the cluster prints why and the others still run.
gitops_timeout_report() {
  local apps=$1 out sep=$'\x1f' what a b c d type got pod container restarts started
  local -a list
  # GROUP/KIND ("" for the core group) of the kinds the cluster's charts render that Argo CD judges by their status:
  # with checks of its own (gitops-engine for the workloads, resource_customizations/ of v3.5.5 for the others) or of
  # base/argo-cd.yaml of svp-gitops (Alertmanager, ImageValidatingPolicy). Never Secret, and none of the kinds whose
  # objects are large (CRDs, ConfigMaps, PrometheusRules) and say nothing of readiness.
  local health_kinds="apps/Deployment apps/StatefulSet apps/DaemonSet batch/Job /PersistentVolumeClaim
    monitoring.coreos.com/Prometheus monitoring.coreos.com/Alertmanager postgresql.cnpg.io/Cluster
    external-secrets.io/ExternalSecret external-secrets.io/SecretStore argoproj.io/Rollout cert-manager.io/Certificate
    cert-manager.io/Issuer cert-manager.io/ClusterIssuer keda.sh/ScaledObject gateway.networking.k8s.io/GatewayClass
    gateway.networking.k8s.io/Gateway gateway.networking.k8s.io/HTTPRoute policies.kyverno.io/ImageValidatingPolicy"
  echo "Applications not Healthy, and their resources that are not ready:" >&2
  # One record per Application: app, NAME, HEALTH; then one per namespace and kind of its resources to read:
  # resource, NAMESPACE ("" when cluster-scoped), KIND, GROUP, NAMES (space-separated). Hooks are left out, as Argo CD
  # leaves them out of the health.
  if ! out=$(kc -n argocd get applications.argoproj.io -o json 2>&1); then
    echo "  cannot list the Applications: $out" >&2
  elif ! out=$(jq -r --arg want "$apps" --arg kinds "$health_kinds" '
      [$want | split("\n")[] | select(. != "")] as $names
      | [$kinds | splits("[[:space:]]+") | select(. != "")] as $judged
      | .items[] | .metadata.name as $app | select(any($names[]; . == $app))
      | select((.status.health.status // "-") != "Healthy")
      | ["app", $app, (.status.health.status // "-")],
        ((.status.resources // [])
          | map(select(.hook != true and ("\(.group // "")/\(.kind)" as $k | any($judged[]; . == $k))))
          | group_by([.namespace // "", .group // "", .kind])[]
          | ["resource", (.[0].namespace // ""), .[0].kind, (.[0].group // ""), (map(.name) | join(" "))])
      | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")' <<<"$out" 2>/dev/null); then
    echo "  (Argo CD's answer is not JSON)" >&2
  else
    while IFS=$sep read -r what a b c d; do
      case $what in
        app) echo "  $a: $b" >&2 ;;
        resource)
          type=$b${c:+.$c}
          read -r -a list <<<"$d"
          if ! got=$(kc ${a:+-n "$a"} get "$type" "${list[@]}" --ignore-not-found -o json </dev/null 2>&1); then
            echo "    cannot read $type${a:+ in $a}: $got" >&2
            continue
          fi
          # -s: kubectl prints one object for one name, a List for several, nothing when none is there.
          jq -rs --arg kind "$b" --arg ns "$a" --arg names "$d" '
            def say: "\(.type)=\(.status)\(.reason // "" | if . != "" then " " + . else "" end)\(.message // "" | if . != "" then ": " + . else "" end)";
            def not_ready:
              (.status // {}) as $s
              | if .kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" then
                  (if .kind == "DaemonSet" then [$s.desiredNumberScheduled, $s.numberReady, $s.updatedNumberScheduled]
                   else [.spec.replicas // 1, $s.readyReplicas, $s.updatedReplicas] end | map(. // 0))
                    as [$want, $ready, $updated]
                  | [if ($s.observedGeneration // 0) < (.metadata.generation // 0)
                       then "generation \(.metadata.generation) not observed yet" else empty end,
                     if $ready < $want or $updated < $want then "\($ready)/\($want) ready, \($updated) updated" else empty end,
                     (($s.conditions // [])[] | select(.reason == "ProgressDeadlineExceeded") | say)]
                elif .kind == "Job" then
                  ($s.conditions // []) as $c
                  | if any($c[]; .type == "Complete" and .status == "True") then []
                    elif any($c[]; .type == "Failed" and .status == "True") then [$c[] | select(.type == "Failed") | say]
                    else ["not complete: \($s.active // 0) active, \($s.failed // 0) failed"] end
                elif .kind == "PersistentVolumeClaim" then
                  if $s.phase == "Bound" then [] else ["phase \($s.phase // "-")"] end
                elif $s == {} then ["no status (no controller has reconciled it)"]
                else [(($s.conditions // []) + ($s.conditionStatus.conditions // []) + [($s.parents // [])[].conditions[]?])[]
                    | select(.status != "True" and (.type | IN("Ready", "Available", "Reconciled", "Healthy", "Accepted",
                        "Programmed", "ResolvedRefs", "WebhookConfigured", "RBACPermissionsGranted")))
                    | say]
                end;
            [.[] | if has("items") then .items[] else . end] as $live
            | $names | split(" ")[] as $name
            | ([$live[] | select(.metadata.name == $name)][0]) as $o
            | (if $o == null then ["missing"] else $o | not_ready end) as $why
            | select($why != [])
            | "    \($kind) \(if $ns != "" then $ns + "/" else "" end)\($name): \($why | join("; "))"
            | gsub("[[:cntrl:]]"; " ")' <<<"$got" >&2 2>/dev/null ||
            echo "    (the answer for $type${a:+ in $a} is not JSON)" >&2
          ;;
      esac
    done <<<"$out"
  fi
  echo "CRDs of the Prometheus and Alertmanager objects:" >&2
  if out=$(kc get customresourcedefinitions.apiextensions.k8s.io prometheuses.monitoring.coreos.com \
    alertmanagers.monitoring.coreos.com --ignore-not-found -o json 2>&1); then
    jq -rs '[.[] | if has("items") then .items[] else . end] as $crds
      | if $crds == [] then "  none" else
          ($crds[] | ((.status.conditions // []) | map(select(.type == "Established")) | .[0]) as $e
            | "  \(.metadata.name): created \(.metadata.creationTimestamp // "-"), Established \($e.status // "-") since \($e.lastTransitionTime // "-")")
        end' <<<"$out" >&2 2>/dev/null || echo "  (the answer is not JSON)" >&2
  else
    echo "  cannot read the CRDs: $out" >&2
  fi
  echo "Prometheus and Alertmanager objects (monitoring.coreos.com):" >&2
  if out=$(kc get prometheuses.monitoring.coreos.com,alertmanagers.monitoring.coreos.com -A -o json 2>&1); then
    jq -r 'if (.items // []) == [] then "  none" else
        (.items[] | "  \(.kind) \(.metadata.namespace)/\(.metadata.name): "
          + (if (.status.conditions // []) == [] then "no status conditions (no controller has reconciled it)"
             else [.status.conditions[]
                 | "\(.type)=\(.status)\(.reason // "" | if . != "" then " " + . else "" end)\(.message // "" | if . != "" then ": " + . else "" end)"]
               | join("; ") end)
          | gsub("[[:cntrl:]]"; " "))
      end' <<<"$out" >&2 || echo "  (the answer is not JSON)" >&2
  else
    echo "  cannot list them: $out" >&2
  fi
  echo "The Prometheus operator (svp-obs):" >&2
  if ! out=$(kc -n svp-obs get pods -o json 2>&1); then
    echo "  cannot list the pods of svp-obs: $out" >&2
    return 0
  fi
  jq -r '[.items[] | select((.metadata.labels // {})["app.kubernetes.io/component"] == "prometheus-operator")
      | .metadata.name as $pod | (.status.containerStatuses // [])[]
      | [$pod, .name, (.restartCount | tostring), (.state.running.startedAt // (.state | keys[0]) // "-")]
      | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")]
    | if . == [] then "-" else .[] end' <<<"$out" 2>/dev/null |
    while IFS=$sep read -r pod container restarts started; do
      if [ "$pod" = - ]; then
        echo "  no pod of the operator in svp-obs" >&2
        continue
      fi
      echo "  pod svp-obs/$pod, container $container: started $started, $restarts restart(s); last lines of its log:" >&2
      { kc -n svp-obs logs "$pod" -c "$container" --tail=60 </dev/null 2>&1 || true; } | mark_log svp-obs >&2
      if [ "$restarts" != 0 ]; then
        echo "  last lines of the attempt before:" >&2
        { kc -n svp-obs logs "$pod" -c "$container" --previous --tail=60 </dev/null 2>&1 || true; } |
          mark_log svp-obs >&2
      fi
    done
}

# The image table, deploy/docker-bake.json: the one place that names the images this repository builds from its own
# tree, the six Go services whose releases its CI builds, signs and promotes (web is one of the seven releases, but its
# source and its releases are svp-frontend's). It is a file of Docker Bake: group default lists the services in the
# order the dev path builds them, and target <service> holds the Dockerfile, the context, the build arguments and the
# local tag of its image, svp/<service>:dev (the name compose runs it by). JSON rather than HCL, so that the scripts read it with jq, without docker;
# under deploy/, so that a test copying deploy/ has it. It is read here, once, as this file is sourced: built_services,
# svp_services and dockerfile answer from it, for the image pipeline of CI (deploy/ci/plan.sh, changed-services.sh,
# image-guard.sh, which hands the action image-leg its Dockerfile and context) as for make k8s-images, make k8s-up
# and make up (build_dev_images, compose_images). Every context is the repository root ("."): the CI build
# (image-guard.sh) and image_paths assume it, so a table with another context stops here instead of being built two
# ways. A table missing, not JSON, or naming a service without a target, a Dockerfile or that context stops the
# sourcing script here too.
image_table=deploy/docker-bake.json
image_rows=$(jq -er '.target as $t | .group.default.targets
  | if type == "array" and length > 0 then .[] else error("group default lists no target") end
  | . as $s
  | if type == "string" and test("^[a-z][a-z0-9-]*$") then . else error("target name \(tojson) is not lowercase letters, digits and -") end
  | ($t[$s] // error("group default names \($s), which has no target"))
  | if .context != "." then error("target \($s): context \(.context | tojson) is not the repository root \".\"")
    elif (.dockerfile | type) != "string" or (.dockerfile | test("^[A-Za-z0-9._/-]+$") | not) then
      error("target \($s): no dockerfile, or one with characters outside letters, digits and . _ / -")
    elif .tags != ["svp/\($s):dev"] then error("target \($s): tags is not [\"svp/\($s):dev\"]")
    else "\($s) \(.dockerfile)" end' "$repo_root/$image_table") ||
  fail "read the image table $image_table of $repo_root (jq names what is wrong above)"
# The services whose images this repository builds from its own tree, in the order of group default.
built_services=()
while read -r image_svc _; do built_services+=("$image_svc"); done <<<"$image_rows"
unset image_svc
# The seven services whose images the cluster runs, in the order the dev path builds them: web last (from the clone of
# svp-frontend, web_dir), since the six Go images share the Go module cache and build fast, so their errors show before
# the web build, the longest of all. Every release set (stg, prd, the records of stg) names these seven.
svp_services=("${built_services[@]}" web)

# dockerfile SERVICE: the Dockerfile that builds SERVICE's image (one of built_services), relative to the repository
# root, its context; fails for a service the image table has no target for.
dockerfile() {
  local svc file
  while read -r svc file; do
    [ "$svc" != "$1" ] || {
      echo "$file"
      return 0
    }
  done <<<"$image_rows"
  echo "dockerfile: $1 is no target of the image table $image_table" >&2
  return 1
}

# web_build_id: prints the build id of the web image on the dev path (SVP_BUILD_ID, which Next uses as its
# deploymentId and the server as its release name): dev- and the first 12 hex digits of the SHA-256 of the list
# "<SHA-256 of the content> <path>", sorted by path, of every file the build context web_dir sends (by its
# .dockerignore, not by git: a .DS_Store git ignores counts, a tracked file .dockerignore leaves out does not) plus the
# Dockerfile (web_dockerfile), each path relative to the clone. The same context gives the same id, so the build cache
# gives the same image ID and `make k8s-up` starts no new ReplicaSet (or canary); any change of the context gives a new
# id, so two different builds never share one deploymentId through a file git does not see. A symlink counts by the
# path it points to (the context sends it as it is); file modes do not count.
#
# Only the form the clone's .dockerignore has is understood: each line (blank lines and # comments aside) is a
# one-level name pattern of letters, digits, . _ - * and ?, which, as in Docker, matches a name at the root of the
# context only and leaves out its whole tree. Any other line fails, naming it, instead of drifting from what Docker
# sends unnoticed; a new form means teaching this function the same rule in the same change.
web_build_id() {
  local dir dockerfile=Dockerfile ignore line path name pattern list kept entry
  local patterns=() entries=() files=()
  dir=$(web_dir) || return 1
  ignore=$dir/.dockerignore
  [ -f "$ignore" ] || {
    echo "web_build_id: $ignore is missing" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    case $line in
    *[!A-Za-z0-9._*?-]* | *'**'*)
      echo "web_build_id: $ignore line '$line' is not a one-level name pattern (letters, digits, . _ - * ?); teach web_build_id of deploy/k8s/lib.sh this form first" >&2
      return 1
      ;;
    esac
    patterns+=("$line")
  done <"$ignore"
  while IFS= read -r -d '' path; do
    name=${path##*/}
    kept=yes
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
      # Unquoted on the right, so a glob: * and ? match a leading dot too, as Docker's matcher does.
      # shellcheck disable=SC2053
      if [[ $name == $pattern ]]; then
        kept=
        break
      fi
    done
    [ -z "$kept" ] || entries+=("$name")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
  [ ${#entries[@]} -gt 0 ] || {
    echo "web_build_id: $ignore leaves nothing of $dir in the build context" >&2
    return 1
  }
  # The Dockerfile counts once: a clone's own is usually in its context already.
  files=("${entries[@]}" "$dockerfile")
  for entry in "${entries[@]}"; do
    if [ "$entry" = "$dockerfile" ]; then
      files=("${entries[@]}")
      break
    fi
  done
  # In a subshell with pipefail, so a failed find or shasum fails the whole list. shasum prints "<hash>  <path>"; the
  # two spaces become one. find does not follow symlinks, so a symlink is hashed by its target path, never its content.
  list=$(
    set -o pipefail
    cd "$dir" || exit 1
    {
      find "${files[@]}" -type f -print0 | xargs -0 shasum -a 256 -- |
        sed 's/^\([0-9a-f]\{64\}\)  /\1 /' || exit 1
      find "${entries[@]}" -type l -print0 | while IFS= read -r -d '' path; do
        printf '%s %s\n' "$(readlink "$path" | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)" "$path"
      done || exit 1
    } | LC_ALL=C sort -k2
  ) || {
    echo "web_build_id: cannot hash the files of the build context $dir" >&2
    return 1
  }
  echo "dev-$(printf '%s\n' "$list" | shasum -a 256 | cut -c1-12)"
}

# bake_images SERVICE...: builds the images of SERVICE... (targets of the image table) from the working tree with one
# `docker buildx bake` of those targets, run from the repository root, for this machine's own architecture, loaded
# into the local image store under their tags svp/<service>:dev; no provenance or SBOM, so each image is one plain
# manifest, as the CI build makes it.
bake_images() {
  (cd "$repo_root" && docker_ buildx bake -f "$image_table" --load --provenance=false --sbom=false "$@")
}

# build_web_image: builds the web image from the clone of svp-frontend (web_dir, web_dockerfile; native architecture),
# with SVP_BUILD_ID from web_build_id, which reads the same folder, and sets image_id to its ID, without the sha256:
# prefix.
build_web_image() {
  local dir id
  dir=$(web_dir) || return 1
  id=$(web_build_id) || return 1
  # --quiet prints only the image ID; a failed build still prints its error.
  image_id=$(docker_ build --quiet --file "$(web_dockerfile "$dir")" --build-arg "SVP_BUILD_ID=$id" "$dir") || return 1
  image_id=${image_id#sha256:}
}

# build_dev_images [SERVICE...]: builds the images of SERVICE... (default: the seven of svp_services) from the working
# tree, those of the image table with bake_images, web from the clone of svp-frontend (build_web_image), pushes each to
# the registry as 127.0.0.1:5111/svp/<service>:dev-<first 12 hex digits of its image ID>, and sets dev_tag_<service
# with _ for -> to that tag. The build cache gives the same image ID for the same inputs, so a run with no code
# change yields the same tags, the pod templates do not change, and no new ReplicaSet (later: no canary) starts. Run
# after ensure_registry.
build_dev_images() {
  local svc id tag ref services=("$@") targets=()
  [ $# -gt 0 ] || services=("${svp_services[@]}")
  for svc in "${services[@]}"; do
    [ "$svc" = web ] || targets+=("$svc")
  done
  if [ ${#targets[@]} -gt 0 ]; then
    echo "build ${targets[*]} (docker buildx bake -f $image_table)"
    bake_images "${targets[@]}" || fail "build the images of ${targets[*]} (docker buildx bake -f $image_table)"
  fi
  for svc in "${services[@]}"; do
    if [ "$svc" = web ]; then
      echo "build web"
      build_web_image || fail "build the image of web"
    else
      image_id=$(docker_ image inspect --format '{{.Id}}' "svp/$svc:dev") || fail "read the ID of image svp/$svc:dev"
      image_id=${image_id#sha256:}
    fi
    id=$image_id
    tag="dev-${id:0:12}"
    ref="127.0.0.1:5111/svp/$svc:$tag"
    docker_ tag "$id" "$ref" || fail "tag the image of $svc as $ref"
    docker_ push --quiet "$ref" >/dev/null || fail "push $ref"
    printf -v "dev_tag_${svc//-/_}" '%s' "$tag"
    ok "$svc image $tag pushed to the registry"
  done
}

# image_paths SERVICE: the paths SERVICE's image is built from, relative to the repository root: what its Dockerfile
# copies (go.mod, go.sum, gen/, internal/, services/<service>/), the Dockerfile itself and .dockerignore, which decides
# what reaches the build. SERVICE is one of built_services: CI builds a release of SERVICE when one of them changed
# (deploy/ci/changed-services.sh).
image_paths() {
  printf '%s\n' go.mod go.sum gen internal "services/$1" "$(dockerfile "$1")" .dockerignore
}

# Release images: built, scanned and signed by CI only,
# under this prefix on GHCR, one image per service; nothing else may be pushed there. The promote pull request writes
# a release's repository, tag (first 12 hex digits of its commit, for people) and digest (what pods run) into
# envs/<env>/images/<service>.yaml of svp-gitops; the GitOps cluster pulls them anonymously by digest. The dev path
# never reads them: `make k8s-up` passes its own registry, tag and an empty digest (deploy/k8s/install.sh).
# This is the prefix of this repository's own releases; the release sources below name every prefix the cluster runs.
# shellcheck disable=SC2034 # read by the scripts that source this file
ghcr_prefix=ghcr.io/anhnvcoder/svp-backend

# Release sources: every repository whose CI builds, signs and publishes images the GitOps path runs. Each has a name,
# its repository URL, the prefix its images live under on GHCR (ending in /), the services it publishes there (a
# service is in two sources only while it moves from one to the other), the drill images it may push there, the
# keyless identity of its images.yml on main (issuer, subject), the ref its build provenance names, and the GitHub App
# that promotes its releases (promoter). They are written once, in this file of chart svp-policy, whose policy admits
# exactly these images with these identities; the scripts read the same file, so what they check is what admission
# checks. The rules on the table are written once too, in the template of the chart, which fails the render of a
# table the policy would get wrong (deploy/ci/sources-test.sh). The scripts read the table without checking those rules
# again, since every table they read on the release path has rendered first: the working tree's in job config of CI
# (make helm-check, sources-test.sh), required before a change reaches main; the one at the revision an environment
# pins, a commit on main, in gitops-check.sh (step 3 renders the charts of that revision) and in Argo CD, which syncs
# no policy that does not render. Every source of the working tree's table has a promoter (deploy/ci/sources-test.sh).
# A table of an older commit may hold a retired source, one without promoter: a repository renamed, its successor
# another source, whose releases signed under the old name stayed admitted while an environment ran them, but nothing
# built, promoted or rescanned for it.
release_sources_file=deploy/helm/svp-policy/files/sources.json

# release_sources [REV]: prints the table of release sources ({"sources": [...]}, compact JSON) of this repository at
# commit REV, or of the working tree when REV is empty; fails when it is not JSON. The template above holds every rule
# of the table; this checks the one every script relies on before it builds, pushes, signs or verifies under a prefix,
# on a table no render may have read yet (an image job, a drill on a machine): each imagePrefix is a registry path
# ending in /, and none starts another, so an image is under the prefix of at most one source.
# Fails too when REV is no commit of this clone, or a commit from before the table: no environment pins one any more,
# so its one source is not rebuilt from the policy's values of then; pin a newer commit.
release_sources() {
  local rev=${1:-} table where="the working tree"
  [ -z "$rev" ] || where="commit ${rev:0:12}"
  if [ -z "$rev" ]; then
    table=$(cat "$repo_root/$release_sources_file") || fail "read $release_sources_file"
  elif ! git -C "$repo_root" cat-file -e "$rev^{commit}" 2>/dev/null; then
    fail "$rev is not a commit of this clone, so its release sources cannot be read"
  elif ! table=$(git -C "$repo_root" show "$rev:$release_sources_file" 2>/dev/null); then
    fail "commit ${rev:0:12} has no $release_sources_file: it is from before the table of release sources, which every script reads; pin a newer commit"
  fi
  table=$(jq -c . <<<"$table" 2>/dev/null) || fail "release sources of $where: $release_sources_file is not readable JSON"
  local bad
  bad=$(jq -r '[.sources[]?.imagePrefix] as $p
    | ($p[] | select(type != "string" or (test("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+/$") | not))
      | "imagePrefix \(tojson) is not a registry path ending in /"),
      ([range(0; $p | length) as $i | range(0; $p | length) as $j
        | select($i != $j and ($p[$i] | type) == "string" and ($p[$j] | type) == "string" and ($p[$j] | startswith($p[$i])))
        | "imagePrefix \($p[$j]) starts with imagePrefix \($p[$i])"] | .[])' <<<"$table") ||
    fail "release sources of $where: read the imagePrefix of every source"
  [ -z "$bad" ] || fail "release sources of $where: $(head -n 1 <<<"$bad") (every source's images must lie under its prefix alone)"
  echo "$table"
}

# release_source NAME [REV]: prints source NAME of the table at REV (release_sources) as compact JSON; fails without
# one.
release_source() {
  local table src
  table=$(release_sources "${2:-}") || exit 1
  src=$(jq -c --arg n "$1" '.sources[] | select(.name == $n)' <<<"$table")
  [ -n "$src" ] || fail "no release source named $1 in $release_sources_file${2:+ at ${2:0:12}}"
  echo "$src"
}

# The two lookups below pick a source by the prefix of an image, and with it the identity a signature of the image is
# checked against, as Kyverno picks its attestor. The template refuses a table in which one prefix starts another, so
# at most one source matches; each lookup still fails when more than one does, the one rule a script needs to pick,
# so that a pick never depends on a render having run first (a drill or a check on a machine reads the working tree as
# it is).

# source_of_repository REPOSITORY [REV]: prints the name of the release source whose imagePrefix REPOSITORY lies
# under, in the table at REV; fails unless exactly one source has such a prefix.
source_of_repository() {
  local table names
  table=$(release_sources "${2:-}") || exit 1
  names=$(jq -r --arg r "$1" '[.sources[] | .imagePrefix as $p | select($r | startswith($p)) | .name] | join(" ")' \
    <<<"$table")
  [ -n "$names" ] || fail "$1 is under the prefix of no release source of $release_sources_file${2:+ at ${2:0:12}}"
  [[ $names != *" "* ]] ||
    fail "$1 is under the prefixes of release sources $names of $release_sources_file${2:+ at ${2:0:12}}: it is of no one source"
  echo "$names"
}

# release_source_of SERVICE REPOSITORY [REV]: prints, as compact JSON, the release source in the table at REV of
# which REPOSITORY is SERVICE's image: <imagePrefix>SERVICE of a source whose services name SERVICE, what the policy
# admits for that service. Status 1, printing nothing, when REPOSITORY is none of them (release_repositories names
# what would be); fails when it is the image of more than one.
release_source_of() {
  local table found
  table=$(release_sources "${3:-}") || exit 1
  found=$(jq -c --arg s "$1" --arg r "$2" '[.sources[] | select((.services | index($s)) and .imagePrefix + $s == $r)]' \
    <<<"$table") || fail "read the release sources of $release_sources_file${3:+ at ${3:0:12}}"
  case $(jq length <<<"$found") in
  0) return 1 ;;
  1) jq -c '.[0]' <<<"$found" ;;
  *) fail "$2 is $1 of release sources $(jq -r 'map(.name) | join(" ")' <<<"$found") of $release_sources_file${3:+ at ${3:0:12}}: it is of no one source" ;;
  esac
}

# release_repositories SERVICE [REV]: prints the repositories SERVICE's releases may come from in the table at REV,
# joined by " or " (empty when no source publishes SERVICE).
release_repositories() {
  local table
  table=$(release_sources "${2:-}") || exit 1
  jq -r --arg s "$1" '[.sources[] | select(.services | index($s)) | .imagePrefix + $s] | join(" or ")' <<<"$table"
}

# values_field FIELD: reads a service's values file on stdin and prints image.FIELD (repository, tag or digest)
# without quotes, "" when empty. Only the shape these files have is read: exactly one line `  FIELD: <value>` inside
# the top-level `image:` block, the value bare or in double quotes, no comment after it, and of FIELD's form:
# repository [0-9a-z.:/_-]*, tag empty or 12 lowercase hex digits (a commit), digest empty or sha256:<64 hex>. Anything
# else fails, naming the problem on stderr, rather than guess: the result goes to a registry, to cosign and to git.
# Exit status: 3 no such line, 4 the line twice, 5 a value of the wrong form.
values_field() {
  local form value rc=0
  case $1 in
  repository) form='^[0-9a-z.:/_-]*$' ;;
  tag) form='^([0-9a-f]{12})?$' ;;
  digest) form='^(sha256:[0-9a-f]{64})?$' ;;
  *) fail "values_field: unknown field '$1'" ;;
  esac
  # awk only finds the line; the form is checked by bash, whose regular expressions are the same on macOS and on the
  # Ubuntu runner (awk's interval expressions are not).
  value=$(awk -v key="$1" '
    /^image:/ { block = 1; next }
    /^[^ #]/ { block = 0 }
    block && $0 ~ "^  " key ":" {
      v = $0
      sub("^  " key ":[ ]*", "", v)
      if (v ~ /^"[^"]*"$/) v = substr(v, 2, length(v) - 2)
      out = v
      found++
    }
    END {
      if (found == 0) exit 3
      if (found > 1) exit 4
      print out
    }') || rc=$?
  [ "$rc" != 0 ] || [[ $value =~ $form ]] || rc=5
  case $rc in
  0)
    echo "$value"
    return 0
    ;;
  3) echo "image.$1: no line '  $1: ...' in the image block" >&2 ;;
  4) echo "image.$1: more than one line '  $1: ...' in the image block" >&2 ;;
  5) echo "image.$1: '$value' does not have the form $form" >&2 ;;
  *) echo "image.$1: cannot read the values" >&2 ;;
  esac
  return "$rc"
}

# ghcr_manifest_status NAME DIGEST: prints the HTTP status GHCR answers an anonymous HEAD of manifest NAME@DIGEST
# with (NAME without ghcr.io/), as a node pulling without credentials gets it: 200 when it can pull it. A package that
# is private or does not exist is refused already by the token endpoint (403), whose status is printed then. 000 when
# GHCR cannot be reached.
ghcr_manifest_status() {
  local resp code token
  resp=$(curl -s --max-time 10 -w '\n%{http_code}' "https://ghcr.io/token?scope=repository:$1:pull&service=ghcr.io") ||
    resp=$'\n000'
  code=${resp##*$'\n'}
  if [ "$code" != 200 ]; then
    echo "$code"
    return 0
  fi
  token=$(jq -r '.token // empty' <<<"${resp%$'\n'*}" 2>/dev/null) || token=
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' -I -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/$1/manifests/$2" || true
}

# release_image SERVICE WHERE: reads SERVICE's image file on stdin (WHERE names it in messages, such as
# "envs/stg/images/gateway.yaml at 1a2b3c4d5e6f") and prints REPOSITORY@DIGEST of the release it names
# once the GitOps cluster can pull it: image.digest set (the promote pull request writes it), image.repository
# SERVICE's image of a release source that publishes SERVICE (release_source_of, the working tree's table), and that
# manifest served to an anonymous pull by GHCR. Fails naming the cause
# otherwise; creates nothing. Whether the release carries a signature and a fresh vuln attestation is
# deploy/ci/verify-release.sh's check.
release_image() {
  local svc=$1 where=$2 values repo digest code
  values=$(cat)
  digest=$(values_field digest <<<"$values") ||
    fail "$svc: no release in $where (image.digest above); the promote pull request of svp-gitops writes it: once it is merged, fetch the clone and run again"
  [ -n "$digest" ] ||
    fail "$svc: image.digest is empty in $where: $svc has no release there yet; once the promote pull request of svp-gitops is merged, fetch the clone and run again"
  repo=$(values_field repository <<<"$values") || fail "$svc: cannot read image.repository in $where (above)"
  release_source_of "$svc" "$repo" >/dev/null ||
    fail "$svc: image.repository is '$repo' in $where; the GitOps path runs only releases of $(release_repositories "$svc")"
  code=$(ghcr_manifest_status "${repo#ghcr.io/}" "$digest")
  case $code in
  200) ;;
  401 | 403 | 404)
    fail "$svc: GHCR refuses an anonymous pull of $repo@$digest (HTTP $code): package $repo is not public yet (GitHub: Package settings > Change visibility) or holds no such digest"
    ;;
  *) fail "$svc: GHCR did not answer for $repo@$digest (HTTP ${code:-none}); check the network and run again" ;;
  esac
  echo "$repo@$digest"
}

# stg_release SERVICE: prints REPOSITORY@DIGEST of SERVICE's release in staging: envs/stg/images/SERVICE.yaml in the
# working tree of the clone of svp-gitops (gitops_dir), read as it is (never fetched: pull that clone for the newest),
# checked by release_image (repository, digest, anonymous pull from GHCR).
stg_release() {
  local gitops file
  gitops=$(gitops_dir) || exit 1
  file=$gitops/envs/stg/images/$1.yaml
  [ -f "$file" ] || fail "$1: $file not found, so staging names no release of $1 in that clone"
  release_image "$1" "envs/stg/images/$1.yaml of svp-gitops at $(gitops_at "$gitops")" <"$file"
}

# gitops_at DIR: the commit the clone DIR of svp-gitops is at, and whether envs/stg/images/ differs from it there.
gitops_at() {
  local sha
  sha=$(git -C "$1" rev-parse HEAD) || fail "read the commit of $1"
  if [ -n "$(git -C "$1" status --porcelain -- envs/stg/images)" ]; then
    echo "$sha with uncommitted changes in envs/stg/images/"
  else
    echo "$sha"
  fi
}

# web_source: what the web client of `make up` and `make k8s-up` runs, from WEB_FROM: stg (the default when unset) runs
# the release staging runs (stg_release web); clone builds its image from web_dir, the clone of svp-frontend; image runs
# WEB_IMAGE, a release given as ghcr.io/<repository>@sha256:<digest>, which GHCR must serve to an anonymous pull as the
# nodes and compose pull it. Sets web_release to REPOSITORY@DIGEST of that release, empty when the image is built. A
# release keeps the SVP_BUILD_ID CI built it with and is never built here, so the targets that build the source maps of
# the web (make web-sourcemaps, make k8s-web-sourcemaps) do not apply to it.
web_source() {
  local repo code
  web_release=
  case ${WEB_FROM:-stg} in
  clone | stg)
    [ -z "${WEB_IMAGE:-}" ] || fail "WEB_IMAGE is set, but WEB_FROM is ${WEB_FROM:-stg}: set WEB_FROM=image to run it, or unset it"
    [ "${WEB_FROM:-stg}" = clone ] || web_release=$(stg_release web) || exit 1
    ;;
  image)
    [[ ${WEB_IMAGE:-} =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]] ||
      fail "WEB_FROM=image needs WEB_IMAGE=ghcr.io/<repository>@sha256:<64 hex digits> (got '${WEB_IMAGE:-}')"
    repo=${WEB_IMAGE%@*}
    code=$(ghcr_manifest_status "${repo#ghcr.io/}" "${WEB_IMAGE#*@}")
    [ "$code" = 200 ] ||
      fail "GHCR does not serve $WEB_IMAGE to an anonymous pull (HTTP ${code:-none}): no such digest, a package that is not public, or no network"
    web_release=$WEB_IMAGE
    ;;
  *)
    fail "WEB_FROM='$WEB_FROM' is not valid: stg (default: the release staging runs), clone (build from the clone of svp-frontend) or image (WEB_IMAGE)"
    ;;
  esac
}

# compose_images: exports what deploy/compose/compose.yaml reads to pick the images of the application for `make up`
# and `make compose-config`. IMAGES unset: the six backend services run their images built from the working tree
# (compose_up_images builds them with bake_images, under the tags of the image table, svp/<service>:dev);
# IMAGES=stg: they run their releases in staging (stg_release), their migrations the same images, so a stack of
# this checkout runs exactly what staging runs, with no Go build. Compose never builds or pulls any of the six (pull
# policy never in compose.yaml). The web client as web_source says: built from web_dir (its folder and Dockerfile) by
# compose, or a release. A release runs as already pulled (compose_up_images): pull policy never, so compose neither
# pulls nor builds it. Sets compose_bake to the services compose_up_images builds, compose_releases to every
# REPOSITORY@DIGEST to pull and compose_notes to one line per choice; prints nothing.
compose_images() {
  local svc var ref dir gitops
  compose_bake=() compose_releases=() compose_notes=()
  case ${IMAGES:-} in
  '')
    for svc in "${built_services[@]}"; do
      var=SVP_$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')_IMAGE
      export "$var=svp/$svc:dev"
    done
    compose_bake=("${built_services[@]}")
    compose_notes+=("the six backend services built from the working tree (docker buildx bake -f $image_table)")
    ;;
  stg)
    for svc in "${built_services[@]}"; do
      var=SVP_$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')_IMAGE
      ref=$(stg_release "$svc") || exit 1
      export "$var=$ref"
      compose_releases+=("$ref")
    done
    gitops=$(gitops_dir) || exit 1
    compose_notes+=("the six backend services and their migrations run the releases of staging, envs/stg/images/ of svp-gitops at $(gitops_at "$gitops")")
    ;;
  *)
    fail "IMAGES='$IMAGES' is not valid: leave it unset (build the six backend services from the working tree) or stg (run their releases in staging)"
    ;;
  esac
  web_source
  if [ -n "$web_release" ]; then
    # Never built in this mode, but compose checks that a build context exists: any folder of the checkout will do.
    export SVP_WEB_IMAGE=$web_release SVP_WEB_PULL_POLICY=never SVP_WEB_CONTEXT=$repo_root/deploy/compose
    compose_releases+=("$web_release")
    compose_notes+=("web runs release $web_release, with the build id CI gave it: make web-sourcemaps does not apply")
  else
    dir=$(web_dir) || exit 1
    export SVP_WEB_IMAGE=svp/web:dev SVP_WEB_PULL_POLICY=build SVP_WEB_CONTEXT=$dir
    export SVP_WEB_DOCKERFILE
    SVP_WEB_DOCKERFILE=$(web_dockerfile "$dir")
    compose_notes+=("web built from $dir")
  fi
}

# compose_up_images: compose_images, then builds the backend images of compose_bake (bake_images) and pulls every
# release for this machine's own architecture (docker without DOCKER_DEFAULT_PLATFORM picks it from the
# multi-architecture index), so that a build that fails or a release that cannot be pulled stops `make up` before
# anything starts, and prints the choices.
compose_up_images() {
  local ref note
  compose_images
  if [ ${#compose_bake[@]} -gt 0 ]; then
    echo "build ${compose_bake[*]} (docker buildx bake -f $image_table)"
    bake_images "${compose_bake[@]}" || fail "build the images of ${compose_bake[*]} (docker buildx bake -f $image_table)"
  fi
  for ref in ${compose_releases[@]+"${compose_releases[@]}"}; do
    echo "pull $ref"
    docker_ pull --quiet "$ref" >/dev/null || fail "pull $ref"
  done
  for note in "${compose_notes[@]}"; do ok "$note"; done
}
