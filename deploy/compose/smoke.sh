#!/usr/bin/env bash
# End-to-end smoke test of the core stack through the gateway: users, videos, the presigned upload, transcode, HLS
# playback, premium playback, feeds, likes, views, follows and refresh tokens. Prints one ok/FAIL line per step and
# exits non-zero on the first failure. Needs curl, jq, openssl and ffmpeg on the host; lib.sh resets the register rate
# limit in the stack's Valkey through docker compose exec.

# Usage: deploy/compose/smoke.sh [base-url]   (default http://127.0.0.1:8080)

# The HLS output must use the versioned layout (media/<id>/<version>/master.m3u8, variants named
# <attempt>/index_<rendition>.m3u8) and its master, a variant playlist, a segment and the thumbnail must come with
# Cache-Control: max-age=31536000, immutable.

# `make k8s-smoke` and `make eks-smoke` run the same steps against a cluster, with SVP_STACK=k3d or eks so lib.sh resets
# the limit in the cluster's Valkey (Deployment svp-ops) instead of the compose stack's.
# Design notes: docs/reference/k8s.md.
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/lib.sh
source "$(dirname "$0")/lib.sh"

# /readyz covers the three services behind the gateway (user, video, feed).
wait_gateway_ready 60

new_user a
title="smoke video $(openssl rand -hex 4)"
jq -n --arg t "$title" '{title: $t, size_bytes: 1048576, content_type: "video/mp4"}' >"$work/video.json"
# A random UUID in canonical lowercase form, sent as a Structured Field String.
hex=$(openssl rand -hex 16)
key="${hex:0:8}-${hex:8:4}-4${hex:13:3}-8${hex:17:3}-${hex:20:12}"
{ cat "$work/a.auth"; printf 'Idempotency-Key: "%s"\n' "$key"; } >"$work/a-key.auth"
status=$(request POST /videos "$work/a-key.auth" "$work/video.json")
video_id=$(field video_id)
[[ $status == 201 && -n $video_id ]] || fail "create video (status $status, $(problem_summary))"
ok "create video"
status=$(request POST /videos "$work/a-key.auth" "$work/video.json")
[[ $status == 201 && $(field video_id) == "$video_id" ]] ||
  fail "repeated create with the same Idempotency-Key returns the same video (status $status, $(problem_summary))"
ok "repeated create with the same Idempotency-Key: same video_id"

status=$(request GET "/videos/$video_id" "$work/a.auth")
[[ $status == 200 ]] || fail "author reads video (status $status, $(problem_summary))"
[[ $(field status) == UPLOADING ]] || fail "video status is UPLOADING (got $(field status))"
[[ $(field title) == "$title" ]] || fail "video title round-trips"
[[ $(field author_id) == "$a_id" ]] || fail "video author_id is user A"
ok "author reads video: UPLOADING, title, author_id"

status=$(request GET "/videos/$video_id")
[[ $status == 401 && $(<"$work/type") == application/problem+json* ]] ||
  fail "read video without token is 401 problem+json (status $status, type $(<"$work/type"))"
ok "read video without token: 401 problem+json"

# User B cannot see A's video while it is not READY (UP-3).
new_user b
status=$(request GET "/videos/$video_id" "$work/b.auth")
[[ $status == 404 && $(field code) == VIDEO_NOT_FOUND ]] ||
  fail "other user reads unpublished video is 404 VIDEO_NOT_FOUND (status $status, $(problem_summary))"
ok "other user reads unpublished video: 404 VIDEO_NOT_FOUND"

# User C registers with a picked handle written in upper case, which user-service lowers; a second account cannot take
# the same handle.
c_handle="smoke_$(openssl rand -hex 6)"
c_email="smoke-$(date +%s)-$(openssl rand -hex 4)@example.test"
SMOKE_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$c_email" --arg h "$(printf '%s' "$c_handle" | tr '[:lower:]' '[:upper:]')" \
  '{email: $e, password: env.SMOKE_PASSWORD, handle: $h, display_name: "Smoke C"}' >"$work/c.reg"
jq '{email, password}' "$work/c.reg" >"$work/c.cred"
status=$(request POST /auth/register "" "$work/c.reg")
[[ $status == 201 && -n $(field user_id) ]] || fail "register with a handle (status $status, $(problem_summary))"
c_id=$(field user_id)
ok "register user c with a handle"

SMOKE_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "dup-$c_email" --arg h "$c_handle" \
  '{email: $e, password: env.SMOKE_PASSWORD, handle: $h}' >"$work/dup.reg"
status=$(request POST /auth/register "" "$work/dup.reg")
[[ $status == 409 && $(field code) == HANDLE_ALREADY_TAKEN ]] ||
  fail "register with a taken handle is 409 HANDLE_ALREADY_TAKEN (status $status, $(problem_summary))"
ok "register with a taken handle: 409 HANDLE_ALREADY_TAKEN"

status=$(request POST /auth/login "" "$work/c.cred")
token=$(field access_token)
: >"$work/body" # the body holds the token: drop it now
[[ $status == 200 && -n $token ]] || fail "login user c (status $status)"
printf 'Authorization: Bearer %s\n' "$token" >"$work/c.auth"
token=""

# GET /me answers the profile only, never the email.
status=$(request GET /me "$work/c.auth")
[[ $status == 200 && $(field user_id) == "$c_id" && $(field handle) == "$c_handle" && $(field display_name) == "Smoke C" ]] &&
  jq -e 'keys == ["display_name", "handle", "user_id"]' "$work/body" >/dev/null ||
  fail "GET /me is 200 with user_id, lowered handle and display name, no email (status $status, $(problem_summary))"
ok "GET /me: the profile with the lowered handle, no email"

jq -n '{display_name: "Smoke C renamed"}' >"$work/rename.json"
status=$(request PATCH /me "$work/c.auth" "$work/rename.json")
[[ $status == 200 && $(field display_name) == "Smoke C renamed" && $(field handle) == "$c_handle" ]] ||
  fail "PATCH /me renames (status $status, $(problem_summary))"
status=$(request GET /me "$work/c.auth")
[[ $status == 200 && $(field display_name) == "Smoke C renamed" ]] ||
  fail "GET /me after PATCH has the new name (status $status, $(problem_summary))"
ok "PATCH /me: display name changed, handle kept"

# A registered without a handle: the generated one is u_ and the last 12 hex digits of the id,
# and the display name defaults to it.
status=$(request GET /me "$work/a.auth")
a_handle=$(field handle)
[[ $status == 200 && $a_handle == "u_${a_id:24}" && $(field display_name) == "$a_handle" ]] ||
  fail "user A has the generated handle u_${a_id:24} as handle and display name (status $status, handle $a_handle)"
ok "user A without a handle: generated handle $a_handle"

status=$(request GET "/profiles/$a_handle" "$work/b.auth")
[[ $status == 200 && $(field user_id) == "$a_id" ]] && jq -e '.followed_by_me == false' "$work/body" >/dev/null ||
  fail "B reads A's profile, followed_by_me false (status $status, $(problem_summary))"
ok "B reads A's profile before following: followed_by_me false"

# A sees the UPLOADING video in their own list; B's list of A's videos holds only READY ones.
status=$(request GET "/me/videos?page_size=50" "$work/a.auth")
[[ $status == 200 ]] && jq -e --arg id "$video_id" 'any(.items[]; .video_id == $id and .status == "UPLOADING")' "$work/body" >/dev/null ||
  fail "GET /me/videos holds A's UPLOADING video (status $status, $(problem_summary))"
ok "GET /me/videos: A's own UPLOADING video listed"
status=$(request GET "/users/$a_id/videos?page_size=50" "$work/b.auth")
[[ $status == 200 ]] && jq -e --arg id "$video_id" 'all(.items[]; .status == "READY") and all(.items[]; .video_id != $id)' "$work/body" >/dev/null ||
  fail "B's GET /users/{A}/videos holds only READY videos (status $status, $(problem_summary))"
ok "GET /users/{A}/videos for B: only READY videos"

# B follows A twice (idempotent) before A uploads, so A's upload reaches B's following feed by fan-out. B unfollows
# later in this script.
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "follow (status $status, $(problem_summary))"
ok "follow"
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "follow again (status $status, $(problem_summary))"
ok "follow again"
status=$(request GET "/profiles/$a_handle" "$work/b.auth")
[[ $status == 200 ]] && jq -e '.followed_by_me == true' "$work/body" >/dev/null ||
  fail "B reads A's profile after following, followed_by_me true (status $status, $(problem_summary))"
ok "B reads A's profile after following: followed_by_me true"

make_video "$work/clip.mp4" 10 1280x720
clip_size=$(file_size "$work/clip.mp4")
create_video clip "$work/a.auth" "smoke upload $(openssl rand -hex 4)" "$clip_size" video/mp4
ok "create video for upload ($clip_size bytes)"

status=$(upload_file clip "$work/clip.mp4")
[[ $status == 2?? ]] || fail "upload to the presigned form (status $status, code $(storage_error_code))"
ok "upload to the presigned form"

status=$(complete_upload clip "$work/a.auth")
[[ $status == 202 && $(field status) == PROCESSING ]] ||
  fail "complete upload is 202 PROCESSING (status $status, $(problem_summary), video status $(field status))"
ok "complete upload: 202 PROCESSING"

# The transcode runs asynchronously (outbox, Kafka, media-worker, Kafka, video-service).
wait_ready clip "$work/a.auth" 180
playlist_url=$(field playlist_url)
thumbnail_url=$(field thumbnail_url)
[[ -n $playlist_url && -n $thumbnail_url ]] || fail "READY video has playlist_url and thumbnail_url"
ok "video READY after ${clip_wait} s, playlist_url and thumbnail_url set"

status=$(fetch "$playlist_url" "$work/master.m3u8")
[[ $status == 200 ]] && grep -q '^#EXT-X-STREAM-INF' "$work/master.m3u8" ||
  fail "anonymous GET master.m3u8 is 200 with #EXT-X-STREAM-INF (status $status)"
ok "anonymous GET master.m3u8"

variant_url=$(resolve "$playlist_url" "$(first_uri "$work/master.m3u8")")
status=$(fetch "$variant_url" "$work/variant.m3u8")
segment_ref=$(first_uri "$work/variant.m3u8")
[[ $status == 200 && -n $segment_ref ]] || fail "anonymous GET variant playlist is 200 with a segment (status $status)"
ok "anonymous GET variant playlist"

status=$(fetch "$(resolve "$variant_url" "$segment_ref")" "$work/segment")
[[ $status == 200 && -s $work/segment ]] || fail "anonymous GET segment is 200 and not empty (status $status)"
ok "anonymous GET segment ($(file_size "$work/segment") bytes)"

status=$(fetch "$thumbnail_url" "$work/thumbnail")
[[ $status == 200 && -s $work/thumbnail ]] || fail "anonymous GET thumbnail is 200 and not empty (status $status)"
ok "anonymous GET thumbnail"

# The output is immutable: a version per video.uploaded, every object cached for a year.
# cache_control URL: the Cache-Control header of a GET of URL ("" when there is none).
cache_control() {
  curl -sS --max-time "$transfer_max_time" -o /dev/null -D - "$1" |
    awk 'tolower($0) ~ /^cache-control:/ { sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print; exit }'
}
uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
immutable='max-age=31536000, immutable'
# playlist_url is <media base>/<key> and every key starts with media/<video_id>/. The media base is the bucket's URL
# on a path-style store (<store>/media) and the CDN's origin on a cloud (https://<cdn domain>, whose paths are keys).
# A URL without media/<video_id>/ leaves media_base equal to it and the key test below fails on the whole URL.
media_base=${playlist_url%/media/"$clip_id"/*}
playlist_key=${playlist_url#"$media_base"/}
thumbnail_key=${thumbnail_url#"$media_base"/}
if [[ $playlist_key =~ ^media/$clip_id/$uuid_re/master\.m3u8$ ]]; then
  variant_ref=$(first_uri "$work/master.m3u8")
  [[ $variant_ref =~ ^$uuid_re/index_[a-z0-9]+\.m3u8$ && $thumbnail_key == "${playlist_key%/*}/${variant_ref%%/*}/thumbnail.jpg" ]] ||
    fail "master names <attempt>/index_<rendition>.m3u8 and the thumbnail is in that attempt directory (variant $variant_ref, thumbnail key $thumbnail_key)"
  # One "<name>|<url>" per object: the names have blanks, the URLs none.
  for object in "master|$playlist_url" "variant playlist|$variant_url" "segment|$(resolve "$variant_url" "$segment_ref")" \
    "thumbnail|$thumbnail_url"; do
    got=$(cache_control "${object#*|}") || got=
    [[ $got == "$immutable" ]] || fail "${object%%|*} has Cache-Control: $immutable (got '$got')"
  done
  ok "versioned key $playlist_key; Cache-Control $immutable on master, variant playlist, segment, thumbnail"
else
  fail "playlist key is media/<video_id>/<version>/master.m3u8 (got $playlist_key)"
fi

# The uploaded original stays private (UP-5).
status=$(fetch "$(upload_url clip)/$(upload_key clip)" "$work/original")
[[ $status == 403 ]] || fail "anonymous GET of the uploaded original is 403 (status $status)"
ok "anonymous GET of the uploaded original: 403"

# The media bucket can be read object by object but not listed, so video ids are not enumerable
# (UP-6). A listing goes to the media base: the bucket's URL on a path-style store, the CDN's origin root on a cloud,
# which signs the request to the bucket, so the bucket's own policy (no s3:ListBucket) refuses it. A base without a
# path gets "/" so the request names the root.
media_listing_url=$media_base
[[ $media_listing_url == *://*/* ]] || media_listing_url+=/
for query in "list-type=2" "list-type=2&prefix=media/"; do
  status=$(fetch "$media_listing_url?$query" "$work/listing")
  [[ $status == 403 ]] || fail "anonymous listing of the media bucket ($query) is 403 (status $status)"
done
ok "anonymous listing of the media bucket: 403"

status=$(request GET "/videos/$clip_id" "$work/b.auth")
[[ $status == 200 && $(field status) == READY ]] ||
  fail "other user reads READY video (status $status, $(problem_summary))"
ok "other user reads READY video"

status=$(request GET "/users/$a_id/videos?page_size=50" "$work/b.auth")
[[ $status == 200 ]] && jq -e --arg id "$clip_id" 'all(.items[]; .status == "READY") and any(.items[]; .video_id == $id)' "$work/body" >/dev/null ||
  fail "B's GET /users/{A}/videos holds the READY video (status $status, $(problem_summary))"
ok "GET /users/{A}/videos for B: the READY video listed"

# The public video needs no token: 200 for the READY video, with the author and counters without liked_by_me, which come
# within 100 ms on a healthy stack, so the check polls; one 404 for a video that is not READY and for a random id.
public_start=$SECONDS
until status=$(request GET "/public/videos/$clip_id") && [[ $status == 200 ]] &&
  jq -e --arg a "$a_id" '.author.user_id == $a and (.stats | keys) == ["like_count", "view_count"]' "$work/body" >/dev/null; do
  [[ $status == 200 ]] || fail "GET /public/videos/{READY video} without a token is 200 (status $status, $(problem_summary))"
  ((SECONDS - public_start < 10)) || fail "public video has author and stats without liked_by_me within 10 s"
  sleep 1
done
ok "GET /public/videos/{READY video} without a token: 200 with author, stats without liked_by_me"
random_id=$(openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/')
for id in "$video_id" "$random_id"; do
  status=$(request GET "/public/videos/$id")
  [[ $status == 404 && $(field code) == VIDEO_NOT_FOUND ]] ||
    fail "GET /public/videos/{not READY or unknown} is 404 VIDEO_NOT_FOUND (status $status, $(problem_summary))"
done
ok "GET /public/videos/{UPLOADING video, random id}: 404 VIDEO_NOT_FOUND"

# The storage enforces the declared size: one byte more than declared is refused (UP-1). Any other refusal (an expired
# policy, a bad signature) would not show that, so the code is pinned.
create_video big "$work/a.auth" "smoke oversize $(openssl rand -hex 4)" 1024 video/mp4
head -c 1025 /dev/urandom >"$work/big.bin"
status=$(upload_file big "$work/big.bin")
code=$(storage_error_code)
[[ $status == 400 && $code == EntityTooLarge ]] ||
  fail "upload larger than size_bytes is refused with 400 EntityTooLarge (status $status, code $code)"
ok "upload larger than size_bytes refused by the storage: $status $code"

# The READY video reaches B's following feed (video.ready, feed-service fan-out) and explore.
wait_feed_item following "$work/b.auth" "$clip_id" 15 '. != null' "video in B's following feed"
feed_playlist_url=$(jq -r '.playlist_url' "$work/item")
ok "video in B's following feed"
wait_feed_item explore "$work/b.auth" "$clip_id" 15 '. != null' "video in explore"
ok "video in explore"
# Feed items carry their author when user-service answers within 100 ms, so the check polls.
wait_feed_item following "$work/b.auth" "$clip_id" 15 ".author.user_id == \"$a_id\" and .author.handle == \"$a_handle\"" \
  "feed item has A as author"
ok "feed item has A as author"
status=$(fetch "$feed_playlist_url" "$work/feed-master.m3u8")
[[ $status == 200 ]] && grep -q '^#EXT-X-STREAM-INF' "$work/feed-master.m3u8" ||
  fail "anonymous GET of the feed item's playlist_url is 200 with #EXT-X-STREAM-INF (status $status)"
ok "anonymous GET of the feed item's playlist_url"

# 12. Likes: B likes twice (idempotent), counted once and seen as B's own like, not A's; then B
# unlikes. The feed carries stats only when engagement-service answers in time, so every stats
# check polls.
for i in 1 2; do
  status=$(request PUT "/videos/$clip_id/like" "$work/b.auth")
  [[ $status == 204 ]] || fail "B likes the video, call $i (status $status, $(problem_summary))"
done
ok "B likes the video twice: 204"
wait_feed_item explore "$work/b.auth" "$clip_id" 15 '.stats.like_count == 1 and .stats.liked_by_me == true' \
  "like_count 1, liked_by_me true for B"
ok "like_count 1, liked_by_me true for B"
wait_feed_item explore "$work/a.auth" "$clip_id" 15 '.stats.like_count == 1 and .stats.liked_by_me == false' \
  "like_count 1, liked_by_me false for A"
ok "like_count 1, liked_by_me false for A"
status=$(request DELETE "/videos/$clip_id/like" "$work/b.auth")
[[ $status == 204 ]] || fail "B unlikes the video (status $status, $(problem_summary))"
wait_feed_item explore "$work/b.auth" "$clip_id" 15 '.stats.like_count == 0 and .stats.liked_by_me == false' \
  "like_count 0 after unlike"
ok "B unlikes the video: like_count 0"

# Views are counted asynchronously (engagement.views.v1, batched by engagement-service). The gateway counts one view per
# user and video every 60 s (RL-3): B's repeated views are still accepted with 202, but only the first is counted; A's
# view is counted too.
for i in 1 2 3; do
  status=$(request POST "/videos/$clip_id/views" "$work/b.auth")
  [[ $status == 202 ]] || fail "B records view $i (status $status, $(problem_summary))"
done
ok "B records 3 views: 202"
wait_feed_item explore "$work/b.auth" "$clip_id" 30 '.stats.view_count == 1' "view_count 1 after B's 3 views (RL-3)"
ok "view_count 1 after B's 3 views (RL-3)"
status=$(request POST "/videos/$clip_id/views" "$work/a.auth")
[[ $status == 202 ]] || fail "A records a view (status $status, $(problem_summary))"
wait_feed_item explore "$work/b.auth" "$clip_id" 30 '.stats.view_count == 2' "view_count 2 after A's view"
ok "A records a view: 202, view_count 2"

status=$(request GET "/feed/following?cursor=abc" "$work/b.auth")
[[ $status == 400 && $(field code) == INVALID_PAGE_TOKEN ]] ||
  fail "following feed with cursor=abc is 400 INVALID_PAGE_TOKEN (status $status, $(problem_summary))"
ok "following feed with cursor=abc: 400 INVALID_PAGE_TOKEN"

# B unfollows A (user.unfollowed): the video leaves B's following feed but stays in explore.
status=$(request DELETE "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "unfollow (status $status, $(problem_summary))"
ok "unfollow"
wait_feed_item following "$work/b.auth" "$clip_id" 15 '. == null' "video gone from B's following feed after unfollow"
ok "video gone from B's following feed after unfollow"
status=$(feed_item explore "$work/b.auth" "$clip_id")
[[ $status == 200 && $(<"$work/item") != null ]] ||
  fail "video still in explore after unfollow (status $status, $(item_summary))"
ok "video still in explore after unfollow"

# Premium videos: two of A's, the same clip. Only the preview is public; the full output is read through the playback
# route, which cuts the master to the caller's tier and signs segment URLs per video and rendition. Every URL comes from
# an answer, so the checks hold whether the store is path-style (compose, k3d) or a CDN (EKS).

# create_premium NAME: POST /videos of clip.mp4 as user A, premium; like create_video of lib.sh.
create_premium() {
  local status
  jq -n --arg t "smoke premium $(openssl rand -hex 4)" --argjson s "$clip_size" \
    '{title: $t, size_bytes: $s, content_type: "video/mp4", premium: true}' >"$work/$1.json"
  status=$(request POST /videos "$work/a.auth" "$work/$1.json")
  [[ $status == 201 && -n $(field video_id) && -n $(field upload_url) ]] ||
    fail "create premium video $1 (status $status, $(problem_summary))"
  printf -v "${1}_id" '%s' "$(field video_id)"
  mv "$work/body" "$work/$1.upload"
}

# signed_playlist NAME AUTH_FILE RENDITION: GET of video NAME's playlist of RENDITION through the playback route; sets
# <NAME>_segment to the URL of its first segment, which must carry a query (the signature).
signed_playlist() {
  local id_var="${1}_id" status segment
  status=$(request GET "/videos/${!id_var}/playback/$3.m3u8" "$2")
  segment=$(first_uri "$work/body")
  [[ $status == 200 && $segment =~ ^https?://[^?]+\?.+ ]] ||
    fail "GET playback $3.m3u8 of $1 is 200 with absolute signed segment URLs (status $status, $(problem_summary))"
  printf -v "${1}_segment" '%s' "$segment"
}

for name in p1 p2; do
  create_premium "$name"
  status=$(upload_file "$name" "$work/clip.mp4")
  [[ $status == 2?? ]] || fail "upload premium video $name (status $status, code $(storage_error_code))"
  status=$(complete_upload "$name" "$work/a.auth")
  [[ $status == 202 && $(field status) == PROCESSING ]] ||
    fail "complete premium video $name is 202 PROCESSING (status $status, $(problem_summary))"
done
ok "create, upload and complete two premium videos"
wait_ready p1 "$work/a.auth" 180
[[ $(field premium) == true && $(field entitlement_tier) == fhd ]] ||
  fail "author reads premium video: premium true, entitlement_tier fhd (got $(field premium), $(field entitlement_tier))"
wait_ready p2 "$work/a.auth" 180
ok "premium videos READY; the author holds fhd"

# B holds no tier yet: the answer names the preview only, never an object under premium/.
status=$(request GET "/videos/$p1_id" "$work/b.auth")
preview_url=$(field playlist_url)
preview_thumbnail_url=$(field thumbnail_url)
[[ $status == 200 && $(field premium) == true && -z $(field entitlement_tier) && $preview_url == */preview/"$p1_id"/* &&
  $preview_thumbnail_url == */preview/"$p1_id"/* ]] ||
  fail "B reads premium video: playlist_url and thumbnail_url under preview/, no entitlement_tier (status $status, $(problem_summary))"
ok "B reads premium video: preview playlist_url and thumbnail_url, no entitlement_tier"

status=$(fetch "$preview_url" "$work/preview-master.m3u8")
[[ $status == 200 ]] && grep -q '^#EXT-X-STREAM-INF' "$work/preview-master.m3u8" ||
  fail "anonymous GET of the preview master is 200 with #EXT-X-STREAM-INF (status $status)"
preview_variant_url=$(resolve "$preview_url" "$(first_uri "$work/preview-master.m3u8")")
status=$(fetch "$preview_variant_url" "$work/preview-variant.m3u8")
preview_segment_ref=$(first_uri "$work/preview-variant.m3u8")
[[ $status == 200 && -n $preview_segment_ref ]] || fail "anonymous GET of the preview playlist is 200 (status $status)"
status=$(fetch "$(resolve "$preview_variant_url" "$preview_segment_ref")" "$work/preview-segment")
[[ $status == 200 && -s $work/preview-segment ]] || fail "anonymous GET of a preview segment is 200 (status $status)"
status=$(fetch "$preview_thumbnail_url" "$work/preview-thumbnail")
[[ $status == 200 && -s $work/preview-thumbnail ]] || fail "anonymous GET of the preview thumbnail is 200 (status $status)"
ok "anonymous GET of the preview master, playlist, segment and thumbnail: 200"

# The author's signed playlist names the objects under premium/. Without a signature each is refused: the segment, the
# media playlist in its directory and the master one level up (<version>/<attempt>/<segment>).
signed_playlist p1 "$work/a.auth" 360p
premium_segment_url=${p1_segment%%\?*}
premium_attempt_url=${premium_segment_url%/*}
for object in "segment|$premium_segment_url" "media playlist|$premium_attempt_url/index_360p.m3u8" \
  "master|${premium_attempt_url%/*}/master.m3u8"; do
  status=$(fetch "${object#*|}" "$work/premium-object")
  [[ $status == 403 ]] || fail "anonymous GET of the premium ${object%%|*} is 403 (status $status)"
done
ok "anonymous GET of a premium segment, media playlist and master: 403"

status=$(request GET "/videos/$p1_id/playback/master.m3u8" "$work/b.auth")
[[ $status == 403 && $(field code) == NOT_ENTITLED ]] ||
  fail "B's master without a tier is 403 NOT_ENTITLED (status $status, $(problem_summary))"
ok "B's master without a tier: 403 NOT_ENTITLED"

jq -n '{tier: "sd"}' >"$work/tier.json"
status=$(request PUT "/me/entitlements/$p1_id" "$work/b.auth" "$work/tier.json")
[[ $status == 200 && $(field video_id) == "$p1_id" && $(field tier) == sd && -n $(field granted_at) ]] ||
  fail "B buys sd: 200 with the entitlement (status $status, $(problem_summary))"
ok "B buys sd: 200"

# The sd tier holds 360p of this 720p clip: the master names it alone, as a playback path.
status=$(request GET "/videos/$p1_id/playback/master.m3u8" "$work/b.auth")
renditions=$({ grep -v -e '^#' -e '^[[:space:]]*$' "$work/body" || true; } | tr -d '\r' | tr '\n' ' ')
[[ $status == 200 && $(<"$work/type") == application/vnd.apple.mpegurl* && $renditions == "360p.m3u8 " ]] ||
  fail "B's master with sd is 200 HLS naming 360p.m3u8 only (status $status, renditions '$renditions', $(problem_summary))"
ok "B's master with sd: 360p only"

signed_playlist p1 "$work/b.auth" 360p
status=$(fetch "$p1_segment" "$work/signed-segment")
[[ $status == 200 && -s $work/signed-segment ]] || fail "GET of a signed segment is 200 and not empty (status $status)"
ok "B's signed 360p playlist plays: segment 200"

status=$(request GET "/videos/$p1_id/playback/720p.m3u8" "$work/b.auth")
[[ $status == 403 && $(field code) == RENDITION_NOT_ENTITLED ]] ||
  fail "B's 720p playlist with sd is 403 RENDITION_NOT_ENTITLED (status $status, $(problem_summary))"
ok "B's 720p playlist with sd: 403 RENDITION_NOT_ENTITLED"

# A signature opens one video's rendition only: B's for p1 on a segment of p2 is refused.
signed_playlist p2 "$work/a.auth" 360p
status=$(fetch "${p2_segment%%\?*}?${p1_segment#*\?}" "$work/borrowed-segment")
[[ $status == 403 ]] || fail "p1's signature on a segment of p2 is 403 (status $status)"
ok "p1's signature on a segment of p2: 403"

# Refresh tokens stay in private files of $work, never on a command line: jq reads them from the response and writes the
# next request body.

# refresh_login NAME: logs user A in again and writes {refresh_token} of the answer to
# $work/<NAME>.json.
refresh_login() {
  local status
  status=$(request POST /auth/login "" "$work/a.cred")
  [[ $status == 200 && -n $(field refresh_token) && -n $(field refresh_expires_at) ]] ||
    fail "login returns refresh_token and refresh_expires_at (status $status, $(problem_summary))"
  jq '{refresh_token}' "$work/body" >"$work/$1.json"
  : >"$work/body"
}
# refresh_with NAME: POST /auth/refresh with $work/<NAME>.json; prints the HTTP status.
refresh_with() { request POST /auth/refresh "" "$work/$1.json"; }

refresh_login r1
ok "login returns a refresh token"

status=$(refresh_with r1)
[[ $status == 200 && -n $(field access_token) && -n $(field refresh_token) ]] ||
  fail "refresh is 200 with new tokens (status $status, $(problem_summary))"
jq '{refresh_token}' "$work/body" >"$work/r2.json"
jq -r '"Authorization: Bearer \(.access_token)"' "$work/body" >"$work/a2.auth"
: >"$work/body"
ok "refresh: 200 with new tokens"

status=$(request GET "/feed/explore?page_size=1" "$work/a2.auth")
[[ $status == 200 ]] || fail "refreshed access token reads explore (status $status, $(problem_summary))"
ok "refreshed access token works"

# Replaying the used token revokes the family, the token that replaced it included.
status=$(refresh_with r1)
[[ $status == 401 && $(field code) == INVALID_REFRESH_TOKEN ]] ||
  fail "refresh with a used token is 401 INVALID_REFRESH_TOKEN (status $status, $(problem_summary))"
ok "refresh with a used token: 401 INVALID_REFRESH_TOKEN"
status=$(refresh_with r2)
[[ $status == 401 && $(field code) == INVALID_REFRESH_TOKEN ]] ||
  fail "newest token of a replayed family is 401 INVALID_REFRESH_TOKEN (status $status, $(problem_summary))"
ok "newest token of the replayed family: 401 INVALID_REFRESH_TOKEN"

# Logout revokes a fresh login's family; a second logout succeeds too (idempotent).
refresh_login r3
for i in 1 2; do
  status=$(request POST /auth/logout "" "$work/r3.json")
  [[ $status == 204 ]] || fail "logout, call $i, is 204 (status $status, $(problem_summary))"
done
ok "logout twice: 204"
status=$(refresh_with r3)
[[ $status == 401 && $(field code) == INVALID_REFRESH_TOKEN ]] ||
  fail "refresh after logout is 401 INVALID_REFRESH_TOKEN (status $status, $(problem_summary))"
ok "refresh after logout: 401 INVALID_REFRESH_TOKEN"

echo "smoke: all steps passed"
