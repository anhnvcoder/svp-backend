#!/usr/bin/env bash
# broker.sh: starts the local Kafka broker of image apache/kafka with server.properties of this directory. Formats the
# storage on first start with the SCRAM-SHA-512 credential of svp-admin (Kafka's way to create the first user of a KRaft
# cluster; every other user is made by kafka-init.sh as svp-admin), then runs the broker in place of this shell.
# Replaces the image's own start script, which cannot add a SCRAM credential when it formats.

# Environment: SVP_KAFKA_ADVERTISED (host:port clients are told, kafka:9096 in compose), SVP_KAFKA_CLUSTER_ID (a base64
# UUID, used only when the storage is formatted), SVP_KAFKA_ADMIN_PASSWORD (letters and digits), SVP_KAFKA_HEAP (heap of
# the broker's JVM, e.g. 512m; the tools run in the same container keep their own default). Runs as the image's user
# with a read-only root file system: configuration and the tools' log directory live under /tmp.

# The password is on the command line of kafka-storage only, inside this container and only on the first start, while
# it formats the empty storage: --add-scram has no file or stdin form. It is never printed.
# Design notes: docs/explanation/deployment.md.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
: "${SVP_KAFKA_ADVERTISED:?broker.sh: SVP_KAFKA_ADVERTISED is not set}"
: "${SVP_KAFKA_CLUSTER_ID:?broker.sh: SVP_KAFKA_CLUSTER_ID is not set}"
: "${SVP_KAFKA_HEAP:?broker.sh: SVP_KAFKA_HEAP is not set}"
password=${SVP_KAFKA_ADMIN_PASSWORD:-}
[[ $password =~ ^[A-Za-z0-9]+$ ]] ||
  { echo "broker.sh: SVP_KAFKA_ADMIN_PASSWORD is empty or holds a character other than a letter or digit" >&2; exit 1; }

export PATH=/opt/kafka/bin:$PATH
export LOG_DIR=/tmp/kafka-logs
config=/tmp/server.properties
umask 077
# The blank echo ends the file's last line: a ConfigMap may hold it without its final newline, and the next line would
# be glued to the last property.
{
  cat "$here/server.properties"
  echo
  echo "advertised.listeners=SASL_SSL://$SVP_KAFKA_ADVERTISED,INTERNAL://localhost:9092"
} >"$config"

# A formatted storage has meta.properties in log.dirs: a restart skips the format, so the password stays off argv.
data=$(sed -n 's/^log\.dirs=//p' "$config")
if [[ ! -e $data/meta.properties ]]; then
  kafka-storage.sh format --cluster-id "$SVP_KAFKA_CLUSTER_ID" --config "$config" \
    --add-scram "SCRAM-SHA-512=[name=svp-admin,password=$password]"
fi
unset password SVP_KAFKA_ADMIN_PASSWORD

# No -loggc: the GC log would be a file under LOG_DIR.
export KAFKA_HEAP_OPTS="-Xms$SVP_KAFKA_HEAP -Xmx$SVP_KAFKA_HEAP"
export KAFKA_LOG4J_OPTS="-Dlog4j2.configurationFile=$here/log4j2.yaml"
export EXTRA_ARGS="-name kafkaServer"
exec kafka-server-start.sh "$config"
