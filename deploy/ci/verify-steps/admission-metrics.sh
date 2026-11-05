#!/usr/bin/env bash
# Step gitops-admission-metrics of job gitops of .github/workflows/verify.yml: the admission time of the first sync of
# the cluster, kept as evidence (the condition of ADR-0040 §6: 20 s without cache, the webhook's timeout 30 s). The
# step runs right after the build step, before k8s-smoke and the drills, so the histograms hold the first sync only.
#
# Prints, from the apiserver (kubectl get --raw /metrics), the summary of
# apiserver_admission_webhook_admission_duration_seconds for the webhooks of the image policies in
# kyverno-resource-validating-webhook-cfg (names ivpol.*; that histogram has the buckets 10, 25 and +Inf only: _count,
# _sum, the mean, <= 10, <= 25, > 25), and from Kyverno (a port-forward of Service kyverno-svc-metrics on a free port
# of 127.0.0.1 between 19100 and 19120, as the namespace's default-deny NetworkPolicy shuts the apiserver's proxy) the
# same for kyverno_admission_review_duration_seconds and, of policy svp-images (label policy_name; svp-policy is the
# chart and webhook name), kyverno_image_validating_policy_execution_duration_seconds (<= 20, <= 30; the buckets of the
# chart at the pinned version are 0.005 ... 10, 15, 20, 25, 30). Each histogram is added up over every label set of
# the series asked for, as it is split by labels the question does not ask about. A metric, a bucket or a port that is
# missing is a NOTE line: the measurement is evidence, not a gate, and the step never fails.
#
# kubectl, curl and nc are those on PATH; kubectl always on context k3d-svp. Usage, from anywhere:
# deploy/ci/verify-steps/admission-metrics.sh
set -uo pipefail

kc() { kubectl --context k3d-svp "$@"; }

# histogram METRIC LABEL PAIRS LE...: reads Prometheus text on stdin and prints one line for the histogram METRIC named
# LABEL: _count, _sum, the mean, the number of observations <= each LE, and the number above the last LE (_count less
# its bucket), added up over every series that holds one of PAIRS (name="value" pairs separated by |; empty: every
# series). A NOTE line instead when it has no series for PAIRS or lacks one of the buckets.
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

# --- The apiserver's view of the webhooks of the image policies.
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

# --- Kyverno's own view: the whole review, and the execution of policy svp-images.
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
