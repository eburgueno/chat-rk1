#!/usr/bin/env bash
# Bring up the local aarch64 build infrastructure:
#   1. aarch64 QEMU binfmt handler (kernel registration; resets on reboot)
#   2. a local OCI registry (images the cluster will pull)
#   3. a buildx builder wired to push to that registry over plain HTTP
#
# Idempotent — safe to re-run (e.g. after a reboot re-clears binfmt). Reads
# scripts/config.env for REGISTRY / BUILDER / PLATFORM (see config.env.example).
#
# Requirements: rootful docker (binfmt --install needs the initial user ns and a
# privileged container). Rootless podman cannot register binfmt.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$here/config.env" ] && source "$here/config.env"
: "${REGISTRY:=localhost:5000}"
: "${BUILDER:=talos-builder}"
: "${PLATFORM:=linux/arm64}"
reg_host="${REGISTRY%%/*}"   # strip any path suffix -> host:port

echo "==> [1/3] Register aarch64 binfmt (idempotent)"
if grep -q qemu-aarch64 /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
  echo "    already registered"
else
  # --network=none sidesteps veth setup entirely (works even when host container
  # networking is degraded, e.g. running kernel older than installed modules).
  docker run --rm --privileged --network=none tonistiigi/binfmt --install aarch64
fi
docker run --rm --platform "$PLATFORM" alpine:latest uname -m | grep -q aarch64 \
  && echo "    emulation OK (arm64 container reports aarch64)"

echo "==> [2/3] Local OCI registry at ${reg_host}"
if [ -n "$(docker ps -q -f name='^talos-registry$')" ]; then
  echo "    already running"
else
  docker rm -f talos-registry 2>/dev/null || true
  # host networking avoids a ports mapping (robust to degraded veth); the
  # listener is pinned to reg_host either way.
  docker run -d --name talos-registry --restart unless-stopped --network host \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -e "REGISTRY_HTTP_ADDR=${reg_host}" \
    -v talos-registry-data:/var/lib/registry registry:2 >/dev/null
fi
curl -fsS -m5 "http://${reg_host}/v2/_catalog" >/dev/null \
  && echo "    registry reachable at http://${reg_host}/v2/"

echo "==> [3/3] buildx builder '${BUILDER}'"
# The builder needs to be told the registry is plain-HTTP/insecure. We generate
# the buildkitd config from the registry host so nothing is hardcoded.
cfg="$(mktemp)"
cat > "$cfg" <<EOF
[registry."${reg_host}"]
  http = true
  insecure = true
EOF
if docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  echo "    already exists"
else
  docker buildx create --name "$BUILDER" --driver docker-container \
    --config "$cfg" --platform linux/arm64,linux/amd64 >/dev/null
fi
rm -f "$cfg"
docker buildx use "$BUILDER"
docker buildx inspect --bootstrap "$BUILDER" | grep -E 'Status|Platforms'
echo "==> infra ready."
