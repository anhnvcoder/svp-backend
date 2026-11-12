#!/usr/bin/env bash
# Creates or updates the cluster's Secrets from .env, the one source of local secrets for compose and the cluster (no
# Secret is ever in git), as a whole change of credentials in the order of deploy/k8s/rotate.sh.
# Design notes: docs/reference/k8s.md.

# Every value is read (the strict rule of deploy/observability/glitchtip/dotenv.sh, the one compose agrees with) and
# checked first: one missing or empty in .env stops the script naming it, nothing applied. Manifests go to kubectl apply
# --server-side on stdin, never through a file or a command line, no value printed nor copied into the last-applied
# annotation. The local cluster only (kc refuses an EKS context here): EKS gets its Secrets from make eks-secrets.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=deploy/k8s/rotate.sh
. "$(dirname "$0")/rotate.sh"
require_k3d "deploy/k8s/secrets.sh (the Secrets of an EKS cluster come from AWS Secrets Manager: make eks-secrets)"
# The command that runs this script again, and the one that makes the cluster, for the messages.
again="make k8s-secrets"
make_cluster="make k8s-up"
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$repo_root/deploy/observability/glitchtip/dotenv.sh"

env_file="$repo_root/.env"
[ -f "$env_file" ] || fail ".env not found; run make env"

# Read every variable below into a shell variable of the same name.
vars=(SVP_PG_SUPERUSER_PASSWORD
  SVP_USER_MIGRATOR_DB_PASSWORD SVP_USER_APP_DB_PASSWORD SVP_VIDEO_MIGRATOR_DB_PASSWORD SVP_VIDEO_APP_DB_PASSWORD
  SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD SVP_ENGAGEMENT_APP_DB_PASSWORD SVP_FEED_MIGRATOR_DB_PASSWORD
  SVP_FEED_APP_DB_PASSWORD SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD
  SVP_S3_ROOT_PASSWORD SVP_VIDEO_S3_SECRET_KEY SVP_MEDIA_WORKER_S3_SECRET_KEY SVP_PG_BACKUP_S3_SECRET_KEY
  SVP_KAFKA_ADMIN_PASSWORD SVP_KAFKA_KEDA_PASSWORD SVP_KAFKA_USER_SERVICE_PASSWORD SVP_KAFKA_VIDEO_SERVICE_PASSWORD
  SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_MEDIA_WORKER_PASSWORD
  SVP_KAFKA_OTELCOL_PASSWORD SVP_VALKEY_GATEWAY_PASSWORD SVP_VALKEY_FEED_SERVICE_PASSWORD SVP_VALKEY_WEB_PASSWORD
  SVP_VALKEY_OPS_PASSWORD JWT_SIGNING_KID JWT_SIGNING_KEY JWT_VERIFY_KEYS SVP_GRAFANA_ADMIN_PASSWORD
  GLITCHTIP_SECRET_KEY GLITCHTIP_ADMIN_EMAIL GLITCHTIP_ADMIN_PASSWORD NEXT_SERVER_ACTIONS_ENCRYPTION_KEY)
dotenv_read "$env_file" "${vars[@]}"
[ -z "$dotenv_missing" ] || fail ".env lacks or has empty:$dotenv_missing; run make env, then this again"
check_next_key
# Telegram is optional: the learner fills in both variables by hand, and without them alerts stay in the UI.
dotenv_read "$env_file" SVP_ALERT_TELEGRAM_BOT_TOKEN SVP_ALERT_TELEGRAM_CHAT_ID

# The local CA of make env (deploy/compose/local-ca.sh): its certificate for every client of Kafka, Valkey and
# Postgres, the server certificate and key that Kafka and Valkey present, and those of Postgres svp-pg.
ca_dir=$repo_root/.local/ca
for f in ca.crt server.crt server.key postgres.crt postgres.key; do
  [ -s "$ca_dir/$f" ] || fail "the local CA is missing in .local/ca/ ($f); run make env, then this again"
done
local_ca=$(<"$ca_dir/ca.crt")
server_crt=$(<"$ca_dir/server.crt")
server_key=$(<"$ca_dir/server.key")
pg_crt=$(<"$ca_dir/postgres.crt")
pg_key=$(<"$ca_dir/postgres.key")
# Valkey's ACL file, written by the script compose uses, so both carry the same access strings; in a private folder
# removed on exit, read into the Secret below.
acl_dir=$(mktemp -d)
trap 'rm -rf "$acl_dir"' EXIT
"$repo_root/deploy/valkey/aclfile.sh" "$env_file" "$acl_dir/users.acl" || fail "write Valkey's ACL file from .env"
valkey_acl=$(<"$acl_dir/users.acl")
rm -rf "$acl_dir"

for ns in svp-data svp svp-obs; do
  kc get namespace "$ns" >/dev/null 2>&1 || fail "namespace $ns not found; run $make_cluster"
done
source_ns=svp-secrets
gitops=
if kc get namespace "$source_ns" >/dev/null 2>&1; then gitops=yes; fi

# Argo CD Notifications: the GitHub App that writes commit statuses on svp-gitops, checked before anything is applied.
notify=off
if [ -n "$gitops" ]; then
  case ${SVP_ARGOCD_NOTIFICATIONS:-} in
    on | off) notify=$SVP_ARGOCD_NOTIFICATIONS ;;
    '') if kc -n argocd get externalsecrets.external-secrets.io argocd-notifications-secret >/dev/null 2>&1; then notify=on; fi ;;
    *) fail "SVP_ARGOCD_NOTIFICATIONS is '$SVP_ARGOCD_NOTIFICATIONS': on or off" ;;
  esac
fi
if [ "$notify" = on ]; then check_notify_key "$env_file" "$again"; fi

manifests() {
  # Superuser of the Postgres svp-pg: CloudNativePG sets its password from this Secret, and the pg-bootstrap Job logs
  # in with it. No service gets it. CloudNativePG follows changes only to the Secrets it made itself or to those
  # labelled cnpg.io/reload; without the label a changed password stays out of Postgres until something else makes the
  # operator reconcile the Cluster, and the pg-bootstrap Job, which logs in with it, fails.
  label='cnpg.io/reload: "true"' secret svp-data pg-superuser kubernetes.io/basic-auth \
    username=postgres password="$SVP_PG_SUPERUSER_PASSWORD"
  # Passwords of each service's migrator and app roles, for the pg-bootstrap Job (deploy/postgres/bootstrap.sql).
  secret svp-data pg-roles Opaque \
    SVP_USER_MIGRATOR_DB_PASSWORD="$SVP_USER_MIGRATOR_DB_PASSWORD" \
    SVP_USER_APP_DB_PASSWORD="$SVP_USER_APP_DB_PASSWORD" \
    SVP_VIDEO_MIGRATOR_DB_PASSWORD="$SVP_VIDEO_MIGRATOR_DB_PASSWORD" \
    SVP_VIDEO_APP_DB_PASSWORD="$SVP_VIDEO_APP_DB_PASSWORD" \
    SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD="$SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD" \
    SVP_ENGAGEMENT_APP_DB_PASSWORD="$SVP_ENGAGEMENT_APP_DB_PASSWORD" \
    SVP_FEED_MIGRATOR_DB_PASSWORD="$SVP_FEED_MIGRATOR_DB_PASSWORD" \
    SVP_FEED_APP_DB_PASSWORD="$SVP_FEED_APP_DB_PASSWORD" \
    SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD="$SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD" \
    SVP_GLITCHTIP_APP_DB_PASSWORD="$SVP_GLITCHTIP_APP_DB_PASSWORD"
  # The object store's root login, as in compose (deploy/s3/init.sh logs in as svp-admin): the store and its init Job
  # only. The keys name no store; chart svp-data maps them to the store's own variables.
  secret svp-data s3-root Opaque \
    S3_ROOT_USER=svp-admin S3_ROOT_PASSWORD="$SVP_S3_ROOT_PASSWORD"
  # Secret keys of the object store users svp-video-service, svp-media-worker and svp-pg-backup, for the s3-init Job.
  secret svp-data s3-users Opaque \
    SVP_VIDEO_S3_SECRET_KEY="$SVP_VIDEO_S3_SECRET_KEY" \
    SVP_MEDIA_WORKER_S3_SECRET_KEY="$SVP_MEDIA_WORKER_S3_SECRET_KEY" \
    SVP_PG_BACKUP_S3_SECRET_KEY="$SVP_PG_BACKUP_S3_SECRET_KEY"
  # The login of the backups of Postgres svp-pg to bucket pg-backups (ObjectStore svp-pg-backup of chart svp-data), the
  # key names the ObjectStore reads. Only the Barman Cloud plugin's sidecar in the Postgres pods reads it, through the
  # API server; no service gets it.
  secret svp-data pg-backup-s3 Opaque \
    ACCESS_KEY_ID=svp-pg-backup ACCESS_SECRET_KEY="$SVP_PG_BACKUP_S3_SECRET_KEY"
  # Kafka's svp-admin: the credential the broker formats its volume with, and the init Job's login.
  secret svp-data kafka-admin Opaque SVP_KAFKA_ADMIN_PASSWORD="$SVP_KAFKA_ADMIN_PASSWORD"
  # The operations CLI (Deployment svp-ops): svp-admin on Kafka, svp-ops on Valkey.
  secret svp-data svp-ops Opaque \
    SVP_KAFKA_ADMIN_PASSWORD="$SVP_KAFKA_ADMIN_PASSWORD" SVP_VALKEY_OPS_PASSWORD="$SVP_VALKEY_OPS_PASSWORD"
  # Password of each Kafka user the init Job creates, keys named as deploy/kafka/kafka-init.sh reads them.
  secret svp-data kafka-users Opaque \
    SVP_KAFKA_USER_SERVICE_PASSWORD="$SVP_KAFKA_USER_SERVICE_PASSWORD" \
    SVP_KAFKA_VIDEO_SERVICE_PASSWORD="$SVP_KAFKA_VIDEO_SERVICE_PASSWORD" \
    SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD="$SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD" \
    SVP_KAFKA_FEED_SERVICE_PASSWORD="$SVP_KAFKA_FEED_SERVICE_PASSWORD" \
    SVP_KAFKA_MEDIA_WORKER_PASSWORD="$SVP_KAFKA_MEDIA_WORKER_PASSWORD" \
    SVP_KAFKA_KEDA_PASSWORD="$SVP_KAFKA_KEDA_PASSWORD" \
    SVP_KAFKA_OTELCOL_PASSWORD="$SVP_KAFKA_OTELCOL_PASSWORD"
  secret svp-data valkey-acl Opaque users.acl="$valkey_acl"$'\n'
  # The local CA's server certificate: key and certificate in one PEM file for Kafka, two files for Valkey.
  secret svp-data kafka-tls Opaque kafka.pem="$server_key"$'\n'"$server_crt"$'\n'
  secret svp-data valkey-tls Opaque valkey.crt="$server_crt"$'\n' valkey.key="$server_key"$'\n'
  secret svp-data local-ca Opaque ca.crt="$local_ca"$'\n'
  # The server certificate of svp-pg (certificates.serverTLSSecret of its Cluster), labelled like pg-superuser so
  # that CloudNativePG follows its changes.
  label='cnpg.io/reload: "true"' secret svp-data pg-tls kubernetes.io/tls \
    tls.crt="$pg_crt"$'\n' tls.key="$pg_key"$'\n'
}

# redis_url USER PASSWORD DB: the REDIS_URL of Valkey user USER, TLS to Service valkey of svp-data, the name its server
# certificate holds. The passwords are letters and digits, so nothing needs URL-encoding.
redis_url() { printf 'rediss://%s:%s@valkey.svp-data.svc.cluster.local:6379/%s' "$1" "$2" "$3"; }

# pg_url SERVICE ROLE PASSWORD: the connection string of role svp_<SERVICE>_<ROLE> to database svp_<SERVICE> on
# svp-pg, verify-full against the local CA that each client mounts at /etc/svp-ca (Secret local-ca), at a name its
# server certificate holds. The passwords are hex, so nothing needs URL-encoding.
pg_url() {
  printf 'postgres://svp_%s_%s:%s@svp-pg-rw.svp-data:5432/svp_%s?sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt' \
    "$1" "$2" "$3" "$1"
}

# The services' Secrets in svp, each with only what that service's pods use, so one compromised pod exposes no more
# than its own credentials; <service>-migrate-env is for the migrate Job only. The JWT signing key is in
# user-service-env alone; the gateway and the four gRPC services get the public keys, which verify but cannot sign.
# web-env: the Server Action key alone, set at run time so it is never in the public image; it must exist (envFrom).
svp_manifests() {
  secret svp user-service-env Opaque \
    DATABASE_URL="$(pg_url user app "$SVP_USER_APP_DB_PASSWORD")" \
    JWT_SIGNING_KID="$JWT_SIGNING_KID" JWT_SIGNING_KEY="$JWT_SIGNING_KEY" \
    KAFKA_SASL_USERNAME=svp-user-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_USER_SERVICE_PASSWORD" \
    JWT_VERIFY_KEYS="$JWT_VERIFY_KEYS"
  secret svp video-service-env Opaque \
    DATABASE_URL="$(pg_url video app "$SVP_VIDEO_APP_DB_PASSWORD")" \
    KAFKA_SASL_USERNAME=svp-video-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_VIDEO_SERVICE_PASSWORD" \
    S3_SECRET_ACCESS_KEY="$SVP_VIDEO_S3_SECRET_KEY" \
    JWT_VERIFY_KEYS="$JWT_VERIFY_KEYS"
  secret svp engagement-service-env Opaque \
    DATABASE_URL="$(pg_url engagement app "$SVP_ENGAGEMENT_APP_DB_PASSWORD")" \
    KAFKA_SASL_USERNAME=svp-engagement-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD" \
    JWT_VERIFY_KEYS="$JWT_VERIFY_KEYS"
  secret svp feed-service-env Opaque \
    DATABASE_URL="$(pg_url feed app "$SVP_FEED_APP_DB_PASSWORD")" \
    KAFKA_SASL_USERNAME=svp-feed-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_FEED_SERVICE_PASSWORD" \
    REDIS_URL="$(redis_url svp-feed-service "$SVP_VALKEY_FEED_SERVICE_PASSWORD" 14)" \
    JWT_VERIFY_KEYS="$JWT_VERIFY_KEYS"
  secret svp media-worker-env Opaque \
    KAFKA_SASL_USERNAME=svp-media-worker KAFKA_SASL_PASSWORD="$SVP_KAFKA_MEDIA_WORKER_PASSWORD" \
    S3_SECRET_ACCESS_KEY="$SVP_MEDIA_WORKER_S3_SECRET_KEY"
  secret svp gateway-env Opaque \
    REDIS_URL="$(redis_url svp-gateway "$SVP_VALKEY_GATEWAY_PASSWORD" 10)" \
    JWT_VERIFY_KEYS="$JWT_VERIFY_KEYS"
  secret svp web-env Opaque \
    REDIS_URL="$(redis_url svp-web "$SVP_VALKEY_WEB_PASSWORD" 9)" \
    NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="$NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"
  secret svp user-service-migrate-env Opaque DATABASE_URL="$(pg_url user migrator "$SVP_USER_MIGRATOR_DB_PASSWORD")"
  secret svp video-service-migrate-env Opaque DATABASE_URL="$(pg_url video migrator "$SVP_VIDEO_MIGRATOR_DB_PASSWORD")"
  secret svp engagement-service-migrate-env Opaque \
    DATABASE_URL="$(pg_url engagement migrator "$SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD")"
  secret svp feed-service-migrate-env Opaque DATABASE_URL="$(pg_url feed migrator "$SVP_FEED_MIGRATOR_DB_PASSWORD")"
  secret svp local-ca Opaque ca.crt="$local_ca"$'\n'
}

# Kafka user svp-keda for KEDA's Kafka scaler (ClusterTriggerAuthentication keda-kafka of chart svp-data, which
# media-worker's ScaledObject names), keys named after the scaler's parameters, SCRAM-SHA-512 over TLS like the
# services; the local CA as its ca. In namespace keda, the only one whose Secrets the KEDA operator may read.
keda_manifests() {
  secret keda keda-kafka Opaque \
    sasl=scram_sha512 tls=enable username=svp-keda password="$SVP_KAFKA_KEDA_PASSWORD"
  secret keda local-ca Opaque ca.crt="$local_ca"$'\n'
}

# Alertmanager's routing, the one deploy/observability/alertmanager/entrypoint.sh writes for compose (keep the two in
# step): severity="page" to Telegram when .env has a bot token and an integer chat id, the rest only in the UI and API;
# severity="ticket" stays there: the 1d/3d SLO windows keep firing for days after a drill. The bot token is never in
# this config (Alertmanager reads it from Secret alertmanager-telegram's file); the chat id is no credential.
telegram=off
if [ -n "$SVP_ALERT_TELEGRAM_BOT_TOKEN" ] && [ -n "$SVP_ALERT_TELEGRAM_CHAT_ID" ]; then
  # chat_id is an integer in Alertmanager's config; anything else would make the operator refuse the whole config.
  if printf '%s' "$SVP_ALERT_TELEGRAM_CHAT_ID" | grep -Eqx -- '-?[0-9]+'; then
    telegram=on
  else
    echo "SVP_ALERT_TELEGRAM_CHAT_ID in .env is not an integer; Telegram receiver off" >&2
  fi
fi
alertmanager_config() {
  local page_receiver=ui-only
  if [ "$telegram" = on ]; then page_receiver=telegram; fi
  cat <<EOF
route:
  receiver: ui-only
  group_by: [alertname, severity]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
  routes:
    - matchers: ['severity="page"']
      receiver: $page_receiver
receivers:
  # No integration: alerts routed here are only listed in the UI and API.
  - name: ui-only
EOF
  if [ "$telegram" = on ]; then
    cat <<EOF
  - name: telegram
    telegram_configs:
      - bot_token_file: /etc/alertmanager/secrets/alertmanager-telegram/bot_token
        chat_id: $SVP_ALERT_TELEGRAM_CHAT_ID
        send_resolved: true
EOF
  fi
}

# The Secrets of svp-obs: grafana-admin, the only way into Grafana (no anonymous user in the cluster), its admin
# password set at each start since it keeps no volume; alertmanager-svp, the config above; alertmanager-telegram,
# empty while Telegram is off, which Alertmanager's pod mounts and would not start without.

# glitchtip-env is for GlitchTip and its init Job only; glitchtip-admin for the init Job only (bootstrap.py sets the
# password only when it creates the user).
obs_manifests() {
  local token=
  if [ "$telegram" = on ]; then token=$SVP_ALERT_TELEGRAM_BOT_TOKEN; fi
  secret svp-obs grafana-admin Opaque \
    admin-user=admin admin-password="$SVP_GRAFANA_ADMIN_PASSWORD"
  secret svp-obs alertmanager-svp Opaque alertmanager.yaml="$(alertmanager_config)"
  secret svp-obs alertmanager-telegram Opaque bot_token="$token"
  secret svp-obs glitchtip-env Opaque \
    SECRET_KEY="$GLITCHTIP_SECRET_KEY" \
    DATABASE_URL="$(pg_url glitchtip app "$SVP_GLITCHTIP_APP_DB_PASSWORD")" \
    MAINTENANCE_DATABASE_URL="$(pg_url glitchtip migrator "$SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD")"
  secret svp-obs glitchtip-admin Opaque \
    GLITCHTIP_ADMIN_EMAIL="$GLITCHTIP_ADMIN_EMAIL" GLITCHTIP_ADMIN_PASSWORD="$GLITCHTIP_ADMIN_PASSWORD"
  # The Collector's kafkametrics receiver logs in as Kafka user svp-otelcol, trusting the local CA.
  secret svp-obs otelcol-kafka Opaque password="$SVP_KAFKA_OTELCOL_PASSWORD"
  secret svp-obs local-ca Opaque ca.crt="$local_ca"$'\n'
}

# The source of the GitOps path's ExternalSecrets in namespace svp-secrets: one Secret per entry, which the store of
# each namespace may read only when an ExternalSecret of that namespace needs it (chart svp-cluster,
# templates/external-secrets.yaml). The Telegram variables go as they are, empty or not: the ExternalSecrets of
# Alertmanager check them as alertmanager_config above does.
source_manifests() {
  secret "$source_ns" pg-superuser Opaque SVP_PG_SUPERUSER_PASSWORD="$SVP_PG_SUPERUSER_PASSWORD"
  secret "$source_ns" pg-roles Opaque \
    SVP_USER_MIGRATOR_DB_PASSWORD="$SVP_USER_MIGRATOR_DB_PASSWORD" \
    SVP_USER_APP_DB_PASSWORD="$SVP_USER_APP_DB_PASSWORD" \
    SVP_VIDEO_MIGRATOR_DB_PASSWORD="$SVP_VIDEO_MIGRATOR_DB_PASSWORD" \
    SVP_VIDEO_APP_DB_PASSWORD="$SVP_VIDEO_APP_DB_PASSWORD" \
    SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD="$SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD" \
    SVP_ENGAGEMENT_APP_DB_PASSWORD="$SVP_ENGAGEMENT_APP_DB_PASSWORD" \
    SVP_FEED_MIGRATOR_DB_PASSWORD="$SVP_FEED_MIGRATOR_DB_PASSWORD" \
    SVP_FEED_APP_DB_PASSWORD="$SVP_FEED_APP_DB_PASSWORD" \
    SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD="$SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD" \
    SVP_GLITCHTIP_APP_DB_PASSWORD="$SVP_GLITCHTIP_APP_DB_PASSWORD"
  secret "$source_ns" s3-root Opaque SVP_S3_ROOT_PASSWORD="$SVP_S3_ROOT_PASSWORD"
  secret "$source_ns" s3-users Opaque \
    SVP_VIDEO_S3_SECRET_KEY="$SVP_VIDEO_S3_SECRET_KEY" \
    SVP_MEDIA_WORKER_S3_SECRET_KEY="$SVP_MEDIA_WORKER_S3_SECRET_KEY" \
    SVP_PG_BACKUP_S3_SECRET_KEY="$SVP_PG_BACKUP_S3_SECRET_KEY"
  secret "$source_ns" kafka-admin Opaque SVP_KAFKA_ADMIN_PASSWORD="$SVP_KAFKA_ADMIN_PASSWORD"
  secret "$source_ns" kafka-users Opaque \
    SVP_KAFKA_KEDA_PASSWORD="$SVP_KAFKA_KEDA_PASSWORD" \
    SVP_KAFKA_USER_SERVICE_PASSWORD="$SVP_KAFKA_USER_SERVICE_PASSWORD" \
    SVP_KAFKA_VIDEO_SERVICE_PASSWORD="$SVP_KAFKA_VIDEO_SERVICE_PASSWORD" \
    SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD="$SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD" \
    SVP_KAFKA_FEED_SERVICE_PASSWORD="$SVP_KAFKA_FEED_SERVICE_PASSWORD" \
    SVP_KAFKA_MEDIA_WORKER_PASSWORD="$SVP_KAFKA_MEDIA_WORKER_PASSWORD" \
    SVP_KAFKA_OTELCOL_PASSWORD="$SVP_KAFKA_OTELCOL_PASSWORD"
  secret "$source_ns" valkey-users Opaque \
    SVP_VALKEY_GATEWAY_PASSWORD="$SVP_VALKEY_GATEWAY_PASSWORD" \
    SVP_VALKEY_FEED_SERVICE_PASSWORD="$SVP_VALKEY_FEED_SERVICE_PASSWORD" \
    SVP_VALKEY_WEB_PASSWORD="$SVP_VALKEY_WEB_PASSWORD" \
    SVP_VALKEY_OPS_PASSWORD="$SVP_VALKEY_OPS_PASSWORD"
  # The local CA in two entries: its certificate, which every namespace's store reads, and the servers' keys, which
  # only the store of svp-data reads.
  secret "$source_ns" local-ca Opaque ca.crt="$local_ca"$'\n'
  secret "$source_ns" local-tls Opaque server.crt="$server_crt"$'\n' server.key="$server_key"$'\n' \
    postgres.crt="$pg_crt"$'\n' postgres.key="$pg_key"$'\n'
  secret "$source_ns" jwt-signing Opaque JWT_SIGNING_KID="$JWT_SIGNING_KID" JWT_SIGNING_KEY="$JWT_SIGNING_KEY"
  secret "$source_ns" jwt-verify Opaque JWT_VERIFY_KEYS="$JWT_VERIFY_KEYS"
  secret "$source_ns" web Opaque NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="$NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"
  secret "$source_ns" obs Opaque \
    SVP_GRAFANA_ADMIN_PASSWORD="$SVP_GRAFANA_ADMIN_PASSWORD" \
    GLITCHTIP_SECRET_KEY="$GLITCHTIP_SECRET_KEY" \
    GLITCHTIP_ADMIN_EMAIL="$GLITCHTIP_ADMIN_EMAIL" GLITCHTIP_ADMIN_PASSWORD="$GLITCHTIP_ADMIN_PASSWORD" \
    SVP_ALERT_TELEGRAM_BOT_TOKEN="$SVP_ALERT_TELEGRAM_BOT_TOKEN" SVP_ALERT_TELEGRAM_CHAT_ID="$SVP_ALERT_TELEGRAM_CHAT_ID"
  # Argo CD Notifications: the App's key as in .env (the ExternalSecret decodes it), and Alertmanager's bot token, empty
  # or not, so that the store of argocd reads this entry alone.
  if [ "$notify" = on ]; then
    secret "$source_ns" argocd-notifications Opaque \
      SVP_ARGOCD_NOTIFY_APP_ID="$SVP_ARGOCD_NOTIFY_APP_ID" \
      SVP_ARGOCD_NOTIFY_INSTALLATION_ID="$SVP_ARGOCD_NOTIFY_INSTALLATION_ID" \
      SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64="$SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64" \
      SVP_ALERT_TELEGRAM_BOT_TOKEN="$SVP_ALERT_TELEGRAM_BOT_TOKEN"
  fi
}

# Reloader first, and every workload's annotation, on a cluster that runs the project's workloads: it restarts them,
# nothing else does.
if [ -n "$gitops" ]; then
  rotate_guard argocd "Argo CD installs them with component reloader and the charts of svp-gitops: sync the cluster to a revision that has them"
else
  rotate_guard dev "make k8s-up installs them, Reloader and every workload's annotation, with the Secrets as they are"
fi

# --- 1. the servers. A changed password of Kafka's svp-admin goes into the running broker before any Secret is
# applied (kafka_admin of deploy/k8s/lib.sh).
kafka_admin

if [ -n "$gitops" ]; then
  source_manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
    fail "apply the source Secrets of namespace $source_ns"
  notify_source=
  if [ "$notify" = on ]; then notify_source=", argocd-notifications"; fi
  ok "source Secrets of $source_ns applied from .env: pg-superuser, pg-roles, s3-root, s3-users, kafka-admin, kafka-users, valkey-users, local-ca, local-tls, jwt-signing, jwt-verify, web, obs$notify_source"
  if ! kc -n "$source_ns" get secret glitchtip-runtime >/dev/null 2>&1; then
    secret "$source_ns" glitchtip-runtime Opaque SENTRY_DSN= SENTRY_AUTH_TOKEN= SENTRY_SOURCEMAPS_TOKEN= |
      kc create -f - >/dev/null || fail "create the empty source Secret $source_ns/glitchtip-runtime"
    ok "source Secret $source_ns/glitchtip-runtime created empty (deploy/k8s/glitchtip-init.sh fills it once GlitchTip runs)"
  fi
  # Every source is written now; a Secret changes only once its ExternalSecret is built again (refreshPolicy
  # OnChange), so those of the clients wait for step 3.
  rotate_es_sync server
else
  # kubectl prints only the kind and name of each object it applied.
  manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
    fail "apply the Secrets of namespace svp-data"
  ok "Secrets of svp-data applied from .env: pg-superuser, pg-roles, s3-root, s3-users, pg-backup-s3, kafka-admin, svp-ops, kafka-users, valkey-acl, kafka-tls, valkey-tls, local-ca, pg-tls"
fi

# The object store (RustFS) takes its root password from its environment at start, keeps its buckets, users and objects
# with another one, and the previous password no longer logs in (checked on the pinned image); Valkey reads its ACL file
# only at start. Reloader restarts both when their Secret changes; the init Jobs and the clients log in with the new
# passwords, so they wait. Postgres needs no restart (CloudNativePG, cnpg.io/reload), Kafka none (kafka_admin above).
rotate_barrier s3 s3 RUSTFS_SECRET_KEY "$SVP_S3_ROOT_PASSWORD"
valkey_barrier

# --- 2. the init Jobs of svp-data, which set the new passwords of Postgres', the object store's and Kafka's users.
if [ -n "$gitops" ]; then rotate_init_argocd; else rotate_init_dev; fi

# --- 3. the clients.
if [ -n "$gitops" ]; then
  rotate_es_sync clients
else
  svp_manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
    fail "apply the Secrets of namespace svp"
  ok "Secrets of svp applied from .env: <service>-env of each service and of web, <service>-migrate-env of each with a database, local-ca"

  obs_manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
    fail "apply the Secrets of namespace svp-obs"
  ok "Secrets of svp-obs applied from .env: grafana-admin, alertmanager-svp, alertmanager-telegram, glitchtip-env, glitchtip-admin, otelcol-kafka, local-ca"

  # Namespace keda is made by chart svp-cluster (wave 1, with its Pod Security labels), which deploy/k8s/install.sh
  # installs before it runs this script. deploy/k8s/gitops.sh runs it before Argo CD applies anything, so there it is
  # made bare here; Argo CD's apply of svp-cluster then adds the labels, before KEDA's first pod (wave 2).
  if ! kc get namespace keda >/dev/null 2>&1; then
    kc create namespace keda >/dev/null || fail "create namespace keda"
    ok "namespace keda created for Secrets keda-kafka and local-ca"
  fi
  keda_manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
    fail "apply the Secret of namespace keda"
  ok "Secrets of keda applied from .env: keda-kafka, local-ca"
fi
if [ "$telegram" = on ]; then
  ok "Alertmanager: severity=page goes to Telegram"
else
  ok "Alertmanager: Telegram receiver off (SVP_ALERT_TELEGRAM_BOT_TOKEN or SVP_ALERT_TELEGRAM_CHAT_ID empty or invalid); alerts are only listed in its UI (make k8s-ui-alertmanager)"
fi
rotate_clients_note
