#!/usr/bin/env bash
# Creates the event topics and their dead-letter topics on the compose Redpanda, run by the one-shot redpanda-init
# container (broker from RPK_BROKERS, Admin API from RPK_ADMIN_HOSTS). Topics are created here, not by auto-create or by
# the services, so the topology lives in one place in the repo and a mistyped name fails. Idempotent: a topic that
# already exists is left as it is, and the cluster property is set to the same value.

# TOPIC_REPLICAS is the replication factor of every topic: 1 on a single broker (compose, the default), 3 on three
# brokers. It applies only to topics this run creates: --if-not-exists leaves an existing topic with the replicas it
# has; changing it there takes `rpk topic alter-config <topic> --set replication.factor=<n>`.
# Design notes: docs/reference/compose.md.
set -euo pipefail

replicas=${TOPIC_REPLICAS:-1}

week_ms=604800000
two_weeks_ms=1209600000

# create NAME PARTITIONS RETENTION_MS. rpk reports a failed create on stdout, in its result
# table, so the output is kept and printed when the command fails.
create() {
  local out
  if ! out=$(rpk topic create "$1" --if-not-exists -p "$2" -r "$replicas" -c "retention.ms=$3" 2>&1); then
    printf '%s\n' "$out" >&2
    echo "redpanda-init: creating topic $1 failed" >&2
    return 1
  fi
  echo "redpanda-init: topic $1 ok"
}

create video.lifecycle.v1 3 "$week_ms"
create media.transcodes.v1 3 "$week_ms"
create user.follows.v1 3 "$week_ms"
create engagement.views.v1 3 "$week_ms"
create video.lifecycle.v1.dlq 1 "$two_weeks_ms"
create media.transcodes.v1.dlq 1 "$two_weeks_ms"
create user.follows.v1.dlq 1 "$two_weeks_ms"
create engagement.views.v1.dlq 1 "$two_weeks_ms"

# Consumer group lag metrics on /public_metrics, scraped by the obs Collector. Set through the Admin API, not
# .bootstrap.yaml: that file only applies when a cluster first forms, so a volume created earlier
# would never get it.
if ! out=$(rpk cluster config set enable_consumer_group_metrics '[group,partition,consumer_lag]' 2>&1); then
  printf '%s\n' "$out" >&2
  echo "redpanda-init: setting enable_consumer_group_metrics failed" >&2
  exit 1
fi
echo "redpanda-init: enable_consumer_group_metrics ok"
