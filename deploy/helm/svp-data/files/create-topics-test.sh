#!/usr/bin/env bash
# Tests for deploy/redpanda/create-topics.sh (files/create-topics.sh here, the script the init Job of this chart and
# compose's redpanda-init run) without a broker: a fake rpk first on PATH records each call and keeps the topics it
# was asked to create, with their replicas, in a file, as rpk does with --if-not-exists (an existing topic is left as
# it is, the call succeeds). Cases:
#   - TOPIC_REPLICAS unset: every topic is created with -r 1;
#   - TOPIC_REPLICAS=3: every topic is created with -r 3;
#   - topics that exist with one replica, TOPIC_REPLICAS=3: no call creates them without --if-not-exists, no call
#     alters a topic or its partitions, and each keeps its one replica.
#
# Usage, from anywhere: deploy/helm/svp-data/files/create-topics-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=$here/create-topics.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

topics='video.lifecycle.v1 media.transcodes.v1 user.follows.v1 engagement.views.v1
video.lifecycle.v1.dlq media.transcodes.v1.dlq user.follows.v1.dlq engagement.views.v1.dlq'

mkdir -p "$work/bin"
# The fake rpk. $FAKE_STATE/rpk.log: one line per call. $FAKE_STATE/topics: "<name> <replicas>" per topic.
cat >"$work/bin/rpk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
s=$FAKE_STATE
printf '%s\n' "$*" >>"$s/rpk.log"
touch "$s/topics"
case "$1 $2" in
  "topic create")
    name=$3 replicas="" exists_ok=false
    shift 3
    while (($#)); do
      case $1 in
        -r) replicas=$2; shift 2 ;;
        -p | -c) shift 2 ;;
        --if-not-exists) exists_ok=true; shift ;;
        *) echo "fake rpk: unexpected flag $1" >&2; exit 2 ;;
      esac
    done
    if grep -q "^$name " "$s/topics"; then
      # rpk prints TOPIC_ALREADY_EXISTS in its result table and fails, unless --if-not-exists.
      "$exists_ok" || { echo "$name TOPIC_ALREADY_EXISTS"; exit 1; }
    else
      echo "$name $replicas" >>"$s/topics"
    fi
    echo "$name OK"
    ;;
  "cluster config") ;;
  *) echo "fake rpk: unexpected call: $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$work/bin/rpk"

# run CASE [VAR=VALUE...]: runs the script with the fake rpk in a fresh state folder $work/CASE (kept topics first).
run() {
  local case=$1
  shift
  mkdir -p "$work/$case"
  if ! env -u TOPIC_REPLICAS "$@" PATH="$work/bin:$PATH" FAKE_STATE="$work/$case" bash "$script" >"$work/$case/out" 2>&1; then
    cat "$work/$case/out" >&2
    fail "$case: create-topics.sh exited non-zero"
    return 1
  fi
}

# expect_replicas CASE N: every topic the fake holds in CASE has N replicas.
expect_replicas() {
  local case=$1 want=$2 t line
  for t in $topics; do
    line=$(grep "^$t " "$work/$case/topics" || true)
    [ "$line" = "$t $want" ] || {
      fail "$case: topic $t has '${line#"$t "}' replicas, want $want"
      return 1
    }
  done
}

# every_create_has CASE PATTERN: each "topic create" call of CASE matches PATTERN (a grep -E expression).
every_create_has() {
  local case=$1 pattern=$2 creates
  creates=$(grep -c '^topic create ' "$work/$case/rpk.log")
  [ "$creates" -eq 8 ] || { fail "$case: $creates topic create calls, want 8"; return 1; }
  [ "$(grep '^topic create ' "$work/$case/rpk.log" | grep -cE -- "$pattern")" -eq 8 ] || {
    fail "$case: a topic create call lacks $pattern: $(grep '^topic create ' "$work/$case/rpk.log" | grep -vE -- "$pattern" | head -1)"
    return 1
  }
}

if run default && every_create_has default ' -r 1 ' && expect_replicas default 1; then
  ok "TOPIC_REPLICAS unset: the 8 topics are created with -r 1"
fi

if run three TOPIC_REPLICAS=3 && every_create_has three ' -r 3 ' && expect_replicas three 3; then
  ok "TOPIC_REPLICAS=3: the 8 topics are created with -r 3"
fi

mkdir -p "$work/existing"
for t in $topics; do echo "$t 1"; done >"$work/existing/topics"
if run existing TOPIC_REPLICAS=3 && every_create_has existing ' --if-not-exists( |$)' && expect_replicas existing 1; then
  if grep -vE '^(topic create |cluster config set )' "$work/existing/rpk.log" | grep -q .; then
    fail "existing topics: a call other than topic create --if-not-exists and cluster config set: $(grep -vE '^(topic create |cluster config set )' "$work/existing/rpk.log" | head -1)"
  elif [ "$(wc -l <"$work/existing/topics")" -ne 8 ]; then
    fail "existing topics: the fake holds $(wc -l <"$work/existing/topics") topics, want 8"
  else
    ok "existing topics with 1 replica, TOPIC_REPLICAS=3: only create --if-not-exists, no alter, each keeps 1 replica"
  fi
fi

if ((failures)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all create-topics.sh tests passed"
