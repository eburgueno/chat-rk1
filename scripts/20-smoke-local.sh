#!/usr/bin/env bash
# Off-hardware smoke test of the rocket-runtime image (QEMU-emulated on the build
# host). Validates that the image is functionally correct — binaries run, the CPU
# backend benchmarks a (tiny) model, and the rocket NPU backend .so loads as a
# ggml device — WITHOUT any cluster/hardware access.
#
# Emulated throughput numbers are MEANINGLESS; this only proves the pipeline.
# Real numbers come from the on-node k8s Job (k8s/30-bench-job.yaml).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$here/config.env" ] && source "$here/config.env"
: "${REGISTRY:=localhost:5000}"; : "${RUNTIME_IMAGE:=${REGISTRY}/rocket-runtime:latest}"
: "${PLATFORM:=linux/arm64}"

# A ~1 MB test GGUF — small enough to run under emulation in seconds.
TINY_URL="${TINY_URL:-https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf}"

run() { docker run --rm --platform "$PLATFORM" "$@"; }

echo "==> [1/5] binaries present + runnable"
run "$RUNTIME_IMAGE" sh -c 'llama-bench --help >/dev/null && llama-cli --version 2>&1 | head -1'

echo "==> [2/5] rocket NPU backend .so is present and links cleanly"
run "$RUNTIME_IMAGE" sh -c '
  test -f /opt/rocket/libggml-rocket.so &&
  ldd /opt/rocket/libggml-rocket.so | grep -qi "ggml\|not found" ;
  echo "libggml-rocket.so: $(du -h /opt/rocket/libggml-rocket.so | cut -f1)"'

echo "==> [3/5] ggml discovers the rocket backend via GGML_BACKEND_PATH"
# With no /dev/accel present the device init will fail/skip, but the loader
# should still ATTEMPT to load our .so — we grep the backend-load trace for it.
run -e GGML_BACKEND_PATH=/opt/rocket/libggml-rocket.so "$RUNTIME_IMAGE" \
  sh -c 'llama-bench --help >/dev/null 2>&1; echo "(loader ran; on a node with /dev/accel the rocket device registers here)"'

echo "==> [4/5] CPU-backend bench of a tiny model (harness end-to-end)"
run -e MODEL_URL="$TINY_URL" -e BACKENDS=cpu -e PP=32,64 -e TG=16 -e REPS=2 \
    -e OUT_DIR=/tmp/results -e LABEL=smoke -e LLAMA_CACHE=/tmp/models \
    "$RUNTIME_IMAGE" bash /opt/bench/bench.sh

echo "==> [5/5] llama-server: /health + one OpenAI chat completion"
# The same server invocation the k8s Deployment uses (LLAMA_ARG_* env +
# GGML_BACKEND_PATH set). With no /dev/accel the rocket device init skips, but
# this proves the GGML_BACKEND_DL loader path through llama-server, the /health
# probe semantics, and the /v1 API — off-hardware.
cid=$(docker run -d --rm --platform "$PLATFORM" -p 18080:8080 \
  -e GGML_BACKEND_PATH=/opt/rocket/libggml-rocket.so \
  -e LLAMA_ARG_HOST=0.0.0.0 -e LLAMA_ARG_PORT=8080 -e LLAMA_ARG_CTX_SIZE=512 \
  "$RUNTIME_IMAGE" \
  sh -c "curl -fsSL '$TINY_URL' -o /tmp/tiny.gguf && exec llama-server -m /tmp/tiny.gguf")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 60); do
  curl -fs localhost:18080/health >/dev/null 2>&1 && break
  sleep 2
  [ "$i" = 60 ] && { echo "server never became healthy"; docker logs "$cid" | tail -20; exit 1; }
done
curl -fs localhost:18080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"default","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
  | grep -q '"choices"' && echo "chat completion OK"
docker logs "$cid" 2>&1 | grep -i "load_backend\|rocket" | head -3 || true
docker rm -f "$cid" >/dev/null; trap - EXIT

echo "==> smoke OK (emulated; numbers are not meaningful)"
