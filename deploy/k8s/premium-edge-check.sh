#!/usr/bin/env bash
# Checks premium playback at the edge of an EKS cluster (make eks-premium-check): users A and B, a public video V0 and
# two premium videos V1, V2 of A through the public API, B holding tier sd of V1. Prints each check with its UTC time:
# the refusals of CloudFront and of the playback route, the hit ratio of CloudFront's cache for public and signed
# segments, and with --wait-expiry the refusal of a signed URL once its policy has expired.

# Calls the API and the CDN over HTTPS with curl alone: no AWS API, no kubectl, no paid CloudFront metric. Tokens,
# passwords and signed queries live only in private files of its temporary folder, removed on exit, never printed.
# Two users stay within the gateway's register limit, so no rate limit key is deleted. Needs curl, jq, openssl, ffmpeg.

# Usage: SVP_KUBE_CONTEXT=svp-stg deploy/k8s/premium-edge-check.sh [--wait-expiry] https://api.<domain>
# Design notes: docs/explanation/premium-playback.md.
set -euo pipefail

wait_expiry=
if [ "${1:-}" = --wait-expiry ]; then
  wait_expiry=1
  shift
fi
[ $# = 1 ] && [[ $1 == https://* ]] || {
  echo "FAIL  usage: deploy/k8s/premium-edge-check.sh [--wait-expiry] https://api.<domain>" >&2
  exit 1
}
[[ ${SVP_KUBE_CONTEXT:-} =~ ^svp-(stg|prd)$ ]] || {
  echo "FAIL  SVP_KUBE_CONTEXT must be svp-stg or svp-prd, an EKS cluster of the project (got '${SVP_KUBE_CONTEXT:-}'); run make eks-premium-check" >&2
  exit 1
}
base=$1
for tool in curl jq openssl ffmpeg; do
  command -v "$tool" >/dev/null || {
    echo "FAIL  $tool is not installed" >&2
    exit 1
  }
done

max_time=10
transfer_max_time=60
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
info() { echo "$(utc)  info  $1"; }
fail() {
  echo "$(utc)  FAIL  $1" >&2
  exit 1
}
# check NAME WANT GOT: one line of the table; a mismatch is counted, and the check goes on to the next line.
check() {
  if [ "$2" = "$3" ]; then
    echo "$(utc)  ok    $1: $3"
  else
    echo "$(utc)  FAIL  $1: want $2, got $3"
    failures=$((failures + 1))
  fi
}

# request METHOD PATH [AUTH_FILE] [BODY_FILE]: the API's answer in $work/body; prints the HTTP status.
request() {
  local args=(-sS --max-time "$max_time" -o "$work/body" -w '%{http_code}' -X "$1" "$base$2")
  if [ -n "${3:-}" ]; then args+=(-H "@$3"); fi
  if [ -n "${4:-}" ]; then args+=(-H 'Content-Type: application/json' --data-binary "@$4"); fi
  : >"$work/body"
  curl "${args[@]}" || true
}
field() { jq -r --arg k "$1" '.[$k] // "" | tostring' "$work/body" 2>/dev/null || true; }
code() { field code; }

# fetch URL FILE [CURL_FLAG...]: anonymous GET of URL from the CDN into FILE, its headers in FILE.headers; prints the
# HTTP status.
fetch() {
  local url=$1 file=$2
  shift 2
  [[ $url == https://* ]] || fail "a media URL of the API is not https (${url%%\?*})"
  : >"$file"
  : >"$file.headers"
  curl -sS --max-time "$transfer_max_time" "$@" -o "$file" -D "$file.headers" -w '%{http_code}' "$url" || true
}
# x_cache FILE: the first word of CloudFront's X-Cache header of the last fetch into FILE (Hit, RefreshHit, Miss...),
# empty when the answer has none (it did not come through CloudFront).
x_cache() { tr -d '\r' <"$1.headers" | sed -n 's/^[Xx]-[Cc]ache: *\([A-Za-z]*\).*/\1/p' | tail -n 1; }

# uris PLAYLIST_FILE: the URI lines of an HLS playlist.
uris() { { grep -v -e '^#' -e '^[[:space:]]*$' "$1" || true; } | tr -d '\r'; }
# resolve BASE_URL REF: REF resolved against the playlist at BASE_URL (an absolute REF as is).
resolve() {
  case $2 in
    https://* | http://*) printf '%s' "$2" ;;
    *) printf '%s/%s' "${1%/*}" "$2" ;;
  esac
}

# new_user NAME: registers and logs in a user of a random e-mail and password; its Authorization header in
# $work/NAME.auth.
new_user() {
  local status
  SVP_CHECK_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "edge-$(date +%s)-$(openssl rand -hex 4)@example.test" \
    '{email: $e, password: env.SVP_CHECK_PASSWORD}' >"$work/$1.cred"
  status=$(request POST /auth/register "" "$work/$1.cred")
  [ "$status" = 201 ] || fail "register user $1 (status $status, code $(code))"
  status=$(request POST /auth/login "" "$work/$1.cred")
  [ "$status" = 200 ] && [ -n "$(field access_token)" ] || fail "login user $1 (status $status)"
  jq -r '"Authorization: Bearer \(.access_token)"' "$work/body" >"$work/$1.auth"
  : >"$work/body"
}

# upload NAME PREMIUM: A creates video NAME (premium true or false) of clip.mp4, uploads it to its presigned form and
# completes it; sets NAME_id.
upload() {
  local status
  jq -n --arg t "edge check $1 $(openssl rand -hex 4)" --argjson s "$(wc -c <"$work/clip.mp4" | tr -d ' ')" \
    --argjson p "$2" '{title: $t, size_bytes: $s, content_type: "video/mp4", premium: $p}' >"$work/$1.json"
  status=$(request POST /videos "$work/a.auth" "$work/$1.json")
  [ "$status" = 201 ] && [ -n "$(field video_id)" ] || fail "create video $1 (status $status, code $(code))"
  printf -v "${1}_id" '%s' "$(field video_id)"
  # The form's URL and fields go to curl in a config file, never on its command line.
  jq -r --arg f "$work/clip.mp4" '"url = \(.upload_url | @json)",
    (.form_fields | to_entries[] | "form-string = \("\(.key)=\(.value)" | @json)"), "form = \("file=@\($f)" | @json)"' \
    "$work/body" >"$work/$1.curl"
  status=$(curl -sS --max-time "$transfer_max_time" -o "$work/body" -w '%{http_code}' -K "$work/$1.curl" || true)
  [[ $status == 2?? ]] || fail "upload video $1 (status $status)"
  local id_var="${1}_id"
  status=$(request POST "/videos/${!id_var}/complete" "$work/a.auth")
  [ "$status" = 202 ] || fail "complete video $1 (status $status, code $(code))"
}

# wait_ready NAME: polls GET /videos/{id} as A until video NAME is READY, at most 600 s.
wait_ready() {
  local id_var="${1}_id" start=$SECONDS status state
  while :; do
    status=$(request GET "/videos/${!id_var}" "$work/a.auth")
    [ "$status" = 200 ] || fail "read video $1 (status $status, code $(code))"
    state=$(field status)
    [ "$state" = READY ] && return
    [ "$state" != FAILED ] || fail "video $1 went FAILED"
    ((SECONDS - start < 600)) || fail "video $1 READY within 600 s (still $state)"
    sleep 5
  done
}

# signed NAME USER RENDITION: the signed playlist of RENDITION of video NAME as USER into $work/NAME-USER-RENDITION;
# fails unless every segment URL is absolute with a query.
signed() {
  local id_var="${1}_id" file="$work/$1-$2-$3" status
  status=$(request GET "/videos/${!id_var}/playback/$3.m3u8" "$work/$2.auth")
  mv "$work/body" "$file"
  [ "$status" = 200 ] && [ -n "$(uris "$file")" ] && [ -z "$(uris "$file" | grep -v '^https://[^?]*?.')" ] ||
    fail "$2's signed playlist $3 of $1 is 200 with absolute signed segment URLs (status $status)"
}

echo "# premium edge check of $base ($SVP_KUBE_CONTEXT), times in UTC"
start=$SECONDS
until [ "$(curl -sS --max-time "$max_time" -o /dev/null -w '%{http_code}' "$base/readyz" || true)" = 200 ]; do
  ((SECONDS - start < 120)) || fail "readyz within 120 s"
  sleep 1
done
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=10" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -b:a 96k -shortest -movflags +faststart "$work/clip.mp4" || fail "make a 10 s 1280x720 test video"
new_user a
new_user b
upload v0 false
upload v1 true
upload v2 true
for v in v0 v1 v2; do wait_ready "$v"; done
jq -n '{tier: "sd"}' >"$work/tier.json"
status=$(request PUT "/me/entitlements/$v1_id" "$work/b.auth" "$work/tier.json")
[ "$status" = 200 ] && [ "$(field tier)" = sd ] || fail "B buys tier sd of V1 (status $status, code $(code))"
info "users A, B; V0 public, V1 and V2 premium, READY; B holds sd of V1"

# --- (a) what must be refused, and what must not.
signed v1 b 360p
signed v1 a 720p
signed v2 a 360p
v1_360=$(uris "$work/v1-b-360p" | head -n 1)
v1_query=${v1_360#*\?}
v1_720=$(uris "$work/v1-a-720p" | head -n 1)
v2_360=$(uris "$work/v2-a-360p" | head -n 1)
check "V1 360p segment, signed (control)" 200 "$(fetch "$v1_360" "$work/segment")"
check "V1 360p segment under premium/, no signature" 403 "$(fetch "${v1_360%%\?*}" "$work/segment")"
# CloudFront picks a behavior on the path normalized as RFC 3986 says (%70 is p, %2F stays, ..%2F is no dot segment),
# then sends the raw path, which S3 decodes: each of these must meet the signed default behavior or name no object.
# --path-as-is keeps curl from rewriting the path.
v1_object=${v1_360%%\?*}
[[ $v1_object == https://*/premium/* ]] || fail "V1's signed segment URL is under premium/"
origin=${v1_object%%/premium/*}
segment_key=${v1_object#"$origin"/premium/}
playlist_key=${segment_key%/*}/index_360p.m3u8
for encoded in 'premium%2F' '%70remium/' 'media/..%2Fpremium/' 'preview/..%2Fpremium/'; do
  check "V1 360p segment under $encoded, no signature" 403 \
    "$(fetch "$origin/$encoded$segment_key" "$work/segment" --path-as-is)"
  check "V1 360p playlist under $encoded, no signature" 403 \
    "$(fetch "$origin/$encoded$playlist_key" "$work/segment" --path-as-is)"
done
check "V1's 360p signature on a 360p segment of V2" 403 "$(fetch "${v2_360%%\?*}?$v1_query" "$work/segment")"
check "V1's 360p signature on a 720p segment of V1" 403 "$(fetch "${v1_720%%\?*}?$v1_query" "$work/segment")"
status=$(request GET "/videos/$v1_id/playback/720p.m3u8" "$work/b.auth")
check "B's 720p playlist of V1 (tier sd)" "403 RENDITION_NOT_ENTITLED" "$status $(code)"
status=$(request GET "/videos/$v2_id/playback/master.m3u8" "$work/b.auth")
check "B's master of V2 (no tier)" "403 NOT_ENTITLED" "$status $(code)"
status=$(request GET "/videos/$v1_id" "$work/b.auth")
[ "$status" = 200 ] || fail "B reads V1 (status $status, code $(code))"
preview=$(field playlist_url)
check "V1 preview master, no signature" 200 "$(fetch "$preview" "$work/preview")"
variant=$(resolve "$preview" "$(uris "$work/preview" | head -n 1)")
[ "$(fetch "$variant" "$work/preview-variant")" = 200 ] || fail "GET the preview playlist of V1"
check "V1 preview segment, no signature" 200 \
  "$(fetch "$(resolve "$variant" "$(uris "$work/preview-variant" | head -n 1)")" "$work/segment")"

# --- (b) CloudFront's cache: every 360p segment of V0 (public) and V1 (signed) in 3 rounds, each round with a query
# of its own. Hit and RefreshHit are hits; an answer without X-Cache did not come through CloudFront, so it counts as
# n/a, never as a hit.
status=$(request GET "/videos/$v0_id" "$work/a.auth")
[ "$status" = 200 ] || fail "A reads V0 (status $status, code $(code))"
v0_master=$(field playlist_url)
[ "$(fetch "$v0_master" "$work/v0-master")" = 200 ] || fail "GET the master of V0"
v0_variant=$(resolve "$v0_master" "$(uris "$work/v0-master" | grep 'index_360p\.m3u8$' | head -n 1)")
[ "$(fetch "$v0_variant" "$work/v0-variant")" = 200 ] && [ -n "$(uris "$work/v0-variant")" ] ||
  fail "GET the 360p playlist of V0"
uris "$work/v0-variant" | while IFS= read -r ref; do resolve "$v0_variant" "$ref"; echo; done >"$work/v0-segments"
uris "$work/v1-b-360p" >"$work/v1-segments"
echo "round  video  segments  hit  miss  other  n/a"
for round in 1 2 3; do
  for v in v0 v1; do
    hit=0 miss=0 other=0 none=0 n=0
    while IFS= read -r url; do
      case $url in *\?*) url="$url&svp_probe=$round" ;; *) url="$url?svp_probe=$round" ;; esac
      status=$(fetch "$url" "$work/segment")
      [ "$status" = 200 ] || {
        echo "$(utc)  FAIL  $v segment of round $round: want 200, got $status"
        failures=$((failures + 1))
      }
      case $(x_cache "$work/segment") in
        Hit | RefreshHit) hit=$((hit + 1)) ;;
        Miss) miss=$((miss + 1)) ;;
        '') none=$((none + 1)) ;;
        *) other=$((other + 1)) ;;
      esac
      n=$((n + 1))
    done <"$work/$v-segments"
    printf '%-5s  %-5s  %-8s  %-3s  %-4s  %-5s  %s\n' "$round" "$(tr v V <<<"$v")" "$n" "$hit" "$miss" "$other" "$none"
    if [ "$round" -gt 1 ]; then
      printf '%s %s %s\n' "$v" "$hit" "$((n - none))" >>"$work/ratio"
    fi
  done
done
for v in v0 v1; do
  read -r hits seen < <(awk -v v="$v" '$1 == v { h += $2; s += $3 } END { print h + 0, s + 0 }' "$work/ratio")
  if [ "$seen" = 0 ]; then
    info "$(tr v V <<<"$v") hit ratio of rounds 2-3: n/a (no X-Cache: not through CloudFront)"
  else
    info "$(tr v V <<<"$v") hit ratio of rounds 2-3: $hits/$seen ($((hits * 100 / seen))%)"
  fi
done

# --- (c) the signed URL of a V1 segment once the DateLessThan of its policy is 5 s past.
if [ -n "$wait_expiry" ]; then
  policy=$(sed -n 's/.*[?&]Policy=\([^&]*\).*/\1/p' <<<"$v1_360")
  [ -n "$policy" ] || fail "the signed URL of V1 has no Policy"
  expires=$(printf '%s' "$policy" | tr -- '-_~' '+=/' | base64 -d 2>/dev/null |
    jq -er '.Statement[0].Condition.DateLessThan["AWS:EpochTime"] | numbers') ||
    fail "read DateLessThan of the policy of V1's signed URL"
  info "V1's signed URL expires at $(jq -rn --argjson t "$expires" '$t | todate'); waiting until 5 s past it"
  while now=$(date +%s); [ "$now" -lt $((expires + 5)) ]; do
    left=$((expires + 5 - now))
    sleep $((left < 60 ? left : 60))
  done
  check "V1 360p signed segment 5 s past DateLessThan" 403 "$(fetch "$v1_360" "$work/segment")"
fi

if [ "$failures" -gt 0 ]; then
  echo "$(utc)  FAIL  $failures check(s) of the premium edge" >&2
  exit 1
fi
echo "$(utc)  ok    every check of the premium edge"
