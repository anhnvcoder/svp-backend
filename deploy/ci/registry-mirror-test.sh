#!/usr/bin/env bash
# Tests for the registry values of chart svp-policy: policy svp-registry-mirror (registryMirror.rules), applied by the
# Kyverno CLI of KYVERNO_CLI_IMAGE (no network) to sample pods with the rules eks sets, and the release registry and
# credentials of ImageValidatingPolicy svp-images (releaseRegistry, registryCredentials). The default values render
# neither. Needs bash, helm, jq and Docker: no network once the CLI image is pulled.

# Usage, from anywhere: deploy/ci/registry-mirror-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=deploy/ci/common.sh
. "$here/common.sh"
chart=$repo_root/deploy/helm/svp-policy
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ecr=000000000000.dkr.ecr.ap-southeast-1.amazonaws.com
digest=sha256:$(printf '%064d' 0)

ok() { echo "ok    $1"; }
bad() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

# render OUT [HELM ARGS...]: helm template of the chart under temporary Helm homes; output and errors in OUT.
render() {
  local out=$1
  shift
  HELM_CACHE_HOME=$work/helm/cache HELM_CONFIG_HOME=$work/helm/config HELM_DATA_HOME=$work/helm/data \
    helm template svp-policy "$chart" "$@" >"$out" 2>&1
}
# doc KIND FILE: the document of FILE whose kind is KIND.
doc() { awk -v kind="kind: $1" '/^---/ { if (keep) exit; buf = ""; next } { buf = buf $0 "\n" } $0 == kind { keep = 1 }
  END { if (keep) printf "%s", buf }' "$2"; }

# The rules eks sets from cluster.ecrRegistry (platforms/eks/svp-policy.values.tpl of svp-gitops), one per upstream;
# ghcr.io/ before its longer ghcr.io/anhnvcoder/, which must still win.
cat >"$work/eks.yaml" <<EOF
registryMirror:
  rules:
    - {from: ghcr.io/, to: $ecr/ghcr/}
    - {from: ghcr.io/anhnvcoder/, to: $ecr/}
    - {from: docker.io/, to: $ecr/docker-hub/}
    - {from: quay.io/, to: $ecr/quay/}
    - {from: registry.k8s.io/, to: $ecr/k8s/}
    - {from: public.ecr.aws/, to: $ecr/ecr-public/}
releaseRegistry: $ecr
registryCredentials:
  providers: [amazon]
EOF

# --- Default values: svp-images alone, without credentials.
if render "$work/default" && grep -q '^kind: ImageValidatingPolicy$' "$work/default" &&
  ! grep -q '^kind: MutatingPolicy$' "$work/default" && ! grep -q '^  credentials:' "$work/default"; then
  ok "default values render svp-images alone, without credentials"
else
  bad "default values: $(tail -n 3 "$work/default")"
fi

# --- eks values: svp-images matches the release images in the ECR registry, with the same attestors.
if ! render "$work/eks" -f "$work/eks.yaml"; then
  bad "eks values: helm template fails: $(tail -n 3 "$work/eks")"
fi
doc ImageValidatingPolicy "$work/eks" >"$work/eks-ivp.yaml"
doc MutatingPolicy "$work/eks" >"$work/mirror.yaml"
want=$(jq -r --arg r "$ecr/" '.sources[] | (.imagePrefix | sub("^ghcr.io/anhnvcoder/"; $r)) as $p
  | (.services + .drillImages)[] | ($p + . + "@*"), ($p + . + ":*")' "$chart/files/sources.json" | sort)
got=$(sed -n 's/^    - glob: "\(.*\)"$/\1/p' "$work/eks-ivp.yaml" | sort)
if [ -n "$got" ] && [ "$got" = "$want" ]; then
  ok "eks: svp-images matches each published name under releaseRegistry ($(grep -c . <<<"$got") globs)"
else
  bad "eks: matchImageReferences: want $(tr '\n' ' ' <<<"$want")got $(tr '\n' ' ' <<<"$got")"
fi
if grep -q 'ghcr\.io' "$work/eks-ivp.yaml"; then
  bad "eks: svp-images still names ghcr.io: $(grep -m 1 'ghcr\.io' "$work/eks-ivp.yaml")"
else
  ok "eks: svp-images names no image prefix on ghcr.io"
fi
attestors() { sed -n '/^  attestors:$/,/^  [^ ]/p' "$1"; }
if [ "$(attestors "$work/eks-ivp.yaml")" = "$(attestors "$work/default")" ]; then
  ok "eks: the attestors of svp-images are those of the default values"
else
  bad "eks: the attestors of svp-images differ from those of the default values"
fi
if [ "$(sed -n '/^  credentials:$/,/^  [^ ]/p' "$work/eks-ivp.yaml" | sed -n 's/^    - //p')" = amazon ]; then
  ok "eks: svp-images reads the registry with credentials provider amazon"
else
  bad "eks: no credentials.providers [amazon] in svp-images"
fi

# --- Sample pods: each upstream to its path in the ECR registry, digests kept; kyverno and other hosts unchanged.
# Expected: namespace/pod field index image-after (image-before in the pods below, same order).
cat >"$work/pods.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: release, namespace: svp}
spec:
  containers:
    - {name: gateway, image: "ghcr.io/anhnvcoder/svp-backend/gateway:sha-1@$digest"}
    - {name: web, image: "ghcr.io/anhnvcoder/svp-frontend/web@$digest"}
---
apiVersion: v1
kind: Pod
metadata: {name: upstreams, namespace: svp-obs}
spec:
  initContainers:
    - {name: a, image: "busybox@$digest"}
  containers:
    - {name: a, image: "ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1@$digest"}
    - {name: b, image: "glitchtip/glitchtip:6.2.6@$digest"}
    - {name: c, image: "redis:8@$digest"}
    - {name: d, image: "docker.io/library/redis:8.10.2-alpine@$digest"}
    - {name: e, image: "docker.io/busybox:1.37"}
    - {name: f, image: "index.docker.io/envoyproxy/gateway:v1.9.3@$digest"}
    - {name: g, image: "registry-1.docker.io/library/alpine:3@$digest"}
    - {name: h, image: "quay.io/argoproj/argocd:v3.5.5@$digest"}
    - {name: i, image: "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0@$digest"}
    - {name: j, image: "public.ecr.aws/karpenter/controller:1.9.0@$digest"}
    - {name: k, image: "$ecr/docker-hub/library/redis:8@$digest"}
    - {name: l, image: "$ecr/svp-backend/gateway@$digest"}
    - {name: m, image: "localhost:5000/x:1"}
    - {name: n, image: "mirror.gcr.io/library/redis:8"}
  ephemeralContainers:
    - {name: a, image: "quay.io/prometheus/busybox:latest"}
---
apiVersion: v1
kind: Pod
metadata: {name: containers-only, namespace: svp-obs}
spec:
  containers:
    - {name: a, image: "quay.io/prometheus/prometheus:v3.7.0@$digest"}
---
apiVersion: v1
kind: Pod
metadata: {name: kyverno, namespace: kyverno}
spec:
  initContainers:
    - {name: a, image: "ghcr.io/kyverno/kyvernopre:v1.19.1@$digest"}
  containers:
    - {name: a, image: "redis:8@$digest"}
EOF
cat >"$work/want" <<EOF
svp/release containers 0 $ecr/svp-backend/gateway:sha-1@$digest
svp/release containers 1 $ecr/svp-frontend/web@$digest
svp-obs/upstreams initContainers 0 $ecr/docker-hub/library/busybox@$digest
svp-obs/upstreams containers 0 $ecr/ghcr/cloudnative-pg/cloudnative-pg:1.30.1@$digest
svp-obs/upstreams containers 1 $ecr/docker-hub/glitchtip/glitchtip:6.2.6@$digest
svp-obs/upstreams containers 2 $ecr/docker-hub/library/redis:8@$digest
svp-obs/upstreams containers 3 $ecr/docker-hub/library/redis:8.10.2-alpine@$digest
svp-obs/upstreams containers 4 $ecr/docker-hub/library/busybox:1.37
svp-obs/upstreams containers 5 $ecr/docker-hub/envoyproxy/gateway:v1.9.3@$digest
svp-obs/upstreams containers 6 $ecr/docker-hub/library/alpine:3@$digest
svp-obs/upstreams containers 7 $ecr/quay/argoproj/argocd:v3.5.5@$digest
svp-obs/upstreams containers 8 $ecr/k8s/kube-state-metrics/kube-state-metrics:v2.20.0@$digest
svp-obs/upstreams containers 9 $ecr/ecr-public/karpenter/controller:1.9.0@$digest
svp-obs/upstreams containers 10 $ecr/docker-hub/library/redis:8@$digest
svp-obs/upstreams containers 11 $ecr/svp-backend/gateway@$digest
svp-obs/upstreams containers 12 localhost:5000/x:1
svp-obs/upstreams containers 13 mirror.gcr.io/library/redis:8
svp-obs/upstreams ephemeralContainers 0 $ecr/quay/prometheus/busybox:latest
svp-obs/containers-only containers 0 $ecr/quay/prometheus/prometheus:v3.7.0@$digest
kyverno/kyverno initContainers 0 ghcr.io/kyverno/kyvernopre:v1.19.1@$digest
kyverno/kyverno containers 0 redis:8@$digest
EOF

image=$(tool_image KYVERNO_CLI_IMAGE)
mkdir "$work/kyverno.d"
cp "$work/eks-ivp.yaml" "$work/mirror.yaml" "$work/pods.yaml" "$work/kyverno.d/"
# kyverno CLI: the policy file and the pods, as the calling user, without network.
kyverno_cli() {
  docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$work/kyverno.d:/w:ro" "$image" apply "/w/$1" \
    --resource /w/pods.yaml --remove-color
}
if ! kyverno_cli mirror.yaml >"$work/applied" 2>&1; then
  bad "the Kyverno CLI fails on svp-registry-mirror: $(tail -n 3 "$work/applied")"
fi
# Each pod the CLI prints after the policy, one line per image as in $work/want.
awk '/^policy svp-registry-mirror applied to / { split($5, p, "/"); pod = p[1] "/" substr(p[3], 1, length(p[3]) - 1); next }
  /^    (containers|initContainers|ephemeralContainers):$/ { field = substr($1, 1, length($1) - 1); n = -1; next }
  /^    [^ ]/ || /^[^ ]/ { field = "" }
  field != "" && /^        - / { n++ }
  field != "" && /^        (- |  )image: / { print pod, field, n, $NF }' "$work/applied" | sort >"$work/got"
if sort "$work/want" | diff -u - "$work/got" >"$work/diff"; then
  ok "svp-registry-mirror: $(grep -c . "$work/want") images of four pods as expected (each upstream, Docker Hub forms,\
 digests kept; ECR, other hosts and namespace kyverno unchanged)"
else
  bad "svp-registry-mirror rewrites other images than expected (- expected, + got):"$'\n'"$(cat "$work/diff")"
fi
# The CLI drops a policy whose schema it does not know: a wrong place for credentials would apply no rule at all. The
# pod of namespace svp, not rewritten here, fails svp-images; the CLI exits 1 for it.
kyverno_cli eks-ivp.yaml >"$work/ivp-applied" 2>&1 || true
if grep -q '^Applying 1 policy rule' "$work/ivp-applied"; then
  ok "the Kyverno CLI loads svp-images with the eks values (credentials in its schema)"
else
  bad "the Kyverno CLI does not load svp-images with the eks values: $(head -n 3 "$work/ivp-applied")"
fi

# --- Values the chart refuses.
# refused NAME MESSAGE VALUES: helm template with the YAML VALUES fails with MESSAGE.
refused() {
  printf '%s\n' "$3" >"$work/case.yaml"
  if render "$work/case" -f "$work/case.yaml"; then
    bad "$1: helm template renders"
  elif grep -qF -- "$2" "$work/case"; then
    ok "$1: helm template refuses it ($2)"
  else
    bad "$1: helm template fails without \"$2\": $(tail -n 1 "$work/case")"
  fi
}
refused "a rule without a trailing /" "must be a registry host and path ending in /" \
  "registryMirror: {rules: [{from: quay.io, to: $ecr/quay/}]}"
refused "a rule breaking out of a CEL string" "must be a registry host and path ending in /" \
  "registryMirror: {rules: [{from: \"quay.io/'/\", to: $ecr/quay/}]}"
refused "two rules from one prefix" "two rules rewrite quay.io/" \
  "registryMirror: {rules: [{from: quay.io/, to: $ecr/quay/}, {from: quay.io/, to: $ecr/q/}]}"
refused "rules not a list" "registryMirror.rules must be a list" "registryMirror: {rules: {from: quay.io/}}"
refused "a releaseRegistry ending in /" "releaseRegistry must be a registry host" "releaseRegistry: $ecr/"
refused "registryCredentials not a map" "registryCredentials must be a map" "registryCredentials: [amazon]"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
