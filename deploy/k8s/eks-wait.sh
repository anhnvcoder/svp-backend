#!/usr/bin/env bash
# Waits for an Argo CD Application of an EKS cluster: svp-observability until Healthy, svp-root until Synced and then
# Healthy. Read-only; it replaces `argocd app wait`, so no argocd CLI and no port-forward to argocd-server is needed.
# Both wait on status fields of the Application resource (status.sync.status, status.health.status).

# Usage: SVP_KUBE_CONTEXT=svp-<env> deploy/k8s/eks-wait.sh <svp-observability|svp-root>   (or make eks-wait)
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
kube_cloud_ok=1

app=${1:-}
case $app in
  svp-observability | svp-root) ;;
  *) fail "APP must be svp-observability or svp-root (got '$app')" ;;
esac
cloud_context || fail "SVP_KUBE_CONTEXT must be svp-stg or svp-prd, an EKS cluster (got $kube_context)"

kc get --raw /readyz >/dev/null 2>&1 ||
  fail "cluster $kube_context is not reachable; open the tunnel to the API and add the context (step 3 of the sequence in docs/reference/eks.md)"
# Terraform of root aws/gitops/<env> makes ApplicationSet svp-bootstrap itself; the Applications come later (svp-root
# from it, svp-observability from svp-root once the earlier sync waves are Healthy), so only its absence means step 4.
[ -n "$(kc -n argocd get applicationsets.argoproj.io/svp-bootstrap --ignore-not-found -o name)" ] ||
  fail "ApplicationSet argocd/svp-bootstrap does not exist in $kube_context; apply root aws/gitops/${kube_context#svp-} first (step 4 of the sequence in docs/reference/eks.md)"

# One budget for the whole wait, so appearing, Synced and Healthy together take at most 30 minutes.
deadline=$((SECONDS + 1800))
left() {
  local n=$((deadline - SECONDS))
  [ "$n" -gt 0 ] || n=1
  echo "${n}s"
}

# svp-root comes from the generator of ApplicationSet svp-bootstrap, whose status conditions say why it made none;
# svp-observability comes from svp-root.
parent=applications.argoproj.io/svp-root
[ "$app" != svp-root ] || parent=applicationsets.argoproj.io/svp-bootstrap
kc -n argocd wait "applications.argoproj.io/$app" --for=create --timeout="$(left)" ||
  fail "Application argocd/$app did not appear in $kube_context in time; read ${parent#*/} with kubectl --context $kube_context -n argocd describe $parent, and check root aws/gitops/${kube_context#svp-} is applied (step 4 of the sequence in docs/reference/eks.md)"

# wait_for FIELD VALUE: kubectl wait on the jsonpath FIELD of the Application until it is VALUE. On timeout, prints
# the sync and health status the Application ended with.
wait_for() {
  if ! kc -n argocd wait "applications.argoproj.io/$app" --for="jsonpath={$1}=$2" --timeout="$(left)"; then
    state=$(kc -n argocd get "applications.argoproj.io/$app" -o jsonpath='sync={.status.sync.status} health={.status.health.status}') ||
      state="unreadable"
    fail "Application argocd/$app is not $2 in time (last state: $state); read it with kubectl --context $kube_context -n argocd describe applications.argoproj.io/$app"
  fi
}

if [ "$app" = svp-root ]; then
  wait_for .status.sync.status Synced
  ok "Application argocd/$app Synced"
fi
wait_for .status.health.status Healthy
ok "Application argocd/$app Healthy"
