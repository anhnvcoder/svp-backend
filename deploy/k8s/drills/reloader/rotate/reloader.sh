# shellcheck shell=bash
# Helpers of the drill test reloader-rotate (chainsaw-test.yaml beside this file, make drill-k8s-reloader), sourced by
# each script of the test from its folder (`. ./reloader.sh`). Written for bash 3.2 (the macOS /bin/bash). curl takes
# the cluster's CA from CURL_CA_BUNDLE, which run.sh sets.

# Needs CALLER_KUBECONFIG (empty: ~/.kube/config; Chainsaw sets KUBECONFIG to its own copy of the cluster) and
# NEW_VALUES, OLD_VALUES (files of NAME=value lines, mode 600) and STATE_DIR (the test's private folder, removed by
# run.sh). A value is read from those files only, never from a command line; it leaves this machine only on the stdin of
# kubectl exec or in a private curl config file of $STATE_DIR, removed at once. Nothing here prints a value or a token.

umask 077
: "${CALLER_KUBECONFIG?the env of the script sets CALLER_KUBECONFIG to the caller KUBECONFIG}"
: "${NEW_VALUES:?the env of the script sets NEW_VALUES to the Chainsaw value newValues (run.sh)}"
: "${OLD_VALUES:?the env of the script sets OLD_VALUES to the Chainsaw value oldValues (run.sh)}"
: "${STATE_DIR:?the env of the script sets STATE_DIR to the Chainsaw value stateDir (run.sh)}"
export KUBECONFIG="$CALLER_KUBECONFIG"
repo=$(git rev-parse --show-toplevel)
state=$STATE_DIR
base=https://api.svp.localhost:8443
# shellcheck disable=SC2034 # read by the test's scripts
web_base=https://svp.localhost:8443
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$repo/deploy/observability/glitchtip/dotenv.sh"

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  exit 1
}
kc() { kubectl --context k3d-svp "$@"; }
[ -d "$state" ] || fail "the test's private folder STATE_DIR exists (deploy/k8s/drills/run.sh makes it)"

# value new|old NAME: the new or the old value of NAME (deploy/k8s/drills/reloader/new-values.sh names the lines of the
# new values; the old ones are those of .env before the drill).
value() {
  local file v
  case $1 in
    new) file=$NEW_VALUES ;;
    old) file=$OLD_VALUES ;;
    *) fail "value new|old NAME" ;;
  esac
  v=$(dotenv_value "$file" "$2") && [ -n "$v" ] || fail "read the $1 value of $2"
  printf '%s' "$v"
}

# The Secrets of namespaces svp, svp-data, svp-obs and keda that each variable the drill changes is written to
# (deploy/k8s/secrets.sh; with External Secrets, the ExternalSecrets of chart svp-cluster build these same Secrets from
# the source Secrets of svp-secrets, which are not among those namespaces).
changes='SVP_S3_ROOT_PASSWORD svp-data/s3-root
SVP_KAFKA_ADMIN_PASSWORD svp-data/redpanda-bootstrap svp-data/redpanda-superusers
SVP_VIDEO_APP_DB_PASSWORD svp-data/pg-roles svp/video-service-env
SVP_KAFKA_FEED_SERVICE_PASSWORD svp-data/kafka-users svp/feed-service-env
SVP_KAFKA_KEDA_PASSWORD svp-data/kafka-users keda/keda-kafka
SVP_GLITCHTIP_APP_DB_PASSWORD svp-data/pg-roles svp-obs/glitchtip-env
SVP_GRAFANA_ADMIN_PASSWORD svp-obs/grafana-admin
JWT_VERIFY_KEYS svp/user-service-env svp/video-service-env svp/engagement-service-env svp/feed-service-env svp/gateway-env
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY svp/web-env'

# The table "Secret -> workload": each Secret whose change restarts a workload, and that workload as
# Kind/namespace/name. Left out, as they restart nothing: pg-superuser (CloudNativePG sets the password itself), the
# inputs of the init Jobs of svp-data, <service>-migrate-env, glitchtip-admin and Alertmanager's (read from files).
# Written from the table, not from the workloads' annotations, so that a workload that does not opt in fails.
readers='svp-data/s3-root StatefulSet/svp-data/s3
svp-data/redpanda-bootstrap StatefulSet/svp-data/redpanda
svp-data/redpanda-superusers StatefulSet/svp-data/redpanda
svp/user-service-env Deployment/svp/user-service
svp/video-service-env Deployment/svp/video-service
svp/engagement-service-env Deployment/svp/engagement-service
svp/feed-service-env Deployment/svp/feed-service
svp/media-worker-env Deployment/svp/media-worker
svp/gateway-env Rollout/svp/gateway
svp/web-env Rollout/svp/web
svp/sentry Deployment/svp/user-service Deployment/svp/video-service Deployment/svp/engagement-service Deployment/svp/feed-service Rollout/svp/gateway Rollout/svp/web
svp-obs/glitchtip-env Deployment/svp-obs/glitchtip
svp-obs/grafana-admin Deployment/svp-obs/kps-grafana
keda/keda-kafka Deployment/keda/keda-operator'

namespaces="svp svp-data svp-obs keda"
init_job_names="pg-bootstrap redpanda-init s3-init"

# expected_secrets: every Secret the drill's change writes, one per line, sorted.
expected_secrets() { printf '%s\n' "$changes" | awk '{ for (i = 2; i <= NF; i++) print $i }' | LC_ALL=C sort -u; }
# readers_of < SECRETS: the workloads that read one of SECRETS (one per line), sorted.
readers_of() {
  awk 'NR == FNR { r[$1] = $0; next } $1 in r { n = split(r[$1], f, " "); for (i = 2; i <= n; i++) print f[i] }' \
    <(printf '%s\n' "$readers") - | LC_ALL=C sort -u
}

# pods FILE: one line "WORKLOAD UID STATE NAME" per pod of a Deployment, StatefulSet, Rollout or CloudNativePG Cluster
# of $namespaces (through its ReplicaSet for a Deployment or a Rollout), sorted; WORKLOAD is Kind/namespace/name, STATE
# terminating (deleted, not gone yet), ready or starting. Pods of Jobs, DaemonSets and the like are not tracked.
pods() {
  local ns rs
  : >"$1.part"
  for ns in $namespaces; do
    rs=$(kc -n "$ns" get replicasets.apps -o json | jq -c '[.items[] | {key: .metadata.name,
      value: ([.metadata.ownerReferences[]? | select(.controller == true) | "\(.kind)/\(.name)"] | first // "")}] | from_entries') ||
      fail "list the ReplicaSets of namespace $ns"
    kc -n "$ns" get pods -o json | jq -r --arg ns "$ns" --argjson rs "$rs" '.items[]
      | ([.metadata.ownerReferences[]? | select(.controller == true)] | first // {}) as $o
      | (if $o.kind == "ReplicaSet" then ($rs[$o.name] // "")
         elif $o.kind == "StatefulSet" or $o.kind == "Cluster" then "\($o.kind)/\($o.name)" else "" end) as $w
      | select($w | test("^(Deployment|Rollout|StatefulSet|Cluster)/"))
      | "\($w | sub("/"; "/" + $ns + "/")) \(.metadata.uid) \(if .metadata.deletionTimestamp != null then "terminating"
          elif any(.status.conditions[]?; .type == "Ready" and .status == "True") then "ready" else "starting" end) \(.metadata.name)"' \
      >>"$1.part" || fail "list the pods of namespace $ns"
  done
  LC_ALL=C sort "$1.part" >"$1"
  rm -f "$1.part"
}

# secret_versions FILE: one line "namespace/name resourceVersion" per Secret of $namespaces, sorted; Helm's release
# records (type helm.sh/release.v1), which every helmfile sync of release svp-data adds to and marks superseded, are
# left out. Only the name and the version leave jq.
secret_versions() {
  local ns
  for ns in $namespaces; do
    kc -n "$ns" get secrets -o json | jq -r --arg ns "$ns" \
      '.items[] | select(.type != "helm.sh/release.v1") | "\($ns)/\(.metadata.name) \(.metadata.resourceVersion)"' ||
      fail "list the Secrets of namespace $ns"
  done | LC_ALL=C sort >"$1"
}

# changed_secrets BEFORE AFTER: the Secrets of two secret_versions files whose version differs, or that only one has.
changed_secrets() { LC_ALL=C join -a 1 -a 2 -e - -o 0,1.2,2.2 "$1" "$2" | awk '$2 != $3 { print $1 }'; }

# init_jobs FILE: one line "name uid succeeded" per init Job of chart svp-data there is (pg-bootstrap, redpanda-init,
# s3-init: hooks of the chart, a new Job at each sync).
init_jobs() {
  kc -n svp-data get jobs.batch -o json | jq -r --arg names " $init_job_names " \
    '.items[] | .metadata.name as $n | select($names | contains(" \($n) ")) | "\($n) \(.metadata.uid) \(.status.succeeded // 0)"' |
    LC_ALL=C sort >"$1" || fail "list the Jobs of namespace svp-data"
}

# revisions FILE: the revision (annotation rollout.argoproj.io/revision) of Rollouts svp/gateway and svp/web.
revisions() {
  local r rev
  for r in gateway web; do
    rev=$(kc -n svp get rollouts.argoproj.io "$r" -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}') &&
      [ -n "$rev" ] || fail "read the revision of Rollout svp/$r"
    echo "$r $rev"
  done >"$1"
}

# snapshot NAME: pods, Secrets, init Jobs and revisions as they are now, in $state/<kind>-NAME.
snapshot() {
  pods "$state/pods-$1"
  secret_versions "$state/secrets-$1"
  init_jobs "$state/jobs-$1"
  revisions "$state/revisions-$1"
}

# replicas WORKLOAD: its spec.replicas.
replicas() {
  local kind=${1%%/*} rest=${1#*/} resource
  case $kind in
    Deployment) resource=deployments.apps ;;
    StatefulSet) resource=statefulsets.apps ;;
    Rollout) resource=rollouts.argoproj.io ;;
    *) return 1 ;;
  esac
  kc -n "${rest%%/*}" get "$resource" "${rest#*/}" -o jsonpath='{.spec.replicas}'
}

# restarted WORKLOAD BEFORE NOW: true when every pod of WORKLOAD in pods file NOW is new (its UID is not in pods file
# BEFORE), terminating ones included, and as many of them are Ready as its replicas; otherwise sets why.
restarted() {
  local w=$1 total old ready want
  total=$(awk -v w="$w" '$1 == w' "$3" | grep -c . || true)
  old=$(awk -v w="$w" 'NR == FNR { if ($1 == w) b[$2] = 1; next } $1 == w && ($2 in b)' "$2" "$3" | grep -c . || true)
  ready=$(awk -v w="$w" '$1 == w && $3 == "ready"' "$3" | grep -c . || true)
  want=$(replicas "$w") || want=
  if [[ ! $want =~ ^[0-9]+$ ]]; then
    why="its replicas could not be read"
  elif [ "$old" != 0 ]; then
    why="$old of its $total pod(s) are still those from before the change"
  elif [ "$ready" -lt "$want" ] || [ "$want" = 0 ]; then
    why="$ready of its $want replica(s) Ready"
  else
    return 0
  fi
  return 1
}

# new_pods WORKLOAD BEFORE NOW: the pods of WORKLOAD in NOW whose UID is not in BEFORE, by name.
new_pods() { awk -v w="$1" 'NR == FNR { if ($1 == w) b[$2] = 1; next } $1 == w && !($2 in b) { print $4 }' "$2" "$3"; }

# kept WORKLOAD BEFORE NOW: true when WORKLOAD has no pod in NOW that BEFORE lacks and, for a StatefulSet or a
# Cluster (a restart deletes their pod before it makes the new one, and neither scales by itself), none terminating;
# otherwise sets why. A pod gone without a new one (a Deployment scaled down by its autoscaler) is no restart.
kept() {
  local added ending=
  added=$(new_pods "$1" "$2" "$3" | paste -sd ' ' -)
  case $1 in
    StatefulSet/* | Cluster/*) ending=$(awk -v w="$1" '$1 == w && $3 == "terminating" { print $4 }' "$3" | paste -sd ' ' -) ;;
  esac
  if [ -n "$added" ]; then
    why="new pod(s) $added"
  elif [ -n "$ending" ]; then
    why="pod(s) $ending terminating"
  else
    return 0
  fi
  return 1
}

# jobs_ran BEFORE AFTER: true when each init Job of chart svp-data is in jobs file AFTER with another UID than in
# BEFORE (or BEFORE lacks it) and has Succeeded; otherwise prints one FAIL line per Job that did not.
jobs_ran() {
  local name uid before_uid succeeded rc=0
  for name in $init_job_names; do
    read -r uid succeeded < <(awk -v n="$name" '$1 == n { print $2, $3 }' "$2") || uid=
    before_uid=$(awk -v n="$name" '$1 == n { print $2 }' "$1")
    if [ -z "$uid" ]; then
      echo "FAIL  Job svp-data/$name: none after the change (an init Job of chart svp-data runs at each sync)"
      rc=1
    elif [ "$uid" = "$before_uid" ]; then
      echo "FAIL  Job svp-data/$name: the same Job as before the change, it did not run again"
      rc=1
    elif [ "${succeeded:-0}" -lt 1 ]; then
      echo "FAIL  Job svp-data/$name: ran again but has not Succeeded"
      rc=1
    else
      echo "ok    Job svp-data/$name ran again and Succeeded"
    fi
  done
  return $rc
}

# new_env FILE: prints FILE, the lines of .env, with the new values: each variable of $changes but JWT_VERIFY_KEYS gets
# its new value, JWT_VERIFY_KEYS gets JWT_VERIFY_KEY_NEW after the keys it has (the signing key stays: tokens of the
# current key stay valid); every other line as it is. The values stay inside awk, read from the files.
new_env() {
  awk -v names="$(printf '%s\n' "$changes" | awk '{ print $1 }' | paste -sd ' ' -)" '
    BEGIN { n = split(names, a, " "); for (j = 1; j <= n; j++) changed[a[j]] = 1 }
    function kv(line) { i = index(line, "="); key = substr(line, 1, i - 1); val = substr(line, i + 1) }
    FILENAME == ARGV[1] { kv($0); old[key] = val; next }
    FILENAME == ARGV[2] { kv($0); new[key] = val; next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      kv($0)
      if (key == "JWT_VERIFY_KEYS") { print key "=" old[key] "," new["JWT_VERIFY_KEY_NEW"]; next }
      if (key in changed) { print key "=" new[key]; next }
    }
    { print }' "$OLD_VALUES" "$NEW_VALUES" "$1"
}

# env_check FILE: true when FILE keeps the rule of .env and holds the new value of each variable of $changes
# (new_env); fails naming the first that it does not, never a value.
env_check() {
  local name want got
  for name in $(printf '%s\n' "$changes" | awk '{ print $1 }'); do
    got=$(dotenv_value "$1" "$name") || fail "the copy of .env with the new values breaks the rule of .env (above)"
    if [ "$name" = JWT_VERIFY_KEYS ]; then want="$(value old "$name"),$(value new JWT_VERIFY_KEY_NEW)"; else
      want=$(value new "$name"); fi
    [ "$got" = "$want" ] || fail "the copy of .env does not hold the new $name"
  done
}

# env_write: puts the new values into .env: a copy made beside it (mode 600) by new_env, checked by env_check, then
# moved in place of .env.
env_tmp=$repo/.env.drill-reloader
env_write() {
  trap 'rm -f "$env_tmp"' EXIT
  new_env "$repo/.env" >"$env_tmp" || fail "write the new values into a copy of .env"
  env_check "$env_tmp"
  mv "$env_tmp" "$repo/.env" || fail "put the copy with the new values in place of .env"
  trap - EXIT
  ok ".env holds the new values: $(printf '%s\n' "$changes" | awk '{ print $1 }' | paste -sd ' ' -) (JWT_VERIFY_KEYS: one key added after its own)"
}

# api METHOD PATH [AUTH_FILE] [BODY_FILE]: a request to the gateway through Envoy; the body goes to $state/body, the
# HTTP status is printed (000 when there was no answer). AUTH_FILE holds the Authorization header, read by curl.
api() {
  local args=(-sS --max-time 10 -o "$state/body" -w '%{http_code}' -X "$1" "$base$2")
  if [ -n "${3:-}" ]; then args+=(-H "@$3"); fi
  if [ -n "${4:-}" ]; then args+=(-H 'Content-Type: application/json' --data-binary "@$4"); fi
  : >"$state/body"
  curl "${args[@]}" 2>/dev/null || true
}

# drill_user: registers and logs in a new user of the drill (a random password, never printed), and writes its
# Authorization header to $state/old.auth (a token of the current signing key) and its id to $state/user-id.
drill_user() {
  local status token
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "drill-reloader-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)@example.test" \
    '{email: $e, password: env.DRILL_PASSWORD}' >"$state/user.json"
  status=$(api POST /auth/register "" "$state/user.json")
  [ "$status" = 201 ] || fail "register the drill's user through the gateway (status $status)"
  jq -r '.user_id // ""' "$state/body" >"$state/user-id"
  status=$(api POST /auth/login "" "$state/user.json")
  token=$(jq -r '.access_token // ""' "$state/body")
  : >"$state/body"
  [ "$status" = 200 ] && [ -n "$token" ] || fail "log the drill's user in through the gateway (status $status)"
  printf 'Authorization: Bearer %s\n' "$token" >"$state/old.auth"
  ok "drill user registered and logged in (its token is signed with the current signing key)"
}

# b64url < DATA: base64url without padding (RFC 7515). unb64url TEXT: the bytes of base64url TEXT.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
unb64url() {
  local s
  s=$(printf '%s' "$1" | tr '_-' '/+')
  while [ $((${#s} % 4)) != 0 ]; do s="$s="; done
  printf '%s' "$s" | openssl base64 -d -A
}

# jwt_new_token: writes $state/new.auth, the Authorization header of a token for the drill's user signed with
# JWT_DRILL_SIGNING_KEY under the kid of JWT_VERIFY_KEY_NEW: the claims user-service writes (internal/authtoken:
# iss svp-user, aud svp-api, sub, iat, exp an hour later, jti), alg EdDSA. Until JWT_VERIFY_KEYS holds that key,
# nothing takes it. The key goes to openssl in a private file of $state, removed at once.
jwt_new_token() {
  local kid sub now header payload
  kid=$(value new JWT_VERIFY_KEY_NEW)
  kid=${kid%%:*}
  sub=$(cat "$state/user-id")
  [ -n "$sub" ] || fail "the drill user's id (drill_user)"
  # The PKCS #8 form of an Ed25519 private key (RFC 8410): a fixed prefix of 16 bytes, then the 32-byte seed.
  {
    printf '\060\056\002\001\000\060\005\006\003\053\145\160\004\042\004\040'
    value new JWT_DRILL_SIGNING_KEY | openssl base64 -d -A
  } >"$state/drill-key.der"
  openssl pkey -inform DER -in "$state/drill-key.der" -out "$state/drill-key.pem" 2>/dev/null ||
    { rm -f "$state/drill-key.der"; fail "read JWT_DRILL_SIGNING_KEY as an Ed25519 key (openssl pkey)"; }
  now=$(date +%s)
  header=$(printf '{"alg":"EdDSA","kid":"%s","typ":"JWT"}' "$kid" | b64url)
  payload=$(jq -cn --arg sub "$sub" --argjson now "$now" --arg jti "drill-reloader-$(openssl rand -hex 8)" \
    '{iss: "svp-user", sub: $sub, aud: ["svp-api"], exp: ($now + 3600), iat: $now, jti: $jti}' | b64url)
  printf '%s.%s' "$header" "$payload" >"$state/jwt-input"
  if ! openssl pkeyutl -sign -rawin -inkey "$state/drill-key.pem" -in "$state/jwt-input" -out "$state/jwt-sig" 2>/dev/null; then
    rm -f "$state/drill-key.der" "$state/drill-key.pem"
    fail "sign the token with openssl pkeyutl -rawin (OpenSSL 1.1.1 or later signs Ed25519)"
  fi
  rm -f "$state/drill-key.der" "$state/drill-key.pem"
  printf 'Authorization: Bearer %s.%s.%s\n' "$header" "$payload" "$(b64url <"$state/jwt-sig")" >"$state/new.auth"
  rm -f "$state/jwt-input" "$state/jwt-sig"
  ok "a token of the drill's user signed with the new key (kid $kid) is ready"
}

# wait_restarts: once make k8s-secrets has changed the Secrets, each workload that reads one that changed (by
# $readers) restarted within 300 s, waited for one after the other; every other workload kept its pods; Rollouts
# gateway and web kept their revision; the init Jobs of svp-data ran again and Succeeded. One line per check, a FAIL
# line for each one that failed; status 1 when one did.
wait_restarts() {
  local changed missing other restart w deadline rc=0 all
  secret_versions "$state/secrets-rotated"
  changed=$(changed_secrets "$state/secrets-before" "$state/secrets-rotated")
  missing=$(LC_ALL=C comm -23 <(expected_secrets) <(printf '%s\n' "$changed" | grep . || true))
  if [ -n "$missing" ]; then
    echo "FAIL  make k8s-secrets changed no version of: $(printf '%s' "$missing" | paste -sd ' ' -)"
    rc=1
  else
    echo "ok    the Secrets of each changed value got a new version: $(expected_secrets | paste -sd ' ' -)"
  fi
  other=$(LC_ALL=C comm -13 <(expected_secrets) <(printf '%s\n' "$changed" | grep . || true) | paste -sd ' ' -)
  [ -z "$other" ] || echo "note  other Secrets changed meanwhile: $other"
  restart=$(printf '%s\n' "$changed" | grep . | readers_of || true)
  for w in $restart; do
    deadline=$((SECONDS + 300))
    while :; do
      pods "$state/pods-now"
      if restarted "$w" "$state/pods-before" "$state/pods-now"; then
        echo "ok    $w restarted: each of its pods is new and Ready ($(new_pods "$w" "$state/pods-before" "$state/pods-now" | grep -c .))"
        break
      fi
      if ((SECONDS >= deadline)); then
        echo "FAIL  $w did not restart within 300 s although a Secret it reads changed: $why"
        rc=1
        break
      fi
      sleep 5
    done
  done
  pods "$state/pods-rotated"
  all=$(awk '{ print $1 }' "$state/pods-before" "$state/pods-rotated" | LC_ALL=C sort -u)
  for w in $all; do
    case " $(printf '%s' "$restart" | paste -sd ' ' -) " in *" $w "*) continue ;; esac
    if kept "$w" "$state/pods-before" "$state/pods-rotated"; then
      echo "ok    $w kept its pods (it reads no Secret that changed)"
    else
      echo "FAIL  $w reads no Secret that changed but $why"
      rc=1
    fi
  done
  revisions "$state/revisions-rotated"
  if cmp -s "$state/revisions-before" "$state/revisions-rotated"; then
    echo "ok    Rollouts gateway and web kept their revision ($(paste -sd ' ' "$state/revisions-rotated")): restarted, no new revision"
  else
    echo "FAIL  the revision of Rollout gateway or web changed: $(paste -sd ' ' "$state/revisions-before") before, $(paste -sd ' ' "$state/revisions-rotated") after"
    rc=1
  fi
  init_jobs "$state/jobs-rotated"
  jobs_ran "$state/jobs-before" "$state/jobs-rotated" || rc=1
  return $rc
}

# control_check: after make k8s-secrets ran again with the same .env (snapshot control first, then 20 s for anything
# Reloader would do): no Secret of the four namespaces got a new version, no tracked workload restarted, and the init
# Jobs of svp-data ran again and Succeeded.
control_check() {
  local changed w rc=0
  pods "$state/pods-again"
  secret_versions "$state/secrets-again"
  init_jobs "$state/jobs-again"
  changed=$(changed_secrets "$state/secrets-control" "$state/secrets-again" | paste -sd ' ' -)
  if [ -n "$changed" ]; then
    echo "FAIL  the same .env changed Secret(s): $changed"
    rc=1
  else
    echo "ok    the same .env changed no Secret of $namespaces (Helm's release records aside)"
  fi
  for w in $(awk '{ print $1 }' "$state/pods-control" "$state/pods-again" | LC_ALL=C sort -u); do
    if kept "$w" "$state/pods-control" "$state/pods-again"; then
      echo "ok    $w kept its pods"
    else
      echo "FAIL  $w restarted with the same .env: $why"
      rc=1
    fi
  done
  jobs_ran "$state/jobs-control" "$state/jobs-again" || rc=1
  return $rc
}

# rpk_login USER old|new VARIABLE: rpk cluster info in the broker container as Kafka user USER with the old or new
# value of VARIABLE (on stdin, read into RPK_PASS, rpk's own variable); prints ok, or the first Kafka error code rpk
# printed (none when it printed none).
rpk_login() {
  value "$2" "$3" | {
    cat
    echo
  } | kc -n svp-data exec -i redpanda-0 -c redpanda -- bash -c '
    IFS= read -r RPK_PASS
    export RPK_PASS RPK_USER=$1
    out=$(timeout 20 rpk cluster info 2>&1) && { echo ok; exit 0; }
    code=$(printf "%s\n" "$out" | grep -oE "[A-Z]+(_[A-Z]+)+" | head -n 1)
    echo "${code:-none}"' bash "$1"
}

# psql_login ROLE DATABASE old|new VARIABLE: SELECT 1 as ROLE on DATABASE over TCP to 127.0.0.1 inside the primary of
# Postgres svp-pg with the old or new value of VARIABLE (on stdin, read into PGPASSWORD); prints ok,
# password-authentication-failed or other.
psql_login() {
  local primary
  primary=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg -o jsonpath='{.status.currentPrimary}') &&
    [ -n "$primary" ] || fail "read the primary of Cluster svp-data/svp-pg"
  value "$3" "$4" | {
    cat
    echo
  } | kc -n svp-data exec -i "$primary" -c postgres -- sh -c '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    out=$(psql -X -w -A -t "host=127.0.0.1 port=5432 user=$1 dbname=$2 sslmode=require connect_timeout=5" -c "select 1" 2>&1)
    case $out in
      1) echo ok ;;
      *"password authentication failed"*) echo password-authentication-failed ;;
      *) echo other ;;
    esac' sh "$1" "$2"
}

# curl_config FILE LINE...: a private curl config file of the lines given (printf, a shell builtin: no command line
# holds them).
curl_config() {
  local f=$1
  shift
  : >"$f"
  printf '%s\n' "$@" >>"$f"
}

# s3_root old|new: the HTTP status of ListBuckets (GET /, signed with SigV4) as the object store's root user svp-admin
# with the old or new SVP_S3_ROOT_PASSWORD, through the test's port-forward on 127.0.0.1:19000.
s3_root() {
  local cfg=$state/s3.curl
  curl_config "$cfg" "user = \"svp-admin:$(value "$1" SVP_S3_ROOT_PASSWORD)\""
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' --aws-sigv4 aws:amz:us-east-1:s3 -K "$cfg" http://127.0.0.1:19000/ || true
  rm -f "$cfg"
}

# grafana_admin old|new: the HTTP status of Grafana's /api/user as admin with the old or new SVP_GRAFANA_ADMIN_PASSWORD,
# through the test's port-forward on 127.0.0.1:13000.
grafana_admin() {
  local cfg=$state/grafana.curl
  curl_config "$cfg" "user = \"admin:$(value "$1" SVP_GRAFANA_ADMIN_PASSWORD)\""
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' -K "$cfg" http://127.0.0.1:13000/api/user || true
  rm -f "$cfg"
}

# glitchtip_api: the HTTP status of GlitchTip's API for project svp/svp with the read-only token of Secret
# svp-obs/glitchtip-api (it reads GlitchTip's database), through the test's port-forward on 127.0.0.1:18000.
glitchtip_api() {
  local cfg=$state/glitchtip.curl
  kc -n svp-obs get secret glitchtip-api -o json |
    jq -r '"header = \(("Authorization: Bearer " + (.data.SENTRY_AUTH_TOKEN | @base64d)) | @json)"' >"$cfg" ||
    fail "read GlitchTip's API token from Secret svp-obs/glitchtip-api"
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' -K "$cfg" http://127.0.0.1:18000/api/0/projects/svp/svp/ || true
  rm -f "$cfg"
}

# web_key old|new: one line "<pod> same|differs|error" per Ready pod of Rollout svp/web, whether the web container
# runs with that NEXT_SERVER_ACTIONS_ENCRYPTION_KEY: the value goes to node in the container on stdin and is compared
# there with the process environment, which the container got at its start (exit 3: differs).
web_key() {
  local pod rc
  pods "$state/pods-web"
  for pod in $(awk '$1 == "Rollout/svp/web" && $3 == "ready" { print $4 }' "$state/pods-web"); do
    rc=0
    value "$1" NEXT_SERVER_ACTIONS_ENCRYPTION_KEY | kc -n svp exec -i "$pod" -c web -- /nodejs/bin/node -e '
      let d = ""
      process.stdin.on("data", (c) => (d += c)).on("end", () =>
        process.exit(d === process.env.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY ? 0 : 3))' >/dev/null 2>&1 || rc=$?
    case $rc in
      0) echo "$pod same" ;;
      3) echo "$pod differs" ;;
      *) echo "$pod error" ;;
    esac
  done
}

# feed_group: "<state> <members> <hosts not of a feed-service pod>" of Kafka group feed-service, read as svp-admin (the
# broker container's own login): Stable with one member or more, each at the address of a running feed-service pod,
# reads "Stable <n> -".
feed_group() {
  local out state members ips stray
  out=$(kc -n svp-data exec redpanda-0 -c redpanda -- rpk group describe feed-service 2>&1) || out=
  state=$(printf '%s\n' "$out" | awk '$1 == "STATE" { print $2 }')
  members=$(printf '%s\n' "$out" | awk '$1 == "MEMBERS" { print $2 }')
  ips=" $(kc -n svp get pods -l app.kubernetes.io/name=feed-service -o jsonpath='{.items[*].status.podIP}') "
  stray=$(printf '%s\n' "$out" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | while read -r ip; do
    case $ips in *" $ip "*) ;; *) echo "$ip" ;; esac
  done | paste -sd ',' -)
  echo "${state:-unknown} ${members:-0} ${stray:--}"
}

# keda_lag: the lag KEDA's metrics server gives for the ScaledObject svp/media-worker (its Kafka trigger, logged in with
# Secret keda/keda-kafka), read from the external metrics API the HPA reads; empty when it gives none.
keda_lag() {
  local metric
  metric=$(kc -n svp get hpa keda-hpa-media-worker -o jsonpath='{.spec.metrics[0].external.metric.name}' 2>/dev/null) || metric=
  [ -n "$metric" ] || return 0
  kc get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/svp/$metric?labelSelector=scaledobject.keda.sh%2Fname%3Dmedia-worker" 2>/dev/null |
    jq -r '.items[0].value // empty' 2>/dev/null || true
}
