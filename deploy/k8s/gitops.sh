#!/usr/bin/env bash
# The GitOps path (`make k8s-gitops-up`): a new cluster svp on which Argo CD builds everything from GitHub: the config
# from svp-gitops at one commit, the charts of this repository at the commit envs/stg/charts.yaml there pins. This
# script installs only what git cannot hold or what must exist before Argo CD; `follow BRANCH` alone is its last step,
# for a cluster built at a commit (the verification run follows main once its checks are over).

# What this script checks is what Argo CD deploys: the release images, Argo CD's install and the Applications come from
# git at that commit, never a working tree, and Argo CD builds at it too, not at the branch. A release image needs a
# clean vuln attestation at most 48 hours old (Kyverno refuses new pods at 72).

# Environment (set by `make k8s-gitops-up`): GITOPS_REV, a branch of the clone's origin (default main, as last fetched,
# no fetch) the cluster is built at and then follows, or a full commit SHA it is built at and stays; SVP_GITOPS_DIR, the
# clone of svp-gitops; SVP_ATTEST_MAX_AGE, drills only (never in .env): a shorter limit than 48h.
# Design notes: docs/reference/k8s.md.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
require_k3d "deploy/k8s/gitops.sh (an EKS cluster is bootstrapped by root aws/gitops/<env> of the infrastructure repository)"

# repoURL and chartRepoURL of argocd/apps/values.yaml of svp-gitops, both in sourceRepos of AppProject svp.
chart_repo_url=https://github.com/anhnvcoder/svp-backend.git
rev=${GITOPS_REV:-main}

command -v jq >/dev/null || fail "jq is not installed (brew install jq): it reads components.json and Argo CD's status"

# follow_branch BRANCH: points root svp-root at refs/heads/BRANCH of svp-gitops (the full name: a short one may resolve
# to a tag), for its own source and every Application's values source, and waits up to 180 s for Argo CD to compare it
# there. At the cluster's commit only the root syncs. Past it, Argo CD deploys the newer one now (a changed gateway or
# web is a canary) and this does not wait; the line saying so has both full commits, which the verification run reads.
follow_branch() {
  local target=refs/heads/$1 app=applications.argoproj.io/svp-root from now patch
  git check-ref-format "$target" || fail "'$1' is not a branch name"
  from=$(kc -n argocd get "$app" -o jsonpath='{.status.sync.revision}') || fail "read Application argocd/svp-root"
  patch=$(jq -cn --arg t "$target" '{spec: {source: {targetRevision: $t, helm: {valuesObject: {targetRevision: $t}}}}}')
  kc -n argocd patch "$app" --type merge -p "$patch" >/dev/null || fail "point Application svp-root at $target"
  wait_until 180 "Application svp-root compared at $target of svp-gitops" \
    test_output "$target" kc -n argocd get "$app" -o jsonpath='{.status.sync.comparedTo.source.targetRevision}'
  now=$(kc -n argocd get "$app" -o jsonpath='{.status.sync.revision}') || fail "read Application argocd/svp-root"
  if [ "$now" = "$from" ]; then
    wait_until 180 "Application svp-root Synced at $target" \
      test_output Synced kc -n argocd get "$app" -o jsonpath='{.status.sync.status}'
    ok "Application svp-root follows $target of svp-gitops, still at ${now:0:12}: nothing new to roll out"
  else
    echo "note  Application svp-root follows $target of svp-gitops, which moved from $from (the commit the cluster runs) to $now: Argo CD deploys it now, a release like any other; a changed gateway or web goes out as a canary, whose analysis promotes it only under traffic (make k8s-traffic-start)"
  fi
}

if [ "${1:-}" = follow ]; then
  [ $# = 2 ] && [ -n "$2" ] || fail "usage: deploy/k8s/gitops.sh follow BRANCH"
  kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1 ||
    fail "cluster svp has no Application argocd/svp-root: it was not made by make k8s-gitops-up"
  follow_branch "$2"
  exit 0
fi
[ $# = 0 ] || fail "usage: deploy/k8s/gitops.sh, or deploy/k8s/gitops.sh follow BRANCH"

work=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$work"' EXIT

# values_json FILE...: prints, on one line of JSON, the values helm makes of the values files FILE... (YAML or JSON)
# merged in that order, later ones winning, maps merged and lists replaced: how Helm reads the values of a chart, the
# values files and valuesObject of an Application among them. A chart of its own, which renders nothing else; no
# cluster is asked. Fails on a file that is no YAML map.
values_json() {
  local chart=$work/values-json f args=()
  if [ ! -d "$chart" ]; then
    mkdir -p "$chart/templates" &&
      printf 'apiVersion: v2\nname: values-json\nversion: 0.1.0\n' >"$chart/Chart.yaml" &&
      echo '# json {{ toJson .Values }}' >"$chart/templates/values.yaml" || return 1
  fi
  for f in "$@"; do args+=(--values "$f"); done
  helm template values-json "$chart" ${args[@]+"${args[@]}"} | sed -n 's/^# json //p'
}

gitops=$(gitops_dir) || exit 1

# --- the revision of svp-gitops and its release images, before anything is created.
if sha=$(git -C "$gitops" rev-parse --verify --quiet "refs/remotes/origin/$rev^{commit}"); then
  branch=$rev
  echo "revision: origin/$rev of svp-gitops = $sha (as last fetched in $gitops; this script does not fetch): the cluster is built at this commit, then follows refs/heads/$rev"
elif [[ $rev =~ ^[0-9a-f]{40}$ ]] && sha=$(git -C "$gitops" rev-parse --verify --quiet "$rev^{commit}"); then
  branch=
  echo "revision: commit $sha of svp-gitops: the cluster is built at this commit and stays at it"
else
  fail "GITOPS_REV=$rev is neither a branch of origin (refs/remotes/origin/$rev) nor a full commit SHA of the clone $gitops"
fi
# at FILE: prints FILE of svp-gitops at the revision.
at() { git -C "$gitops" show "$sha:$1"; }
# The environment the root hands to chart argocd/apps (value env). Always stg: a lab cluster only ever runs as
# staging, and prd is rendered by the checks alone, so there is nothing to choose.
env=stg
# The platform it hands too (value platform): k3d, the platform of this cluster. A revision without the platform layer
# platforms/ is refused.
git -C "$gitops" cat-file -e "$sha:platforms" 2>/dev/null ||
  fail "${sha:0:12} of svp-gitops has no platforms/: the platform layer platforms/ is required; nothing was created"
platform=k3d
# The two levels of the root: chart argocd/root, which renders Application svp-apps of chart argocd/apps.
for f in argocd/root/Chart.yaml argocd/apps/Chart.yaml argocd/apps/components.json argocd/project.yaml argocd/bootstrap.json \
  "envs/$env/charts.yaml"; do
  git -C "$gitops" cat-file -e "$sha:$f" 2>/dev/null ||
    fail "${sha:0:12} of svp-gitops has no $f, so Argo CD could not build $env from it; nothing was created"
done
# The commit of this repository whose charts stg runs; the namespaces below are rendered from its chart svp-cluster.
chart_rev=$(at "envs/$env/charts.yaml" | sed -n 's/^revision: *//p')
[[ $chart_rev =~ ^[0-9a-f]{40}$ ]] ||
  fail "envs/$env/charts.yaml at ${sha:0:12} of svp-gitops: revision is '$chart_rev', not a full commit of this repository"
git -C "$repo_root" cat-file -e "$chart_rev^{commit}" 2>/dev/null ||
  fail "envs/$env/charts.yaml at ${sha:0:12} of svp-gitops pins commit ${chart_rev:0:12} of this repository, which this clone does not hold: git fetch origin, and run again"
echo "env: $env on platform $platform (overlays and release images of envs/$env, charts of this repository at ${chart_rev:0:12})"

# Every service is checked before the script stops, so one run names every release that is missing. release_image
# (lib.sh) reads the image file from git and asks GHCR; values-check.sh --gitops then checks each signature, vuln
# attestation and provenance (when chart svp-policy requires it) anonymously.
unready=
for svc in "${svp_services[@]}"; do
  file="envs/$env/images/$svc.yaml"
  if ! content=$(at "$file" 2>/dev/null); then
    echo "FAIL  $svc: $file is missing at ${sha:0:12} of svp-gitops" >&2
    unready=1
  elif ! release_image "$svc" "$file at ${sha:0:12} of svp-gitops" <<<"$content" >/dev/null; then
    unready=1
  fi
done
[ -z "$unready" ] ||
  fail "the release images at ${sha:0:12} of svp-gitops are not ready for the GitOps path (above); nothing was created"
mkdir -p "$work/release" &&
  git -C "$gitops" archive "$sha" "envs/$env" | tar -x -C "$work/release" ||
  fail "unpack envs/$env of ${sha:0:12} of svp-gitops with git archive"
if ! "$repo_root/deploy/ci/values-check.sh" --gitops "$work/release" ""; then
  refresh="gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f rescan=true"
  fail "a release at ${sha:0:12} of svp-gitops is not signed, its vuln attestation is not clean and fresh, or the provenance the policy requires is missing or wrong (above); nothing was created. Refresh the vuln attestations of the releases: $refresh, then run this again once that run is green (a missing provenance needs a new release instead, as named above)"
fi
ok "release images at ${sha:0:12} of svp-gitops: GHCR serves all seven anonymously, each signed by its release source with a fresh, clean vuln attestation"
# The Applications to wait for: the root, svp-apps it renders and one per component of components.json at the revision
# (the copy svp-apps renders, as stg pins no gitopsRevision) that runs on the platform (no platforms in components.json:
# every platform).
want_apps=$(at argocd/apps/components.json | jq -r --arg p "$platform" \
  '.components[] | select((has("platforms") | not) or (.platforms | index($p)) != null) | .name') &&
  [ -n "$want_apps" ] ||
  fail "read the component names of argocd/apps/components.json at ${sha:0:12} of svp-gitops"
want_apps=$(printf 'svp-root\nsvp-apps\n%s\n' "$want_apps")

# --- a new cluster only: the dev path's releases (Helm) and Argo CD's would fight over the same objects.
if k3d_ cluster get svp >/dev/null 2>&1; then
  fail "cluster svp already exists; the GitOps path starts from a new cluster: run make k8s-down first"
fi
# The registry stays although nothing is pushed to it on this path: deploy/k8s/k3d.yaml, shared by both paths, names
# it as the nodes' registry, and the cluster cannot be created without it.
ensure_registry
ensure_cluster

# The nodes' architecture, which the root hands to chart argocd/apps (value nodeArch): Argo Rollouts' traffic
# router plugin is a native binary, and a component with archValues in components.json gets the values file of that
# architecture (argo-rollouts-amd64.yaml on a Linux x86_64 host such as a CI runner). The first node's, and every
# other node must run the same: one plugin binary serves the controller wherever it is scheduled.
node_archs=$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}') ||
  fail "read the architecture of the nodes of svp"
node_arch=$(head -n 1 <<<"$node_archs")
[ -z "$(grep -vxF -- "$node_arch" <<<"$node_archs")" ] ||
  fail "the nodes of svp run different architectures ($(sort -u <<<"$node_archs" | paste -sd ' ' -)): Argo Rollouts gets one plugin binary, built for one of them"
case $node_arch in
  amd64 | arm64) ok "nodes run $node_arch: the root Application gets nodeArch=$node_arch" ;;
  *) fail "nodes of svp run '$node_arch': the release images and the plugin of Argo Rollouts exist for amd64 and arm64 only" ;;
esac

# The root Application: it reads commit $sha of svp-gitops and hands the same commit to every Application it makes, so
# the releases checked above are the ones deployed whatever reaches the branch meanwhile; it follows the branch only
# once the cluster is built (follow_branch). argocd_root_app (lib.sh) writes the revision and the environment as strings
# whatever they look like; the nodes' architecture and the platform join them, strings too.
root_app=$(argocd_root_app "$gitops_url" "$sha" "$env" "$chart_repo_url" |
  jq -c --arg arch "$node_arch" --arg platform "$platform" \
    '.spec.source.helm.valuesObject.nodeArch = $arch | .spec.source.helm.valuesObject.platform = $platform') ||
  fail "write Application svp-root"

# --- the Secrets. Chart svp-cluster (wave 1) owns the project's namespaces, but the Secrets and Envoy Gateway (wave 0,
# which binds a Role in each namespace it watches) need them earlier: so they are made here from its own template at the
# commit of envs/stg/charts.yaml (git archive), with the same Pod Security labels as install.sh. With externalSecrets
# on, the overlay adds namespace svp-secrets, which secrets.sh fills.
cluster_chart=deploy/helm/svp-cluster
cluster_overlay=envs/$env/svp-cluster.yaml
git -C "$repo_root" cat-file -e "$chart_rev:$cluster_chart/Chart.yaml" 2>/dev/null ||
  fail "commit ${chart_rev:0:12} of this repository (envs/$env/charts.yaml) has no $cluster_chart"
mkdir -p "$work/charts" && git -C "$repo_root" archive "$chart_rev" "$cluster_chart" | tar -x -C "$work/charts" ||
  fail "unpack $cluster_chart of ${chart_rev:0:12} with git archive"
overlay_args=()
# The values files of svp-cluster in the order Argo CD reads them, the chart's own first: whether they turn on
# Argo CD Notifications' Secret (below).
cluster_values=("$work/charts/$cluster_chart/values.yaml")
if git -C "$gitops" cat-file -e "$sha:platforms/$platform/svp-cluster.yaml" 2>/dev/null; then
  at "platforms/$platform/svp-cluster.yaml" >"$work/platform-svp-cluster.yaml" ||
    fail "read platforms/$platform/svp-cluster.yaml at ${sha:0:12} of svp-gitops"
  overlay_args=(--values "$work/platform-svp-cluster.yaml")
  cluster_values+=("$work/platform-svp-cluster.yaml")
fi
if git -C "$gitops" cat-file -e "$sha:$cluster_overlay" 2>/dev/null; then
  at "$cluster_overlay" >"$work/svp-cluster.yaml" || fail "read $cluster_overlay at ${sha:0:12} of svp-gitops"
  overlay_args+=(--values "$work/svp-cluster.yaml")
  cluster_values+=("$work/svp-cluster.yaml")
fi
project_ns=$(hc template svp-cluster "$work/charts/$cluster_chart" --show-only templates/namespaces.yaml \
  ${overlay_args[@]+"${overlay_args[@]}"} --set-json 'platformNamespaces=[]') ||
  fail "render the project's namespaces of chart svp-cluster at ${chart_rev:0:12}"
kc apply --server-side --field-manager=svp-pod-security -f - <<<"$project_ns" >/dev/null ||
  fail "create the project's namespaces with Pod Security restricted"
ok "the project's namespaces ($(sed -n 's/^  name: //p' <<<"$project_ns" | paste -sd ' ' -)) enforce Pod Security restricted"
# Argo CD Notifications' Secret: its ExternalSecret exists only with externalSecrets and argocdNotifications on (a chart
# from before the key: off), so secrets.sh writes its source, and requires its variables in .env, only then.
notify=$(values_json "${cluster_values[@]}" |
  jq -r 'if .externalSecrets.enabled == true and .externalSecrets.argocdNotifications == true then "on" else "off" end') &&
  [ -n "$notify" ] || fail "read externalSecrets of the values of svp-cluster"
SVP_ARGOCD_NOTIFICATIONS=$notify "$repo_root/deploy/k8s/secrets.sh"
# With notifications on, the root's failed syncs and Degraded health also go to Telegram under the rule of
# Alertmanager's receiver (secrets.sh): .env holds the bot token and an integer chat id. The token reaches Argo CD
# through its Secret; the chat, which the public svp-gitops does not hold, through the root's annotations
# (argocd_root_telegram). Without them only the commit status is written.
if [ "$notify" = on ]; then
  # shellcheck source=deploy/observability/glitchtip/dotenv.sh
  . "$repo_root/deploy/observability/glitchtip/dotenv.sh"
  telegram_token=$(dotenv_value "$repo_root/.env" SVP_ALERT_TELEGRAM_BOT_TOKEN) &&
    telegram_chat=$(dotenv_value "$repo_root/.env" SVP_ALERT_TELEGRAM_CHAT_ID) || fail "read $repo_root/.env"
  if [ -n "$telegram_token" ] && [[ $telegram_chat =~ ^-?[0-9]+$ ]]; then
    root_app=$(argocd_root_telegram "$telegram_chat" <<<"$root_app") || fail "subscribe Application svp-root to Telegram"
    ok "Argo CD Notifications: commit status argocd/$env, and the root's failed syncs and Degraded health to Telegram"
  else
    ok "Argo CD Notifications: commit status argocd/$env only (SVP_ALERT_TELEGRAM_BOT_TOKEN or SVP_ALERT_TELEGRAM_CHAT_ID empty or invalid)"
  fi
fi

# --- Argo CD, as argocd/bootstrap.json at the revision names it, then the platform's values of it when the revision has
# them. Pod Security "restricted" on namespace argocd before its first pod, from the template of chart svp-cluster; no
# helm --create-namespace, whose apply would leave the labels out.
hc template svp-cluster "$work/charts/$cluster_chart" --show-only templates/namespaces.yaml \
  --set-json 'namespaces=[]' --set-json 'platformNamespaces=[{"name":"argocd"}]' |
  kc apply --server-side --field-manager=svp-pod-security -f - >/dev/null ||
  fail "create namespace argocd with Pod Security restricted"
ok "namespace argocd enforces Pod Security restricted"
bootstrap=$(at argocd/bootstrap.json | jq -r '[.repo, .chart, .version, .values] | map(. // "") | join(" ")') ||
  fail "read argocd/bootstrap.json at ${sha:0:12} of svp-gitops"
read -r argocd_repo argocd_chart argocd_version argocd_values <<<"$bootstrap"
[ -n "$argocd_values" ] && [ "$argocd_repo $argocd_chart" = "https://argoproj.github.io/argo-helm argo-cd" ] ||
  fail "argocd/bootstrap.json at ${sha:0:12} of svp-gitops must install chart argo-cd of https://argoproj.github.io/argo-helm with a values file"
at "$argocd_values" >"$work/argo-cd.yaml" || fail "read $argocd_values at ${sha:0:12} of svp-gitops"
argocd_args=(--values "$work/argo-cd.yaml")
argocd_platform=platforms/$platform/argo-cd.yaml
if git -C "$gitops" cat-file -e "$sha:$argocd_platform" 2>/dev/null; then
  at "$argocd_platform" >"$work/argo-cd-platform.yaml" || fail "read $argocd_platform at ${sha:0:12} of svp-gitops"
  argocd_args+=(--values "$work/argo-cd-platform.yaml")
  argocd_values+=", $argocd_platform"
fi
echo "helm upgrade --install argocd (argo-cd $argocd_version, namespace argocd, values $argocd_values)"
hc upgrade --install argocd "$argocd_chart" --repo "$argocd_repo" --version "$argocd_version" \
  "${argocd_args[@]}" --namespace argocd --wait --timeout 10m >/dev/null || fail "install Argo CD"
ok "Argo CD installed"

# No repository Secret: Argo CD reads $gitops_url and $chart_repo_url over HTTPS without credentials.

# --force-conflicts: argocd-server created AppProject default at its start and owns its fields until this apply
# empties them.
at argocd/project.yaml | kc apply --server-side --field-manager=svp-gitops --force-conflicts -f - >/dev/null ||
  fail "apply AppProjects svp and default"
ok "AppProject svp, AppProject default emptied"

kc apply --server-side --field-manager=svp-gitops -f - <<<"$root_app" >/dev/null || fail "apply Application svp-root"
ok "Application svp-root reads ${sha:0:12} of $gitops_url (HTTPS, no credentials), charts of ${chart_rev:0:12}, nodeArch $node_arch, env $env, platform $platform"

# app_report: prints one line per name of $want_apps: `ready NAME` (Synced, Healthy and last sync Succeeded, so a
# PostSync hook still running or failed is not ready), `wait NAME(S/H/P)` (anything else; "-" when unset) or `missing
# NAME` (not created yet); then per problem `error NAME: ...` (a condition ending in Error, or a sync Failed or in Error
# once its retries were spent) or `retry NAME: ...` (a failed sync being retried).
app_report() {
  kc -n argocd get applications.argoproj.io -o json | jq -r --arg want "$want_apps" '
    (.items | map({key: .metadata.name, value: .}) | from_entries) as $apps
    | [$want | split("\n")[] | select(. != "")] as $names
    | ($names[] as $n | $apps[$n] as $a
        | if $a == null then "missing \($n)"
          else ($a.status.sync.status // "-") as $s | ($a.status.health.status // "-") as $h
            | ($a.status.operationState.phase // "-") as $p
            | if $s == "Synced" and $h == "Healthy" and $p == "Succeeded" then "ready \($n)"
              else "wait \($n)(\($s)/\($h)/\($p))" end
          end),
      ($names[] as $n | $apps[$n] // empty | .status as $st
        | (($st.conditions // [])[] | select(.type | endswith("Error"))
            | "error \($n): \(.type): \(.message // "" | gsub("\n"; " "))"),
          ($st.operationState // empty
            | (.message // "" | gsub("\n"; " ")) as $m
            | if .phase == "Failed" or .phase == "Error" then "error \($n): sync \(.phase): \($m)"
              elif .phase == "Running" and (.retryCount // 0) > 0 then "retry \($n): \($m)"
              else empty end))'
}

# Every Application of $want_apps ready within the deadline. GlitchTip's DSN goes into Secret svp/sentry once
# svp-observability is ready (Reloader restarts the services that started before it). Argo CD retries a failed
# comparison at each poll (60 s), so an error is printed when it first shows and the wait stops after 180 s of errors
# (three polls: not a passing failure such as a moment without GitHub), instead of running out its 1800 s.
want=$(printf '%s' "$want_apps" | grep -c .)
again="make k8s-down && make k8s-gitops-up"
deadline=$((SECONDS + 1800))
dsn_done=
last=
shown=
errors_since=
while :; do
  report=$(app_report) || fail "list the Applications of namespace argocd"
  if [ -z "$dsn_done" ] && printf '%s\n' "$report" | grep -qx 'ready svp-observability'; then
    "$repo_root/deploy/k8s/glitchtip-init.sh"
    dsn_done=yes
  fi
  ready=$(printf '%s\n' "$report" | grep -c '^ready ' || true)
  if [ "$ready" = "$want" ] && [ -n "$dsn_done" ]; then break; fi
  pending=$(printf '%s\n' "$report" | awk '$1 == "wait" { printf " %s", $2 } $1 == "missing" { m++ }
    END { if (m) printf " and %d not created yet", m }')
  if [ "$pending" != "$last" ]; then
    echo "wait  $ready/$want Applications ready;$pending"
    last=$pending
  fi
  problems=$(printf '%s\n' "$report" | grep -E '^(error|retry) ' || true)
  if [ "$problems" != "$shown" ]; then
    [ -z "$problems" ] || printf '%s\n' "$problems" | sed 's/^/argo  /'
    shown=$problems
  fi
  if printf '%s\n' "$problems" | grep -q '^error '; then
    errors_since=${errors_since:-$SECONDS}
    ((SECONDS - errors_since < 180)) ||
      fail "Argo CD has reported the errors above for 180s, so this script stops; fix their cause (the repository must be public, Argo CD reads it without credentials; the revision; a chart), then $again"
  else
    errors_since=
  fi
  if ((SECONDS >= deadline)); then
    kc -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name}: {.status.operationState.message} {.status.conditions[*].message}{"\n"}{end}' >&2
    gitops_timeout_report "$want_apps" || true
    fail "every Application Synced and Healthy within 1800s"
  fi
  sleep 10
done
ok "$want Applications Synced and Healthy, their syncs Succeeded, at ${sha:0:12} of svp-gitops"
[ -z "$branch" ] || follow_branch "$branch"
export_ca

echo
echo "Argo CD UI: make k8s-ui-argocd (https://127.0.0.1:8081, user admin; password:"
echo "  kubectl --context k3d-svp -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
