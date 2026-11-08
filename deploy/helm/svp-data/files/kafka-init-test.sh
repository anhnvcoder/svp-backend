#!/usr/bin/env bash
# Tests for deploy/kafka/kafka-init.sh (files/kafka-init.sh here) without a broker: the script runs through the real
# wrapper deploy/ops/svp-kafka, with fake Kafka tools (kafka-*.sh) and a fake sleep first on PATH. Each fake tool
# records its call, checks the client properties file the wrapper hands it (mode 600, svp-admin's SCRAM-SHA-512 login
# over SASL_SSL, the CA as PEM trust store) and keeps the topics and SCRAM credentials it was asked to make.

# Usage, from anywhere: deploy/helm/svp-data/files/kafka-init-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=$here/kafka-init.sh
ops=$(cd "$here/../../../ops" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

admin_pw=Adm1nPassw0rd
users='USER_SERVICE VIDEO_SERVICE ENGAGEMENT_SERVICE FEED_SERVICE MEDIA_WORKER KEDA OTELCOL'
topics='video.lifecycle.v1 3 604800000
media.transcodes.v1 3 604800000
user.follows.v1 3 604800000
engagement.views.v1 3 604800000
video.lifecycle.v1.dlq 1 1209600000
media.transcodes.v1.dlq 1 1209600000
user.follows.v1.dlq 1 1209600000
engagement.views.v1.dlq 1 1209600000'
# The ACLs kafka-init must add, one per line as "<principal> <operation> <resource args>", in its order.
acls='User:svp-admin All --cluster
User:svp-admin All --topic *
User:svp-admin All --group *
User:svp-admin All --transactional-id *
User:svp-user-service Write --topic user.follows.v1
User:svp-video-service Write --topic video.lifecycle.v1 --topic media.transcodes.v1.dlq
User:svp-video-service Read --topic media.transcodes.v1
User:svp-video-service Read --group video-service
User:svp-engagement-service Write --topic engagement.views.v1 --topic engagement.views.v1.dlq
User:svp-engagement-service Read --topic engagement.views.v1
User:svp-engagement-service Read --group engagement-service
User:svp-feed-service Write --topic user.follows.v1.dlq --topic video.lifecycle.v1.dlq
User:svp-feed-service Read --topic user.follows.v1 --topic video.lifecycle.v1
User:svp-feed-service Read --group feed-service
User:svp-media-worker Write --topic media.transcodes.v1 --topic video.lifecycle.v1.dlq
User:svp-media-worker Read --topic video.lifecycle.v1
User:svp-media-worker Read --group media-worker
User:svp-keda Describe --topic video.lifecycle.v1
User:svp-keda Describe --group media-worker
User:svp-otelcol Describe --topic video.lifecycle.v1 --topic media.transcodes.v1 --topic user.follows.v1 --topic engagement.views.v1 --topic video.lifecycle.v1.dlq --topic media.transcodes.v1.dlq --topic user.follows.v1.dlq --topic engagement.views.v1.dlq
User:svp-otelcol Describe --group video-service --group engagement-service --group feed-service --group media-worker'

mkdir -p "$work/bin"
# The fake tools, one script under every name. $FAKE_STATE/calls: "<tool> <args>" per call, the properties file's path
# replaced by PROPS. $FAKE_STATE/topics: "<name> <partitions> <retention.ms>". $FAKE_STATE/scram: "<user> <password>".
# $FAKE_STATE/login-failures: how many broker-api-versions calls still fail. $FAKE_STATE/configs-fail: configs fails
# naming the credential with its value, as kafka-configs does.
cat >"$work/bin/fake-kafka-tool" <<'EOF'
#!/usr/bin/env bash
# No -u: bash 3.2 of macOS calls an empty array unbound.
set -eo pipefail
s=$FAKE_STATE
tool=$(basename "$0" .sh)
tool=${tool#kafka-}
args=("$@")
[[ ${args[0]} == --bootstrap-server && ${args[1]} == kafka:9096 && ${args[2]} == --command-config ]] ||
  { echo "fake $tool: want --bootstrap-server kafka:9096 --command-config FILE first, got: ${args[*]:0:3}" >&2; exit 3; }
props=${args[3]}
[[ $(stat -c %a "$props" 2>/dev/null || stat -f %Lp "$props") == 600 ]] || { echo "fake $tool: properties file not mode 600" >&2; exit 3; }
want="security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"svp-admin\" password=\"$FAKE_ADMIN_PW\";
ssl.truststore.type=PEM
ssl.truststore.location=/etc/svp-ca/ca.crt"
[[ $(<"$props") == "$want" ]] || { echo "fake $tool: unexpected client properties" >&2; exit 3; }
echo "$props" >>"$s/props-files"
rest=("${args[@]:4}")
printf '%s %s\n' "$tool" "${rest[*]}" >>"$s/calls"
for a in "$@"; do
  [[ $a != *"$FAKE_ADMIN_PW"* && $a != *PwOf* ]] || { echo "fake $tool: a password on the command line" >&2; exit 3; }
done
touch "$s/topics" "$s/scram"
case $tool in
  broker-api-versions)
    n=$(cat "$s/login-failures" 2>/dev/null || echo 0)
    if ((n > 0)); then
      echo $((n - 1)) >"$s/login-failures"
      echo "Authentication failed during authentication due to invalid credentials" >&2
      exit 1
    fi
    ;;
  acls) ;;
  topics)
    name="" partitions="" retention="" exists_ok=false
    set -- "${rest[@]}"
    while (($#)); do
      case $1 in
        --create) shift ;;
        --if-not-exists) exists_ok=true; shift ;;
        --topic) name=$2; shift 2 ;;
        --partitions) partitions=$2; shift 2 ;;
        --config) retention=${2#retention.ms=}; shift 2 ;;
        *) echo "fake topics: unexpected argument $1" >&2; exit 2 ;;
      esac
    done
    if grep -q "^$name " "$s/topics"; then
      "$exists_ok" || { echo "Topic '$name' already exists." >&2; exit 1; }
    else
      echo "$name $partitions $retention" >>"$s/topics"
    fi
    ;;
  configs)
    [[ ${rest[*]} =~ ^--alter\ --entity-type\ users\ --entity-name\ (svp-[a-z-]+)\ --add-config-file\ (.+)$ ]] ||
      { echo "fake configs: unexpected call ${rest[*]}" >&2; exit 2; }
    user=${BASH_REMATCH[1]} file=${BASH_REMATCH[2]}
    [[ $(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file") == 600 ]] || { echo "fake configs: credential file not mode 600" >&2; exit 3; }
    line=$(<"$file")
    if [[ -e $s/configs-fail ]]; then
      echo "Invalid credential property ${line/SCRAM-SHA-512/SCRAM_SHA_512}" >&2
      exit 1
    fi
    [[ $line =~ ^SCRAM-SHA-512=password=([A-Za-z0-9]+)$ ]] || { echo "fake configs: bad credential line" >&2; exit 2; }
    grep -v "^$user " "$s/scram" >"$s/scram.new" || true
    echo "$user ${BASH_REMATCH[1]}" >>"$s/scram.new"
    mv "$s/scram.new" "$s/scram"
    ;;
  *) echo "fake: unexpected tool $tool" >&2; exit 2 ;;
esac
EOF
chmod +x "$work/bin/fake-kafka-tool"
for t in acls topics configs broker-api-versions; do ln -s fake-kafka-tool "$work/bin/kafka-$t.sh"; done
cat >"$work/bin/sleep" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/sleeps"
EOF
chmod +x "$work/bin/sleep"

# run CASE [VAR=VALUE...]: runs the script in a fresh state folder $work/CASE (kept files first), with svp-admin's and
# every user's password set (PwOf<USER without _>, which the fakes look for on command lines); the VAR=VALUE pairs
# come last, so they override. Output in $work/CASE/out, exit status in $work/CASE/rc.
run() {
  local case=$1 envs=() u unset_vars=()
  shift
  # None of the variables the script reads comes from the caller's environment.
  for u in KAFKA_BROKERS SVP_CA_FILE SVP_KAFKA_ADMIN_PASSWORD SVP_KAFKA_CREATE_USERS SVP_KAFKA_LOGIN_WAIT_SECONDS SVP_AS_USER; do unset_vars+=(-u "$u"); done
  mkdir -p "$work/$case/tmp"
  for u in $users; do envs+=("SVP_KAFKA_${u}_PASSWORD=PwOf${u//_/}"); done
  set +e
  env "${unset_vars[@]}" PATH="$ops:$work/bin:/usr/bin:/bin" TMPDIR="$work/$case/tmp" FAKE_STATE="$work/$case" \
    FAKE_ADMIN_PW="$admin_pw" KAFKA_BROKERS=kafka:9096 SVP_CA_FILE=/etc/svp-ca/ca.crt SVP_KAFKA_ADMIN_PASSWORD="$admin_pw" \
    SVP_KAFKA_CREATE_USERS=true "${envs[@]}" "$@" bash "$script" >"$work/$case/out" 2>&1
  echo $? >"$work/$case/rc"
  set -e
}
rc() { cat "$work/$1/rc"; }
passed() {
  [[ $(rc "$1") == 0 ]] || {
    cat "$work/$1/out" >&2
    fail "$1: kafka-init.sh exited $(rc "$1")"
    return 1
  }
}
# calls CASE TOOL: the recorded calls of TOOL in CASE, without the tool's name.
calls() { sed -n "s/^$2 //p" "$work/$1/calls"; }
# added_acls CASE: the ACLs added in CASE, as in $acls.
added_acls() {
  calls "$1" acls | sed -E 's/^--add --allow-principal ([^ ]+) --operation ([^ ]+) --resource-pattern-type literal /\1 \2 /'
}
no_password_out() {
  ! grep -q -e "$admin_pw" -e PwOf "$work/$1/out" || { fail "$1: a password in the script's output"; return 1; }
}
no_props_left() {
  [[ -z $(find "$work/$1/tmp" -mindepth 1) ]] || { fail "$1: files left in TMPDIR"; return 1; }
}

if run fresh && passed fresh; then
  if [[ $(sort "$work/fresh/topics") != "$(sort <<<"$topics")" ]]; then
    fail "fresh: topics made: $(tr '\n' ';' <"$work/fresh/topics"), want the 8 topics with their partitions and retention"
  elif calls fresh topics | grep -q -e --replication-factor -e --replica-assignment; then
    fail "fresh: a topic was created with a replication factor; topics take the broker's default"
  elif [[ $(added_acls fresh) != "$acls" ]]; then
    fail "fresh: ACLs added, in order: $(added_acls fresh | tr '\n' ';'), want the ACL table of kafka-init.sh"
  elif [[ $(sed -n 1p "$work/fresh/calls") != broker-api-versions* ]] ||
    [[ $(sed -n 2,5p "$work/fresh/calls" | cut -d' ' -f1 | sort -u) != acls ]]; then
    fail "fresh: the first calls are not the login check and then the four ACLs of svp-admin"
  elif [[ $(sort "$work/fresh/scram") != "$(for u in $users; do
    n=$(tr 'A-Z_' 'a-z-' <<<"$u")
    echo "svp-$n PwOf${u//_/}"
  done | sort)" ]]; then
    fail "fresh: SCRAM credentials set: $(cut -d' ' -f1 "$work/fresh/scram" | tr '\n' ' '), want the 7 users with their passwords"
  elif no_password_out fresh && no_props_left fresh; then
    ok "SVP_KAFKA_CREATE_USERS=true: login check, svp-admin's ACLs first, 8 topics without replication factor, 7 users, the ACL table; logged in as svp-admin from a 600 file, removed after, no password on a command line or in the output"
  fi
fi

if run no-users SVP_KAFKA_CREATE_USERS=false && passed no-users; then
  if [[ -n $(calls no-users configs) ]]; then
    fail "no-users: kafka-configs was called: $(calls no-users configs | head -1)"
  elif [[ $(added_acls no-users) != "$acls" ]]; then
    fail "no-users: the ACL table was not added as with users"
  else
    ok "SVP_KAFKA_CREATE_USERS=false (MSK): no user made, the same topics and ACLs"
  fi
fi

mkdir -p "$work/again"
echo "${topics// 3 / 6 }" >"$work/again/topics"
if run again && passed again; then
  if [[ $(<"$work/again/topics") != "${topics// 3 / 6 }" ]]; then
    fail "again: existing topics changed"
  elif [[ $(calls again topics | grep -c -- '--if-not-exists') != 8 ]]; then
    fail "again: a topic create without --if-not-exists"
  else
    ok "run again on existing topics (other partitions): no failure, every topic left as it is"
  fi
fi

mkdir -p "$work/slow-login"
echo 2 >"$work/slow-login/login-failures"
if run slow-login && passed slow-login; then
  if [[ $(grep -c '^broker-api-versions' "$work/slow-login/calls") != 3 || $(wc -l <"$work/slow-login/sleeps") -ne 2 ]]; then
    fail "slow-login: $(grep -c '^broker-api-versions' "$work/slow-login/calls") login checks and $(wc -l <"$work/slow-login/sleeps" | tr -d ' ') sleeps, want 3 and 2"
  else
    ok "svp-admin refused twice (a SCRAM secret not on MSK yet): waits 5 s and tries again, then goes on"
  fi
fi

mkdir -p "$work/no-login"
echo 1000 >"$work/no-login/login-failures"
run no-login
if [[ $(rc no-login) == 0 ]]; then
  fail "no-login: exit 0 though svp-admin never logged in"
elif [[ $(grep -c '^broker-api-versions' "$work/no-login/calls") != 120 ]] || grep -qv '^broker-api-versions' "$work/no-login/calls"; then
  fail "no-login: $(grep -c '^broker-api-versions' "$work/no-login/calls") login checks or other calls, want 120 login checks (10 minutes) and nothing else"
elif ! grep -q 'could not log in to kafka:9096 within 600 s;.*(compose: make clean-data)' "$work/no-login/out"; then
  fail "no-login: no message naming the broker, the wait and make clean-data"
else
  ok "svp-admin never logs in, SVP_KAFKA_LOGIN_WAIT_SECONDS unset: fails after 120 tries (10 minutes), naming make clean-data, nothing else done"
fi

mkdir -p "$work/short-wait"
echo 1000 >"$work/short-wait/login-failures"
run short-wait SVP_KAFKA_LOGIN_WAIT_SECONDS=60
if [[ $(rc short-wait) == 0 ]]; then
  fail "short-wait: exit 0 though svp-admin never logged in"
elif [[ $(grep -c '^broker-api-versions' "$work/short-wait/calls") != 12 ]]; then
  fail "short-wait: $(grep -c '^broker-api-versions' "$work/short-wait/calls") login checks, want 12 (60 s)"
elif ! grep -q 'within 60 s;' "$work/short-wait/out"; then
  fail "short-wait: the message does not name the 60 s wait"
else
  ok "SVP_KAFKA_LOGIN_WAIT_SECONDS=60 (compose): fails after 12 tries"
fi

for value in 0 1m; do
  run "wait-$value" SVP_KAFKA_LOGIN_WAIT_SECONDS="$value"
  if [[ $(rc "wait-$value") == 0 ]] || [[ -s $work/wait-$value/calls ]] ||
    ! grep -q 'SVP_KAFKA_LOGIN_WAIT_SECONDS must be a whole number' "$work/wait-$value/out"; then
    fail "SVP_KAFKA_LOGIN_WAIT_SECONDS='$value': not refused before any Kafka call"
  else
    ok "SVP_KAFKA_LOGIN_WAIT_SECONDS='$value': refused before any Kafka call"
  fi
done

run missing-pw SVP_KAFKA_KEDA_PASSWORD=
if [[ $(rc missing-pw) == 0 ]]; then
  fail "missing-pw: exit 0 with SVP_KAFKA_KEDA_PASSWORD empty"
elif ! grep -q 'SVP_KAFKA_KEDA_PASSWORD, the password of svp-keda' "$work/missing-pw/out"; then
  fail "missing-pw: the message does not name SVP_KAFKA_KEDA_PASSWORD"
elif grep -q '^configs.*svp-keda' "$work/missing-pw/calls"; then
  fail "missing-pw: svp-keda was set without a password"
else
  ok "a user's password empty: fails naming its variable, before setting that user"
fi

run bad-pw 'SVP_KAFKA_KEDA_PASSWORD=a"b'
if [[ $(rc bad-pw) == 0 ]] || ! grep -q 'holds a character other than a letter or digit' "$work/bad-pw/out"; then
  fail "bad-pw: a password with a quote was not refused"
else
  ok "a password with a character other than a letter or digit: refused"
fi

mkdir -p "$work/configs-fail"
touch "$work/configs-fail/configs-fail"
run configs-fail
if [[ $(rc configs-fail) == 0 ]]; then
  fail "configs-fail: exit 0 though kafka-configs failed"
elif ! grep -q 'Invalid credential property SCRAM_SHA_512=password=<password>' "$work/configs-fail/out"; then
  fail "configs-fail: kafka-configs' message not printed with the password masked"
elif no_password_out configs-fail && no_props_left configs-fail; then
  ok "kafka-configs fails naming the credential: its message printed with the password masked, nothing left in TMPDIR"
fi

for value in "" yes; do
  run "create-users-$value" SVP_KAFKA_CREATE_USERS="$value"
  if [[ $(rc "create-users-$value") == 0 ]] || [[ -s $work/create-users-$value/calls ]]; then
    fail "SVP_KAFKA_CREATE_USERS='$value': not refused before any Kafka call"
  else
    ok "SVP_KAFKA_CREATE_USERS='$value': refused before any Kafka call"
  fi
done

if ((failures)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all kafka-init.sh tests passed"
