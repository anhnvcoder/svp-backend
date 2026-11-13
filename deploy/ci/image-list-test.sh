#!/usr/bin/env bash
# Tests for deploy/ci/image-list.sh in a throwaway copy of what it reads, with a fake gitops-check.sh that writes
# made-up rendered references: no chart is rendered, no network, Docker or cluster. Runs on macOS and Linux.

# Usage, from anywhere: deploy/ci/image-list-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# same NAME WANT GOT: ok when the two strings are equal; shows both otherwise.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}

tree=$work/tree
mkdir -p "$tree/deploy/ci" "$tree/deploy/k8s"
cp "$here/image-list.sh" "$here/common.sh" "$tree/deploy/ci/"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/docker-bake.json" "$tree/deploy/"
# The fake renders nothing: it checks its arguments and writes the references of $FAKE_REFS to OUT.
cat >"$tree/deploy/ci/gitops-check.sh" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = --images ] && [ "$2" = ../gitops ] && [ "$3" = stg ] || { echo "unexpected arguments: $*" >&2; exit 2; }
cp "$FAKE_REFS" "$4"
echo "ok    fake render"
FAKE
chmod 755 "$tree/deploy/ci/gitops-check.sh" "$tree/deploy/ci/image-list.sh"

d1=sha256:$(printf '1%.0s' $(seq 64))
d2=sha256:$(printf '2%.0s' $(seq 64))
d3=sha256:$(printf '3%.0s' $(seq 64))
# list REFS...: runs image-list.sh on the made-up references; stdout in $work/out, stderr in $work/err, status printed.
list() {
  printf '%s\n' "$@" >"$work/refs"
  local rc=0
  FAKE_REFS=$work/refs "$tree/deploy/ci/image-list.sh" ../gitops stg >"$work/out" 2>"$work/err" || rc=$?
  echo "$rc"
}

# --- Lines of the right shape, Docker Hub names written in full, release images left out, sorted, once.
rc=$(list "quay.io/jetstack/cert-manager-controller:v1.19.1@$d1" \
  "ghcr.io/anhnvcoder/svp-backend/gateway:0123456789ab@$d2" \
  "nginx:1.27@$d3" "grafana/grafana:11.3.0@$d2" "docker.io/otel/opentelemetry-collector-contrib:0.110.0@$d1" \
  "index.docker.io/library/redis:7@$d3" "registry.k8s.io/pause:3.10@$d1" "localhost:5000/team/app:1@$d1" \
  "quay.io/jetstack/cert-manager-controller:v1.19.1@$d1" "ghcr.io/kyverno/kyverno:v1.16.0@$d2")
same "status of a list of tagged images" 0 "$rc"
same "the lines: Docker Hub in full, no release image, sorted, once" \
  "docker.io/grafana/grafana:11.3.0@$d2
docker.io/library/nginx:1.27@$d3
docker.io/library/redis:7@$d3
docker.io/otel/opentelemetry-collector-contrib:0.110.0@$d1
ghcr.io/kyverno/kyverno:v1.16.0@$d2
localhost:5000/team/app:1@$d1
quay.io/jetstack/cert-manager-controller:v1.19.1@$d1
registry.k8s.io/pause:3.10@$d1" "$(cat "$work/out")"
same "the fake's progress goes to stderr, not into the list" 1 "$(grep -c 'fake render' "$work/err")"

# --- A release image alone gives an empty list, not an error.
rc=$(list "ghcr.io/anhnvcoder/svp-frontend/web:0123456789ab@$d1")
same "status of a list of release images alone" 0 "$rc"
same "no line for release images alone" "" "$(cat "$work/out")"

# --- A digest without a tag names the image on stderr and fails, with nothing on stdout.
rc=$(list "quay.io/jetstack/cert-manager-controller@$d1" "nginx:1.27@$d3" "localhost:5000/team/app@$d2")
same "status of images without a tag" 1 "$rc"
same "nothing on stdout when an image has no tag" "" "$(cat "$work/out")"
for name in quay.io/jetstack/cert-manager-controller localhost:5000/team/app; do
  if grep -qF "$name" "$work/err"; then ok "stderr names $name"; else fail "stderr names $name"; fi
done

# --- A reference without a sha256 digest is no answer either.
rc=$(list "nginx:1.27")
same "status of an image without a digest" 1 "$rc"

# --- The arguments.
rc=0
"$tree/deploy/ci/image-list.sh" ../gitops >/dev/null 2>"$work/err" || rc=$?
same "status without an environment" 1 "$rc"

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed" >&2; exit 1; }
echo "ok    image-list.sh"
