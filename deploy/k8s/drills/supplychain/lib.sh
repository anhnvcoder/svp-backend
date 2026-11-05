# shellcheck shell=bash
# Helpers of the supply chain drill (deploy/k8s/drills/supplychain/case-*/chainsaw-test.yaml): the image policy of
# namespace svp (Kyverno ImageValidatingPolicy svp-images, chart deploy/helm/svp-policy) on cluster svp. Each test is
# one case of the drill; what each case shows, and why, is written in its test. Every script step of a test sources
# this file from the test's folder (`. ../lib.sh`) with, in its environment:
#   CASE               the letter of the case (a…m), which every verdict line and the state folder name;
#   CALLER_KUBECONFIG  env('KUBECONFIG') of the chainsaw process (empty: ~/.kube/config). kubectl and helm use it and
#                      always name context k3d-svp, not the copy of the cluster Chainsaw gives each script;
#   UNSIGNED, VULNERABLE, NO_PROVENANCE, ENFORCE_TMP
#                      the Chainsaw values unsigned, vulnerable, noProvenance and enforceTmp (make drill-k8s-supplychain
#                      SUPPLYCHAIN_UNSIGNED=… SUPPLYCHAIN_VULNERABLE=… SUPPLYCHAIN_NO_PROVENANCE=…|none
#                      SUPPLYCHAIN_ENFORCE_TMP=1), empty when not given.
#
# A check prints one line `PASS|FAIL|SKIP  (<case>) <detail>[ [<ms> ms]]` and its script exits 1 after a FAIL. Chainsaw
# has no skip decided while a test runs, so a SKIP is a passing step whose line gives the reason; the steps of that
# case after it print `ok    (<case>) … not run` and pass. A step that finds the case cannot run (an image or an
# attestation missing) fails, and the test stops there, its cleanups still run.
#
# What a step learns for the steps after it (the path, the policy's webhooks at the start, what to undo) goes to
# .k8s/drills/supplychain-state/case-<case>/ (ignored by git): made anew by the test's first step, removed by its last
# cleanup. The drill reads no Secret and calls no API of the gateway, so it deletes no rate limit key.
set -euo pipefail
: "${CASE:?CASE, the letter of the case, is not set}"

# The cluster of Chainsaw's own client, which runs the declarative steps: the server of the kubeconfig Chainsaw puts in
# KUBECONFIG for a script. preflight checks it is context k3d-svp.
chainsaw_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
export KUBECONFIG=${CALLER_KUBECONFIG:-}
# kc and hc of deploy/k8s/lib.sh name this context on every call.
export SVP_KUBE_CONTEXT=k3d-svp
# cosign_ (cosign from PATH, otherwise the pinned COSIGN_IMAGE; verification only), sign_identity,
# check_vuln_statement and provenance_absent; with them deploy/k8s/lib.sh (kc, hc, ok, fail, wait_until,
# image_policy_ready, release_sources, source_of_repository).
# shellcheck source=deploy/ci/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../../ci/common.sh"

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
state=$repo_root/.k8s/drills/supplychain-state/case-$CASE

policy=svp-images
policy_values=$repo_root/deploy/helm/svp-policy/values.yaml
admission=kyverno-admission-controller
owner=svp-drill-supplychain
deploy_name=drill-supplychain-unsigned
rebuild="gh workflow run images.yml --repo anhnvcoder/svp-backend --ref main -f drill=true"
# Case k: CloudNativePG's operator v1.28.1, signed with cosign's older format (a .sig image beside it, as the project's
# releases are) by its release workflow.
vendor_image=ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1@sha256:0edcdaefaa83d68822158cf4370d83d185c54db2b6beb7e0848aca16eafa6344
vendor_subject=https://github.com/cloudnative-pg/cloudnative-pg/.github/workflows/release-publish.yml@refs/tags/v1.28.1
github_issuer=https://token.actions.githubusercontent.com

# The release sources the policy admits (files/sources.json of its chart): this repository's own, backend, holds the
# drill images and the images of cases a, e and f; every image a case reads with cosign is read with the identity of
# the source whose prefix it is under (image_identity), as Kyverno picks its attestor.
sources=$(release_sources) || exit 1
prefix=$(jq -r '.sources[] | select(.name == "backend") | .imagePrefix' <<<"$sources")
[[ $prefix == */ ]] || fail "read the imagePrefix of release source backend (got '$prefix')"
# The maximum age the policy checks, for the cases that read an attestation's age themselves (c, l).
max_age=$(sed -n 's/^  maxAttestationAge: *//p' "$policy_values")
[[ $max_age =~ ^[0-9]+[hms]$ ]] ||
  fail "read imageVerification.maxAttestationAge of deploy/helm/svp-policy/values.yaml as <number>h, m or s (got '$max_age')"
case $max_age in
*h) max_age_s=$((${max_age%h} * 3600)) ;;
*m) max_age_s=$((${max_age%m} * 60)) ;;
*s) max_age_s=${max_age%s} ;;
esac
# Every <imagePrefix><name> the policy's first check admits: a service or drill image of a source, under its prefix.
admitted_names=$(jq -r '.sources[] | .imagePrefix as $p | (.services + .drillImages)[] | $p + .' <<<"$sources")

# st NAME: what an earlier step of the test recorded under NAME (empty when nothing); st_set NAME VALUE records it.
st() { cat "$state/$1" 2>/dev/null || true; }
st_set() { printf '%s' "$2" >"$state/$1"; }

failed=
# result PASS|FAIL|SKIP DETAIL [MS]: the verdict line of a check of this case.
result() {
  printf '%-4s  (%s) %s%s\n' "$1" "$CASE" "$2" "${3:+ [${3} ms]}"
  [[ $1 != FAIL ]] || failed=1
}
# skip REASON: the case cannot run on this cluster or with these images; its later steps do not run.
skip() {
  result SKIP "$1"
  st_set skip "$1"
}
# not_skipped WHAT: false, after a line saying WHAT is not run, when an earlier step skipped the case.
not_skipped() {
  [ -f "$state/skip" ] || return 0
  ok "($CASE) $1: not run, the case is SKIP above"
  return 1
}
# finish: the script's status, 1 when one of its checks failed.
finish() { [ -z "$failed" ]; }

# now: seconds since the epoch with milliseconds (bash 3.2 has no EPOCHREALTIME).
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# timed COMMAND...: runs COMMAND; sets out (its stdout and stderr), rc and ms (wall time). Never at the end of a pipe,
# where it would run in a subshell and set nothing.
timed() {
  local t0 t1
  t0=$(now)
  rc=0
  out=$("$@" 2>&1) || rc=$?
  t1=$(now)
  ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%d", (b - a) * 1000 }')
}

# pod NAME NAMESPACE IMAGE [LABEL]: a pod that meets Pod Security "restricted" in every respect, so what refuses it is
# the image policy, never PSA; LABEL is the value of label svp-drill.
pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels:
    app.kubernetes.io/managed-by: $owner
    svp-drill: ${4:-supplychain}
EOF
  pod_spec "$3"
}

# pod_spec IMAGE: the spec of those pods, at the indentation of a Pod (sed indents it for a pod template).
pod_spec() {
  cat <<EOF
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: c
      image: $1
      command: ["sleep", "60"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 32Mi}
EOF
}

# dry_run NAME NAMESPACE IMAGE [LABEL]: a server-side dry run of pod NAME; out, rc, ms as timed.
dry_run() {
  pod "$@" >"$work/pod.yaml"
  timed kc create --dry-run=server -f "$work/pod.yaml"
}

# reason: Kyverno's message out of $out (what follows "denied the request: "), or the first line of $out.
reason() {
  local r
  r=$(sed -n 's/.*denied the request: //p' <<<"$out" | head -n 1)
  printf '%s' "${r:-$(head -n 1 <<<"$out")}"
}

# admitted WHAT [MARK]: PASS when the command succeeded and $out holds MARK, the line kubectl prints for an admitted
# dry run: "(server dry run)" for create (the default), "pod/<name> patched" for patch, which prints no dry-run suffix.
admitted() {
  local mark=${2:-"(server dry run)"}
  if [[ $rc == 0 && $out == *"$mark"* ]]; then
    result PASS "$1: admitted" "$ms"
  else
    result FAIL "$1: admitted (got: $(reason))" "$ms"
  fi
}

# refused WANT WHAT [MAX_MS]: PASS when the request was refused with a message holding WANT (and, with MAX_MS, in less
# than MAX_MS). The message of the rule that should refuse it, not any refusal.
refused() {
  if [[ $rc == 0 ]]; then
    result FAIL "$2: refused with '$1' (it was admitted)" "$ms"
  elif [[ $out != *"$1"* ]]; then
    result FAIL "$2: refused with '$1' (got: $(reason))" "$ms"
  elif [[ -n ${3:-} ]] && ((ms >= $3)); then
    result FAIL "$2: refused within $3 ms (took $ms ms): $(reason)" "$ms"
  else
    result PASS "$2: $(reason)" "$ms"
  fi
}

# image_identity IMAGE: sets policy_issuer and policy_subject to the identity of the release source of IMAGE
# (REPOSITORY@DIGEST, or with a tag), what the policy verifies it with.
image_identity() {
  local repo=${1%@*} name
  [[ $repo == */*:* ]] && repo=${repo%:*}
  name=$(source_of_repository "$repo") || exit 1
  sign_identity "$name"
  policy_issuer=$sign_issuer policy_subject=$sign_subject
}

# check_inputs: each input image given is <imagePrefix of a release source><one of its services or drill images>
# @sha256:<64 hex>; noProvenance may also be none.
check_inputs() {
  local pair var value
  for pair in UNSIGNED:unsigned VULNERABLE:vulnerable NO_PROVENANCE:noProvenance; do
    var=${pair%%:*}
    value=${!var:-}
    [ -n "$value" ] || continue
    [ "$var" != NO_PROVENANCE ] || [ "$value" != none ] || continue
    [[ $value =~ ^([a-z0-9._/-]+)(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] &&
      grep -qxF -- "${BASH_REMATCH[1]}" <<<"$admitted_names" ||
      fail "value ${pair#*:} must be <imagePrefix of a release source><one of its services or drill images>@sha256:<64 hex>, one of: $(tr "\n" " " <<<"$admitted_names")(got '$value')"
  done
}

# Webhooks of the image policies (names starting ivpol.) in Kyverno's resource webhook configuration: what scopes them
# (selectors, rules, match conditions) and failurePolicy, as sorted JSON. Kyverno writes them; the drill must leave
# them as it found them.
webhooks() {
  kc get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json | jq -S -c '[.webhooks[]
    | select(.name | startswith("ivpol."))
    | {name, failurePolicy, namespaceSelector, objectSelector, rules, matchConditions, timeoutSeconds}] | sort_by(.name)'
}
# webhooks_line JSON: the webhooks as one readable line (name, failurePolicy, namespaceSelector).
webhooks_line() { jq -r 'map("\(.name) \(.failurePolicy) \(.namespaceSelector | tostring)") | join("; ")' <<<"$1"; }

# policy_checks_provenance NAME: prints yes when ImageValidatingPolicy NAME has attestation provenance (chart svp-policy
# rendered with requireProvenance), no otherwise.
policy_checks_provenance() {
  kc get imagevalidatingpolicies.policies.kyverno.io "$1" -o json |
    jq -r 'if any(.spec.attestations[]?; .name == "provenance") then "yes" else "no" end'
}

# policy_mode NAME: Deny or Audit, the validationActions of ImageValidatingPolicy NAME.
policy_mode() { kc get imagevalidatingpolicies.policies.kyverno.io "$1" -o jsonpath='{.spec.validationActions[*]}'; }

# preflight: the first step of every test. Chainsaw runs on context k3d-svp; the inputs are well formed; the state of
# the test is made anew with the path (gitops when Argo CD's root Application svp-root exists, dev otherwise), the
# mode of the policy, whether it checks provenance and its webhooks now (compared again by webhooks_back at the end).
preflight() {
  local k3d mode provenance hooks path=dev
  k3d=$(kubectl config view --minify --context k3d-svp -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  [ -n "$k3d" ] && [ "$chainsaw_server" = "$k3d" ] ||
    fail "chainsaw runs on ${chainsaw_server:-no cluster}, not on context k3d-svp (${k3d:-not in the kubeconfig}): run it with --kube-context k3d-svp"
  check_inputs
  rm -rf "$state"
  mkdir -p "$state"
  if kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1; then path=gitops; fi
  mode=$(policy_mode "$policy") || fail "read ImageValidatingPolicy $policy (is Kyverno installed? make k8s-up)"
  image_policy_ready "$policy" || fail "ImageValidatingPolicy $policy is not ready with its webhook"
  provenance=$(policy_checks_provenance "$policy") || fail "read the attestations of ImageValidatingPolicy $policy"
  hooks=$(webhooks) || fail "read Kyverno's webhook configuration kyverno-resource-validating-webhook-cfg"
  st_set path "$path"
  st_set mode "$mode"
  st_set provenance "$provenance"
  st_set webhooks-start "$hooks"
  ok "($CASE) cluster on the $path path, policy $policy in ${mode:-?}, provenance checked: $provenance; its webhooks: $(webhooks_line "$hooks")"
}

# enforce_tmp_allowed: fails unless the policy may be put in Enforce for the case: the dev path, whose policy is in
# Audit and refuses nothing, with enforceTmp.
enforce_tmp_allowed() {
  [[ $(st path) == dev && ${ENFORCE_TMP:-} =~ ^(1|true)$ ]] ||
    fail "policy $policy is in $(st mode), which refuses nothing (the dev path's mode): run SUPPLYCHAIN_ENFORCE_TMP=1 make drill-k8s-supplychain, which switches release svp-policy to Enforce for each case and back to Audit at its end"
}

# enforce_tmp_up: the policy in Enforce for the case. Nothing to do when it is (the GitOps path); on the dev path, with
# enforceTmp, release svp-policy upgraded to Enforce, recorded first so that audit_back puts Audit back whatever
# happens. Case k, which needs Audit, runs before every case that calls this: its test is the drill's one test that is
# not concurrent, and Chainsaw runs those first.
enforce_tmp_up() {
  [ "$(st mode)" != Deny ] || return 0
  enforce_tmp_allowed
  st_set enforce-tmp 1
  set_mode Enforce
  ok "($CASE) release svp-policy in Enforce for the case (enforceTmp)"
}

# audit_back: release svp-policy back in Audit when enforce_tmp_up put it in Enforce.
audit_back() {
  [ -n "$(st enforce-tmp)" ] || return 0
  if (set_mode Audit); then
    rm -f "$state/enforce-tmp"
    ok "($CASE) release svp-policy back in Audit"
  else
    echo "FAIL  ($CASE) put release svp-policy back in Audit: make k8s-up" >&2
    return 1
  fi
}

# webhooks_back: the last cleanup of every test. The webhooks of the image policies are as preflight found them, then
# the state of the test is removed.
webhooks_back() {
  local start now
  start=$(st webhooks-start)
  if [ -n "$start" ]; then
    now=$(webhooks 2>&1) || true
    if [[ $now == "$start" ]]; then
      ok "($CASE) the policy's webhooks are as at the start of the case: $(webhooks_line "$start")"
    else
      echo "FAIL  ($CASE) the policy's webhooks differ from the start of the case (start: $start; now: $now)" >&2
      return 1
    fi
  fi
  rm -rf "$state"
}

# kyverno_up: the admission controller has its replica ready and policy svp-images is ready with its webhook.
kyverno_up() {
  kc -n kyverno rollout status deployment "$admission" --timeout=180s >/dev/null ||
    fail "deployment kyverno/$admission ready within 180s"
  wait_until 120 "ImageValidatingPolicy $policy ready with its webhook" image_policy_ready "$policy"
}

# set_mode MODE: release svp-policy upgraded with imageVerification.mode MODE (the dev path only), then waits until
# Kyverno has the policy ready with the webhook of that failurePolicy.
set_mode() {
  local want=Ignore
  [[ $1 == Enforce ]] && want=Fail
  hc upgrade svp-policy "$repo_root/deploy/helm/svp-policy" --namespace kyverno \
    --set "imageVerification.mode=$1" --wait --timeout 2m >/dev/null || fail "upgrade release svp-policy to $1"
  wait_until 120 "ImageValidatingPolicy $policy ready in $1 with a webhook of failurePolicy $want" \
    image_policy_ready "$policy" "$want"
}

# apply_policy NAME FILE: applies temporary ImageValidatingPolicy NAME (manifest FILE) and waits until Kyverno has it
# ready with its webhook; NAME is recorded first, so delete_temp_policies deletes it whatever happens.
apply_policy() {
  printf '%s\n' "$1" >>"$state/temp-policies"
  kc apply -f "$2" >/dev/null || fail "apply the temporary ImageValidatingPolicy $1"
  wait_until 120 "temporary ImageValidatingPolicy $1 ready with its webhook" image_policy_ready "$1" Fail
}

# drill_webhooks_gone: no webhook of a temporary policy is left. Each selects pods by label svp-drill, which policy
# svp-images never does. Kyverno removes a deleted policy's webhook a moment after the policy (informer, queue, then
# an update of the configuration), so whatever compares the webhooks afterwards waits for this first.
drill_webhooks_gone() {
  kc get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json | jq -e '[.webhooks[]
    | select(.name | startswith("ivpol."))
    | select((.objectSelector.matchLabels // {})["svp-drill"] != null)] | length == 0' >/dev/null
}

# delete_temp_policies: every temporary policy apply_policy recorded deleted, then their webhooks gone. Goes on after
# a failure, and fails at the end.
delete_temp_policies() {
  local p rc=0
  [ -s "$state/temp-policies" ] || return 0
  for p in $(sort -u "$state/temp-policies"); do
    if kc delete imagevalidatingpolicies.policies.kyverno.io "$p" --ignore-not-found --wait=true >/dev/null; then
      ok "($CASE) temporary ImageValidatingPolicy $p deleted"
    else
      echo "FAIL  ($CASE) delete the temporary policy: kubectl --context k3d-svp delete imagevalidatingpolicies.policies.kyverno.io $p" >&2
      rc=1
    fi
  done
  # In a subshell: wait_until's fail would otherwise end the script before the status below.
  if (wait_until 120 "Kyverno removed the webhooks of the temporary policies" drill_webhooks_gone); then
    ok "($CASE) the webhooks of the temporary policies are gone"
  else
    rc=1
  fi
  [ "$rc" -ne 0 ] || rm -f "$state/temp-policies"
  return "$rc"
}

# signed_image: the first image by digest under backend's prefix that a pod of svp runs (a GHCR release), empty when
# none does (the dev path's images are unsigned dev builds).
signed_image() {
  kc -n svp get pods -o json | jq -r --arg p "$prefix" '[.items[].spec.containers[].image
    | select(startswith($p) and test("@sha256:[0-9a-f]{64}$"))] | first // empty'
}

# local_image: the first image of the local registry a pod of svp runs, else a dev image of it by name.
local_image() {
  local image
  image=$(kc -n svp get pods -o json | jq -r '[.items[].spec.containers[].image
    | select(startswith("k3d-svp-registry:5111/"))] | first // empty')
  echo "${image:-k3d-svp-registry:5111/svp/gateway:dev-000000000000}"
}

# unsigned_image: value unsigned when given, otherwise the newest drill-unsigned under the prefix of release source
# backend on GHCR (deploy/ci/ghcr-digest.sh newest, anonymous; its last error line in $work/unsigned.err), empty when
# there is none. CI pushes it with no signature and no attestation, so nothing on GHCR refers to it. Not a platform
# manifest of a signed release's index: in Sigstore bundles the release's attestations refer to each platform
# manifest too and Kyverno counts them as its signature, so it would pass the signature rule and be refused later, for
# the vuln attestation; b, h and i would then depend on the format.
unsigned_image() {
  if [ -n "${UNSIGNED:-}" ]; then
    echo "$UNSIGNED"
  else
    "$repo_root/deploy/ci/ghcr-digest.sh" newest drill-unsigned 2>"$work/unsigned.err" || true
  fi
}

# bad_image: the image h and i send as "unsigned", with bad_rule the message that refuses it: the unsigned image
# (unsigned_image; the signature rule), or the dev image of the local registry when there is none (the prefix rule).
bad_image() {
  bad=$(unsigned_image)
  if [ -n "$bad" ]; then
    bad_rule="image without a keyless signature by"
  else
    bad=$(local_image)
    bad_rule="image not allowed in namespace svp"
  fi
}

# target_pod: target, a Running pod of svp, and target_container, its first container, for cases h and i.
target_pod() {
  target=$(kc -n svp get pods -l app.kubernetes.io/component=server --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}') || target=
  [[ -n $target ]] || fail "a Running pod of svp (app.kubernetes.io/component=server) to patch in cases h and i"
  target_container=$(kc -n svp get pod "$target" -o jsonpath='{.spec.containers[0].name}')
}

# ephemeral IMAGE (case h): the patch that adds ephemeral container drill-debug with IMAGE to pod target, as kubectl
# debug does, restricted in every respect.
ephemeral() {
  jq -nc --arg i "$1" --arg t "$target_container" '{spec: {ephemeralContainers: [{
    name: "drill-debug", image: $i, command: ["sleep", "1"], targetContainerName: $t,
    securityContext: {runAsNonRoot: true, runAsUser: 65532, allowPrivilegeEscalation: false,
      readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}, seccompProfile: {type: "RuntimeDefault"}}}]}}'
}

# Argo CD on the GitOps cluster (case g): the root svp-root makes Application kyverno with automated sync and selfHeal,
# and would put back what the case changes. argo_pause turns off the automated sync of the root, then of kyverno, each
# once no sync of it runs; argo_restore puts the syncPolicy each had back, kyverno first, and checks it is the same as
# before.
argo_pause() {
  local app deadline
  for app in svp-root kyverno; do
    kc -n argocd get applications.argoproj.io "$app" -o json | jq -S -c '.spec.syncPolicy' >"$state/syncpolicy-$app" ||
      fail "read the syncPolicy of Application argocd/$app"
    st_set argo-paused "$app $(st argo-paused)"
    if jq -e '.automated != null' "$state/syncpolicy-$app" >/dev/null; then
      kc -n argocd patch applications.argoproj.io "$app" --type json \
        -p '[{"op": "remove", "path": "/spec/syncPolicy/automated"}]' >/dev/null ||
        fail "turn off the automated sync of Application argocd/$app"
    fi
    deadline=$((SECONDS + 300))
    while [[ $(kc -n argocd get applications.argoproj.io "$app" -o jsonpath='{.status.operationState.phase}') == Running ]]; do
      ((SECONDS < deadline)) || fail "the running sync of Application argocd/$app ends within 300s"
      sleep 2
    done
    ok "($CASE) Application $app: automated sync off, no sync running"
  done
}
argo_restore() {
  local app now
  for app in $(st argo-paused); do
    kc -n argocd patch applications.argoproj.io "$app" --type merge \
      -p "{\"spec\":{\"syncPolicy\":$(cat "$state/syncpolicy-$app")}}" >/dev/null || return 1
    now=$(kc -n argocd get applications.argoproj.io "$app" -o json | jq -S -c '.spec.syncPolicy') || return 1
    [[ $now == "$(cat "$state/syncpolicy-$app")" ]] || {
      echo "FAIL  ($CASE) Application argocd/$app: syncPolicy $now, before the drill $(cat "$state/syncpolicy-$app")" >&2
      return 1
    }
    ok "($CASE) Application $app: syncPolicy back as before the drill"
  done
  rm -f "$state/argo-paused"
}

# park (case g): the admission controller stopped without scaling it: strategy Recreate stops the running pod before
# its replacement, which waits for a node labelled svp-drill-supplychain=no-such-node that never comes; the replicas
# stay as they are, so Kyverno keeps its webhooks. Recorded first, so unpark runs whatever happens.
park() {
  st_set parked 1
  kc -n kyverno patch deployment "$admission" --type json -p '[
    {"op": "replace", "path": "/spec/strategy", "value": {"type": "Recreate"}},
    {"op": "add", "path": "/spec/template/spec/nodeSelector/svp-drill-supplychain", "value": "no-such-node"}]' >/dev/null ||
    fail "make deployment kyverno/$admission unschedulable"
}

# unpark (case g): the admission controller's strategy and nodeSelector back as they were, then the pod and the policy
# ready.
unpark() {
  kc -n kyverno patch deployment "$admission" --type json -p "[
    {\"op\": \"replace\", \"path\": \"/spec/strategy\", \"value\": $(st strategy)},
    {\"op\": \"remove\", \"path\": \"/spec/template/spec/nodeSelector/svp-drill-supplychain\"}]" >/dev/null || return 1
  kyverno_up
}

# down (case g): the Deployment still asks for its replicas, with the drill's nodeSelector, and no pod of it is ready.
down() {
  local d
  d=$(kc -n kyverno get deployment "$admission" -o json) || return 1
  [[ $(jq -r --arg r "$(st replicas)" '(.spec.replicas | tostring) == $r
    and .spec.template.spec.nodeSelector["svp-drill-supplychain"] == "no-such-node"
    and (.status.readyReplicas // 0) == 0' <<<"$d") == true ]]
}
