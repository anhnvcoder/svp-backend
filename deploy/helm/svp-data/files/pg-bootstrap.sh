#!/usr/bin/env bash
# Creates or updates the roles and databases of the services and GlitchTip on the in-cluster Postgres svp-pg, by running
# deploy/postgres/bootstrap.sql (the file compose uses, mounted at /init/bootstrap.sql) once per database as the
# superuser. Run by the pg-bootstrap Job of chart svp-data after every install and upgrade; idempotent.

# The connection comes from PGHOST, PGPORT, PGUSER, PGPASSWORD, PGSSLMODE and PGDATABASE; the role passwords from
# SVP_<SERVICE>_{MIGRATOR,APP}_DB_PASSWORD. Every password stays in the environment, never on a command line, and none
# is printed. SVP_PG_MODE=external: a managed Postgres (Amazon RDS, master user, not a superuser), not CloudNativePG's.
# Design notes: docs/explanation/deployment.md.
set -euo pipefail

wait_seconds=${SVP_WAIT_SECONDS:?}
mode=${SVP_PG_MODE:-cluster}
services=(user video engagement feed glitchtip)

# Read every password before changing anything: a missing one stops the Job with nothing half applied.
for svc in "${services[@]}"; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  for role in MIGRATOR APP; do
    name="SVP_${upper}_${role}_DB_PASSWORD"
    if [[ -z ${!name:-} ]]; then
      echo "pg-bootstrap: $name is missing or empty in Secret pg-roles; run make env, then make k8s-secrets" >&2
      exit 1
    fi
  done
done

# The operator creates the instance asynchronously and sets the superuser password once it runs: wait until a login
# with that password works, for a bounded time, then fail with Postgres's own (terse) error.
deadline=$((SECONDS + wait_seconds))
until err=$(psql -X -q -v VERBOSITY=terse -c 'SELECT 1' 2>&1 >/dev/null); do
  if ((SECONDS >= deadline)); then
    echo "pg-bootstrap: no superuser login to $PGHOST:$PGPORT within ${wait_seconds}s; last error: $err" >&2
    exit 1
  fi
  sleep 3
done

for svc in "${services[@]}"; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  migrator="SVP_${upper}_MIGRATOR_DB_PASSWORD"
  app="SVP_${upper}_APP_DB_PASSWORD"
  SVP_MIGRATOR_PASSWORD=${!migrator} SVP_APP_PASSWORD=${!app} \
    psql -X -q -v db="svp_${svc}" -v migrator="svp_${svc}_migrator" -v app="svp_${svc}_app" -f /init/bootstrap.sql
  echo "pg-bootstrap: database svp_${svc} and roles svp_${svc}_migrator, svp_${svc}_app ok"
done

# A managed Postgres has neither the operator's roles nor its database app. Its own databases postgres and template1 are
# closed to PUBLIC as on svp-pg; the master user keeps CONNECT on them as their owner, or, where it does not own one,
# the REVOKE changes nothing and only warns. Its internal roles (rdsadmin on RDS) are superusers, which skip the check.
if [[ $mode == external ]]; then
  psql -X -q -1 -v ON_ERROR_STOP=1 -v VERBOSITY=terse -c 'REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC'
  echo "pg-bootstrap: CONNECT on databases postgres and template1 revoked from PUBLIC"
  exit 0
fi

# bootstrap.sql takes CONNECT away from PUBLIC on the svp_* databases only. postgres, app and template1, made by initdb
# and CloudNativePG, keep the default grant, so every service role could log in to them, and none needs to. CONNECT is
# granted by name to the two operator roles that do (cnpg_metrics_exporter, streaming_replica) and revoked from PUBLIC
# in one transaction, once the operator has created those roles; GRANT and REVOKE are idempotent.
until [[ $(psql -X -q -At -c "SELECT count(*) FROM pg_catalog.pg_roles
    WHERE rolname IN ('cnpg_metrics_exporter', 'streaming_replica')") == 2 ]]; do
  if ((SECONDS >= deadline)); then
    echo "pg-bootstrap: roles cnpg_metrics_exporter and streaming_replica not created by the operator within" \
      "${wait_seconds}s; CONNECT on postgres, app and template1 left as it was" >&2
    exit 1
  fi
  sleep 3
done
psql -X -q -1 -v ON_ERROR_STOP=1 -v VERBOSITY=terse \
  -c 'GRANT CONNECT ON DATABASE postgres TO cnpg_metrics_exporter, streaming_replica' \
  -c 'GRANT CONNECT ON DATABASE app TO cnpg_metrics_exporter' \
  -c 'REVOKE CONNECT ON DATABASE postgres, app, template1 FROM PUBLIC'
echo "pg-bootstrap: CONNECT on databases postgres, app and template1 revoked from PUBLIC, granted to operator roles"
