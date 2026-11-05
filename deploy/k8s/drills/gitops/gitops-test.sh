#!/usr/bin/env bash
# Tests for the Chainsaw tests of make drill-k8s-gitops (deploy/k8s/drills/gitops/), without a cluster:
#   - external-secrets and argocd-metrics, whose checks are scripts, run as they are with chainsaw test --no-cluster in a
#     throwaway git repository holding a copy of deploy/k8s/drills/ and of the chart files they read at the commit the
#     cluster runs its charts at, a fake kubectl first on PATH (and for argocd-metrics a fake nc and curl standing for
#     the port-forward and Prometheus): each case must pass or fail with its own message, and no Secret value may reach
#     the output;
#   - env, whose checks are declarative, by its own assertion trees (read from the file with yq, YQ_IMAGE of the
#     Makefile, through Docker without network) given to chainsaw assert against made-up objects: an object the assert
#     must match, or the error must not (chainsaw assert succeeding on an object means the error operation fails).
# chainsaw is the pinned one (make tools); bash, git, jq and Docker.
#
# Usage, from anywhere: deploy/k8s/drills/gitops/gitops-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../../../.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
same() { if [ "$3" = "$2" ]; then ok "$1"; else fail "$1: want '$2', got '$3'"; fi; }
# has, lacks NAME WHAT TEXT: TEXT is, is not in what the scripts of run NAME printed ($work/NAME.out; chainsaw's log also
# echoes each script, whose messages must not count).
has() { if grep -qF -- "$3" "$work/$1.out"; then ok "$1: $2"; else fail "$1: $2"; fi; }
lacks() { if grep -qF -- "$3" "$work/$1.out"; then fail "$1: $2"; else ok "$1: $2"; fi; }

chainsaw=$(command -v chainsaw || echo "$(go env GOPATH)/bin/chainsaw")
[ -x "$chainsaw" ] || { echo "FAIL  no chainsaw on PATH or in GOPATH/bin: make tools" >&2; exit 1; }
gq() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

# The throwaway repository: the drills, and the chart files the tests read, committed; the cluster runs its charts at
# that commit ($rev).
tree=$work/tree
es_file=deploy/helm/svp-cluster/files/external-secrets.yaml
pm_file=deploy/helm/svp-observability/templates/argocd.yaml
mkdir -p "$tree/deploy/k8s" "$tree/${es_file%/*}" "$tree/${pm_file%/*}"
cp -R "$src/deploy/k8s/drills" "$tree/deploy/k8s/"
cp "$src/$es_file" "$tree/$es_file"
cp "$src/$pm_file" "$tree/$pm_file"
git init -q "$tree" && gq -C "$tree" add -A && gq -C "$tree" commit -qm base
rev=$(git -C "$tree" rev-parse HEAD)
# A commit of the charts before the PodMonitor of Argo CD.
gq -C "$tree" rm -q "$pm_file" && gq -C "$tree" commit -qm "charts without the PodMonitor"
old_rev=$(git -C "$tree" rev-parse HEAD)
gone_rev=$(printf '%040d' 7)

# The fake kubectl, from the files of $FAKE_DIR: ExternalSecrets of es (one NAMESPACE/NAME per line, each Ready with key
# "key", unless listed in not-ready; its Secret of type Opaque with that key, unless listed in no-secret, or with keys
# "key,other" when listed in other-keys), Application svp-cluster rendering the lines of rendered (NAMESPACE/NAME, then
# prune for one with requiresPruning) at chart revision charts-rev (FAKE_APP_FAIL=1: it cannot be read), Application
# svp-observability at that revision, the Applications of apps (one name per line); a port-forward that runs until
# killed.
mkdir -p "$work/bin"
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "--context k3d-svp" ] || exit 1
shift 2
ns=
if [ "$1" = -n ]; then ns=$2 && shift 2; fi
d=$FAKE_DIR
app() {
  jq -n --arg path "deploy/helm/$1" --arg rev "$(cat "$d/charts-rev")" \
    '{spec: {sources: [{repoURL: "https://github.com/anhnvcoder/svp-backend.git", path: $path, targetRevision: $rev},
      {repoURL: "https://github.com/anhnvcoder/svp-gitops.git", ref: "values", targetRevision: "main"}]}}'
}
case "$*" in
"get externalsecrets.external-secrets.io -A -o json")
  jq -Rn --rawfile notready <(cat "$d/not-ready" 2>/dev/null) '[inputs | select(. != "") as $id | split("/")
    | {metadata: {namespace: .[0], name: .[1]}, spec: {target: {template: {type: "Opaque", data: {key: ""}}}},
       status: {conditions: [{type: "Ready", status: (if ($notready | split("\n") | index($id)) then "False" else "True" end),
         reason: "SecretSyncedError", message: "could not\nget secret"}]}}] | {items: .}' "$d/es" ;;
"get secrets -o json")
  jq -Rn --arg ns "$ns" --rawfile none <(cat "$d/no-secret" 2>/dev/null) --rawfile other <(cat "$d/other-keys" 2>/dev/null) \
    '[inputs | select(. != "") as $id | split("/") | select(.[0] == $ns) | select(($none | split("\n") | index($id)) | not)
      | {metadata: {name: .[1]}, type: "Opaque",
         data: (if ($other | split("\n") | index($id)) then {key: "dmFsdWU=", other: "dmFsdWU="} else {key: "dmFsdWU="} end)}]
    | {items: .}' "$d/es" ;;
"get applications.argoproj.io svp-cluster -o json")
  [ "$ns" = argocd ] && [ "${FAKE_APP_FAIL:-}" != 1 ] || { echo "Error from server (NotFound)" >&2; exit 1; }
  app svp-cluster | jq --rawfile r "$d/rendered" '. + {status: {resources: ([$r | split("\n")[] | select(. != "")
    | split(" ") | (.[0] | split("/")) as $id
    | {group: "external-secrets.io", kind: "ExternalSecret", namespace: $id[0], name: $id[1]}
      + (if .[1] == "prune" then {requiresPruning: true} else {} end)]
    + [{kind: "SecretStore", namespace: "argocd", name: "svp-store"}])}}' ;;
"get applications.argoproj.io svp-observability -o json")
  [ "$ns" = argocd ] || exit 1
  app svp-observability ;;
"get applications.argoproj.io -o name")
  sed 's|^|application.argoproj.io/|' "$d/apps" ;;
"port-forward --address 127.0.0.1 service/kps-prometheus 19090:9090")
  while :; do sleep 1; done ;;
*) echo "fake kubectl: unexpected: $*" >&2; exit 1 ;;
esac
EOF
# nc: every port free. curl: Prometheus on 127.0.0.1:19090 once the port-forward runs, answering each query with the
# number in $FAKE_DIR/q-<query name>: count (count(argocd_app_info)), healthy, firing.
cat >"$work/bin/nc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_DIR
case " $* " in
  *" http://127.0.0.1:19090/-/ready "*) exit 0 ;;
  *" http://127.0.0.1:19090/api/v1/query "*)
    case " $* " in
      *'query=count(argocd_app_info) '*) f=count ;;
      *'query=count(argocd_app_info{sync_status="Synced",health_status="Healthy"}) '*) f=healthy ;;
      *'query=count(ALERTS{alertname=~"ArgoCDApplication.*",alertstate="firing"}) '*) f=firing ;;
      *) exit 22 ;;
    esac
    echo "$*" >>"$d/queries"
    if [ -s "$d/q-$f" ]; then
      jq -nc --arg v "$(cat "$d/q-$f")" '{data: {result: [{value: [0, $v]}]}}'
    else
      echo '{"data":{"result":[]}}'
    fi ;;
  *) exit 7 ;;
esac
EOF
chmod 755 "$work/bin/kubectl" "$work/bin/nc" "$work/bin/curl"

# saw NAME TEST [FAKE_APP_FAIL=1]: chainsaw test --no-cluster on deploy/k8s/drills/gitops/TEST of the throwaway
# repository, with the drills' configuration, over the fake state of $work/NAME.d; its output in $work/NAME.log;
# prints its status.
saw() {
  local name=$1 test=$2 app_fail='' rc=0
  [ "${3:-}" != FAKE_APP_FAIL=1 ] || app_fail=1
  mkdir -p "$work/$name.report"
  (
    cd "$tree"
    PATH="$work/bin:$PATH" FAKE_DIR="$work/$name.d" FAKE_APP_FAIL=$app_fail "$chainsaw" test --no-cluster --no-color \
      --config deploy/k8s/drills/.chainsaw.yaml --test-dir "deploy/k8s/drills/gitops/$test" --selector drill=gitops \
      --report-path "$work/$name.report" --report-name "$name" --assert-timeout 2s
  ) >"$work/$name.log" 2>&1 </dev/null || rc=$?
  awk '/^ *=== (STDOUT|STDERR)$/ { on = 1; next } /^ *(=== |sink\.go:|--- )/ { on = 0 } on' "$work/$name.log" >"$work/$name.out"
  echo "$rc"
}
# state NAME ES RENDERED [CHARTS_REV]: the fake state of case NAME: the cluster's ExternalSecrets ES and the render
# RENDERED (lines), the charts at CHARTS_REV (default $rev).
state() {
  mkdir -p "$work/$1.d"
  printf '%s\n' "$2" >"$work/$1.d/es"
  printf '%s\n' "$3" >"$work/$1.d/rendered"
  echo "${4:-$rev}" >"$work/$1.d/charts-rev"
}
# external NAME ES RENDERED [CHARTS_REV] [FAKE_APP_FAIL=1]: gitops-external-secrets over that state; prints its status.
external() {
  state "$1" "$2" "$3" "${4:-}"
  saw "$1" external-secrets "${5:-}"
}

# --- gitops-external-secrets.
notify_es=argocd/argocd-notifications-secret
# An empty cluster: the diff's < lines are what is wanted.
same "external-secrets: an empty cluster fails" 1 "$(external empty "" "")"
base_es=$(sed -n 's/^ *< //p' "$work/empty.out" | LC_ALL=C sort -u)
same "external-secrets: an entry without enabledBy is wanted whatever Application svp-cluster renders" \
  "$(($(grep -c '^- namespace: ' "$src/$es_file") - $(grep -c '^  enabledBy: ' "$src/$es_file")))" \
  "$(grep -c . <<<"$base_es")"
has empty "an empty cluster has no ExternalSecret to be Ready" "FAIL  gitops-external-secrets: no ExternalSecret in the cluster"
grep -qx "$notify_es" <<<"$base_es" &&
  fail "external-secrets: $notify_es is not wanted where Application svp-cluster does not render it" ||
  ok "external-secrets: $notify_es is not wanted where Application svp-cluster does not render it"
has empty "an entry left out is named with its key" \
  "not wanted: $notify_es (enabledBy argocdNotifications), as Application svp-cluster renders no ExternalSecret of it"
has empty "the charts' commit is named" "charts of ${rev:0:12} (Application svp-cluster)"
base_count=$(grep -c . <<<"$base_es")
same "external-secrets: a cluster with argocdNotifications off passes" 0 "$(external off "$base_es" "$base_es")"
has off "every ExternalSecret is counted" "ok    $base_count ExternalSecrets Ready, each Secret with its type and keys"
has off "each Secret gets a line" "ok    $(head -n 1 <<<"$base_es"): Ready, Secret Opaque with keys key"
same "external-secrets: a cluster with argocdNotifications on passes" 0 \
  "$(external on "$base_es"$'\n'"$notify_es" "$base_es"$'\n'"$notify_es")"
has on "with one ExternalSecret more" "ok    $((base_count + 1)) ExternalSecrets Ready, each Secret with its type and keys"
lacks on "nothing is left out" "not wanted: $notify_es"
same "external-secrets: an ExternalSecret Application svp-cluster renders and the cluster lacks fails" 1 \
  "$(external missing "$base_es" "$base_es"$'\n'"$notify_es")"
has missing "it is named as wanted" "< $notify_es"
same "external-secrets: an ExternalSecret in the cluster that Application svp-cluster prunes fails" 1 \
  "$(external pruned "$base_es"$'\n'"$notify_es" "$base_es"$'\n'"$notify_es prune")"
has pruned "it is named as the cluster's" "> $notify_es"
same "external-secrets: an entry without enabledBy that the cluster lacks fails, rendered or not" 1 \
  "$(external lacks "$(sed 1d <<<"$base_es")" "")"
has lacks "it is named as wanted" "< $(head -n 1 <<<"$base_es")"
same "external-secrets: Application svp-cluster that cannot be read fails" 1 \
  "$(external no-app "$base_es" "$base_es" "" FAKE_APP_FAIL=1)"
has no-app "it says what it could not read" "FAIL  gitops-external-secrets: read Application argocd/svp-cluster"
same "external-secrets: charts at a commit this checkout does not have fail" 1 \
  "$(external no-commit "$base_es" "$base_es" "$gone_rev")"
has no-commit "it names the commit and the history it needs" "at the commit Application svp-cluster runs it at ('$gone_rev'"
first=$(head -n 1 <<<"$base_es")
state not-ready "$base_es" "$base_es"
echo "$first" >"$work/not-ready.d/not-ready"
same "external-secrets: an ExternalSecret not Ready fails" 1 "$(saw not-ready external-secrets)"
has not-ready "it is named with its reason, its message on one line" \
  "FAIL  $first: ExternalSecret Ready False SecretSyncedError: could not get secret"
state no-secret "$base_es" "$base_es"
echo "$first" >"$work/no-secret.d/no-secret"
same "external-secrets: an ExternalSecret without its Secret fails" 1 "$(saw no-secret external-secrets)"
has no-secret "it is named" "FAIL  $first: no Secret"
state other-keys "$base_es" "$base_es"
echo "$first" >"$work/other-keys.d/other-keys"
same "external-secrets: a Secret with a key its ExternalSecret does not name fails" 1 "$(saw other-keys external-secrets)"
has other-keys "its keys are named, never a value" "FAIL  $first: Secret keys key,other, want key"
for n in off on other-keys; do
  lacks "$n" "no value of a Secret is printed" dmFsdWU=
done
if grep -rqF dmFsdWU= "$work"/*.report 2>/dev/null; then
  fail "external-secrets: no value of a Secret in a report"
else
  ok "external-secrets: no value of a Secret in a report"
fi

# --- gitops-argocd-metrics.
# metrics NAME CHARTS_REV COUNT HEALTHY FIRING: gitops-argocd-metrics with 3 Applications, the charts at CHARTS_REV and
# Prometheus answering COUNT, HEALTHY, FIRING; prints its status.
metrics() {
  state "$1" "" "" "$2"
  printf '%s\n' svp-root svp-apps gateway >"$work/$1.d/apps"
  [ -z "$3" ] || echo "$3" >"$work/$1.d/q-count"
  [ -z "$4" ] || echo "$4" >"$work/$1.d/q-healthy"
  [ -z "$5" ] || echo "$5" >"$work/$1.d/q-firing"
  saw "$1" argocd-metrics
}
same "argocd-metrics: every Application Synced and Healthy, no alert firing, passes" 0 "$(metrics all "$rev" 3 3 0)"
has all "it gives the numbers" "Applications: 3; argocd_app_info series: 3, Synced and Healthy: 3; ArgoCDApplication* firing: 0"
same "argocd-metrics: an ArgoCDApplication* alert firing fails" 1 "$(metrics firing "$rev" 3 3 1)"
has firing "it says why" "FAIL  gitops-argocd-metrics: Prometheus must see every Application Synced and Healthy within 180 s"
same "argocd-metrics: charts that predate the PodMonitor pass, saying so" 0 "$(metrics old "$old_rev" "" "" "")"
has old "it names the commit" "skipped, the charts the cluster runs (${old_rev:0:12}) predate the PodMonitor of Argo CD"
[ ! -s "$work/old.d/queries" ] && ok "argocd-metrics: charts that predate the PodMonitor send no query" ||
  fail "argocd-metrics: charts that predate the PodMonitor send no query"
same "argocd-metrics: charts at a commit this checkout does not have fail, not skip" 1 "$(metrics gone "$gone_rev" 3 3 0)"
has gone "it names the commit" "is not in this checkout (it needs the whole history)"
if pgrep -f "$work/bin/kubectl" >/dev/null 2>&1; then
  fail "argocd-metrics: the port-forward is stopped when the test ends"
else
  ok "argocd-metrics: the port-forward is stopped when the test ends"
fi

# --- gitops-env, by its assertion trees.
yq_image=$(sed -n 's/^YQ_IMAGE[[:space:]]*:=[[:space:]]*//p' "$src/Makefile")
# tree STEP OP INDEX: the resource tree of operation INDEX (OP: assert or error) of step STEP of env/chainsaw-test.yaml.
tree_of() {
  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$here/env:/test:ro" "$yq_image" \
    ".spec.steps[] | select(.name == \"$1\") | .try[$3].$2.resource" /test/chainsaw-test.yaml
}
tree_of gitops-env-application assert 0 >"$work/env-app.yaml"
tree_of gitops-env-pods assert 0 >"$work/env-pod.yaml"
tree_of gitops-env-pods error 1 >"$work/env-pod-error.yaml"
for f in env-app env-pod env-pod-error; do
  grep -q 'SENTRY_ENVIRONMENT' "$work/$f.yaml" || fail "env: read the tree $f of env/chainsaw-test.yaml"
done
# matches TREE OBJECT: chainsaw assert of the tree on the object (YAML on stdin); prints yes or no.
matches() {
  cat >"$work/object.yaml"
  if "$chainsaw" assert --no-color -f "$work/$1.yaml" -r "$work/object.yaml" --timeout 1s >"$work/assert.log" 2>&1; then
    echo yes
  else
    echo no
  fi
}
application() {
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata: {name: gateway, namespace: argocd}\nspec:\n  sources:\n'
  printf '  - %s\n' "$@"
}
pod() {
  printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: gateway-1, namespace: svp, labels: {app.kubernetes.io/name: gateway}}\n'
  printf 'spec:\n  containers:\n  - name: istio-proxy\n    env: [{name: SENTRY_ENVIRONMENT, value: stg}]\n'
  printf '  - name: gateway\n    env: [{name: OTHER, value: x}%s]\nstatus: {phase: %s}\n' "${2:+, {name: SENTRY_ENVIRONMENT, value: $2\}}" "$1"
}
same "env: an Application with stg in the valuesObject of its chart source passes" yes \
  "$(application '{path: deploy/helm/svp-service, helm: {valuesObject: {env: {SENTRY_ENVIRONMENT: stg}}}}' '{ref: values}' |
    matches env-app)"
same "env: the first SENTRY_ENVIRONMENT counts, whichever source carries it" yes \
  "$(application '{ref: values}' '{path: deploy/helm/svp-service, helm: {valuesObject: {env: {SENTRY_ENVIRONMENT: stg}}}}' |
    matches env-app)"
same "env: an Application with prd fails" no \
  "$(application '{path: deploy/helm/svp-service, helm: {valuesObject: {env: {SENTRY_ENVIRONMENT: prd}}}}' | matches env-app)"
same "env: an Application without the overlay fails" no "$(application '{path: deploy/helm/svp-service}' | matches env-app)"
same "env: a running gateway pod with stg is found" yes "$(pod Running stg | matches env-pod)"
same "env: ... and is no error" no "$(pod Running stg | matches env-pod-error)"
same "env: a running gateway pod with prd is not one of stg" no "$(pod Running prd | matches env-pod)"
same "env: ... and is an error" yes "$(pod Running prd | matches env-pod-error)"
same "env: a running gateway pod without SENTRY_ENVIRONMENT in its gateway container is an error" yes \
  "$(pod Running "" | matches env-pod-error)"
same "env: a pending gateway pod is not read" no "$(pod Pending prd | matches env-pod-error)"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
