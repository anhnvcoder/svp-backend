#!/usr/bin/env bash
# Tests for the wrappers svp-kafka and svp-valkey of this directory, without a broker or a server: fake kafka-*.sh tools
# and a fake valkey-cli first on PATH record their command line, the client properties file svp-kafka hands over (and
# its mode), REDISCLI_AUTH and their stdin. Covers the default login (svp-admin, svp-ops), SVP_AS_USER with the password
# on the first line of stdin, the trust store with and without SVP_CA_FILE, and the refusals.

# Usage, from anywhere: deploy/ops/ops-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

admin_pw=Adm1nPw
ops_pw=0psPw
mkdir -p "$work/bin"
# The fake Kafka tool, under every name used here: $FAKE_STATE/argv (one argument per line, the properties file as
# PROPS), $FAKE_STATE/props (the file's content), $FAKE_STATE/mode, $FAKE_STATE/stdin. Exits FAKE_RC.
cat >"$work/bin/fake-kafka-tool" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
s=$FAKE_STATE
basename "$0" >"$s/tool"
: >"$s/argv"
prev=
for a in "$@"; do
  case $prev in
    --command-config | --producer.config | --consumer.config)
      cp "$a" "$s/props"
      (stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a") >"$s/mode"
      echo "$a" >"$s/props-path"
      a=PROPS
      ;;
  esac
  echo "$a" >>"$s/argv"
  prev=$a
done
cat >"$s/stdin"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$work/bin/fake-kafka-tool"
for t in topics console-producer console-consumer; do ln -s fake-kafka-tool "$work/bin/kafka-$t.sh"; done
cat >"$work/bin/valkey-cli" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
s=$FAKE_STATE
printf '%s\n' "$@" >"$s/argv"
printf '%s' "${REDISCLI_AUTH-<unset>}" >"$s/auth"
cat >"$s/stdin"
EOF
chmod +x "$work/bin/valkey-cli"

# The variables the wrappers and fakes read: each case sets its own, none comes from the caller's environment.
wrapper_vars=(KAFKA_BROKERS SVP_KAFKA_ADMIN_PASSWORD SVP_CA_FILE SVP_AS_USER VALKEY_HOST SVP_VALKEY_OPS_PASSWORD
  REDISCLI_AUTH FAKE_RC)
unset_vars=()
for v in "${wrapper_vars[@]}"; do unset_vars+=(-u "$v"); done

# run CASE STDIN WRAPPER [ARGS...]: runs WRAPPER with ARGS and STDIN in a fresh state folder $work/CASE, with only the
# variables of CASE_ENV (an array) of those above set. Output in $work/CASE/out, status in rc.
run() {
  local case=$1 input=$2 wrapper=$3
  shift 3
  mkdir -p "$work/$case/tmp"
  set +e
  printf '%s' "$input" | env "${unset_vars[@]}" PATH="$work/bin:/usr/bin:/bin" TMPDIR="$work/$case/tmp" FAKE_STATE="$work/$case" \
    ${case_env[@]+"${case_env[@]}"} "$here/$wrapper" "$@" >"$work/$case/out" 2>&1
  echo $? >"$work/$case/rc"
  set -e
}
rc() { cat "$work/$1/rc"; }
argv() { tr '\n' ' ' <"$work/$1/argv"; }
no_secret() {
  if grep -rq -e "$admin_pw" -e "$ops_pw" -e Us3rPw "$work/$1/out" "$work/$1/argv" 2>/dev/null; then
    fail "$1: a password in the output or on the command line"
    return 1
  fi
}
left_empty() {
  [[ -z $(find "$work/$1/tmp" -mindepth 1) ]] || { fail "$1: files left in TMPDIR"; return 1; }
}
jaas() { printf 'sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";' "$1" "$2"; }

# svp-kafka, as svp-admin, with the CA.
case_env=(KAFKA_BROKERS=kafka:9096 SVP_KAFKA_ADMIN_PASSWORD="$admin_pw" SVP_CA_FILE=/etc/svp-ca/ca.crt)
run kafka-admin "" svp-kafka topics --list
want_props="security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
$(jaas svp-admin "$admin_pw")
ssl.truststore.type=PEM
ssl.truststore.location=/etc/svp-ca/ca.crt"
if [[ $(rc kafka-admin) != 0 ]]; then
  cat "$work/kafka-admin/out" >&2
  fail "kafka-admin: exit $(rc kafka-admin)"
elif [[ $(<"$work/kafka-admin/tool") != kafka-topics.sh ]]; then
  fail "kafka-admin: ran $(<"$work/kafka-admin/tool"), want kafka-topics.sh"
elif [[ $(argv kafka-admin) != "--bootstrap-server kafka:9096 --command-config PROPS --list " ]]; then
  fail "kafka-admin: command line '$(argv kafka-admin)'"
elif [[ $(<"$work/kafka-admin/props") != "$want_props" ]]; then
  fail "kafka-admin: client properties are not svp-admin's SCRAM-SHA-512 login over SASL_SSL with the CA as PEM trust store"
elif [[ $(<"$work/kafka-admin/mode") != 600 ]]; then
  fail "kafka-admin: properties file mode $(<"$work/kafka-admin/mode"), want 600"
elif no_secret kafka-admin && left_empty kafka-admin; then
  ok "svp-kafka topics --list: kafka-topics.sh against KAFKA_BROKERS as svp-admin from a 600 file, CA as PEM trust store, file removed after, no password on the command line"
fi

# Without SVP_CA_FILE: no trust store lines (the JVM's own, for MSK).
case_env=("KAFKA_BROKERS=b-1.example:9096,b-2.example:9096" SVP_KAFKA_ADMIN_PASSWORD="$admin_pw")
run kafka-no-ca "" svp-kafka topics --describe
if [[ $(rc kafka-no-ca) != 0 ]] || grep -q truststore "$work/kafka-no-ca/props" ||
  [[ $(argv kafka-no-ca) != "--bootstrap-server b-1.example:9096,b-2.example:9096 --command-config PROPS --describe " ]]; then
  fail "kafka-no-ca: without SVP_CA_FILE the file has trust store lines or the command line is '$(argv kafka-no-ca)'"
else
  ok "svp-kafka without SVP_CA_FILE: no trust store set (the JVM's own roots), every broker of KAFKA_BROKERS passed"
fi

# SVP_AS_USER: the password is the first line of stdin, the rest reaches the tool; the console clients' own flag.
case_env=(KAFKA_BROKERS=kafka:9096 SVP_KAFKA_ADMIN_PASSWORD="$admin_pw" SVP_CA_FILE=/etc/svp-ca/ca.crt
  SVP_AS_USER=svp-user-service)
run kafka-as-user $'Us3rPw\nrecord one\nrecord two\n' svp-kafka console-producer --topic user.follows.v1
if [[ $(rc kafka-as-user) != 0 ]]; then
  cat "$work/kafka-as-user/out" >&2
  fail "kafka-as-user: exit $(rc kafka-as-user)"
elif [[ $(argv kafka-as-user) != "--bootstrap-server kafka:9096 --producer.config PROPS --topic user.follows.v1 " ]]; then
  fail "kafka-as-user: command line '$(argv kafka-as-user)'"
elif ! grep -qxF "$(jaas svp-user-service Us3rPw)" "$work/kafka-as-user/props" || grep -q "$admin_pw" "$work/kafka-as-user/props"; then
  fail "kafka-as-user: the file does not log in as svp-user-service with the password from stdin alone"
elif [[ $(<"$work/kafka-as-user/stdin") != $'record one\nrecord two' ]]; then
  fail "kafka-as-user: the tool's stdin is '$(<"$work/kafka-as-user/stdin")', want the lines after the password"
elif no_secret kafka-as-user && left_empty kafka-as-user; then
  ok "SVP_AS_USER=svp-user-service svp-kafka console-producer: --producer.config, logs in as that user with the first line of stdin, the rest reaches the producer"
fi

run kafka-consumer "Us3rPw"$'\n' svp-kafka console-consumer --topic user.follows.v1
if [[ $(rc kafka-consumer) != 0 ]] || [[ $(argv kafka-consumer) != "--bootstrap-server kafka:9096 --consumer.config PROPS --topic user.follows.v1 " ]]; then
  fail "kafka-consumer: command line '$(argv kafka-consumer)', want --consumer.config"
else
  ok "svp-kafka console-consumer: --consumer.config"
fi

# The tool's exit status is the wrapper's, and the file is removed all the same.
case_env=(KAFKA_BROKERS=kafka:9096 SVP_KAFKA_ADMIN_PASSWORD="$admin_pw" FAKE_RC=3)
run kafka-rc "" svp-kafka topics --list
if [[ $(rc kafka-rc) != 3 ]] || ! left_empty kafka-rc; then
  fail "kafka-rc: exit $(rc kafka-rc) (want the tool's 3) or the file was left behind"
else
  ok "svp-kafka: exits with the tool's status and removes the file when the tool fails"
fi

# refuse CASE STDIN MESSAGE WRAPPER ARGS...: the wrapper exits 2 printing MESSAGE and runs no tool.
refuse() {
  local case=$1 input=$2 message=$3
  shift 3
  run "$case" "$input" "$@"
  if [[ $(rc "$case") != 2 ]] || ! grep -qF -- "$message" "$work/$case/out" || [[ -e $work/$case/argv ]]; then
    fail "$case: want exit 2 with '$message' and no tool run (exit $(rc "$case"): $(head -c 200 "$work/$case/out"))"
  elif no_secret "$case"; then
    ok "$case: refused ($message)"
  fi
}
case_env=(KAFKA_BROKERS=kafka:9096)
refuse kafka-no-admin-pw "" "SVP_KAFKA_ADMIN_PASSWORD is not set" svp-kafka topics --list
case_env=(SVP_KAFKA_ADMIN_PASSWORD="$admin_pw")
refuse kafka-no-brokers "" "KAFKA_BROKERS is not set" svp-kafka topics --list
case_env=(KAFKA_BROKERS=kafka:9096 SVP_KAFKA_ADMIN_PASSWORD="$admin_pw")
refuse kafka-no-tool "" "usage: svp-kafka TOOL" svp-kafka
refuse kafka-bad-tool "" "TOOL is a tool name" svp-kafka ../bin/sh
case_env=(KAFKA_BROKERS=kafka:9096 'SVP_KAFKA_ADMIN_PASSWORD=a"b')
refuse kafka-bad-pw "" "holds a character other than a letter or digit" svp-kafka topics --list
case_env=(KAFKA_BROKERS=kafka:9096 SVP_KAFKA_ADMIN_PASSWORD="$admin_pw" SVP_AS_USER=svp-keda)
refuse kafka-as-user-no-pw "" "the first line of stdin must be the password of svp-keda" svp-kafka topics --list
case_env=(KAFKA_BROKERS=kafka:9096 SVP_KAFKA_ADMIN_PASSWORD="$admin_pw" 'SVP_AS_USER=svp-x" password="y')
refuse kafka-bad-user "Us3rPw"$'\n' "SVP_AS_USER is a Kafka user" svp-kafka topics --list

# svp-valkey, as svp-ops, with the CA.
case_env=(VALKEY_HOST=valkey SVP_VALKEY_OPS_PASSWORD="$ops_pw" SVP_CA_FILE=/etc/svp-ca/ca.crt)
run valkey-ops "" svp-valkey -n 10 --scan --pattern 'svp:gw:rl:register:*'
if [[ $(rc valkey-ops) != 0 ]]; then
  cat "$work/valkey-ops/out" >&2
  fail "valkey-ops: exit $(rc valkey-ops)"
elif [[ $(argv valkey-ops) != "--tls --user svp-ops -h valkey -p 6379 --cacert /etc/svp-ca/ca.crt -n 10 --scan --pattern svp:gw:rl:register:* " ]]; then
  fail "valkey-ops: command line '$(argv valkey-ops)'"
elif [[ $(<"$work/valkey-ops/auth") != "$ops_pw" ]]; then
  fail "valkey-ops: REDISCLI_AUTH is not SVP_VALKEY_OPS_PASSWORD"
elif no_secret valkey-ops; then
  ok "svp-valkey: valkey-cli --tls --user svp-ops on VALKEY_HOST:6379 with --cacert, password in REDISCLI_AUTH only"
fi

case_env=(VALKEY_HOST=master.svp-stg.example SVP_VALKEY_OPS_PASSWORD="$ops_pw")
run valkey-no-ca "" svp-valkey PING
if [[ $(rc valkey-no-ca) != 0 ]] || [[ $(argv valkey-no-ca) != "--tls --user svp-ops -h master.svp-stg.example -p 6379 PING " ]]; then
  fail "valkey-no-ca: command line '$(argv valkey-no-ca)', want no --cacert"
else
  ok "svp-valkey without SVP_CA_FILE: no --cacert (the system's roots)"
fi

case_env=(VALKEY_HOST=valkey SVP_VALKEY_OPS_PASSWORD="$ops_pw" SVP_AS_USER=svp-feed-service)
run valkey-as-user $'Us3rPw\nSELECT 10\n' svp-valkey
if [[ $(rc valkey-as-user) != 0 ]] || [[ $(argv valkey-as-user) != "--tls --user svp-feed-service -h valkey -p 6379 " ]]; then
  fail "valkey-as-user: exit $(rc valkey-as-user), command line '$(argv valkey-as-user)'"
elif [[ $(<"$work/valkey-as-user/auth") != Us3rPw ]]; then
  fail "valkey-as-user: REDISCLI_AUTH is not the first line of stdin"
elif [[ $(<"$work/valkey-as-user/stdin") != "SELECT 10" ]]; then
  fail "valkey-as-user: valkey-cli's stdin is '$(<"$work/valkey-as-user/stdin")', want the lines after the password"
elif no_secret valkey-as-user; then
  ok "SVP_AS_USER=svp-feed-service svp-valkey: logs in as that user with the first line of stdin, the rest reaches valkey-cli"
fi

case_env=(SVP_VALKEY_OPS_PASSWORD="$ops_pw")
refuse valkey-no-host "" "VALKEY_HOST is not set" svp-valkey PING
case_env=(VALKEY_HOST=valkey)
refuse valkey-no-ops-pw "" "SVP_VALKEY_OPS_PASSWORD is not set" svp-valkey PING
case_env=(VALKEY_HOST=valkey SVP_VALKEY_OPS_PASSWORD="$ops_pw" SVP_AS_USER=svp-web)
refuse valkey-as-user-no-pw "" "the first line of stdin must be the password of svp-web" svp-valkey PING
case_env=(VALKEY_HOST=valkey SVP_VALKEY_OPS_PASSWORD="$ops_pw" SVP_AS_USER=default)
refuse valkey-bad-user "Us3rPw"$'\n' "SVP_AS_USER is a Valkey user" svp-valkey PING

if ((failures)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all svp-kafka and svp-valkey tests passed"
