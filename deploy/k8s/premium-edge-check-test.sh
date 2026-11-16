#!/usr/bin/env bash
# Tests for deploy/k8s/premium-edge-check.sh without a cluster, AWS or a network: a fake curl first on PATH plays the
# API (users, videos, tiers, signed playlists) and the CDN (CloudFront's behaviors on the normalized path, its check of
# a custom policy's Resource and DateLessThan, X-Cache by path; S3 decoding the raw path into a key), fake date and
# sleep a clock that sleeping moves on, fake ffmpeg the test video.

# Each case turns one rule of the fake off (a file in its state folder) and wants the checks of that rule alone to
# fail. No output may hold a password, token, policy or signature the fakes made.
# Usage, from anywhere: deploy/k8s/premium-edge-check-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
for tool in jq openssl; do
  command -v "$tool" >/dev/null || {
    echo "FAIL  $tool is not installed" >&2
    exit 1
  }
done

bin=$work/bin
mkdir -p "$bin"
cat >"$bin/date" <<'EOF'
#!/usr/bin/env bash
# Epoch seconds from the fake clock; every other format from the real date.
if [ "$*" = +%s ]; then cat "$FAKE_STATE/now"; else exec /bin/date "$@"; fi
EOF
cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo $(($(cat "$FAKE_STATE/now") + $1)) >"$FAKE_STATE/now"
EOF
cat >"$bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
eval "out=\${$#}"
printf 'fake mp4 %s\n' "$*" >"$out"
EOF
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
api=https://api.svp.example
cdn=https://cdn.svp.example
out=/dev/null headers= method=GET url= auth= data= cfg= as_is=
while [ $# -gt 0 ]; do
  case $1 in
    -sS) ;;
    --max-time) shift ;;
    -o) out=$2; shift ;;
    -w) [ "$2" = '%{http_code}' ] || { echo "fake curl: -w $2" >&2; exit 2; }; shift ;;
    -X) method=$2; shift ;;
    -H) case $2 in @*) auth=${2#@} ;; esac; shift ;;
    -D) headers=$2; shift ;;
    --data-binary) data=${2#@}; shift ;;
    -K) cfg=$2; shift ;;
    --path-as-is) as_is=1 ;;
    -*) echo "fake curl: unexpected flag $1" >&2; exit 2 ;;
    *) url=$1 ;;
  esac
  shift
done
# A signed URL on the command line is visible to ps: logged for the test to refuse.
case $url in *Signature=*) echo "${url%%\?*}" >>"$s/argv-signed" ;; esac
# Without form lines, a config file holds a URL quoted as curl reads one.
if [ -n "$cfg" ] && ! grep -q '^form' "$cfg"; then
  url=$(perl -ne 'print s/\\(.)/$1/gr if s/^url = "(.*)"\n\z/$1/' "$cfg")
  cfg=
fi
probe=$(sed -n 's/.*[?&]svp_probe=\([0-9]*\).*/\1/p' <<<"$url")
echo "$method ${url%%\?*}${probe:+ svp_probe=$probe}${as_is:+ path-as-is}" >>"$s/calls"
off() { [ -f "$s/off-$1" ]; }
now=$(cat "$s/now")
# answer STATUS [X-CACHE]: the status as -w prints it, the body from stdin into -o, the headers into -D.
answer() {
  cat >"$out"
  if [ -n "$headers" ]; then
    printf 'HTTP/2 %s\r\ncontent-type: application/octet-stream\r\n' "$1" >"$headers"
    [ -z "${2:-}" ] || off x-cache || printf 'x-cache: %s from cloudfront\r\n' "$2" >>"$headers"
  fi
  printf '%s' "$1"
}
problem() { jq -n --arg c "$2" '{code: $c}' | answer "$1"; }
user_of() { [ -n "$auth" ] && sed -n 's/^Authorization: Bearer tok_[0-9a-f]*_//p' "$auth"; }
# tier VIDEO USER: fhd for the author, the tier USER bought, or nothing.
tier() {
  if [ "$(cut -d' ' -f1 "$s/videos/$1")" = "$2" ]; then echo fhd; else cat "$s/tiers/$2-$1" 2>/dev/null || true; fi
}
if [ -n "$cfg" ]; then answer 204 </dev/null; exit 0; fi
case $url in
  "$api/readyz") answer 200 </dev/null ;;
  "$api/auth/register")
    jq -r .password "$data" >>"$s/secrets"
    n=$(($(ls "$s/users" | wc -l) + 1))
    jq -r .email "$data" >"$s/users/u$n"
    jq -n --arg id "u$n" '{user_id: $id}' | answer 201 ;;
  "$api/auth/login")
    u=$(grep -lxF "$(jq -r .email "$data")" "$s"/users/* | xargs basename)
    t="tok_$(openssl rand -hex 12)_$u"
    echo "$t" >>"$s/secrets"
    jq -n --arg t "$t" '{access_token: $t}' | answer 200 ;;
  "$api/videos")
    n=$(($(ls "$s/videos" | wc -l) + 1))
    echo "$(user_of) $(jq -r .premium "$data")" >"$s/videos/vid$n"
    jq -n --arg id "vid$n" '{video_id: $id, upload_url: "https://s3.svp.example/svp-media", form_fields: {key: "uploads/\($id)"}}' |
      answer 201 ;;
  "$api/videos/"*/complete) jq -n '{status: "PROCESSING"}' | answer 202 ;;
  "$api/me/entitlements/"*)
    id=${url##*/}
    jq -r .tier "$data" >"$s/tiers/$(user_of)-$id"
    jq -n --arg id "$id" '{video_id: $id, tier: "sd", granted_at: "2026-01-01T00:00:00Z"}' | answer 200 ;;
  "$api/videos/"*/playback/*)
    p=${url#"$api/videos/"}
    id=${p%%/*} file=${p##*/} r=${p##*/}
    r=${r%.m3u8}
    t=$(tier "$id" "$(user_of)")
    if [ -z "$t" ] && ! off entitlement; then problem 403 NOT_ENTITLED; exit 0; fi
    if [ "$file" = master.m3u8 ]; then printf '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n360p.m3u8\n' | answer 200; exit 0; fi
    if [ "$t" = sd ] && [ "$r" != 360p ] && ! off rendition; then problem 403 RENDITION_NOT_ENTITLED; exit 0; fi
    exp=$((now + 1000))
    policy=$(printf '{"Statement":[{"Resource":"%s/premium/%s/1/att/index_%s_*","Condition":{"DateLessThan":{"AWS:EpochTime":%s}}}]}' \
      "$cdn" "$id" "$r" "$exp" | base64 | tr -d '\n' | tr '+=/' '-_~')
    sig="sig$(openssl rand -hex 12)"
    printf '%s\n%s\n' "$policy" "$sig" >>"$s/secrets"
    q="Policy=$policy&Signature=$sig&Key-Pair-Id=K1&Hash-Algorithm=SHA256"
    {
      printf '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
      for i in 0 1 2; do printf '#EXTINF:4,\n%s/premium/%s/1/att/index_%s_%s.ts?%s\n' "$cdn" "$id" "$r" "$i" "$q"; done
      echo '#EXT-X-ENDLIST'
    } | answer 200 ;;
  "$api/videos/"*)
    id=${url##*/}
    read -r author premium <"$s/videos/$id"
    prefix=media
    [ "$premium" = false ] || prefix=preview
    jq -n --arg id "$id" --argjson p "$premium" --arg url "$cdn/$prefix/$id/1/master.m3u8" --arg t "$(tier "$id" "$(user_of)")" \
      '{video_id: $id, status: "READY", premium: $p, playlist_url: $url} + (if $t == "" then {} else {entitlement_tier: $t} end)' |
      answer 200 ;;
  "$cdn/"*)
    path=${url%%\?*}
    query=
    case $url in *\?*) query=${url#*\?} ;; esac
    # signed RULE: the query holds a policy whose Resource covers the path and whose DateLessThan is ahead; with RULE
    # off, a request without a policy passes too.
    signed() {
      local policy statement resource exp in_scope=0
      policy=$(sed -n 's/^\(.*&\)\{0,1\}Policy=\([^&]*\).*/\2/p' <<<"$query")
      if [ -z "$policy" ]; then off "$1"; return; fi
      statement=$(printf '%s' "$policy" | tr -- '-_~' '+=/' | base64 -d)
      resource=$(jq -r '.Statement[0].Resource | rtrimstr("*")' <<<"$statement")
      exp=$(jq -r '.Statement[0].Condition.DateLessThan["AWS:EpochTime"]' <<<"$statement")
      [[ $path == "$resource"* ]] && in_scope=1
      off video-scope && [[ ${path##*/} == "${resource##*/}"* ]] && in_scope=1
      off rendition-scope && [[ ${path%/*} == "${resource%/*}" ]] && in_scope=1
      [ "$in_scope" = 1 ] && { [ "$now" -lt "$exp" ] || off expiry; }
    }
    # The behavior is picked on the path normalized as RFC 3986 says (%70, the one unreserved escape the script sends,
    # decoded; %2F kept): media/* and preview/* public, the default signed. Rule signature off drops the key group;
    # rule default-signed off is the layout of a public default with premium/* alone signed.
    case $(sed 's/%70/p/g' <<<"$path") in
      "$cdn/media/"* | "$cdn/preview/"*) ;;
      "$cdn/premium/"*)
        signed signature || { answer 403 Error </dev/null; exit 0; }
        # Rule probe-query off: an edge whose signature covers the whole query, so svp_probe breaks it.
        if off probe-query && [[ $query == *svp_probe=* ]]; then answer 403 Error </dev/null; exit 0; fi ;;
      *) off default-signed || signed signature || { answer 403 Error </dev/null; exit 0; } ;;
    esac
    # S3 gets the raw path and decodes it into the key; a key with a .. segment names no object, and without
    # ListBucket that is a 403. Rule literal-keys off resolves the .. instead.
    path=$(sed -e 's/%2[Ff]/\//g' -e 's/%70/p/g' <<<"$path")
    if off literal-keys; then path=$(sed 's#/[^/]*/\.\./#/#' <<<"$path"); fi
    case $path in */../*) answer 403 Error </dev/null; exit 0 ;; esac
    case $path in
      */master.m3u8)
        case $path in "$cdn/preview/"*) ! off preview-master || { answer 403 Error </dev/null; exit 0; } ;; esac
        printf '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\natt/index_360p.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\natt/index_720p.m3u8\n' |
          answer 200 Miss ;;
      "$cdn/preview/"*.m3u8) printf '#EXTM3U\n#EXTINF:4,\nindex_360p_0.ts\n#EXT-X-ENDLIST\n' | answer 200 Miss ;;
      *.m3u8) printf '#EXTM3U\n#EXTINF:4,\nindex_360p_0.ts\n#EXTINF:4,\nindex_360p_1.ts\n#EXTINF:2,\nindex_360p_2.ts\n#EXT-X-ENDLIST\n' |
        answer 200 Miss ;;
      *.ts)
        case $path in
          "$cdn/preview/"*) ! off preview-segment || { answer 403 Error </dev/null; exit 0; } ;;
        esac
        if grep -qxF "$path" "$s/cached" 2>/dev/null; then hit=Hit; else hit=Miss; echo "$path" >>"$s/cached"; fi
        echo segment | answer 200 "$hit" ;;
      *) answer 404 </dev/null ;;
    esac ;;
  *) echo "fake curl: unexpected URL ${url%%\?*}" >&2; exit 3 ;;
esac
EOF
chmod 755 "$bin"/*

clock_start=1800000000
# run OUT [ARG...]: the script with the fakes, context svp-stg, in an empty folder with its own TMPDIR; output (stdout
# and stderr) in OUT, exit status in $rc. The files off-<rule> of FAKE_STATE, made before, turn rules of the fake off.
new_state() {
  FAKE_STATE=$(mktemp -d "$work/state.XXXXXX")
  export FAKE_STATE
  mkdir -p "$FAKE_STATE/users" "$FAKE_STATE/videos" "$FAKE_STATE/tiers" "$FAKE_STATE/tmp" "$FAKE_STATE/cwd"
  : >"$FAKE_STATE/calls"
  : >"$FAKE_STATE/secrets"
  echo "$clock_start" >"$FAKE_STATE/now"
}
run() {
  local out=$1
  shift
  rc=0
  (cd "$FAKE_STATE/cwd" && env PATH="$bin:$PATH" TMPDIR="$FAKE_STATE/tmp" SVP_KUBE_CONTEXT="${context-svp-stg}" \
    perl -e 'alarm 120; exec @ARGV' "$here/premium-edge-check.sh" "$@") >"$out" 2>&1 || rc=$?
}
api=https://api.svp.example
# leaks OUT: the secrets of the fakes that OUT holds, one line each; nothing when none.
leaks() {
  local v
  while IFS= read -r v; do
    [ -z "$v" ] || ! grep -qF -- "$v" "$1" || echo "${v:0:8}..."
  done <"$FAKE_STATE/secrets"
}
# left: what the run left in its TMPDIR or working folder.
left() { ls -A "$FAKE_STATE/tmp" "$FAKE_STATE/cwd" | grep -v -e '^$' -e ':$' || true; }
# row LINE OUT: OUT has LINE after a UTC time, exactly.
row() { grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z  ' "$2" | cut -c23- | grep -qxF -- "$1"; }

# --- every rule of the edge kept.
new_state
run "$work/pass.out" "$api"
want_rows=("ok    V1 360p segment, signed (control): 200"
  "ok    V1 360p segment under premium/, no signature: 403"
  "ok    V1 360p segment under premium%2F, no signature: 403"
  "ok    V1 360p playlist under premium%2F, no signature: 403"
  "ok    V1 360p segment under %70remium/, no signature: 403"
  "ok    V1 360p playlist under %70remium/, no signature: 403"
  "ok    V1 360p segment under media/..%2Fpremium/, no signature: 403"
  "ok    V1 360p playlist under media/..%2Fpremium/, no signature: 403"
  "ok    V1 360p segment under preview/..%2Fpremium/, no signature: 403"
  "ok    V1 360p playlist under preview/..%2Fpremium/, no signature: 403"
  "ok    V1's 360p signature on a 360p segment of V2: 403"
  "ok    V1's 360p signature on a 720p segment of V1: 403"
  "ok    B's 720p playlist of V1 (tier sd): 403 RENDITION_NOT_ENTITLED"
  "ok    B's master of V2 (no tier): 403 NOT_ENTITLED"
  "ok    V1 preview master, no signature: 200"
  "ok    V1 preview segment, no signature: 200"
  "ok    every check of the premium edge")
missing=
for r in "${want_rows[@]}"; do row "$r" "$work/pass.out" || missing="$missing; $r"; done
table=$(sed -n '/^round  video/,/hit ratio/p' "$work/pass.out")
if [ "$rc" = 0 ] && [ -z "$missing" ] && ! grep -q FAIL "$work/pass.out" &&
  grep -qx '1      V0     3         0    3     0      0' <<<"$table" &&
  grep -qx '2      V0     3         3    0     0      0' <<<"$table" &&
  grep -qx '3      V1     3         3    0     0      0' <<<"$table" &&
  row 'info  V0 hit ratio of rounds 2-3: 6/6 (100%)' "$work/pass.out" &&
  row 'info  V1 hit ratio of rounds 2-3: 6/6 (100%)' "$work/pass.out" && ! grep -q 'DateLessThan' "$work/pass.out"; then
  ok "every rule kept: each check ok with its UTC time, the cache table of 3 rounds (round 1 of V0 all Miss, rounds 2-3 all Hit), hit ratio of rounds 2-3 6/6 for V0 and V1, no wait without --wait-expiry"
else
  fail "every rule kept: exit $rc, missing$missing"$'\n'"$(sed 's/^/      /' "$work/pass.out")"
fi
found=$(leaks "$work/pass.out")
if [ -z "$found" ]; then ok "every rule kept: no password, token, policy or signature in the output"; else fail "secrets in the output: $found"; fi
if [ -z "$(left)" ]; then ok "every rule kept: nothing left in TMPDIR or the working folder"; else fail "left behind: $(left)"; fi
if [ ! -e "$FAKE_STATE/argv-signed" ]; then
  ok "every rule kept: no signed URL on curl's command line"
else
  fail "signed URLs on curl's command line:"$'\n'"$(sed 's/^/      /' "$FAKE_STATE/argv-signed" 2>/dev/null)"
fi
probes=$(for r in 1 2 3; do grep -c "^GET https://cdn.svp.example/.*/index_360p_[0-9].ts svp_probe=$r\$" "$FAKE_STATE/calls"; done |
  paste -sd ' ' -)
if [ "$probes" = "6 6 6" ]; then
  ok "the cache rounds GET each 360p segment of V0 and V1 once a round, svp_probe=<round> in the query"
else
  fail "segment GETs per round: $probes"
fi
prefixes='(premium%2F|%70remium/|(media|preview)/\.\.%2Fpremium/)'
encoded=$(grep -cE "^GET https://cdn\\.svp\\.example/${prefixes}vid2/1/att/index_360p(_0\\.ts|\\.m3u8) path-as-is\$" \
  "$FAKE_STATE/calls" || true)
if [ "$encoded" = 8 ]; then
  ok "the encoded paths of V1's 360p segment and playlist go to the CDN with --path-as-is, no query"
else
  fail "GETs of encoded paths with --path-as-is: $encoded, want 8"$'\n'"$(sed 's/^/      /' "$FAKE_STATE/calls")"
fi

# --- each refusal the edge or the route must give, turned off in the fake: its checks alone fail.
# off_fails RULE ROW...: with RULE of the fake off the script exits non-zero, each ROW is a FAIL line, and nothing
# else fails.
off_fails() {
  local rule=$1 r missing=
  shift
  new_state
  : >"$FAKE_STATE/off-$rule"
  run "$work/neg.out" "$api"
  for r in "$@"; do row "FAIL  $r" "$work/neg.out" || missing="$missing; $r"; done
  if [ "$rc" != 0 ] && [ -z "$missing" ] && [ "$(grep -c '  FAIL  ' "$work/neg.out")" = $(($# + 1)) ] &&
    row "FAIL  $# check(s) of the premium edge" "$work/neg.out"; then
    ok "rule $rule off: '$1'$([ $# = 1 ] || echo " and $(($# - 1)) more"), the other checks ok, exit $rc"
  else
    fail "rule $rule off: exit $rc, want $# failure(s), missing$missing"$'\n'"$(sed 's/^/      /' "$work/neg.out")"
  fi
}
unsigned() { echo "V1 360p $1 under $2, no signature: want 403, got 200"; }
off_fails signature "$(unsigned segment premium/)" "$(unsigned segment premium%2F)" "$(unsigned playlist premium%2F)" \
  "$(unsigned segment %70remium/)" "$(unsigned playlist %70remium/)"
off_fails video-scope "V1's 360p signature on a 360p segment of V2: want 403, got 200"
off_fails rendition-scope "V1's 360p signature on a 720p segment of V1: want 403, got 200"
off_fails rendition "B's 720p playlist of V1 (tier sd): want 403 RENDITION_NOT_ENTITLED, got 200 "
off_fails entitlement "B's master of V2 (no tier): want 403 NOT_ENTITLED, got 200 "
off_fails preview-segment "V1 preview segment, no signature: want 200, got 403"
# A signature over the whole query: each signed segment of the cache rounds, svp_probe in its query, is refused.
probe_rows=()
for r in 1 2 3; do probe_rows+=("v1 segment of round $r: want 200, got 403" "v1 segment of round $r: want 200, got 403"
  "v1 segment of round $r: want 200, got 403"); done
off_fails probe-query "${probe_rows[@]}"
# A public default with premium/* alone signed: %70remium/ normalizes into premium/*, premium%2F reaches S3 and plays.
off_fails default-signed "$(unsigned segment premium%2F)" "$(unsigned playlist premium%2F)"
# An S3 that resolves .. in a key: the public behaviors hand out premium/ objects.
off_fails literal-keys "$(unsigned segment media/..%2Fpremium/)" "$(unsigned playlist media/..%2Fpremium/)" \
  "$(unsigned segment preview/..%2Fpremium/)" "$(unsigned playlist preview/..%2Fpremium/)"
new_state
: >"$FAKE_STATE/off-preview-master"
run "$work/neg.out" "$api"
if [ "$rc" != 0 ] && row 'FAIL  V1 preview master, no signature: want 200, got 403' "$work/neg.out"; then
  ok "rule preview-master off: 'V1 preview master, no signature: want 200, got 403', exit $rc"
else
  fail "rule preview-master off: exit $rc"$'\n'"$(sed 's/^/      /' "$work/neg.out")"
fi

# --- no X-Cache: the answers did not come through CloudFront, n/a and never a hit.
new_state
: >"$FAKE_STATE/off-x-cache"
run "$work/nocache.out" "$api"
if [ "$rc" = 0 ] && grep -qx '2      V1     3         0    0     0      3' "$work/nocache.out" &&
  row 'info  V0 hit ratio of rounds 2-3: n/a (no X-Cache: not through CloudFront)' "$work/nocache.out" &&
  row 'info  V1 hit ratio of rounds 2-3: n/a (no X-Cache: not through CloudFront)' "$work/nocache.out"; then
  ok "no X-Cache: the table counts n/a, no hit, and the ratio is n/a"
else
  fail "no X-Cache: exit $rc"$'\n'"$(sed 's/^/      /' "$work/nocache.out")"
fi

# --- --wait-expiry: the fake signs for 1000 s; the script sleeps past DateLessThan + 5 s, then the CDN refuses.
new_state
run "$work/expiry.out" --wait-expiry "$api"
now=$(cat "$FAKE_STATE/now")
expires=$(jq -rn --argjson t $((clock_start + 1000)) '$t | todate')
if [ "$rc" = 0 ] && row 'ok    V1 360p signed segment 5 s past DateLessThan: 403' "$work/expiry.out" &&
  row "info  V1's signed URL expires at $expires; waiting until 5 s past it" "$work/expiry.out" &&
  [ "$now" -ge $((clock_start + 1005)) ] && [ "$now" -le $((clock_start + 1200)) ]; then
  ok "--wait-expiry: DateLessThan read from the policy, the clock slept to 5 s past it ($((now - clock_start)) s), the segment 403"
else
  fail "--wait-expiry: exit $rc, clock +$((now - clock_start)) s"$'\n'"$(sed 's/^/      /' "$work/expiry.out")"
fi
found=$(leaks "$work/expiry.out")
if [ -z "$found" ]; then ok "--wait-expiry: no policy or signature in the output"; else fail "--wait-expiry: secrets in the output: $found"; fi
new_state
: >"$FAKE_STATE/off-expiry"
run "$work/expiry.out" --wait-expiry "$api"
if [ "$rc" != 0 ] && row 'FAIL  V1 360p signed segment 5 s past DateLessThan: want 403, got 200' "$work/expiry.out"; then
  ok "--wait-expiry, an edge that ignores DateLessThan: the check fails"
else
  fail "--wait-expiry, an edge that ignores DateLessThan: exit $rc"$'\n'"$(sed 's/^/      /' "$work/expiry.out")"
fi

# --- refused before any request.
for c in "k3d-svp|$api|SVP_KUBE_CONTEXT must be svp-stg or svp-prd" "|$api|SVP_KUBE_CONTEXT must be svp-stg or svp-prd" \
  "svp-stg|http://api.svp.example|usage: deploy/k8s/premium-edge-check.sh"; do
  IFS='|' read -r context url message <<<"$c"
  new_state
  run "$work/out" "$url"
  if [ "$rc" != 0 ] && grep -qF -- "$message" "$work/out" && [ ! -s "$FAKE_STATE/calls" ]; then
    ok "context '$context', $url: refused before any request ($message)"
  else
    fail "context '$context', $url: exit $rc, calls $(wc -l <"$FAKE_STATE/calls")"$'\n'"$(sed 's/^/      /' "$work/out")"
  fi
done
unset context

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures case(s) of deploy/k8s/premium-edge-check-test.sh" >&2
  exit 1
fi
echo "ok    deploy/k8s/premium-edge-check-test.sh: every case"
