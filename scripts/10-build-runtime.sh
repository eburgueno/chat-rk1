#!/usr/bin/env bash
# Build the aarch64 rocket-runtime image (llama.cpp + rocket-userspace +
# ggml-rocket) and push it to the local registry. Reads scripts/config.env.
#
#   scripts/10-build-runtime.sh [--load]   # --load: also load into local docker
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
[ -f "$here/config.env" ] && source "$here/config.env"
: "${REGISTRY:=localhost:5000}"; : "${BUILDER:=talos-builder}"
: "${PLATFORM:=linux/arm64}"; : "${RUNTIME_IMAGE:=${REGISTRY}/rocket-runtime:latest}"

extra=(--push)
[ "${1:-}" = "--load" ] && extra=(--load)

# Stage the benchmark harness into the build context so the image bakes it in.
cp "$root/bench/bench.sh" "$root/docker/runtime/bench.sh"

set -x
docker buildx build --builder "$BUILDER" --platform "$PLATFORM" \
  -t "$RUNTIME_IMAGE" \
  --build-arg "ROCKET_USERSPACE_REF=${ROCKET_USERSPACE_REF:-}" \
  --build-arg "GGML_ROCKET_REF=${GGML_ROCKET_REF:-}" \
  --build-arg "PATCHES_REF=${PATCHES_REF:-}" \
  --build-arg "LLAMACPP_REF=${LLAMACPP_REF:-}" \
  "${extra[@]}" \
  "$root/docker/runtime"
