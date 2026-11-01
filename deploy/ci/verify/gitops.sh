# shellcheck shell=bash
# Scenario gitops of deploy/ci/verify-run.sh, which sources this file: a new cluster k3d-svp that Argo CD builds from
# the deployment configuration svp-gitops (main, the clone verify-run.sh makes with make gitops-clone) and the charts
# of this repository at the commit its envs/stg/charts.yaml pins, running the signed release images of GHCR by digest
# (job gitops of .github/workflows/verify.yml). The scripts of this run's checkout drive it (the bootstrap, the drills).
# make k8s-gitops-up at the commit of main of svp-gitops the clone holds (the cluster runs as staging, and stays at
# that commit through every check, so a release merged meanwhile changes nothing the checks read), the staging overlay
# seen applied, its ExternalSecrets, Argo CD's metrics, make k8s-smoke, the supply chain drill (Kyverno enforcing) and
# the threat model drill. Dispatched, or weekly on main with scenario compose-obs (SVP_VERIFY_SCHEDULED=true, set by the
# job on a scheduled run only; any other value is a dispatch): on a scheduled run drill-k8s-supplychain leaves out
# cases c and l when their image is too old (below).
#
# Steps that are not a make target of their own:
#   gitops-env             the overlays of envs/stg of svp-gitops reached the cluster: Application gateway reads
#                          envs/stg/gateway.yaml after its values, and every running gateway pod has
#                          SENTRY_ENVIRONMENT=stg (the only variable of the pod spec read)
#   gitops-external-secrets the cluster's ExternalSecrets are exactly those of files/external-secrets.yaml of chart
#                          svp-cluster at the commit the cluster runs its charts at (envs/stg/charts.yaml of
#                          svp-gitops at origin/main of the clone), each Ready, and the Secret each builds exists with
#                          the type and exactly the keys
#                          its ExternalSecret names (those of its template, or of its data without one): one line per
#                          Secret. Only the names of the keys leave kubectl's pipe, never a value
#   gitops-argocd-metrics  Prometheus scrapes Argo CD's view of the Applications (PodMonitor argocd-application-controller
#                          of chart svp-observability): within 180 s, argocd_app_info has one series per Application of
#                          namespace argocd and every one is Synced and Healthy, and no ArgoCDApplication* alert fires.
#                          Read through a port-forward of Prometheus on 127.0.0.1:19091. When the charts stg runs
#                          (envs/stg/charts.yaml of svp-gitops) predate that PodMonitor, it says so and passes: the
#                          check starts with the first promote that brings it
#   drill-k8s-supplychain  make drill-k8s-supplychain with the images it needs, read from GHCR without credentials
#                          (deploy/ci/ghcr-digest.sh): the newest drill-unsigned as the unsigned image of cases b, h
#                          and i (no signature or attestation names it), the newest drill-vulnerable, and for case l
#                          (signed and attested vuln, without build provenance) the newest drill-no-provenance. An image
#                          that cannot be read is left out and the step fails after the drill: its case SKIPs, except
#                          drill-unsigned, which the drill then looks up itself. Cases c
#                          and l pass only when their drill image's vuln attestation is within 72 hours: dispatch
#                          images.yml -f drill=true less than 72 hours before this run (no image file of svp-gitops
#                          names a drill image, so the daily rescan never attests one again). Nobody dispatches it
#                          before a scheduled run, so there gitops_stale leaves out the image of c or l whose vuln
#                          attestation is past the policy's maximum age (its case SKIPs, failing nothing), with a NOTE
#                          line naming the case, its age and that dispatch; every other case must pass as on a
#                          dispatch, which keeps both and fails them.
#                          Case m (the release sources apart) needs no image of its own: it moves the releases the
#                          cluster runs and the image of case l under the other source's prefix, and SKIPs its
#                          identity part until a release of svp-frontend runs here

build=k8s-gitops-up
job_minutes_default=160
k3d=1

# The branch of svp-gitops: main, the ref make gitops-clone checked out. The cluster is built at its commit in the
# clone and stays at it.
gitops_rev=main
export gitops_rev

# gitops_up: make k8s-gitops-up at the commit of main of svp-gitops in the clone (SVP_GITOPS_DIR, which verify-run.sh
# sets once it has cloned it), given as that commit: the cluster stays at it.
gitops_up() {
  local sha
  sha=$(git -C "${SVP_GITOPS_DIR:?the clone of svp-gitops, which verify-run.sh sets}" rev-parse --verify --quiet \
    "refs/remotes/origin/$gitops_rev^{commit}") || {
    echo "FAIL  origin/$gitops_rev is not in the clone of svp-gitops ($SVP_GITOPS_DIR)"
    return 1
  }
  make k8s-gitops-up GITOPS_REV="$sha"
}

# gitops_charts_rev: prints the commit of this repository whose charts the cluster runs, revision of
# envs/stg/charts.yaml at origin/main of the clone of svp-gitops (SVP_GITOPS_DIR, which verify-run.sh sets once it has
# cloned it; the revision the bootstrap read).
gitops_charts_rev() {
  git -C "${SVP_GITOPS_DIR:?the clone of svp-gitops, which verify-run.sh sets}" show \
    "refs/remotes/origin/$gitops_rev:envs/stg/charts.yaml" | sed -n 's/^revision: *//p'
}

# gitops_env: see gitops-env in the header.
gitops_env() {
  # shellcheck disable=SC2016 # $values is Argo CD's name of the values source, written as it is
  local want='$values/envs/stg/gateway.yaml' files pods values
  files=$(kc -n argocd get applications.argoproj.io gateway -o json |
    jq -r '[.spec.sources[] | .helm.valueFiles // [] | .[]] | join(" ")') || {
    echo "FAIL  gitops-env: read Application gateway"
    return 1
  }
  echo "Application gateway reads: $files"
  case " $files " in
  *" $want "*) ;;
  *)
    echo "FAIL  gitops-env: Application gateway does not read $want"
    return 1
    ;;
  esac
  pods=$(kc -n svp get pods -l app.kubernetes.io/name=gateway --field-selector=status.phase=Running -o json) || {
    echo "FAIL  gitops-env: list the gateway's pods"
    return 1
  }
  # One line per running pod: its name and the value of SENTRY_ENVIRONMENT in its gateway container, nothing else.
  values=$(jq -r '.items[] | .metadata.name + " " + ([.spec.containers[] | select(.name == "gateway") | .env[]?
    | select(.name == "SENTRY_ENVIRONMENT") | .value] | first // "unset")' <<<"$pods") || {
    echo "FAIL  gitops-env: read SENTRY_ENVIRONMENT of the gateway's pods"
    return 1
  }
  if [ -n "$values" ]; then sed 's/^/SENTRY_ENVIRONMENT of /' <<<"$values"; else echo "no running gateway pod"; fi
  if [ -z "$values" ] || awk '$2 != "stg" { bad = 1 } END { exit !bad }' <<<"$values"; then
    echo "FAIL  gitops-env: every running gateway pod must have SENTRY_ENVIRONMENT=stg"
    return 1
  fi
  echo "ok    the staging overlay is applied"
}

# gitops_argocd_metrics: see gitops-argocd-metrics in the header.
gitops_argocd_metrics() {
  local file=deploy/helm/svp-observability/templates/argocd.yaml port=19091 rev apps pid deadline got healthy firing
  # The commit itself must be there: a clone without it would read as charts without the PodMonitor and pass.
  rev=$(gitops_charts_rev) && [[ $rev =~ ^[0-9a-f]{40}$ ]] && git -C "$repo" cat-file -e "$rev^{commit}" 2>/dev/null || {
    echo "FAIL  gitops-argocd-metrics: read the commit envs/stg/charts.yaml of svp-gitops pins"
    return 1
  }
  if ! git -C "$repo" cat-file -e "$rev:$file" 2>/dev/null; then
    echo "skipped: the charts stg runs (${rev:0:12}) have no $file yet; checked from the first promote that brings it"
    return 0
  fi
  apps=$(kc -n argocd get applications.argoproj.io -o name | grep -c .) || {
    echo "FAIL  gitops-argocd-metrics: list the Applications of namespace argocd"
    return 1
  }
  kc -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus "$port:9090" >/dev/null 2>&1 &
  pid=$!
  # q QUERY: the value of the first sample of QUERY, 0 when it has none or Prometheus did not answer.
  q() {
    curl -sf --max-time 10 "http://127.0.0.1:$port/api/v1/query" --data-urlencode "query=$1" |
      jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo 0
  }
  deadline=$((SECONDS + 180))
  while :; do
    got=$(q 'count(argocd_app_info)')
    healthy=$(q 'count(argocd_app_info{sync_status="Synced",health_status="Healthy"})')
    [ "$got" = "$apps" ] && [ "$healthy" = "$apps" ] && break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 10
  done
  firing=$(q 'count(ALERTS{alertname=~"ArgoCDApplication.*",alertstate="firing"})')
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "Applications: $apps; argocd_app_info series: $got, Synced and Healthy: $healthy; ArgoCDApplication* firing: $firing"
  if [ "$got" != "$apps" ] || [ "$healthy" != "$apps" ] || [ "$firing" != 0 ]; then
    echo "FAIL  gitops-argocd-metrics: Prometheus must see every Application Synced and Healthy within 180 s, with no ArgoCDApplication* alert firing"
    return 1
  fi
  echo "ok    Prometheus sees every Application of Argo CD, all Synced and Healthy"
}

# gitops_external_secrets: see gitops-external-secrets in the header.
gitops_external_secrets() {
  local file=deploy/helm/svp-cluster/files/external-secrets.yaml rev list want have es secrets report ns
  rev=$(gitops_charts_rev) && [[ $rev =~ ^[0-9a-f]{40}$ ]] &&
    list=$(git -C "$repo" show "$rev:$file") || {
    echo "FAIL  gitops-external-secrets: read $file at the commit envs/stg/charts.yaml of svp-gitops pins"
    return 1
  }
  echo "charts of ${rev:0:12} (envs/stg/charts.yaml of svp-gitops)"
  want=$(awk '/^- namespace: / { ns = $3 } /^  name: / { if (ns != "") print ns "/" $2; ns = "" }' <<<"$list" | sort)
  es=$(kc get externalsecrets.external-secrets.io -A -o json) || {
    echo "FAIL  gitops-external-secrets: list the ExternalSecrets"
    return 1
  }
  have=$(jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$es" | sort)
  # Name, type and key names of each Secret of the namespaces with ExternalSecrets; the values go no further than jq.
  secrets=$(for ns in $(jq -r '[.items[].metadata.namespace] | unique[]' <<<"$es"); do
    kc -n "$ns" get secrets -o json | jq -c --arg ns "$ns" \
      '.items[] | {id: "\($ns)/\(.metadata.name)", type, keys: ((.data // {}) | keys)}' || exit 1
  done | jq -s 'map({key: .id, value: .}) | from_entries') || {
    echo "FAIL  gitops-external-secrets: read the key names of the Secrets"
    return 1
  }
  report=$(jq -r --argjson secrets "$secrets" '.items[] | "\(.metadata.namespace)/\(.metadata.name)" as $id
    | ((.status.conditions // []) | map(select(.type == "Ready")) | first // {}) as $r
    | ((.spec.target.template.data // null | if . == null then null else keys end)
        // [.spec.data[]?.secretKey] | sort) as $want
    | (.spec.target.template.type // "Opaque") as $type
    | $secrets[$id] as $s
    | if $r.status != "True" then
        "FAIL  \($id): ExternalSecret Ready \($r.status // "-") \($r.reason // "-"): \($r.message // "" | gsub("\n"; " "))"
      elif $s == null then "FAIL  \($id): no Secret"
      elif ($s.keys | sort) != $want then "FAIL  \($id): Secret keys \($s.keys | sort | join(",")), want \($want | join(","))"
      elif $s.type != $type then "FAIL  \($id): Secret type \($s.type), want \($type)"
      else "ok    \($id): Ready, Secret \($type) with keys \($want | join(","))" end' <<<"$es") || {
    echo "FAIL  gitops-external-secrets: compare the ExternalSecrets with their Secrets"
    return 1
  }
  [ -z "$report" ] || printf '%s\n' "$report"
  if [ "$have" != "$want" ]; then
    echo "FAIL  gitops-external-secrets: the cluster's ExternalSecrets (>) differ from files/external-secrets.yaml at ${rev:0:12} (<):"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") | grep '^[<>]'
    return 1
  fi
  if grep -q '^FAIL' <<<"$report"; then return 1; fi
  echo "ok    $(grep -c . <<<"$want") ExternalSecrets Ready, each Secret with its type and keys"
}

# gitops_stale CASE IMAGE: status 0, after printing a NOTE line that names the case, the age and the dispatch that
# makes it pass again (a new build of the drill images), when the vuln attestation of IMAGE (REPOSITORY@DIGEST) was scanned longer ago than
# the policy's maximum age (imageVerification.maxAttestationAge of chart svp-policy) less an hour, read as
# drill-k8s-supplychain reads it: the oldest scanFinishedOn of the attestations cosign verifies, anonymously, with the
# identity of the release source whose prefix IMAGE is under. CASE c is drill-vulnerable, CASE l drill-no-provenance:
# only a new build of the drill images scans them again. Status 1 otherwise, also when cosign or the time cannot be
# read: the drill then reads it again and fails the case with what it got.
gitops_stale() (
  # shellcheck source=deploy/ci/common.sh
  . "$here/common.sh" || exit 1
  source=$(source_of_repository "${2%@*}") || exit 1
  sign_identity "$source"
  max_age=$(sed -n 's/^  maxAttestationAge: *//p' "$repo_root/deploy/helm/svp-policy/values.yaml")
  [[ $max_age =~ ^[0-9]+[hms]$ ]] || exit 1
  case $max_age in
  *h) max_s=$((${max_age%h} * 3600)) ;;
  *m) max_s=$((${max_age%m} * 60)) ;;
  *s) max_s=${max_age%s} ;;
  esac
  envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" "$2" 2>/dev/null) || exit 1
  scanned=$(jq -rs '[.[].payload | @base64d | fromjson | .predicate.metadata.scanFinishedOn] | min // empty' \
    <<<"$envelopes" 2>/dev/null) || exit 1
  [[ $scanned =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || exit 1
  age=$(jq -nr --arg t "$scanned" 'now - ($t | fromdateiso8601) | floor') && [[ $age =~ ^[0-9]+$ ]] || exit 1
  # An hour short of the maximum: the drill and Kyverno read the age again minutes later, after the cases before c.
  [ "$age" -gt "$((max_s - 3600))" ] || exit 1
  hint=$(ci_dispatch_hint images.yml main drill=true) || exit 1
  echo "NOTE  case $1 left out on this scheduled run (it SKIPs): $2 was scanned at $scanned, $((age / 3600)) h ago," \
    "within an hour of $max_age or more; nobody rescans it before a scheduled run, so it is checked on a dispatch run within $max_age" \
    "of: $hint"
)

# gitops_supplychain: see drill-k8s-supplychain in the header.
gitops_supplychain() {
  local unsigned vulnerable no_provenance missing= rc=0
  unsigned=$("$here/ghcr-digest.sh" newest drill-unsigned) || missing="$missing drill-unsigned;"
  vulnerable=$("$here/ghcr-digest.sh" newest drill-vulnerable) || missing="$missing drill-vulnerable;"
  no_provenance=$("$here/ghcr-digest.sh" newest drill-no-provenance) || missing="$missing drill-no-provenance;"
  # A scheduled run: see SVP_VERIFY_SCHEDULED in the header.
  if [ "${SVP_VERIFY_SCHEDULED:-}" = true ]; then
    if [ -n "$vulnerable" ] && gitops_stale c "$vulnerable"; then vulnerable=; fi
    if [ -n "$no_provenance" ] && gitops_stale l "$no_provenance"; then no_provenance=; fi
  fi
  echo "unsigned: ${unsigned:-none}; vulnerable: ${vulnerable:-none}"
  echo "without provenance: ${no_provenance:-none, case l SKIPs}"
  # none, not empty: the drill looks drill-no-provenance up itself when it is not given one.
  make drill-k8s-supplychain SUPPLYCHAIN_UNSIGNED="$unsigned" SUPPLYCHAIN_VULNERABLE="$vulnerable" \
    SUPPLYCHAIN_NO_PROVENANCE="${no_provenance:-none}" || rc=$?
  if [ -n "$missing" ]; then
    echo "FAIL  drill-k8s-supplychain ran without what GHCR did not give (above):$missing"
    return 1
  fi
  return "$rc"
}

export -f gitops_up gitops_charts_rev gitops_env gitops_external_secrets gitops_argocd_metrics gitops_stale \
  gitops_supplychain

scenario_targets() {
  step k8s-gitops-up 60 bash -c gitops_up
  step gitops-env 2 bash -c gitops_env
  step gitops-external-secrets 2 bash -c gitops_external_secrets
  step gitops-argocd-metrics 5 bash -c gitops_argocd_metrics
  step k8s-smoke 15 make k8s-smoke
  step drill-k8s-supplychain 40 bash -c gitops_supplychain
  step drill-k8s-threats 30 make drill-k8s-threats
}
