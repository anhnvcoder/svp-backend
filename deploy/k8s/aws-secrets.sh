#!/usr/bin/env bash
# Writes the values of the entries svp/<env>/<entry> of AWS Secrets Manager, the source from which External Secrets
# Operator builds every Secret of the EKS cluster svp-<env> (SVP_KUBE_CONTEXT svp-stg or svp-prd; `make eks-secrets`),
# as deploy/k8s/secrets.sh writes the source Secrets of a lab cluster. The infrastructure repository makes the entries,
# with no value (its module external-secrets); this script runs after the apply of its root aws/envs/<env> and before
# that of root aws/gitops/<env>, so the source exists before Argo CD does, and again whenever .env changes.
#
# The entries and their keys are those the ExternalSecrets of chart svp-cluster read on EKS: a render of its
# files/external-secrets.yaml with a managed object store (s3.mode external: no source for the users of an object
# store in the cluster) and Argo CD Notifications on (externalSecrets.argocdNotifications). Each key is the variable
# of .env of that name, read with the strict rule of deploy/observability/glitchtip/dotenv.sh, but for:
#   - SVP_PG_SUPERUSER_PASSWORD (entry pg-superuser), the master password of the managed Postgres (RDS), which the
#     session's script reads from AWS into SVP_RDS_MASTER_PASSWORD of this script's environment: required, never read
#     from .env, kept in this shell alone (no program it starts gets it in its environment);
#   - the keys of entry glitchtip-runtime, GlitchTip's own values: the entry is written with its three keys empty only
#     while it has no version AWSCURRENT (a new environment), so that its ExternalSecrets are Ready before GlitchTip
#     runs, and never again: deploy/k8s/glitchtip-init.sh fills it (make eks-glitchtip-init);
#   - the Telegram variables, optional: empty, they are written empty, as on a lab cluster.
# Every value is read and checked before anything is written (a variable missing or empty in .env stops the script
# naming it), and so is the account: AWS_PROFILE must be of the account of the environment (aws_setup of
# deploy/k8s/lib.sh). Each entry is one put-secret-value with its JSON in a file of a folder of mode 700, removed on
# exit: no value is on a command line, on stdout or stderr.
#
# A run on an environment whose entry glitchtip-runtime has a version is a change of secrets of a running cluster, in
# the order of a lab cluster's: (1) a changed password of Redpanda's superuser goes into the running broker first
# (redpanda_admin of deploy/k8s/lib.sh), so the cluster must be reachable (svp-prd: through its tunnel); (2) the
# entries are written; (3) every ExternalSecret is built again from them (es_force_sync: their refreshPolicy is
# OnChange). The runbook goes on from there: a sync of Application svp-data, whose init Jobs set the new passwords in
# Postgres and Redpanda, then a restart of each workload whose Secret changed. A first run asks the cluster nothing:
# nothing reads the entries before Argo CD is installed.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
cloud_context ||
  fail "context $kube_context is the local cluster, whose Secrets come from .env (make k8s-secrets): this script writes those of an EKS cluster, SVP_KUBE_CONTEXT svp-stg or svp-prd"
# Written for a cloud cluster: kc may reach the EKS cluster SVP_KUBE_CONTEXT names (deploy/k8s/lib.sh).
kube_cloud_ok=1
# The command that runs this script again, for the messages.
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

# AWS_PROFILE and its account, then the folder of the entries' files.
aws_setup
trap 'rm -rf "$aws_dir"' EXIT

# --- the entries and their keys, from the ExternalSecrets of chart svp-cluster as rendered for EKS. The set does not
# depend on the store, so the render takes store kubernetes, whose entries are named without a prefix and which needs
# no IAM role. Each YAML document of the render becomes one line of JSON read by Helm itself (fromYaml): no YAML tool
# of its own.
chart=$repo_root/deploy/helm/svp-cluster
helm template svp-cluster "$chart" --show-only templates/external-secrets.yaml \
  --set externalSecrets.enabled=true --set externalSecrets.argocdNotifications=true --set s3.mode=external \
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

# --- the values, every one read and checked before anything is written.
optional=(SVP_ALERT_TELEGRAM_BOT_TOKEN SVP_ALERT_TELEGRAM_CHAT_ID)
# Keys whose value comes from elsewhere (above) or that check_notify_key reads; the others are required in .env.
not_dotenv=(SVP_PG_SUPERUSER_PASSWORD SENTRY_DSN SENTRY_AUTH_TOKEN SENTRY_SOURCEMAPS_TOKEN
  SVP_ARGOCD_NOTIFY_APP_ID SVP_ARGOCD_NOTIFY_INSTALLATION_ID SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64)
required=()
while IFS= read -r key; do
  case " ${optional[*]} ${not_dotenv[*]} " in *" $key "*) ;; *) required+=("$key") ;; esac
done < <(jq -r '[.[][]] | unique[]' <<<"$entries")
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

# --- (1) on a running environment, Redpanda takes a changed password of its superuser first.
if [ -n "$running" ]; then
  kc get --raw /readyz >/dev/null 2>&1 ||
    fail "cluster $kube_context is not reachable (svp-prd: open the tunnel of output api_tunnel_command of the infrastructure repository); its entries have values already, and a changed password of Redpanda's superuser must reach the broker before them; nothing was written"
  redpanda_admin
fi

# --- (2) the entries.
written=
for name in $names; do
  [ "$name" != glitchtip-runtime ] || continue
  for key in $(jq -r --arg n "$name" '.[$n][]' <<<"$entries"); do
    printf '%s\n%s\n' "$key" "${!key}"
  done | aws_put_entry "$name"
  written="$written $name"
done
ok "entries of $aws_prefix written:$written (pg-superuser from SVP_RDS_MASTER_PASSWORD, the others from .env)"
if jq -e 'has("glitchtip-runtime")' <<<"$entries" >/dev/null; then
  if [ -z "$running" ]; then
    jq -r '.["glitchtip-runtime"][] | ., ""' <<<"$entries" | aws_put_entry glitchtip-runtime
    ok "entry ${aws_prefix}glitchtip-runtime written with its keys empty (make eks-glitchtip-init CONTEXT=$kube_context fills it once GlitchTip runs)"
  else
    echo "skip  entry ${aws_prefix}glitchtip-runtime: it has a value already, GlitchTip's own (make eks-glitchtip-init)"
  fi
fi

# --- (3) every ExternalSecret built again from the new values.
if [ -z "$running" ]; then
  echo "skip  ExternalSecrets: a new environment; Argo CD creates them (chart svp-cluster), each built from the entries then"
elif kc get crd externalsecrets.external-secrets.io >/dev/null 2>&1 &&
  [ -n "$(kc get externalsecrets.external-secrets.io -A -o name)" ]; then
  es_force_sync
  ok "every ExternalSecret built again from the entries of $aws_prefix; next: sync Application svp-data, then restart each workload whose Secret changed (docs/reference/eks.md)"
else
  echo "skip  ExternalSecrets: none yet; Argo CD creates them (chart svp-cluster), each built from the entries then"
fi
