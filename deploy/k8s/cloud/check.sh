#!/usr/bin/env bash
# Static check of the manifests of the k6 Job of the cloud cluster, run by `make cloud-check`. Nothing here reaches a
# cluster or reads .env; it needs helm, jq, docker and network access (GitHub).
#
#   1. Renders the k6 Job with deploy/k6/cloud/render.sh (run with no argument, manifests on stdout).
#   2. kubeconform -strict against the Kubernetes schemas of CLOUD_K8S_VERSION at a pinned commit of
#      yannh/kubernetes-json-schema. Strict: an unknown field fails. A kind without a schema fails: there is no
#      -ignore-missing-schemas.
#   3. What a schema cannot say: every image is pinned by exactly one @sha256:<64 hex>.
#
# Usage: deploy/k8s/cloud/check.sh [ROOT]
#   ROOT: a directory laid out like this repository (default: the repository), from which deploy/k6/ is read; a copy
#   with one field broken shows what the check reports for it. Nothing is written outside a temporary directory.
#   KUBECONFORM_IMAGE and CLOUD_K8S_VERSION come from the Makefile.
set -euo pipefail

root=$(cd "${1:-$(dirname "$0")/../../..}" && pwd)
: "${KUBECONFORM_IMAGE:?set KUBECONFORM_IMAGE (run make cloud-check)}"
: "${CLOUD_K8S_VERSION:?set CLOUD_K8S_VERSION (run make cloud-check)}"

# yannh/kubernetes-json-schema at a commit, not master: the schemas a check passes against do not move under it.
k8s_schemas_commit=f7d855e49c34b039c9ef2196444910275e31e09e

fail() {
  echo "FAIL  $1" >&2
  exit 1
}

tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
export HELM_CACHE_HOME=$tmp/helm/cache HELM_CONFIG_HOME=$tmp/helm/config HELM_DATA_HOME=$tmp/helm/data
mkdir -p "$tmp/manifests" "$tmp/y2j/in" "$tmp/y2j/templates"
docker_run=(env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$(id -u):$(id -g)")

# YAML to JSON lines without a YAML tool: Helm's fromYaml in a throwaway chart, one {"file", "doc"} object per document
# of every file in $tmp/y2j/in.
cat >"$tmp/y2j/Chart.yaml" <<'EOF'
apiVersion: v2
name: y2j
version: 0.0.0
EOF
cat >"$tmp/y2j/templates/out.yaml" <<'EOF'
{{- range $path, $_ := .Files.Glob "in/*" }}
{{- range regexSplit "(?m)^---[ \t]*$" ($.Files.Get $path) -1 }}
{{- $doc := fromYaml . }}
{{- if hasKey $doc "Error" }}{{ fail (printf "%s: %s" $path (get $doc "Error")) }}{{ end }}
{{- if $doc }}
{{ dict "file" (base $path) "doc" $doc | toJson }}
{{- end }}
{{- end }}
{{- end }}
EOF
yaml2json() {
  helm template y2j "$tmp/y2j" | grep '^{' || true
}

# 1. The k6 Job.
bash "$root/deploy/k6/cloud/render.sh" >"$tmp/manifests/rendered__k6-cloud.yaml" || fail "deploy/k6/cloud/render.sh"
echo "rendered deploy/k6/cloud/render.sh"

failed=0

# 2. kubeconform, with the Kubernetes schemas fetched from GitHub at the pinned commit.
if "${docker_run[@]}" -v "$tmp/manifests:/manifests:ro" "$KUBECONFORM_IMAGE" \
  -strict -summary -kubernetes-version "$CLOUD_K8S_VERSION" \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$k8s_schemas_commit/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
  /manifests; then
  echo "ok    kubeconform -strict (Kubernetes $CLOUD_K8S_VERSION)"
else
  echo "FAIL  kubeconform -strict (Kubernetes $CLOUD_K8S_VERSION)" >&2
  failed=1
fi

# 3. Images: every string field named image, and every env value whose name has the word IMAGE, on every document as
# JSON.
cp "$tmp/manifests"/* "$tmp/y2j/in/"
yaml2json >"$tmp/docs.jsonl"
images=$(jq -r '
  (.file | gsub("__"; "/")) as $f
  | (.doc | [.. | objects | .image? | strings]
      + [.. | objects | select((.name? | type) == "string" and (.name | test("(^|_)IMAGES?(_|$)")))
         | .value? | strings])[]
  | "\($f)\t\(.)"
' "$tmp/docs.jsonl" | sort -u) || fail "read the images of the manifests"
total=0
missing=
while IFS=$'\t' read -r f ref; do
  [ -n "$ref" ] || continue
  total=$((total + 1))
  [[ $ref =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || missing+="  $f: $ref"$'\n'
done <<<"$images"
if [ -n "$missing" ]; then
  printf 'FAIL  images without exactly one @sha256:<64 hex>:\n%s' "$missing" >&2
  failed=1
elif [ "$total" -eq 0 ]; then
  echo "FAIL  no image found in the output of deploy/k6/cloud/render.sh" >&2
  failed=1
else
  echo "ok    $total image references, every one pinned by digest"
fi

[ "$failed" -eq 0 ] || exit 1
echo "ok    cloud manifests"
