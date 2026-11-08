# shellcheck shell=bash
# Helpers of the observability drill (obs-threats.sh): docker compose through the command `make` passes in $COMPOSE,
# stopping and recreating a service with drill-only settings, uploading a video, read-only queries to the stack of
# `make up OBS=lgtm`, and putting the stack back on exit. Written for bash 3.2.
# Source it after setting `base` (the gateway URL); it sources ../lib.sh, whose rules it keeps.

# shellcheck source=deploy/compose/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[[ -n ${COMPOSE:-} ]] || fail "COMPOSE is not set; run the drills through make"
read -r -a compose_cmd <<<"$COMPOSE"

# Every service a drill may stop or kill; on exit they are all started again.
stack_services=(kafka s3 user-service video-service engagement-service feed-service gateway media-worker)

compose() { "${compose_cmd[@]}" "$@"; }

# A stack from `make up IMAGES=stg` runs releases pulled from GHCR. A drill starts services again with
# compose alone, without the image variables make up exported, so compose would build those services from
# the working tree and the stack would quietly stop running the releases: refuse before anything changes.
release_services=$(compose ps --format '{{.Service}} {{.Image}}' "${stack_services[@]}") ||
  fail "list the containers of the stack (compose ps)"
release_services=$(awk '$2 ~ /^ghcr\.io\// { printf "%s%s", sep, $1; sep = " " }' <<<"$release_services")
[[ -z $release_services ]] ||
  fail "the stack runs releases from GHCR ($release_services; make up IMAGES=stg), which a drill would replace with builds of the working tree: make down, then make up without IMAGES, and run the drill again"

# restore_stack: starts every stack service that is not running and recreates every one whose
# settings differ from compose.yaml (a service a drill recreated with drill-only settings goes
# back to the defaults, since those variables are never exported); prints ok, or FAIL and
# returns 1.
restore_stack() {
  if compose up -d --no-deps --wait "${stack_services[@]}" >"$work/restore.log" 2>&1; then
    echo "ok    stack running again (${stack_services[*]})"
  else
    echo "FAIL  restore the stack: compose up --wait failed (see make ps / make logs)" >&2
    return 1
  fi
}

# drill_exit: the EXIT trap. Restores the stack, removes $work, and keeps the script's exit
# status (1 when the stack cannot be restored).
drill_exit() {
  local rc=$?
  trap - EXIT
  restore_stack || rc=1
  rm -rf "$work"
  exit "$rc"
}
trap drill_exit EXIT

# now: seconds since the epoch with milliseconds (bash 3.2 has no EPOCHREALTIME).
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# check_uuid VALUE: fails unless VALUE is a UUID (it goes into SQL and grep patterns).
check_uuid() {
  [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "video id is a UUID (got '$1')"
}

# upload_video NAME AUTH_FILE FILE: creates video NAME for FILE, uploads it through the presigned
# form and completes it (202 PROCESSING); sets <NAME>_id like create_video.
upload_video() {
  local name=$1 size status id_var="${1}_id"
  size=$(file_size "$3")
  create_video "$name" "$2" "drill $name $(openssl rand -hex 4)" "$size" video/mp4
  check_uuid "${!id_var}"
  status=$(upload_file "$name" "$3")
  [[ $status == 2?? ]] || fail "upload video $name to the presigned form (status $status, code $(storage_error_code))"
  status=$(complete_upload "$name" "$2")
  [[ $status == 202 && $(field status) == PROCESSING ]] ||
    fail "complete video $name is 202 PROCESSING (status $status, $(problem_summary), video status $(field status))"
}

# start_service SERVICE: starts SERVICE again and waits until it is running (healthy when it has
# a healthcheck).
start_service() {
  compose up -d --no-deps --wait "$1" >/dev/null 2>&1 || fail "start $1 again"
}

# recreate_service SERVICE [VAR=VALUE...]: recreates SERVICE alone with the compose variables given
# (none: the defaults of compose.yaml) and waits until it is healthy. The variables reach this one
# compose call only.
recreate_service() {
  local service=$1
  shift
  env "$@" "${compose_cmd[@]}" up -d --no-deps --wait "$service" >"$work/recreate.log" 2>&1 ||
    fail "recreate $service${1:+ with $*}: $(tail -n 1 "$work/recreate.log") (see make logs SVC=$service)"
}

# Read-only access to the stack of `make up OBS=lgtm`. Prometheus, Tempo and Loki are reached through Grafana's
# datasource proxy, since their own ports are not published; Alertmanager and GlitchTip through their loopback ports.
# The GlitchTip API token (read-only: event:read, project:read) is read from .env into a shell variable that is never
# exported, printed, written to a file or put on a command line: the printf builtin writes the header to curl's stdin.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
env_file=$repo_root/.env
grafana_url=http://127.0.0.1:3000
proxy_url=$grafana_url/api/datasources/proxy/uid
alertmanager_url=http://127.0.0.1:9093
# Lines a Loki query may return; a query that reaches it fails, since lines would be missing.
loki_limit=5000
sentry_api_url=
sentry_org=
sentry_project=
sentry_token=
sentry_status=
# jq function: an RFC 3339 UTC time ("2026-10-17T05:00:05.200Z", fraction optional) in seconds
# since the epoch, with the fraction.
jq_epoch='def epoch: capture("^(?<s>[^.Z]+)(?<f>[.][0-9]+)?Z$") | ((.s + "Z") | fromdateiso8601) + (("0" + (.f // "")) | tonumber);'

# obs_get URL OUT [CURL_ARGS...]: GET URL into OUT; CURL_ARGS such as --data-urlencode NAME=VALUE
# become the query string. Prints the HTTP status (000 when nothing answered).
obs_get() {
  local url=$1 out=$2
  shift 2
  : >"$out"
  curl -sS -G --max-time "$max_time" -o "$out" -w '%{http_code}' "$@" "$url" || true
}

# prom_query EXPR: an instant PromQL query; the response stays in $work/prom.json and prom_value
# is set to the value of its first sample ("" when the result is empty). It sets a variable instead
# of printing because `fail` inside $(...) would only end the subshell; call it as a plain command.
prom_query() {
  local status
  status=$(obs_get "$proxy_url/prometheus/api/v1/query" "$work/prom.json" --data-urlencode "query=$1")
  [[ $status == 200 && $(jq -r '.status' "$work/prom.json" 2>/dev/null) == success ]] ||
    fail "Prometheus query through Grafana is 200 (status $status): $1"
  prom_value=$(jq -r '.data.result[0].value[1] // ""' "$work/prom.json")
}

# loki_query LOGQL START END: the log lines of LOGQL between START and END (seconds since the
# epoch), oldest first, into $work/loki.json as an array of objects: the stream's labels and
# structured metadata (service_name, trace_id, user_id, status, ...) plus `line`, the log message.
loki_query() {
  local status n
  status=$(obs_get "$proxy_url/loki/loki/api/v1/query_range" "$work/loki-raw.json" --data-urlencode "query=$1" \
    --data-urlencode "start=${2%.*}000000000" --data-urlencode "end=$((${3%.*} + 1))000000000" \
    --data-urlencode "limit=$loki_limit" --data-urlencode direction=forward)
  [[ $status == 200 && $(jq -r '.status' "$work/loki-raw.json" 2>/dev/null) == success ]] ||
    fail "Loki query through Grafana is 200 (status $status): $1"
  jq '[.data.result[] | .stream as $s | .values[] | $s + {line: .[1], ts: .[0]}] | sort_by(.ts)' \
    "$work/loki-raw.json" >"$work/loki.json"
  n=$(jq length "$work/loki.json")
  ((n < loki_limit)) || fail "Loki query returned $n lines, its limit; lines would be missing: $1"
}

# tempo_search TRACEQL START END: the traces matching TRACEQL between START and END (seconds since the epoch) into
# $work/tempo-traces, one "START_SECONDS TRACE_ID" line each, oldest first. Trace ids are padded to 32 hex digits:
# Tempo drops leading zeros, logs and GlitchTip keep them. Tempo answers 400 "start must be before end" when START is
# exactly 30 s before its now (it splits the range there); a second later the search works, so that answer is retried.
tempo_search() {
  local status try
  for try in 1 2 3; do
    status=$(obs_get "$proxy_url/tempo/api/search" "$work/tempo-search.json" --data-urlencode "q=$1" \
      --data-urlencode "start=${2%.*}" --data-urlencode "end=$((${3%.*} + 1))" --data-urlencode limit=1000)
    [[ $status == 400 ]] && grep -q 'start must be before end' "$work/tempo-search.json" || break
    sleep 1
  done
  [[ $status == 200 ]] ||
    fail "Tempo search through Grafana is 200 (status $status: $(head -c 200 "$work/tempo-search.json" | tr '\n' ' ')): $1"
  jq -r '.traces[]? | "\(.startTimeUnixNano) \(.traceID)"' "$work/tempo-search.json" |
    awk '$2 ~ /^[0-9a-f]+$/ { id = $2; while (length(id) < 32) id = "0" id; printf "%.6f %s\n", $1 / 1e9, id }' |
    sort -n >"$work/tempo-traces"
}

# tempo_trace TRACE_ID OUT: the whole trace from Tempo into OUT; prints the HTTP status (404 while
# Tempo has not ingested it yet).
tempo_trace() { obs_get "$proxy_url/tempo/api/traces/$1" "$2"; }

# am_alerts ALERTNAME SEVERITY: the alerts with that name and severity that Alertmanager holds (in
# any state; resolved ones are gone) into $work/alerts.json, each with `starts`, its startsAt in
# seconds since the epoch.
am_alerts() {
  local status
  status=$(obs_get "$alertmanager_url/api/v2/alerts" "$work/alerts-raw.json" \
    --data-urlencode "filter=alertname=\"$1\"" --data-urlencode "filter=severity=\"$2\"")
  [[ $status == 200 ]] || fail "Alertmanager GET /api/v2/alerts is 200 (status $status)"
  jq "$jq_epoch"' [.[] | . + {starts: (.startsAt | epoch)}]' "$work/alerts-raw.json" >"$work/alerts.json"
}

# wait_alert_gone ALERTNAME SEVERITY TIMEOUT: waits until Alertmanager holds no such alert, printing
# its progress every minute, so that the alert a drill then checks is a new one; fails after
# TIMEOUT seconds.
wait_alert_gone() {
  local start=$SECONDS next=0
  while :; do
    am_alerts "$1" "$2"
    [[ $(jq length "$work/alerts.json") == 0 ]] && return 0
    ((SECONDS - start < $3)) ||
      fail "$1 ($2) from an earlier run resolved in Alertmanager within $3 s (still active; run the drill again later)"
    if ((SECONDS - start >= next)); then
      echo "wait  $1 ($2) from an earlier run still active after $((SECONDS - start)) s; waiting for it to resolve (at most $3 s)"
      next=$((next + 60))
    fi
    sleep 15
  done
}

# wait_alert_new ALERTNAME SEVERITY SINCE TIMEOUT: polls Alertmanager every 5 s until it holds such
# an alert with startsAt after SINCE (seconds since the epoch) and sets alert_starts to that
# startsAt; returns 1 after TIMEOUT seconds, so the caller can say why before failing.
wait_alert_new() {
  local deadline=$((SECONDS + $4))
  while :; do
    am_alerts "$1" "$2"
    alert_starts=$(jq -r --argjson t "$3" '[.[] | select(.starts > $t) | .starts] | min // ""' "$work/alerts.json")
    [[ -n $alert_starts ]] && return 0
    ((SECONDS < deadline)) || return 1
    sleep 5
  done
}

# recent_5xx_expr SELECTOR: PromQL for the 5xx that the gateway HTTP count series of SELECTOR (with
# a 5xx status matcher) shows in the last 60 s: the increase of every series, plus every series
# that appeared meanwhile, since the first sample of a new series already holds errors that
# increase() does not count.
recent_5xx_expr() {
  printf '(sum(increase(%s[60s])) or vector(0)) + (sum(%s unless %s offset 60s) or vector(0))' "$1" "$1" "$1"
}

# wait_quiet_5xx SELECTOR SECONDS TIMEOUT: waits until Prometheus has shown no new 5xx in SELECTOR
# for SECONDS in a row (polling every 5 s), so that the error tracker's limit of one event per
# fingerprint per 30 s cannot hold back the event of the next error; fails
# after TIMEOUT seconds. A 5xx not yet exported (at most 15 s old) cannot be seen this way.
wait_quiet_5xx() {
  local start=$SECONDS quiet_since=
  while :; do
    prom_query "$(recent_5xx_expr "$1")"
    if awk -v v="$prom_value" 'BEGIN { exit !(v + 0 == 0) }'; then
      quiet_since=${quiet_since:-$SECONDS}
      ((SECONDS - quiet_since >= $2)) && return 0
    else
      quiet_since=
    fi
    ((SECONDS - start < $3)) || fail "no new 5xx in Prometheus for $2 s in a row within $3 s ($1)"
    sleep 5
  done
}

# sentry_init: reads SENTRY_API_URL, SENTRY_ORG, SENTRY_PROJECT and SENTRY_AUTH_TOKEN from .env
# with the strict rule of deploy/observability/glitchtip/dotenv.sh; fails naming the first one
# missing or empty, never printing a value.
sentry_init() {
  local v
  # shellcheck source=deploy/observability/glitchtip/dotenv.sh
  . "$repo_root/deploy/observability/glitchtip/dotenv.sh"
  for v in SENTRY_API_URL SENTRY_ORG SENTRY_PROJECT SENTRY_AUTH_TOKEN; do
    [[ -n $(dotenv_value "$env_file" "$v") ]] ||
      fail "$v is missing or empty in .env; run make up OBS=lgtm (or make glitchtip-init) first"
  done
  sentry_api_url=$(dotenv_value "$env_file" SENTRY_API_URL)
  sentry_org=$(dotenv_value "$env_file" SENTRY_ORG)
  sentry_project=$(dotenv_value "$env_file" SENTRY_PROJECT)
  sentry_token=$(dotenv_value "$env_file" SENTRY_AUTH_TOKEN)
  # Another port on the loopback can be an SSH tunnel to another machine: only GlitchTip's own.
  [[ $sentry_api_url == http://127.0.0.1:8000 ]] ||
    fail "SENTRY_API_URL in .env is the local GlitchTip (http://127.0.0.1:8000); the drills send its token nowhere else"
  [[ $sentry_org =~ ^[a-z0-9-]+$ && $sentry_project =~ ^[a-z0-9-]+$ ]] ||
    fail "SENTRY_ORG and SENTRY_PROJECT in .env are slugs"
}

# sentry_get PATH OUT: GET PATH (under SENTRY_API_URL, or a full URL there such as a next page)
# with the drill token into OUT, the response headers into $work/sentry.headers; sets
# sentry_status. A 401 or 403 fails: the token is wrong or lacks its scopes.
sentry_get() {
  local url=$1
  [[ $url == http* ]] || url=$sentry_api_url$url
  [[ $url == "$sentry_api_url"/* ]] || fail "GlitchTip API URL stays under SENTRY_API_URL (got another host)"
  : >"$2"
  sentry_status=$(printf 'Authorization: Bearer %s\n' "$sentry_token" |
    curl -sS --max-time "$max_time" -H @- -o "$2" -D "$work/sentry.headers" -w '%{http_code}' "$url" || true)
  case $sentry_status in
    401 | 403)
      fail "GlitchTip API answered $sentry_status: SENTRY_AUTH_TOKEN in .env is wrong or lacks the event:read and project:read scopes"
      ;;
  esac
}

# sentry_next_page: the next page's URL from the Link header of the last sentry_get, "" on the last
# page.
sentry_next_page() {
  { tr -d '\r' <"$work/sentry.headers" | grep -i '^link:' | grep -o '<[^>]*>; rel="next"; results="true"' || true; } |
    sed 's/^<\([^>]*\)>.*/\1/' | head -n 1
}

# sentry_find_event TRACE_ID: looks for the GlitchTip event tagged with TRACE_ID: the issues whose
# tags hold it, then their events, page by page, for the one with that trace_id tag (an issue's
# newest event need not be it). Sets sentry_event (its event id), sentry_issue and sentry_link
# (the issue's page), all "" when there is none yet.
sentry_find_event() {
  local issue url page
  sentry_event=
  sentry_issue=
  sentry_link=
  sentry_get "/api/0/projects/$sentry_org/$sentry_project/issues/?query=trace_id%3A$1" "$work/sentry-issues.json"
  [[ $sentry_status == 200 ]] || fail "GlitchTip issue search by trace_id is 200 (status $sentry_status)"
  for issue in $(jq -r '.[].id | select(test("^[0-9]+$"))' "$work/sentry-issues.json"); do
    url="/api/0/issues/$issue/events/"
    for ((page = 0; page < 20; page++)); do
      sentry_get "$url" "$work/sentry-events.json"
      [[ $sentry_status == 200 ]] || fail "GlitchTip events of issue $issue is 200 (status $sentry_status)"
      sentry_event=$(jq -r --arg t "$1" \
        'first(.[] | select(any(.tags[]?; .key == "trace_id" and .value == $t)) | .event_id) // ""' "$work/sentry-events.json")
      if [[ -n $sentry_event ]]; then
        sentry_issue=$issue
        sentry_link=$(jq -r --arg i "$issue" 'first(.[] | select(.id == $i) | .permalink) // ""' "$work/sentry-issues.json")
        return 0
      fi
      url=$(sentry_next_page)
      [[ -n $url ]] || break
    done
  done
}

# sentry_event_json EVENT_ID OUT: the whole event into OUT; fails unless it is there.
sentry_event_json() {
  [[ $1 =~ ^[0-9a-f]{32}$ ]] || fail "GlitchTip event id is 32 hex digits (got '$1')"
  sentry_get "/api/0/projects/$sentry_org/$sentry_project/events/$1/" "$2"
  [[ $sentry_status == 200 ]] || fail "GlitchTip GET event $1 is 200 (status $sentry_status)"
}

# obs_preflight: the stack of `make up OBS=lgtm` answers (Grafana, Prometheus, Tempo, Loki, Alertmanager, the GlitchTip
# API), the gateway's metrics reached Prometheus within the last 45 s (waited for up to metrics_wait seconds, with the
# WARN lines of obs_report when they do not come), and .env holds SENTRY_DSN: without it the services report no error
# and a drill would wait for an event that cannot come.
obs_preflight() {
  local status age start waited=
  local age_query='time() - max(timestamp(go_goroutine_count{service_name="gateway"}))'
  status=$(obs_get "$grafana_url/api/health" "$work/obs.json")
  [[ $status == 200 ]] || fail "Grafana at $grafana_url answers (status $status); run make up OBS=lgtm"
  status=$(obs_get "$alertmanager_url/-/ready" "$work/obs.json")
  [[ $status == 200 ]] || fail "Alertmanager at $alertmanager_url is ready (status $status); run make up OBS=lgtm"
  status=$(obs_get "$proxy_url/tempo/api/echo" "$work/obs.json")
  [[ $status == 200 ]] || fail "Tempo answers through Grafana (status $status)"
  status=$(obs_get "$proxy_url/loki/loki/api/v1/labels" "$work/obs.json")
  [[ $status == 200 ]] || fail "Loki answers through Grafana (status $status)"
  prom_query "$age_query"
  age=${prom_value:-never}
  if ! metrics_fresh "$age"; then
    echo "WARN  the gateway's metrics are not in Prometheus yet (newest sample: $(sample_age "$age")); waiting up to $metrics_wait s"
    start=$SECONDS
    while ! metrics_fresh "$age" && ((SECONDS - start < metrics_wait)); do
      sleep 5
      prom_query "$age_query"
      age=${prom_value:-never}
    done
    waited=$((SECONDS - start))
    if ! metrics_fresh "$age"; then
      obs_report
      fail "the gateway's metrics reach Prometheus within $metrics_wait s (newest sample: $(sample_age "$age"); see the WARN lines above)"
    fi
  fi
  sentry_init
  [[ -n $(dotenv_value "$env_file" SENTRY_DSN) ]] ||
    fail "SENTRY_DSN is missing or empty in .env, so the services report no error; run make glitchtip-init, then make up OBS=lgtm"
  sentry_get "/api/0/projects/$sentry_org/$sentry_project/" "$work/obs.json"
  [[ $sentry_status == 200 ]] ||
    fail "GlitchTip API at $sentry_api_url answers for project $sentry_org/$sentry_project (status $sentry_status)"
  ok "observability stack up: Grafana, Prometheus, Tempo, Loki, Alertmanager, GlitchTip API (gateway metrics ${age%.*} s old${waited:+, after waiting $waited s})"
}

# Seconds obs_preflight waits for the gateway's metrics on a stack just started. The gateway exports its metrics every
# 15 s, the first time one interval after it starts, and `make up --wait` returns a few seconds after the gateway
# starts, so a drill run right after it finds no sample yet. 60 s holds four export intervals, with the Collector's
# batch (1 s) and LGTM's ingestion on top.
metrics_wait=${metrics_wait:-60}

# metrics_fresh AGE: AGE (seconds, or never) is under 45 s, the freshness the alert rules ask of
# every gauge.
metrics_fresh() { awk -v a="$1" 'BEGIN { exit !(a != "never" && a + 0 < 45) }'; }

# sample_age AGE: AGE in words, for a line.
sample_age() { if [[ $1 == never ]]; then echo "none within 5 min"; else echo "${1%.*} s old"; fi; }

docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

# obs_report: WARN lines on the path of the gateway's metrics to Prometheus: the state of otelcol, lgtm and gateway,
# counts from their logs (export failures by cause, samples Prometheus refused, refusals for memory), and the age of
# the newest go_goroutine_count sample of each Go service. Names and numbers only, never a line of a container's log:
# the verdict lines of a drill reach the public artifact of verify.yml. Never fails.
obs_report() {
  local t ids svc id line ready n f cr de dns other rej mem first last status
  t=$(now)
  ids=$(compose ps -a --format json 2>/dev/null |
    jq -rn '[inputs | if type == "array" then .[] else . end] | .[] | "\(.Service) \(.ID)"' 2>/dev/null) || ids=
  for svc in otelcol lgtm gateway; do
    id=$(awk -v s="$svc" '$1 == s { print $2; exit }' <<<"$ids")
    if [[ -z $id ]]; then
      echo "WARN  telemetry: no container of $svc"
      continue
    fi
    line=$(docker_ inspect "$id" 2>/dev/null | jq -r --argjson now "$t" "$jq_epoch"' .[0]
      | "\(.State.Status), health \(.State.Health.Status // "none"), \(.RestartCount) restart(s), started \($now - (.State.StartedAt | epoch) | floor) s ago"' \
      2>/dev/null) || line="docker inspect failed"
    case $svc in
      lgtm)
        if ready=$(docker_ exec "$id" stat -c %Y /tmp/ready 2>/dev/null) && [[ $ready =~ ^[0-9]+$ ]]; then
          line+=", /tmp/ready written $(awk -v n="$t" -v r="$ready" 'BEGIN { printf "%d", n - r }') s ago"
        else
          line+=", /tmp/ready not found or not read"
        fi
        n=$(docker_ logs "$id" 2>&1 | grep -cE 'out of order|out of bounds|too old' || :)
        line+="; $n log lines saying out of order, out of bounds or too old"
        ;;
      otelcol)
        docker_ logs --timestamps "$id" >"$work/otelcol.log" 2>&1 || :
        read -r n f cr de dns other rej mem first last <<<"$(awk '
          { n++ }
          /Exporting failed/ {
            f++
            if (first == "") first = $1
            last = $1
            if (/connection refused/) cr++
            else if (/[Dd]eadline ?[Ee]xceeded/) de++
            else if (/no such host|produced zero addresses/) dns++
            else other++
          }
          /Rejecting data|Dropping data/ { rej++ }
          /high memory usage|above soft limit/ { mem++ }
          END {
            printf "%d %d %d %d %d %d %d %d %s %s\n", n, f, cr, de, dns, other, rej, mem,
              (first == "" ? "-" : first), (last == "" ? "-" : last)
          }' "$work/otelcol.log")"
        line+="; log: $n lines, $f export failures ($cr connection refused, $de deadline exceeded, $dns name resolution, $other other; "
        line+=$(jq -rn --arg a "$first" --arg b "$last" --argjson now "$t" "$jq_epoch"'
          def ago: if . == "-" then "none" else "\($now - epoch | floor) s ago" end; "first \($a | ago), newest \($b | ago)"' \
          2>/dev/null) || line+="times unreadable"
        line+="), $rej lines rejecting or dropping data, $mem refusals for memory"
        ;;
      gateway)
        n=$(docker_ logs "$id" 2>&1 | grep -c 'telemetry export failed' || :)
        line+="; $n \"telemetry export failed\" warnings in its log"
        ;;
    esac
    echo "WARN  telemetry: $svc $line"
  done
  status=$(obs_get "$proxy_url/prometheus/api/v1/query" "$work/obs-ages.json" \
    --data-urlencode 'query=time() - max by (service_name) (timestamp(go_goroutine_count))')
  line=$(jq -r '[.data.result[] | "\(.metric.service_name) \(.value[1] | tonumber | floor) s"] | sort | join(", ")' \
    "$work/obs-ages.json" 2>/dev/null) || line=
  echo "WARN  telemetry: newest go_goroutine_count sample in Prometheus by service_name (query status $status): ${line:-none}"
  status=$(obs_get "$proxy_url/prometheus/api/v1/query" "$work/obs-names.json" \
    --data-urlencode 'query=count by (__name__) ({service_name="gateway", __name__=~"go_.+"})')
  line=$(jq -r '[.data.result[].metric.__name__] | sort | join(", ")' "$work/obs-names.json" 2>/dev/null) || line=
  echo "WARN  telemetry: go_ metrics of the gateway in Prometheus (query status $status): ${line:-none}"
}
