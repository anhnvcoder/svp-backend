#!/usr/bin/env bash
# Puts GlitchTip's DSN and the drills' API token into the cluster's Secrets once GlitchTip runs in svp-obs,
# the cluster's side of what deploy/observability/glitchtip/init.sh does for compose:
#   Secret svp/sentry            SENTRY_DSN, the DSN of project svp with host glitchtip.svp-obs:8000, read by the five
#                                services that report errors (optional reference: until it exists they run without)
#   Secret svp-obs/glitchtip-api SENTRY_AUTH_TOKEN, the read-only API token svp-drill (event:read, project:read)
#   Secret svp-obs/glitchtip-sourcemaps
#                                SENTRY_SOURCEMAPS_TOKEN, the API token svp-sourcemaps (project:releases) with which
#                                `make k8s-web-sourcemaps` uploads the web client's source maps;
#                                skipped with a note while GlitchTip has no such token (a GitOps revision whose
#                                bootstrap.py predates it), so the DSN still reaches the services
# All are GlitchTip's own values, made by its init Job (bootstrap.py): they never go to .env, a file or the terminal.
# They are read inside the running GlitchTip pod through its ORM and come back on stdout into a shell variable only.
# On the GitOps path's staging (a cluster with namespace svp-secrets) those three Secrets are ExternalSecrets of chart
# svp-cluster: the values go into their source instead, Secret svp-secrets/glitchtip-runtime (SENTRY_DSN,
# SENTRY_AUTH_TOKEN, SENTRY_SOURCEMAPS_TOKEN, empty while GlitchTip has no such token), and the three ExternalSecrets
# are built again from it (es_force_sync of deploy/k8s/lib.sh). On an EKS cluster
# (SVP_KUBE_CONTEXT svp-stg or svp-prd, `make eks-glitchtip-init`) the source is entry svp/<env>/glitchtip-runtime of
# AWS Secrets Manager, written with the AWS profile AWS_PROFILE of that environment's account, checked before anything
# is read (aws_setup and aws_put_entry of deploy/k8s/lib.sh: the values go through a file of mode 700, never on a
# command line); the same three ExternalSecrets are built again from it.
#
# No restart here: each service that reports errors names Secret sentry in its annotation
# secret.reloader.stakater.com/reload (chart svp-service), so Reloader (component reloader of svp-gitops) restarts it
# when the DSN in that Secret changes, the gateway and the web client, Argo Rollouts Rollouts, through Argo Rollouts'
# own restart (no new revision). Reloader does not restart anything when the Secret is first created (reloadOnCreate off,
# base/reloader.yaml of svp-gitops): on the dev path this script creates it before the services' wave starts, and on
# the GitOps path and EKS the Secret exists, empty, as soon as its ExternalSecret does, so the services read the DSN at
# their start or Reloader restarts them when it is filled in. A workload whose template does not read Secret sentry
# (media-worker) is left alone.
#
# Needs only GlitchTip ready (its init Job has run); run by deploy/k8s/install.sh after chart svp-observability, by
# `make k8s-glitchtip-init` on its own (`make eks-glitchtip-init` on an EKS cluster, once Argo CD reports Application
# svp-observability Healthy), and by the GitOps path of k3d once Argo CD reports GlitchTip healthy.
# Idempotent: the DSN and tokens do not change between runs (bootstrap.py never makes a second key or token), so a
# second run applies the same Secrets, which keep their resourceVersion, and Reloader restarts nothing.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
# Written for a cloud cluster too: kc may reach the EKS cluster SVP_KUBE_CONTEXT names (deploy/k8s/lib.sh).
kube_cloud_ok=1
make_cluster="make k8s-up"
if cloud_context; then
  make_cluster="the apply of root aws/gitops/${kube_context#svp-} of the infrastructure repository"
  aws_setup
  trap 'rm -rf "$aws_dir"' EXIT
fi

kc get --raw /readyz >/dev/null 2>&1 ||
  fail "cluster ${kube_context#k3d-} is not reachable (context $kube_context); run $make_cluster"
kc -n svp-obs rollout status deployment/glitchtip --timeout=300s >/dev/null ||
  fail "GlitchTip (deployment svp-obs/glitchtip) ready within 300s; install it with $make_cluster"

# The first active key of project svp and the oldest tokens labelled svp-drill and svp-sourcemaps: what bootstrap.py
# hands out. Prefixed lines, so nothing else Django may print can be taken for them. The values are printed to this
# script's pipe only.
# The code goes to `manage.py shell -c`, not on stdin: the shell reads stdin only when it already holds data the moment
# Django has started, and otherwise opens an interactive console, whose prompt would come before the values. It holds
# no secret, so it may be on the command line. It is read into a variable, not written as a heredoc inside $(...),
# which bash 3.2 parses badly; read returns 1 at the end of its input, which is expected here.
read -r -d '' read_creds <<'PY' || true
from apps.api_tokens.models import APIToken
from apps.projects.models import ProjectKey

key = (
    ProjectKey.objects.filter(project__organization__slug="svp", project__slug="svp", is_active=True)
    .order_by("pk")
    .first()
)
token = APIToken.objects.filter(label="svp-drill").order_by("pk").first()
sourcemaps_token = APIToken.objects.filter(label="svp-sourcemaps").order_by("pk").first()
if key is None or not key.get_dsn():
    raise SystemExit("glitchtip-init: project svp has no active key; did the init Job run bootstrap.py?")
if token is None:
    raise SystemExit("glitchtip-init: no API token labelled svp-drill; did the init Job run bootstrap.py?")
print("svp-dsn=" + key.get_dsn())
print("svp-token=" + token.token)
if sourcemaps_token is not None:
    print("svp-sourcemaps-token=" + sourcemaps_token.token)
PY
creds=$(kc -n svp-obs exec deployment/glitchtip -c glitchtip -- python manage.py shell -c "$read_creds") ||
  fail "read the DSN and API tokens inside GlitchTip (kubectl --context $kube_context -n svp-obs logs deployment/glitchtip)"
dsn=$(printf '%s\n' "$creds" | sed -n 's/^svp-dsn=//p')
token=$(printf '%s\n' "$creds" | sed -n 's/^svp-token=//p')
sourcemaps_token=$(printf '%s\n' "$creds" | sed -n 's/^svp-sourcemaps-token=//p')
creds=
[ -n "$dsn" ] && [ -n "$token" ] || fail "GlitchTip gave no DSN or no read-only API token"

# GlitchTip names itself by the address the port-forward listens on (GLITCHTIP_DOMAIN of chart svp-observability); the
# services reach it by its Service.
service_dsn=${dsn/@127.0.0.1:8000\//@glitchtip.svp-obs:8000/}
[ "$service_dsn" != "$dsn" ] || fail "the DSN does not name 127.0.0.1:8000; check GLITCHTIP_DOMAIN in deploy/helm/svp-observability/values.yaml"

if cloud_context; then
  printf '%s\n' SENTRY_DSN "$service_dsn" SENTRY_AUTH_TOKEN "$token" SENTRY_SOURCEMAPS_TOKEN "$sourcemaps_token" |
    aws_put_entry glitchtip-runtime
  es_force_sync svp/sentry svp-obs/glitchtip-api svp-obs/glitchtip-sourcemaps
  ok "GlitchTip's DSN and API tokens in entry ${aws_prefix}glitchtip-runtime of AWS Secrets Manager, ExternalSecrets svp/sentry, svp-obs/glitchtip-api and svp-obs/glitchtip-sourcemaps built again from it"
elif kc get namespace svp-secrets >/dev/null 2>&1; then
  secret svp-secrets glitchtip-runtime Opaque SENTRY_DSN="$service_dsn" SENTRY_AUTH_TOKEN="$token" \
    SENTRY_SOURCEMAPS_TOKEN="$sourcemaps_token" |
    kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
    fail "apply source Secret svp-secrets/glitchtip-runtime"
  es_force_sync svp/sentry svp-obs/glitchtip-api svp-obs/glitchtip-sourcemaps
  ok "GlitchTip's DSN and API tokens in source Secret svp-secrets/glitchtip-runtime, ExternalSecrets svp/sentry, svp-obs/glitchtip-api and svp-obs/glitchtip-sourcemaps built again from it"
else
  {
    secret svp sentry Opaque SENTRY_DSN="$service_dsn"
    secret svp-obs glitchtip-api Opaque SENTRY_AUTH_TOKEN="$token"
    [ -z "$sourcemaps_token" ] ||
      secret svp-obs glitchtip-sourcemaps Opaque SENTRY_SOURCEMAPS_TOKEN="$sourcemaps_token"
  } | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
    fail "apply the Secrets of GlitchTip's DSN and API tokens"
fi
ok "GlitchTip's DSN in Secret svp/sentry, its read-only API token in Secret svp-obs/glitchtip-api"
if [ -n "$sourcemaps_token" ]; then
  ok "GlitchTip's source map upload token in Secret svp-obs/glitchtip-sourcemaps"
else
  # The token only serves make k8s-web-sourcemaps; losing the DSN over it would leave the services without error
  # reporting.
  echo "skip  Secret svp-obs/glitchtip-sourcemaps: GlitchTip has no API token labelled svp-sourcemaps (its bootstrap.py predates it); make k8s-web-sourcemaps cannot upload until it does"
fi

ok "Reloader restarts each service that reads Secret svp/sentry when the DSN in it changed (none when it did not); follow them with kubectl --context $kube_context -n svp get pods -w"
