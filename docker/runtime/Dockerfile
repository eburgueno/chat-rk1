# syntax=docker/dockerfile:1
#
# rocket-runtime — aarch64 LLM inference image for the RK3588 NPU.
#
# Contains stock llama.cpp (llama-bench / llama-cli / llama-server) built with a
# shared, DL-capable ggml, plus the rocket NPU backend as a runtime-loadable
# GGML_BACKEND_DL module (libggml-rocket.so). The SAME image benchmarks both
# backends:
#   CPU:  llama-bench -m model.gguf              # no NPU backend loaded
#   NPU:  GGML_BACKEND_PATH=/opt/rocket/libggml-rocket.so llama-bench -m model.gguf
#
# Built for linux/arm64 (native on an RK1 node, or QEMU-emulated via buildx).
# All upstream sources are pinned by commit (build-args, defaulted from
# scripts/config.env) for reproducibility.
#
# The NPU backend is loaded lazily; it only touches /dev/accel at runtime. This
# image runs fine on any aarch64 host for the CPU baseline with no NPU present.

ARG BASE=debian:trixie-slim

# ---- build args (pinned upstream sources) ------------------------------------
ARG ROCKET_USERSPACE_REPO=https://github.com/gregordinary/rocket-userspace
ARG ROCKET_USERSPACE_REF=1a181cd69fd98fafa998cfeca963d35cb5f43c46
ARG GGML_ROCKET_REPO=https://github.com/gregordinary/ggml-rocket
ARG GGML_ROCKET_REF=fb3f14e6b0873911af5d209f15f3b84393afbd54
ARG PATCHES_REPO=https://github.com/gregordinary/patches
ARG PATCHES_REF=314b1b34b561e0b7f92a9893798eda3f3a8abf16
ARG LLAMACPP_REPO=https://github.com/ggml-org/llama.cpp
ARG LLAMACPP_REF=465e49b9cea78a68b9c244ffb48d0ee24a82873d

# ==============================================================================
# Stage 1: build
# ==============================================================================
FROM ${BASE} AS build
ARG ROCKET_USERSPACE_REPO ROCKET_USERSPACE_REF
ARG GGML_ROCKET_REPO GGML_ROCKET_REF
ARG PATCHES_REPO PATCHES_REF
ARG LLAMACPP_REPO LLAMACPP_REF
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates pkg-config \
      libdrm-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# --- the rocket DRM-accel uAPI header ------------------------------------------
# rocket-userspace needs <drm/rocket_accel.h> at configure time. On a rocket
# kernel it ships in /usr/include/drm; in this container we install it from the
# patches repo (the authoritative out-of-tree copy).
RUN git clone --filter=blob:none "${PATCHES_REPO}" patches \
    && git -C patches checkout "${PATCHES_REF}" \
    && install -D -m0644 patches/rocket/uapi/rocket_accel.h \
         /usr/include/drm/rocket_accel.h

# --- llama.cpp: shared libs + DL backend loader --------------------------------
# GGML_BACKEND_DL=ON makes ggml discover backends via GGML_BACKEND_PATH at
# runtime; BUILD_SHARED_LIBS=ON emits the libggml-*.so our backend links against.
RUN git clone "${LLAMACPP_REPO}" llama.cpp \
    && git -C llama.cpp checkout "${LLAMACPP_REF}" \
    && cmake -S llama.cpp -B llama.cpp/build \
         -DCMAKE_BUILD_TYPE=Release \
         -DGGML_BACKEND_DL=ON -DBUILD_SHARED_LIBS=ON \
         -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+fp16+dotprod \
         -DLLAMA_CURL=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    && cmake --build llama.cpp/build -j"$(nproc)" \
         --target llama-bench llama-cli llama-server

# --- rocket-userspace (librocketnpu) -------------------------------------------
RUN git clone "${ROCKET_USERSPACE_REPO}" rocket-userspace \
    && git -C rocket-userspace checkout "${ROCKET_USERSPACE_REF}" \
    && cmake -S rocket-userspace -B rocket-userspace/build \
         -DCMAKE_BUILD_TYPE=Release -DROCKETNPU_BUILD_TESTS=OFF \
    && cmake --build rocket-userspace/build -j"$(nproc)" \
    && cmake --install rocket-userspace/build --prefix /usr/local

# --- ggml-rocket: the drop-in NPU backend .so ----------------------------------
# DL mode, linking the shared ggml from the llama.cpp build above. NATIVE_FP16 is
# the RK3588 (armv8.2-a+fp16) default.
RUN git clone "${GGML_ROCKET_REPO}" ggml-rocket \
    && git -C ggml-rocket checkout "${GGML_ROCKET_REF}" \
    && cmake -S ggml-rocket -B ggml-rocket/build-dl \
         -DCMAKE_BUILD_TYPE=Release \
         -DGGML_ROCKET_DL=ON \
         -DHOST_DIR=/src/llama.cpp \
         -DGGML_LIB_DIR=/src/llama.cpp/build/bin \
         -DROCKETNPU_DIR=/src/rocket-userspace \
    && cmake --build ggml-rocket/build-dl -j"$(nproc)" \
    && install -D -m0755 ggml-rocket/build-dl/libggml-rocket.so \
         /opt/rocket/libggml-rocket.so

# Collect the llama.cpp binaries + shared libs into ONE flat prefix. With
# GGML_BACKEND_DL the CPU backend (libggml-cpu.so) is a module ggml discovers in
# the executable's own directory — so binaries and backend .so must be
# co-located (a bin/ + lib/ split breaks auto-discovery: "CPU backend is not
# loaded"). libggml-rocket.so is deliberately kept OUT of this dir (in
# /opt/rocket) so it loads ONLY when GGML_BACKEND_PATH points at it — that is
# what keeps the CPU baseline free of any NPU offload.
RUN mkdir -p /opt/llama \
    && cp -a llama.cpp/build/bin/llama-bench llama.cpp/build/bin/llama-cli \
          llama.cpp/build/bin/llama-server /opt/llama/ \
    && cp -a llama.cpp/build/bin/*.so* /opt/llama/   # all shared libs, keep symlinks

# ==============================================================================
# Stage 2: runtime
# ==============================================================================
FROM ${BASE} AS runtime
LABEL org.opencontainers.image.source="https://github.com/eburgueno/chat-rk1" \
      org.opencontainers.image.description="llama.cpp + ggml-rocket NPU backend for the RK3588 (Turing RK1) — llama-server/llama-bench/llama-cli" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libdrm2 libcurl4 libgomp1 ca-certificates python3 curl \
    && rm -rf /var/lib/apt/lists/*

# Flat layout: binaries + ggml backend/base libs together in /opt/llama so the
# DL loader auto-discovers the CPU backend from the executable's directory.
COPY --from=build /opt/llama/ /opt/llama/
COPY --from=build /opt/rocket/libggml-rocket.so /opt/rocket/libggml-rocket.so
# The benchmark harness (staged into the build context by 10-build-runtime.sh).
COPY bench.sh /opt/bench/bench.sh
RUN chmod +x /opt/bench/bench.sh

# CPU baseline: leave GGML_BACKEND_PATH unset. NPU: set it to $ROCKET_BACKEND.
ENV PATH=/opt/llama:$PATH \
    LD_LIBRARY_PATH=/opt/llama \
    ROCKET_BACKEND=/opt/rocket/libggml-rocket.so \
    LLAMA_CACHE=/models
WORKDIR /models
# Default: print backend/system info so a bare `docker run` proves the build.
CMD ["llama-bench", "--help"]
