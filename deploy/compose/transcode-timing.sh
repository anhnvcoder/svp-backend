#!/usr/bin/env bash
# Measures the time from "upload complete" to READY of one clip uploaded N times through the gateway: registers one
# user, then N times creates a video, uploads the clip, completes it and waits for READY. Prints one `<video_id>
# <seconds>` line per upload (wait_ready's seconds, 1 s resolution) and a last `p50=<s> max=<s>` line from those.

# A video that goes FAILED or is not READY in time exits non-zero. Needs curl, jq and openssl on the host; lib.sh resets
# the register rate limit in the stack's Valkey.

# Usage: deploy/compose/transcode-timing.sh <base-url> <clip> <n>
# LOCAL LAB ONLY: lib.sh deletes the register rate limit keys in the Valkey of the stack SVP_STACK names; `make
# transcode-timing` and `make eks-transcode-timing` set it. Never point it at a shared or production stack.
# Design notes: docs/reference/compose.md.
set -euo pipefail

# The arguments are checked before lib.sh is sourced: sourcing it already reaches the stack's Valkey.
usage() {
  echo "FAIL  $1; usage: deploy/compose/transcode-timing.sh <base-url> <clip> <n>" >&2
  exit 1
}
[[ $# == 3 ]] || usage "expected 3 arguments, got $#"
base=$1
clip=$2
n=$3
[[ $base == http://* || $base == https://* ]] || usage "base-url must start with http:// or https:// (got '$base')"
[[ -f $clip ]] || usage "clip '$clip' is not a file"
[[ $n =~ ^[1-9][0-9]*$ ]] || usage "n must be a positive integer (got '$n')"

# shellcheck source=deploy/compose/lib.sh
source "$(dirname "$0")/lib.sh"

# Seconds one video may take to become READY. 600 s is ten times the 60 s reference clip: it covers the queue wait of
# MediaConvert and ffmpeg on a laptop, and still stops a stuck video instead of waiting for it forever.
ready_timeout=600

# p50_max: reads `<video_id> <seconds>` lines on stdin; the p50 of an odd count is the middle value of the sorted
# seconds, of an even count the mean of the two middle values.
p50_max() { awk '{print $2}' | sort -n | awk '{a[NR]=$1} END {print "p50=" (NR % 2 ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2) " max=" a[NR]}'; }

wait_gateway_ready 60
new_user t
size=$(file_size "$clip")
: >"$work/times"
for ((i = 1; i <= n; i++)); do
  create_video v "$work/t.auth" "timing $(openssl rand -hex 4)" "$size" video/mp4
  status=$(upload_file v "$clip")
  [[ $status == 2?? ]] || fail "upload $i to its presigned form (status $status, code $(storage_error_code))"
  status=$(complete_upload v "$work/t.auth")
  [[ $status == 202 && $(field status) == PROCESSING ]] ||
    fail "complete upload $i is 202 PROCESSING (status $status, $(problem_summary), video status $(field status))"
  wait_ready v "$work/t.auth" "$ready_timeout"
  echo "$v_id $v_wait" | tee -a "$work/times"
done
p50_max <"$work/times"
