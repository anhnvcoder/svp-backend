#!/usr/bin/env bash
# kafka-init.sh: the topics, Kafka users and ACLs of the project, on every broker it runs against: the local one (the
# one-shot kafka-init container of compose, Job kafka-init of chart svp-data on k3d) and Amazon MSK (the same Job on
# EKS). Topics are made here, not by auto-create or by the services, so the topology lives in one place in the repo and
# a mistyped name fails. Runs every Kafka command through /opt/svp/bin/svp-kafka, logged in as svp-admin.

# Steps, in this order: wait until svp-admin can log in; grant svp-admin ALL on the cluster and on every topic, group
# and transactional id before any other ACL (the broker allows a resource with no ACL to everyone, and from then on
# every resource has one); create the topics; create or reset the users (SVP_KAFKA_CREATE_USERS=true, where the broker
# keeps them) or leave them to the broker's owner (false, on MSK: Terraform associates a secret per user); grant ACLs.

# Environment: what svp-kafka reads (KAFKA_BROKERS, SVP_KAFKA_ADMIN_PASSWORD, SVP_CA_FILE when the CA is not public),
# SVP_KAFKA_CREATE_USERS (true or false), and with true SVP_KAFKA_<USER>_PASSWORD of each user below (letters and
# digits), e.g. SVP_KAFKA_USER_SERVICE_PASSWORD for svp-user-service. SVP_KAFKA_LOGIN_WAIT_SECONDS: how long to wait for
# the login, 600 when unset (MSK takes up to 10 minutes to apply a new SCRAM secret; a local broker needs far less).

# Topics take the broker's default.replication.factor and min.insync.replicas (one broker locally, set per env on MSK):
# no replication factor is passed. Idempotent: an existing topic is left as it is, an existing user gets its password
# set again, and adding an ACL that exists changes nothing. A password reaches kafka-configs in a properties file of
# mode 600, never on a command line, and nothing prints one.

# Design notes: docs/explanation/deployment.md.
set -euo pipefail

export PATH=/opt/svp/bin:$PATH
case ${SVP_KAFKA_CREATE_USERS:-} in
  true | false) ;;
  *) echo "kafka-init: SVP_KAFKA_CREATE_USERS must be true or false (got '${SVP_KAFKA_CREATE_USERS:-}')" >&2; exit 1 ;;
esac
wait_seconds=${SVP_KAFKA_LOGIN_WAIT_SECONDS:-600}
if [[ ! $wait_seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "kafka-init: SVP_KAFKA_LOGIN_WAIT_SECONDS must be a whole number of seconds (got '$wait_seconds')" >&2
  exit 1
fi

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/kafka-init.XXXXXX")
trap 'rm -rf "$work"' EXIT

# run DESCRIPTION svp-kafka ARGS...: runs a Kafka command quietly and prints its output (which holds no password) only
# when it fails.
run() {
  local what=$1
  shift
  if ! "$@" >"$work/out" 2>&1; then
    cat "$work/out" >&2
    echo "kafka-init: $what failed" >&2
    return 1
  fi
}

# One try every 5 s. A local broker keeps the svp-admin credential it was first formatted with, so after
# SVP_KAFKA_ADMIN_PASSWORD changed it never logs in: the message names the way out.
tries=$(((wait_seconds + 4) / 5))
until svp-kafka broker-api-versions >"$work/out" 2>&1; do
  tries=$((tries - 1))
  if ((tries == 0)); then
    cat "$work/out" >&2
    echo "kafka-init: svp-admin could not log in to $KAFKA_BROKERS within $wait_seconds s; a local broker" \
      "formatted with another SVP_KAFKA_ADMIN_PASSWORD needs its data deleted (compose: make clean-data)" >&2
    exit 1
  fi
  sleep 5
done
echo "kafka-init: svp-admin logged in to $KAFKA_BROKERS"

# admin_all RESOURCE...: grants svp-admin ALL on RESOURCE (* is the wildcard of a literal pattern, not a prefix).
admin_all() {
  run "granting svp-admin ALL on $*" svp-kafka acls --add --allow-principal User:svp-admin --operation All \
    --resource-pattern-type literal "$@"
}
admin_all --cluster
admin_all --topic '*'
admin_all --group '*'
admin_all --transactional-id '*'
echo "kafka-init: acl svp-admin All on the cluster and every topic, group and transactional id ok"

week_ms=604800000
two_weeks_ms=1209600000

# topic NAME PARTITIONS RETENTION_MS
topic() {
  run "creating topic $1" svp-kafka topics --create --if-not-exists --topic "$1" --partitions "$2" --config "retention.ms=$3"
  echo "kafka-init: topic $1 ok"
}

topic video.lifecycle.v1 3 "$week_ms"
topic media.transcodes.v1 3 "$week_ms"
topic user.follows.v1 3 "$week_ms"
topic engagement.views.v1 3 "$week_ms"
topic video.lifecycle.v1.dlq 1 "$two_weeks_ms"
topic media.transcodes.v1.dlq 1 "$two_weeks_ms"
topic user.follows.v1.dlq 1 "$two_weeks_ms"
topic engagement.views.v1.dlq 1 "$two_weeks_ms"

# user NAME: with SVP_KAFKA_CREATE_USERS=true, creates NAME or sets its password again (SCRAM-SHA-512), from
# SVP_KAFKA_<NAME without svp-, upper case, - as _>_PASSWORD.
user() {
  [[ $SVP_KAFKA_CREATE_USERS == true ]] || return 0
  local var pw out
  var=${1#svp-}
  var=SVP_KAFKA_$(tr 'a-z-' 'A-Z_' <<<"$var")_PASSWORD
  pw=${!var:-}
  if [[ ! $pw =~ ^[A-Za-z0-9]+$ ]]; then
    echo "kafka-init: $var, the password of $1, is empty or holds a character other than a letter or digit" >&2
    return 1
  fi
  # In a file the value has no [ ] around it (--add-config strips them, --add-config-file does not).
  printf 'SCRAM-SHA-512=password=%s\n' "$pw" >"$work/scram.properties"
  if ! svp-kafka configs --alter --entity-type users --entity-name "$1" \
    --add-config-file "$work/scram.properties" >"$work/out" 2>&1; then
    # kafka-configs names a credential it refuses with its value: the password is masked before printing.
    out=$(<"$work/out")
    printf '%s\n' "${out//"$pw"/<password>}" >&2
    echo "kafka-init: setting the SCRAM credential of $1 failed" >&2
    return 1
  fi
  rm -f "$work/scram.properties"
  echo "kafka-init: user $1 ok"
}

# allow USER OPERATION --topic T... | --group G...: grants USER the operation on the named topics or groups, matched by
# exact name (literal), never by prefix.
allow() {
  local who=$1 op=$2
  shift 2
  run "granting $op to $who on $*" svp-kafka acls --add --allow-principal "User:$who" --operation "$op" \
    --resource-pattern-type literal "$@"
  echo "kafka-init: acl $who $op $* ok"
}

# The ACL table: each service may touch only the topics and groups its code uses. Producers are
# idempotent, which needs WRITE on a topic and no cluster right (KIP-679); READ and WRITE imply DESCRIBE, which metadata
# and offset lookups need.
user svp-user-service
allow svp-user-service Write --topic user.follows.v1

user svp-video-service
allow svp-video-service Write --topic video.lifecycle.v1 --topic media.transcodes.v1.dlq
allow svp-video-service Read --topic media.transcodes.v1
allow svp-video-service Read --group video-service

user svp-engagement-service
allow svp-engagement-service Write --topic engagement.views.v1 --topic engagement.views.v1.dlq
allow svp-engagement-service Read --topic engagement.views.v1
allow svp-engagement-service Read --group engagement-service

user svp-feed-service
allow svp-feed-service Write --topic user.follows.v1.dlq --topic video.lifecycle.v1.dlq
allow svp-feed-service Read --topic user.follows.v1 --topic video.lifecycle.v1
allow svp-feed-service Read --group feed-service

user svp-media-worker
allow svp-media-worker Write --topic media.transcodes.v1 --topic video.lifecycle.v1.dlq
allow svp-media-worker Read --topic video.lifecycle.v1
allow svp-media-worker Read --group media-worker

# KEDA's Kafka scaler only reads the lag of media-worker's group: metadata of the topic, the group's committed and the
# partitions' end offsets. DESCRIBE alone gives that and lets it neither consume nor join the group.
user svp-keda
allow svp-keda Describe --topic video.lifecycle.v1
allow svp-keda Describe --group media-worker

# The Collector's kafkametrics receiver reads the lag of every consumer group: DESCRIBE on the topics and groups only.
user svp-otelcol
allow svp-otelcol Describe --topic video.lifecycle.v1 --topic media.transcodes.v1 --topic user.follows.v1 \
  --topic engagement.views.v1 --topic video.lifecycle.v1.dlq --topic media.transcodes.v1.dlq --topic user.follows.v1.dlq \
  --topic engagement.views.v1.dlq
allow svp-otelcol Describe --group video-service --group engagement-service --group feed-service --group media-worker

echo "kafka-init: done"
