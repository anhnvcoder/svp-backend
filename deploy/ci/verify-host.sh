#!/usr/bin/env bash
# verify-host.sh compose-obs|gitops: validates runner environment before verification make targets; Linux only (GNU df).
# Disk: free >= need (16 GiB compose-obs, 30 gitops) + 15% to stay under kubelet's 85% image GC threshold + 2 GiB.
# Memory: logs vm.min_free_kbytes which Seastar takes off broker cgroup limit; redpanda.yaml leaves room for it.
# Design notes: docs/reference/ci.md.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
# The job's own temp directory on GitHub Actions, emptied when the job ends; /tmp on a machine.
tmp_root=${RUNNER_TEMP:-/tmp}
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
gib=$((1024 * 1024 * 1024))
hosts_line='127.0.0.1 svp.localhost api.svp.localhost s3.svp.localhost'

fail() {
  echo "FAIL  verify-host: $1" >&2
  exit 1
}
# Docker without DOCKER_DEFAULT_PLATFORM to avoid emulating foreign-architecture container images.
docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

scenario=${1:-}
case $scenario in
  compose-obs) need_gib=16 k3d=0 ;;
  gitops) need_gib=30 k3d=1 ;;
  *) fail "usage: verify-host.sh compose-obs|gitops (got '$scenario')" ;;
esac
[ "$(uname -s)" = Linux ] || fail "runs on Linux only (the runner or the rented VM)"
mkdir -p "$out"
printf '%s\n' "$scenario" >"$out/scenario"

root=$(docker_ info -f '{{.DockerRootDir}}') || fail "docker info answers"
# disk: sets size and avail, in bytes, of the filesystem holding Docker's data.
disk() { read -r size avail < <(df -B1 --output=size,avail "$root" | tail -n 1); }
disk
required=$((need_gib * gib + size * 15 / 100 + 2 * gib))
report() { echo "disk: $((avail / gib)) GiB free of $((size / gib)) GiB on the filesystem of $root; the scenario needs $((required / gib)) GiB free"; }
report
if [ "$avail" -lt "$required" ]; then
  echo "disk: short; deleting the runner image's toolsets this repository does not use"
  sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL
  disk
  report
  [ "$avail" -ge "$required" ] || fail "disk: $((avail / gib)) GiB free, $((required / gib)) GiB needed, even after the clean-up"
fi
{
  df -h "$root"
  echo
  docker_ system df
} >"$out/df-before.txt"
cat "$out/df-before.txt"

[ "$k3d" = 1 ] || exit 0

if ! grep -qxF "$hosts_line" /etc/hosts; then
  echo "$hosts_line" | sudo tee -a /etc/hosts >/dev/null
fi
for name in svp.localhost api.svp.localhost s3.svp.localhost; do
  addrs=$(getent ahosts "$name" | awk '{ print $1 }' | sort -u | tr '\n' ' ')
  [ "$addrs" = "127.0.0.1 " ] || fail "$name resolves to '${addrs% }', not 127.0.0.1 alone"
done
echo "hosts: svp.localhost, api.svp.localhost, s3.svp.localhost resolve to 127.0.0.1 only"

k3s_minor=$(sed -n 's/^K3S_IMAGE_TAG *:= *v1\.\([0-9][0-9]*\)\..*/\1/p' "$repo/Makefile")
[ -n "$k3s_minor" ] || fail "read the minor version of K3S_IMAGE_TAG in the Makefile"
# --client asks no server, so a context the kubeconfig does not hold yet (before make k8s-up) does not fail it;
# the context is named all the same, as in every kubectl call of the repository.
client_minor=$(kubectl --context k3d-svp version --client -o json | jq -r '.clientVersion.minor' | tr -dc '0-9')
[ -n "$client_minor" ] || fail "read the minor version of kubectl"
skew=$((client_minor - k3s_minor))
[ "${skew#-}" -le 1 ] || fail "kubectl 1.$client_minor is more than one minor version from k3s 1.$k3s_minor"
echo "kubectl: 1.$client_minor for k3s 1.$k3s_minor (within one minor version)"

echo "memory: vm.min_free_kbytes $(cat /proc/sys/vm/min_free_kbytes) kB (Seastar takes it off the Redpanda broker's limit)"
