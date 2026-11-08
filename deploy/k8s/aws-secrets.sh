#!/usr/bin/env bash
# Writes the entries svp/<env>/<entry> of AWS Secrets Manager, the source External Secrets Operator builds every Secret
# of EKS cluster svp-<env> from (SVP_KUBE_CONTEXT svp-stg or svp-prd; make eks-secrets). Run after the apply of root
# aws/envs/<env> and before that of aws/gitops/<env>, and again whenever .env changes.

# The entries of the Kafka and Valkey users (kafka-admin, kafka-users, valkey-users) are Terraform's: it makes their
# passwords with those of Amazon MSK and ElastiCache in one apply, so this script only checks that they exist.

# Every value and the account are read and checked before anything is written. pg-superuser takes
# SVP_RDS_MASTER_PASSWORD of the environment, never .env, kept in this shell alone. Each entry is one put-secret-value
# with its JSON in a file of a folder of mode 700, removed on exit: no value is on a command line, stdout or stderr.
# Design notes: docs/reference/k8s.md.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=deploy/k8s/rotate.sh
. "$(dirname "$0")/rotate.sh"
cloud_context ||
  fail "context $kube_context is the local cluster, whose Secrets come from .env (make k8s-secrets): this script writes those of an EKS cluster, SVP_KUBE_CONTEXT svp-stg or svp-prd"
# Written for a cloud cluster: kc may reach the EKS cluster SVP_KUBE_CONTEXT names (deploy/k8s/lib.sh).
kube_cloud_ok=1
again="make eks-secrets CONTEXT=$kube_context"
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$repo_root/deploy/observability/glitchtip/dotenv.sh"

for tool in aws jq helm; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
env_file="$repo_root/.env"
[ -f "$env_file" ] || fail ".env not found; run make env"
# The password of the managed Postgres first, before any other program runs.
[ -n "${SVP_RDS_MASTER_PASSWORD:-}" ] ||
  fail "SVP_RDS_MASTER_PASSWORD is not set or empty: the master password of the managed Postgres of $kube_context, which the session's script reads from AWS; nothing was written"
SVP_PG_SUPERUSER_PASSWORD=$SVP_RDS_MASTER_PASSWORD
unset SVP_RDS_MASTER_PASSWORD

aws_setup
trap 'rm -rf "$aws_dir"' EXIT

# --- the entries and their keys, from the ExternalSecrets of chart svp-cluster as rendered for EKS (Kafka and Valkey
# managed: localKafkaValkey off). The set does not depend on the store, so the render takes store kubernetes, whose
# entries are named without a prefix and which needs no IAM role. Each YAML document of the render becomes one line of
# JSON read by Helm itself (fromYaml): no YAML tool of its own.
chart=$repo_root/deploy/helm/svp-cluster
helm template svp-cluster "$chart" --show-only templates/external-secrets.yaml \
  --set externalSecrets.enabled=true --set externalSecrets.argocdNotifications=true --set s3.mode=external \
  --set externalSecrets.localKafkaValkey=false \
  >"$aws_dir/render.yaml" || fail "render the ExternalSecrets of chart svp-cluster for EKS"
mkdir -p "$aws_dir/yj/templates" "$aws_dir/yj/in" && cp "$aws_dir/render.yaml" "$aws_dir/yj/in/doc" &&
  printf 'apiVersion: v2\nname: yj\nversion: 0.1.0\n' >"$aws_dir/yj/Chart.yaml" &&
  printf '%s\n' '{{- range $doc := regexSplit `(?m)^---.*$` (.Files.Get "in/doc") -1 }}' \
    '{{- if regexMatch `(?m)^[^#\s]` $doc }}' '# json {{ fromYaml $doc | toJson }}' '{{- end }}' '{{- end }}' \
    >"$aws_dir/yj/templates/json.yaml" || fail "write a chart in $aws_dir"
# {"<entry>": ["<key>", ...], ...}, entries and keys sorted.
entries=$(helm template yj "$aws_dir/yj" | sed -n 's/^# json //p' | jq -sc '
  [.[] | select(.kind == "ExternalSecret") | .spec.data[].remoteRef | {entry: .key, key: .property}]
  | group_by(.entry) | map({key: .[0].entry, value: (map(.key) | unique)}) | from_entries') &&
  [ "$(jq length <<<"$entries")" -gt 0 ] || fail "read the entries of the ExternalSecrets of chart svp-cluster"
names=$(jq -r 'keys[]' <<<"$entries")
# The entries Terraform writes (above): read by the cluster, never written here, their keys not taken from .env.
terraform_entries=(kafka-admin kafka-users valkey-users)
entries_written=$(jq -c --args 'with_entries(select(.key | IN($ARGS.positional[]) | not))' \
  "${terraform_entries[@]}" <<<"$entries") || fail "leave out the entries of the infrastructure repository"

# --- the values, every one read and checked before anything is written.
optional=(SVP_ALERT_TELEGRAM_BOT_TOKEN SVP_ALERT_TELEGRAM_CHAT_ID)
# Keys whose value comes from elsewhere (above) or that check_notify_key reads; the others are required in .env.
not_dotenv=(SVP_PG_SUPERUSER_PASSWORD SENTRY_DSN SENTRY_AUTH_TOKEN SENTRY_SOURCEMAPS_TOKEN
  SVP_ARGOCD_NOTIFY_APP_ID SVP_ARGOCD_NOTIFY_INSTALLATION_ID SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64)
required=()
while IFS= read -r key; do
  case " ${optional[*]} ${not_dotenv[*]} " in *" $key "*) ;; *) required+=("$key") ;; esac
done < <(jq -r '[.[][]] | unique[]' <<<"$entries_written")
dotenv_read "$env_file" "${required[@]}"
[ -z "$dotenv_missing" ] || fail ".env lacks or has empty:$dotenv_missing; run make env, then this again; nothing was written"
dotenv_read "$env_file" "${optional[@]}"
if jq -e 'has("web")' <<<"$entries" >/dev/null; then check_next_key; fi
if jq -e 'has("argocd-notifications")' <<<"$entries" >/dev/null; then check_notify_key "$env_file" "$again"; fi
# One line per value on the way to jq (aws_put_entry); .env holds none of several lines, the environment might.
[[ $SVP_PG_SUPERUSER_PASSWORD != *$'\n'* ]] ||
  fail "SVP_RDS_MASTER_PASSWORD holds a line break, which no entry may; nothing was written"

# --- every entry exists (the infrastructure repository made it), and whether glitchtip-runtime has a value yet.
for name in $names; do
  aws_ secretsmanager describe-secret --secret-id "$aws_prefix$name" --query Name --output text >/dev/null ||
    fail "entry $aws_prefix$name of AWS Secrets Manager not found (above): apply root aws/envs/$aws_env of the infrastructure repository first; nothing was written"
done
running=
if jq -e 'has("glitchtip-runtime")' <<<"$entries" >/dev/null; then
  running=$(aws_ secretsmanager list-secret-version-ids --secret-id "${aws_prefix}glitchtip-runtime" \
    --query "Versions[?contains(VersionStages, 'AWSCURRENT')].VersionId" --output text) ||
    fail "read the versions of entry ${aws_prefix}glitchtip-runtime"
fi

# --- on a running environment Reloader must run before anything is written: it restarts the workloads whose Secret
# changes, and this script then has the init Jobs and the clients follow in the order of deploy/k8s/rotate.sh.
if [ -n "$running" ]; then
  kc get --raw /readyz >/dev/null 2>&1 ||
    fail "cluster $kube_context is not reachable (svp-prd: open the tunnel of output api_tunnel_command of the infrastructure repository); its entries have values already, and a change of credentials must reach its workloads in order; nothing was written"
  rotate_guard argocd "Argo CD installs them with component reloader and the charts of svp-gitops: sync Application svp-apps to a revision that has them"
fi

written=
for name in $(jq -r 'keys[]' <<<"$entries_written"); do
  [ "$name" != glitchtip-runtime ] || continue
  for key in $(jq -r --arg n "$name" '.[$n][]' <<<"$entries"); do
    printf '%s\n%s\n' "$key" "${!key}"
  done | aws_put_entry "$name"
  written="$written $name"
done
ok "entries of $aws_prefix written:$written (pg-superuser from SVP_RDS_MASTER_PASSWORD, the others from .env); ${terraform_entries[*]} left to the infrastructure repository"
if jq -e 'has("glitchtip-runtime")' <<<"$entries" >/dev/null; then
  if [ -z "$running" ]; then
    jq -r '.["glitchtip-runtime"][] | ., ""' <<<"$entries" | aws_put_entry glitchtip-runtime
    ok "entry ${aws_prefix}glitchtip-runtime written with its keys empty (make eks-glitchtip-init CONTEXT=$kube_context fills it once GlitchTip runs)"
  else
    echo "skip  entry ${aws_prefix}glitchtip-runtime: it has a value already, GlitchTip's own (make eks-glitchtip-init)"
  fi
fi

if [ -z "$running" ]; then
  echo "skip  ExternalSecrets: a new environment; Argo CD creates them (chart svp-cluster), each built from the entries then"
  exit 0
fi
rotate_es_sync server
rotate_init_argocd
rotate_es_sync clients
rotate_clients_note
