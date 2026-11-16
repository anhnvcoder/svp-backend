#!/usr/bin/env bash
# Creates or updates the Postgres roles and databases of the services and of the GlitchTip error tracker (svp_glitchtip)
# on the Postgres container of compose as the superuser, by running bootstrap.sql once per database. Idempotent. Reads
# only the role passwords from the env file, with the strict rule of deploy/observability/glitchtip/dotenv.sh (the one
# compose agrees with), never prints them, and reads all of them before it starts Postgres or changes anything.

# psql runs inside the container (`$COMPOSE exec`), as its OS user postgres over the Unix socket (deploy/postgres/
# pg_hba.conf), so the host needs no psql. The passwords reach it as environment variables named on the command line
# without their values.
# Usage: COMPOSE='<docker compose command>' deploy/postgres/bootstrap.sh <env-file>
set -euo pipefail

env_file=${1:?usage: bootstrap.sh <env-file>}
: "${COMPOSE:?COMPOSE must hold the docker compose command}"
. "$(dirname "$0")/../observability/glitchtip/dotenv.sh"

# value prints NAME's value in the env file and fails when the file breaks the rule or NAME is
# missing or empty.
value() {
  local v
  v=$(dotenv_value "$env_file" "$1") || return 1
  if [[ -z $v ]]; then
    echo "bootstrap: $1 is missing or empty in $env_file" >&2
    return 1
  fi
  printf '%s' "$v"
}

services=(user video engagement feed glitchtip)
# Timeouts of the app role of each service in its database, set by bootstrap.sql: requests stay well under them, and a
# background job that needs longer raises its statement timeout for its own transaction. GlitchTip's are reset.
app_statement_timeout=5s
app_idle_in_transaction_timeout=30s
migrator_passwords=()
app_passwords=()
for svc in "${services[@]}"; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  migrator_passwords+=("$(value "SVP_${upper}_MIGRATOR_DB_PASSWORD")")
  app_passwords+=("$(value "SVP_${upper}_APP_DB_PASSWORD")")
done

# Starts the container (and tls-init before it) when it is not running, and waits until it is healthy.
$COMPOSE up -d --wait postgres

for i in "${!services[@]}"; do
  svc=${services[$i]}
  statement_timeout=$app_statement_timeout idle_timeout=$app_idle_in_transaction_timeout
  if [[ $svc == glitchtip ]]; then
    statement_timeout='' idle_timeout=''
  fi
  SVP_MIGRATOR_PASSWORD=${migrator_passwords[$i]} SVP_APP_PASSWORD=${app_passwords[$i]} \
    $COMPOSE exec -T -e SVP_MIGRATOR_PASSWORD -e SVP_APP_PASSWORD postgres \
    psql -U postgres -d postgres -X -q \
    -v db="svp_${svc}" -v migrator="svp_${svc}_migrator" -v app="svp_${svc}_app" \
    -v statement_timeout="$statement_timeout" -v idle_in_transaction_session_timeout="$idle_timeout" \
    -f /opt/svp/postgres/bootstrap.sql
  echo "bootstrap: database svp_${svc} and roles svp_${svc}_migrator, svp_${svc}_app ok"
done
