#!/usr/bin/env bash
# Measures admission webhook duration of the cluster's first sync for evidence.
# Reads apiserver metrics for image policy webhooks and Kyverno Prometheus metrics via port-forward.
# Usage, from anywhere: deploy/ci/verify-steps/admission-metrics.sh
# Design notes: docs/reference/ci.md.
set -uo pipefail

kc() { kubectl --context k3d-svp "$@"; }

# histogram METRIC LABEL PAIRS LE...: parses Prometheus histogram text from stdin and prints summary.
# Sums _count, _sum, mean, and cumulative buckets <= each LE for series matching PAIRS (or all).
# Outputs a NOTE line if required series or buckets are missing; never exits non-zero.
histogram() {
  awk -v metric="$1" -v label="$2" -v pairs="$3" -v les="${*:4}" '
    BEGIN { np = split(pairs, pr, "|"); nl = split(les, want, " ") }
    /^#/ || NF < 2 { next }
    {
      b = index($0, "{")
      if (b == 0) next
      name = substr($0, 1, b - 1)
      rest = substr($0, b + 1)
      lbl = substr(rest, 1, index(rest, "}") - 1)
      ok = (pairs == "")
      for (i = 1; i <= np; i++) if (index("," lbl ",", "," pr[i] ",") > 0) ok = 1
      if (!ok) next
      if (name == metric "_count") { count += $NF; has_count = 1 }
      else if (name == metric "_sum") { sum += $NF; has_sum = 1 }
      else if (name == metric "_bucket" && match(lbl, /le="[^"]*"/)) {
        le = substr(lbl, RSTART + 4, RLENGTH - 5)
        if (le != "+Inf") { bk[le + 0] += $NF; has_bk[le + 0] = 1 }
      }
    }
    END {
      if (!has_count || !has_sum) {
        print "NOTE  " label ": no " metric "_count and _sum series" (pairs == "" ? "" : " for " pairs) " in what was read"
        exit
      }
      for (i = 1; i <= nl; i++) if (!((want[i] + 0) in has_bk)) miss = miss " " want[i]
      if (miss != "") {
        print "NOTE  " label ": _count " count ", _sum " sprintf("%.3f", sum) " s, but no bucket le=" miss
        exit
      }
      line = sprintf("%s: _count %d, _sum %.3f s, mean %.3f s", label, count, sum, count > 0 ? sum / count : 0)
      for (i = 1; i <= nl; i++) line = line sprintf(", <= %s s: %d", want[i], bk[want[i] + 0])
      line = line sprintf(", > %s s: %d", want[nl], count - bk[want[nl] + 0])
      print line
    }'
}

names=$(kc get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json 2>/dev/null |
  jq -r '.webhooks[].name | select(startswith("ivpol."))') || names=
if [ -z "$names" ]; then
  echo "NOTE  apiserver: no webhook of an image policy (ivpol.*) in kyverno-resource-validating-webhook-cfg"
else
  pairs=$(sed '/^$/d; s/.*/name="&"/' <<<"$names" | paste -sd '|' -)
  kc get --raw /metrics 2>/dev/null | histogram apiserver_admission_webhook_admission_duration_seconds \
    "apiserver_admission_webhook_admission_duration_seconds{name=$(paste -sd ' ' - <<<"$names" | sed 's/ *$//')}" \
    "$pairs" 10 25
  echo "NOTE  that histogram has buckets up to 2.5, then 10, 25 and +Inf only: 20 s lies between le=10 and le=25, the 30 s timeout of the webhook between le=25 and +Inf; the mean is the only exact figure"
fi

port=19100
while nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1 && [ "$port" -lt 19120 ]; do port=$((port + 1)); done
if nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
  echo "NOTE  kyverno: no free port on 127.0.0.1 between 19100 and 19120 for a port-forward"
  exit 0
fi
kc -n kyverno port-forward --address 127.0.0.1 service/kyverno-svc-metrics "$port:8000" >/dev/null 2>&1 &
pid=$!
text=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  text=$(curl -sf --max-time 10 "http://127.0.0.1:$port/metrics") && break
  sleep 1
done
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
histogram kyverno_admission_review_duration_seconds kyverno_admission_review_duration_seconds "" 20 30 <<<"$text"
histogram kyverno_image_validating_policy_execution_duration_seconds \
  'kyverno_image_validating_policy_execution_duration_seconds{policy_name="svp-images"}' 'policy_name="svp-images"' \
  20 30 <<<"$text"
exit 0
