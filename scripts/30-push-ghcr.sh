#!/usr/bin/env bash
# Publish the rocket-runtime image to ghcr.io. Reads scripts/config.env
# (GHCR_OWNER / GHCR_IMAGE / RUNTIME_VERSION / LLAMACPP_REF).
#
# CI equivalent: .github/workflows/publish-runtime.yml runs this same build
# (reading scripts/config.env.example instead) whenever a vX.Y.Z tag is
# pushed — use this script for a local/manual publish, the workflow for the
# normal release flow.
#
# Prerequisite (interactive, do it yourself once):
#   docker login ghcr.io -u <your-github-username>   # PAT with write:packages
#
# Pushes two tags:
#   $GHCR_IMAGE:$RUNTIME_VERSION      — the human release tag the manifests pin
#   $GHCR_IMAGE:llamacpp-<short sha>  — immutable provenance tag (the llama.cpp
#                                       pin is the fragile ABI axis; see
#                                       config.env.example)
#
# After the FIRST push, make the package public: github.com → your profile →
# Packages → chat-rk1/rocket-runtime → Package settings → Change visibility.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
[ -f "$here/config.env" ] && source "$here/config.env"
: "${BUILDER:=talos-builder}"; : "${PLATFORM:=linux/arm64}"
: "${GHCR_OWNER:=eburgueno}"
: "${GHCR_IMAGE:=ghcr.io/${GHCR_OWNER}/chat-rk1/rocket-runtime}"
: "${RUNTIME_VERSION:=v0.1.0}"
: "${LLAMACPP_REF:=}"

if ! grep -q '"ghcr.io"' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" 2>/dev/null; then
  echo "ERROR: not logged in to ghcr.io — run: docker login ghcr.io -u $GHCR_OWNER" >&2
  exit 2
fi

tags=(-t "$GHCR_IMAGE:$RUNTIME_VERSION")
[ -n "$LLAMACPP_REF" ] && tags+=(-t "$GHCR_IMAGE:llamacpp-${LLAMACPP_REF:0:7}")

# Only pass refs that are actually set — an EMPTY --build-arg overrides the
# Dockerfile's pinned ARG default and breaks `git checkout ""`.
for v in ROCKET_USERSPACE_REF GGML_ROCKET_REF PATCHES_REF LLAMACPP_REF; do
  [ -n "${!v:-}" ] && tags+=(--build-arg "$v=${!v}")
done

# Same build invocation as 10-build-runtime.sh — with a warm buildx cache this
# is a retag-speed no-op, not a rebuild.
cp "$root/bench/bench.sh" "$root/docker/runtime/bench.sh"
set -x
docker buildx build --builder "$BUILDER" --platform "$PLATFORM" \
  "${tags[@]}" \
  --push \
  "$root/docker/runtime"
set +x
echo "pushed: $GHCR_IMAGE:$RUNTIME_VERSION"
[ -n "$LLAMACPP_REF" ] && echo "pushed: $GHCR_IMAGE:llamacpp-${LLAMACPP_REF:0:7}"
echo "remember: first push → make the ghcr package PUBLIC (see header)."
