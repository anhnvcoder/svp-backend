#!/usr/bin/env bash
# Puts GlitchTip's DSN and API tokens into Secrets svp/sentry, svp-obs/glitchtip-api, svp-obs/glitchtip-sourcemaps
# (on the GitOps path's staging and on EKS, into their source) once GlitchTip runs in svp-obs. Read inside its pod,
# they come back on stdout into a shell variable only: never to .env or the terminal.
# Design notes: docs/reference/k8s.md.
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
# hands out. Prefixed lines, so nothing else Django may print is taken for them; printed to this script's pipe only.

# The code goes to `manage.py shell -c`, not on stdin, where the shell opens an interactive console (its prompt before
# the values) unless data is already there once Django has started; holding no secret, it may be on the command line.
# Read into a variable, not a heredoc inside $(...), which bash 3.2 parses badly; read returns 1 at the end of its
# input, which is expected here.
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
