#!/usr/bin/env bash
# Tests for deploy/ci/verify-steps/admission-metrics.sh with a fake kubectl, curl and nc first on PATH: kubectl lists
# the webhooks of FAKE_WEBHOOKS (one name per line) in kyverno-resource-validating-webhook-cfg, answers get --raw
# /metrics with the file FAKE_APISERVER and runs a port-forward that only sleeps; curl answers with the file
# FAKE_KYVERNO once that port-forward has started; nc finds every port free unless FAKE_PORTS_BUSY=1. FAKE_KUBECTL_FAIL=1 makes kubectl fail as for a
# cluster that does not answer. The sample has the real buckets: the apiserver's 10, 25 and +Inf (two series of the
# Kyverno webhook, rejected false and true, and one of another webhook that must not count), Kyverno's 20 and 30
# (policy svp-images, and another policy). Every case exits 0: the measurement is evidence, not a gate. Runs on macOS
# and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/verify-steps/admission-metrics-test.sh
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
has() { if grep -qF -- "$3" "$work/$1.log"; then ok "$1: $2"; else fail "$1: $2"; fi; }
lacks() { if grep -qF -- "$3" "$work/$1.log"; then fail "$1: $2"; else ok "$1: $2"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_KUBECTL_FAIL:-}" != 1 ] || { echo "The connection to the server was refused" >&2; exit 1; }
[ "$1 $2" = "--context k3d-svp" ] || exit 2
shift 2
case "$*" in
  "get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json")
    jq -Rn '{webhooks: [inputs | select(. != "") | {name: .}]}' "$FAKE_WEBHOOKS" ;;
  "get --raw /metrics") cat "$FAKE_APISERVER" ;;
  "-n kyverno port-forward --address 127.0.0.1 service/kyverno-svc-metrics "*":8000") touch "$FAKE_FORWARDED" && exec sleep 30 ;;
  *) exit 2 ;;
esac
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Only once the port-forward runs, as Kyverno's metrics answer only through it.
[ -f "$FAKE_FORWARDED" ] || exit 7
case " $* " in *" http://127.0.0.1:191"[0-2][0-9]"/metrics "*) cat "$FAKE_KYVERNO" ;; *) exit 7 ;; esac
EOF
cat >"$work/bin/nc" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_PORTS_BUSY:-}" = 1 ]
EOF
chmod 755 "$work/bin/kubectl" "$work/bin/curl" "$work/bin/nc"

hook=ivpol.validate.kyverno.svc-ignore-finegrained-svp-images
other=validate.kyverno.svc-fail
cat >"$work/apiserver.txt" <<SAMPLE
# TYPE apiserver_admission_webhook_admission_duration_seconds histogram
apiserver_admission_webhook_admission_duration_seconds_bucket{le="10",name="$hook",operation="CREATE",rejected="false",type="validating"} 7
apiserver_admission_webhook_admission_duration_seconds_bucket{le="25",name="$hook",operation="CREATE",rejected="false",type="validating"} 9
apiserver_admission_webhook_admission_duration_seconds_bucket{le="+Inf",name="$hook",operation="CREATE",rejected="false",type="validating"} 10
apiserver_admission_webhook_admission_duration_seconds_sum{name="$hook",operation="CREATE",rejected="false",type="validating"} 50.5
apiserver_admission_webhook_admission_duration_seconds_count{name="$hook",operation="CREATE",rejected="false",type="validating"} 10
apiserver_admission_webhook_admission_duration_seconds_bucket{le="10",name="$hook",operation="CREATE",rejected="true",type="validating"} 1
apiserver_admission_webhook_admission_duration_seconds_bucket{le="25",name="$hook",operation="CREATE",rejected="true",type="validating"} 2
apiserver_admission_webhook_admission_duration_seconds_bucket{le="+Inf",name="$hook",operation="CREATE",rejected="true",type="validating"} 2
apiserver_admission_webhook_admission_duration_seconds_sum{name="$hook",operation="CREATE",rejected="true",type="validating"} 9.5
apiserver_admission_webhook_admission_duration_seconds_count{name="$hook",operation="CREATE",rejected="true",type="validating"} 2
apiserver_admission_webhook_admission_duration_seconds_bucket{le="10",name="$other",operation="CREATE",rejected="false",type="validating"} 100
apiserver_admission_webhook_admission_duration_seconds_bucket{le="25",name="$other",operation="CREATE",rejected="false",type="validating"} 100
apiserver_admission_webhook_admission_duration_seconds_bucket{le="+Inf",name="$other",operation="CREATE",rejected="false",type="validating"} 100
apiserver_admission_webhook_admission_duration_seconds_sum{name="$other",operation="CREATE",rejected="false",type="validating"} 3
apiserver_admission_webhook_admission_duration_seconds_count{name="$other",operation="CREATE",rejected="false",type="validating"} 100
SAMPLE
cat >"$work/kyverno.txt" <<'SAMPLE'
kyverno_admission_review_duration_seconds_bucket{le="20",resource_kind="Pod"} 40
kyverno_admission_review_duration_seconds_bucket{le="30",resource_kind="Pod"} 44
kyverno_admission_review_duration_seconds_bucket{le="+Inf",resource_kind="Pod"} 45
kyverno_admission_review_duration_seconds_sum{resource_kind="Pod"} 90
kyverno_admission_review_duration_seconds_count{resource_kind="Pod"} 45
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="20",policy_name="svp-images"} 5
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="30",policy_name="svp-images"} 6
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="+Inf",policy_name="svp-images"} 6
kyverno_image_validating_policy_execution_duration_seconds_sum{policy_name="svp-images"} 60
kyverno_image_validating_policy_execution_duration_seconds_count{policy_name="svp-images"} 6
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="20",policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="30",policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_bucket{le="+Inf",policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_sum{policy_name="other"} 900
kyverno_image_validating_policy_execution_duration_seconds_count{policy_name="other"} 900
SAMPLE
printf '%s\n' "$hook" "validate.kyverno.svc-fail-finegrained-svp-policy" >"$work/webhooks.txt"

# run NAME [VAR=VALUE...]: admission-metrics.sh with the fakes over the samples (VAR=VALUE overrides a fake's file or
# switch); its output in $work/NAME.log. A status other than 0 is a failed check.
run() {
  local name=$1 rc=0
  shift
  rm -f "$work/forwarded"
  env PATH="$work/bin:$PATH" FAKE_FORWARDED="$work/forwarded" FAKE_WEBHOOKS="$work/webhooks.txt" FAKE_APISERVER="$work/apiserver.txt" \
    FAKE_KYVERNO="$work/kyverno.txt" "$@" "$here/admission-metrics.sh" >"$work/$name.log" 2>&1 </dev/null || rc=$?
  [ "$rc" = 0 ] && ok "$name: exits 0" || fail "$name: exits 0 (got $rc)"
}

run all
has all "the apiserver line adds the series of the webhook (rejected false and true) and leaves the other webhook out" \
  "apiserver_admission_webhook_admission_duration_seconds{name=$hook}: _count 12, _sum 60.000 s, mean 5.000 s, <= 10 s: 8, <= 25 s: 11, > 25 s: 1"
has all "it says where 20 s and 30 s fall in the buckets" \
  "20 s lies between le=10 and le=25, the 30 s timeout of the webhook between le=25 and +Inf"
has all "the Kyverno admission review line" \
  "kyverno_admission_review_duration_seconds: _count 45, _sum 90.000 s, mean 2.000 s, <= 20 s: 40, <= 30 s: 44, > 30 s: 1"
has all "the line of policy svp-images leaves the other policy out" \
  'kyverno_image_validating_policy_execution_duration_seconds{policy_name="svp-images"}: _count 6, _sum 60.000 s, mean 10.000 s, <= 20 s: 5, <= 30 s: 6, > 30 s: 0'
lacks all "only ivpol.* webhooks are read from the configuration" "svc-fail-finegrained-svp-policy"

printf '%s\n' ivpol.validate.kyverno.svc-fail-finegrained-other >"$work/webhooks-other.txt"
run other FAKE_WEBHOOKS="$work/webhooks-other.txt"
has other "a webhook with no series is a NOTE" \
  "NOTE  apiserver_admission_webhook_admission_duration_seconds{name=ivpol.validate.kyverno.svc-fail-finegrained-other}: no apiserver_admission_webhook_admission_duration_seconds_count and _sum series"
printf '%s\n' validate.kyverno.svc-fail >"$work/webhooks-none.txt"
run none FAKE_WEBHOOKS="$work/webhooks-none.txt"
has none "no webhook of an image policy is a NOTE" "NOTE  apiserver: no webhook of an image policy (ivpol.*)"
has none "Kyverno's histograms are still read" "kyverno_admission_review_duration_seconds: _count 45"
sed '/le="25"/d' "$work/apiserver.txt" >"$work/apiserver-nobucket.txt"
run nobucket FAKE_APISERVER="$work/apiserver-nobucket.txt"
has nobucket "a missing bucket is a NOTE that says which" "but no bucket le= 25"
: >"$work/empty.txt"
run kyverno-empty FAKE_KYVERNO="$work/empty.txt"
has kyverno-empty "no Kyverno metrics is a NOTE for the review histogram" \
  "NOTE  kyverno_admission_review_duration_seconds: no kyverno_admission_review_duration_seconds_count and _sum series in what was read"
has kyverno-empty "and for the policy histogram" \
  'NOTE  kyverno_image_validating_policy_execution_duration_seconds{policy_name="svp-images"}: no'
run busy FAKE_PORTS_BUSY=1
has busy "no free port is a NOTE" "NOTE  kyverno: no free port on 127.0.0.1 between 19100 and 19120 for a port-forward"
run down FAKE_KUBECTL_FAIL=1
has down "a cluster that does not answer is NOTE lines" "NOTE  apiserver: no webhook of an image policy (ivpol.*)"
lacks down "and no line of a histogram" "_count 45"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
