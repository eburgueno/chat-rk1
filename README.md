# chat-rk1 — an NPU-accelerated LLM chat UI on a Turing RK1, on Talos Linux

> **AI disclosure:** this repository — manifests, scripts, and documentation —
> was largely written with AI assistance (Claude), directed and reviewed by a
> human. Everything performance-related was measured on real hardware (the
> numbers below are from a live cluster, not model output), but read with the
> same healthy skepticism you'd apply to any homelab writeup.

**"I have a Turing RK1 (RK3588) running Talos — can I run an LLM on it, with
the NPU actually doing something useful?"**

Yes. This repo takes you from that question to a working, browser-based chat
UI (Open WebUI + llama.cpp's `llama-server`) on your Kubernetes cluster, with
the RK3588's NPU accelerating the part it's genuinely good at — **prefill**,
i.e. time-to-first-token. Everything needed is vendored here: the device-tree
overlay, the (optional) patched kernel module and Talos extension recipe, the
container image build, the Kubernetes manifests, and the rescue kit for when
you poke device trees on real hardware.

Measured end-to-end on the reference node (RK1 32 GB, Talos v1.13.4, kernel
6.18.34, NPU at 600 MHz, Qwen2.5-3B-Instruct f16, ~1940-token prompt, the
exact stack these manifests deploy):

| | time to first token | tokens/s while streaming |
|---|---|---|
| CPU only (8 cores) | 106.6 s | ~3.0 |
| **with NPU** | **60.0 s** | ~3.0 |

The NPU answers **1.8× sooner** on a long prompt and streams at the same
speed. At the benchmark level (`llama-bench`, pp512) the gap is **2.4×**
(49 vs 20 t/s). The win grows with dense model size (7B: 2.95×) and shrinks
to nothing for MoE models. Decode is memory-bandwidth-bound and identical
either way — the NPU buys you *responsiveness*, not streaming speed.

What that means in practice: pasting a long document, a big code file, or
carrying a long chat history feels dramatically less "did it hang?" — and
that's exactly the workload where a 3B-f16 model on a $130 board is otherwise
painful.

## What you need

- A **Turing Pi 2** with at least one **RK1** module — 32 GB recommended
  (16 GB works for models ≤3B), ideally with local SATA/NVMe storage.
- A **Talos ≥ v1.13.4** Kubernetes cluster on it (kernel 6.18+, which carries
  the mainline `rocket` NPU driver). Cluster scaffolding assumed present:
  a storage class (local-disk one preferred), an nginx ingress with some TLS
  arrangement, outbound internet from pods (for the model download).
- An **x86 build host** with docker — only if you build the runtime image
  yourself or go for the 600 MHz kernel module (a prebuilt image on ghcr.io
  is the default path).

## Architecture

```
browser ──HTTPS──> ingress ──> Open WebUI ──OpenAI API──> llama-server ──/dev/accel──> NPU
                               (any node)                 (NPU node,          (rocket driver,
                                open-webui-data PVC)       model-cache PVC)    3 cores)
```

| Component | Image | Role |
|---|---|---|
| llama-server | `ghcr.io/eburgueno/chat-rk1/rocket-runtime` | OpenAI-compatible inference server; llama.cpp + the `ggml-rocket` NPU backend |
| Open WebUI | `ghcr.io/open-webui/open-webui` (pinned) | chat interface, history, RAG |

**The entire CPU-vs-NPU story is one environment variable.** The runtime
image contains stock llama.cpp built with runtime-loadable backends
(`GGML_BACKEND_DL`) plus `libggml-rocket.so`. When `GGML_BACKEND_PATH` points
at that `.so`, ggml offloads the big prefill matmuls to the NPU; unset it and
the same image is a clean CPU baseline. That's also your A/B test (Step 6).

## Step 1 — a Talos image with the NPU enabled

Covered in **[`docs/talos-image.md`](docs/talos-image.md)**. Short version:

- **Standard path (200 MHz, no builds):** add the official
  `siderolabs/rockchip-rknn` extension to your factory.talos.dev schematic
  (turingrk1 overlay), upgrade the node, verify `/dev/accel/accel0` exists.
  Prefill win at this clock: ~1.8× (pp512).
- **Optional path (600 MHz, +35% prefill):** build the patched `rocket.ko`
  (clock lever) and its `rocket-patched` extension —
  [`docker/module/README.md`](docker/module/README.md). Hours of one-time
  kernel build and a module-signature caveat; the headline 2.4× numbers are
  from this clock. Do it after the 200 MHz stack works.

> ⚠ If you end up touching the device tree (only needed on older overlays),
> stage the rescue kit first: [`docs/rescue.md`](docs/rescue.md). A bad DTB
> on the RK1 disables **both** A/B boot slots.

## Step 2 — node prep

```sh
# verify the NPU is live (see docs/talos-image.md for expected output)
talosctl -n <node-ip> ls /dev/accel                      # accel0
talosctl -n <node-ip> dmesg | grep -i rocket             # cores bound

# tell the manifests which node has it
kubectl label node <your-npu-node> npu.rocket-stack/enabled=true
```

> After a **cold power-on**, do one `talosctl reboot` — cold boots can lose
> the CMA pool the NPU allocates from (symptom: NPU jobs fail or silently
> fall back until the next reboot).

## Step 3 — the runtime image

Default: use the prebuilt `ghcr.io/eburgueno/chat-rk1/rocket-runtime` — nothing
to do.

Build your own (recommended for pin-bumps; required if you don't trust random
images, which is fair):

```sh
cp scripts/config.env.example scripts/config.env    # set REGISTRY etc.
source scripts/config.env
scripts/00-infra.sh          # binfmt + local registry + buildx (one-time)
scripts/10-build-runtime.sh  # build + push (QEMU cross-build, ~1h first time)
scripts/20-smoke-local.sh    # prove it works, incl. llama-server, off-hardware
```

Point the manifests at your image via a kustomize overlay (Step 4). If your
registry is plain-HTTP on the LAN, apply `talos/registry-insecure.patch.yaml`
to the nodes so containerd will pull from it. To publish your build to ghcr:
`scripts/30-push-ghcr.sh`.

## Step 4 — deploy

Manifests are numbered; details in [`k8s/README.md`](k8s/README.md). Two
equivalent routes:

**Plain kubectl** (edit `k8s/50-ingress.yaml`'s hostname first, and the
storage class comment in `10-model-cache-pvc.yaml`):

```sh
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-model-cache-pvc.yaml
kubectl apply -f k8s/20-llama-server-config.yaml
kubectl apply -f k8s/30-llama-server.yaml
kubectl apply -f k8s/40-open-webui.yaml
kubectl apply -f k8s/50-ingress.yaml
```

**Kustomize overlay** (keeps the base pristine; recommended):

```sh
cp -r kustomize/overlays/example kustomize/overlays/mysite
# edit mysite/: storage class, hostname, image, optionally model
kubectl apply -k kustomize/overlays/mysite/
```

First start downloads the default model (Qwen2.5-3B-Instruct f16, ~6.2 GB)
into the model-cache PVC — the pod shows `Init:0/1` meanwhile:

```sh
kubectl -n chat-rk1 logs -f deploy/llama-server -c fetch-model   # progress
kubectl -n chat-rk1 rollout status deploy/llama-server deploy/open-webui
```

On the reference cluster this took ~6 minutes to fully Ready.

## Step 5 — chat

Open `https://<your-host>/` — no login by default (`WEBUI_AUTH=false`; flip
it in `k8s/40-open-webui.yaml` **before** exposing beyond your LAN). Pick
`qwen2.5-3b-instruct` and paste something long.

Direct API access (any OpenAI-compatible client — IDE plugins, `llm`, etc.):

```sh
kubectl -n chat-rk1 port-forward svc/llama-server 8080:8080
curl localhost:8080/v1/models
curl localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"default","messages":[{"role":"user","content":"hello"}]}'
```

- **Base URL** `http://localhost:8080/v1` · **API key** anything non-empty ·
  **model** `qwen2.5-3b-instruct`
- llama-server also serves its own minimal web UI on that port — handy for
  debugging without Open WebUI in the loop.

## Step 6 — prove the NPU is actually working

Three checks, strongest first:

1. **Benchmark inside the pod** (backend column should read `ROCKET`, and
   pp512 should be ~2.4× the CPU number):
   ```sh
   kubectl -n chat-rk1 exec deploy/llama-server -- \
     llama-bench -m /models/Qwen2.5-3B-Instruct-f16.gguf -p 512 -n 0 -r 1 -ngl 0
   kubectl -n chat-rk1 exec deploy/llama-server -- sh -c \
     'env -u GGML_BACKEND_PATH llama-bench -m /models/Qwen2.5-3B-Instruct-f16.gguf -p 512 -n 0 -r 1'
   ```
   Measured here: **48.9** vs **20.3** t/s (600 MHz).
2. **TTFT A/B on the live server** with `scripts/ttft-check.sh` (procedure in
   the script header — disable the backend with an env override, compare,
   restore). Measured here: **60.0 s vs 106.6 s** at ~1940 prompt tokens.

One non-check: `llama-server` loads the backend silently — its log filter
hides ggml's `load_backend:` line, so **don't** take its absence in
`kubectl logs` as failure. The `llama-bench` runs above do print it
(`load_backend: loaded ROCKET backend from /opt/rocket/libggml-rocket.so`).

Optional: reproduce the full benchmark suite with the vendored Job
(`k8s/80-bench-config.yaml` + `k8s/90-bench-job.yaml`, see `k8s/README.md`)
and compare against [`results/`](results/README.md).

## Models — what to run

Defaults and alternatives (all measured on this stack at 600 MHz, f16
weights; swap via `20-llama-server-config.yaml` or your overlay's
`model.patch.yaml` — keep `MODEL_URL`/`MODEL_FILE`/`LLAMA_ARG_ALIAS` in sync):

| Model (GGUF f16) | Size | NPU prefill win (pp512) | Decode | RAM fit | Verdict |
|---|---|---|---|---|---|
| Qwen2.5-1.5B-Instruct | ~3.1 GB | 2.17× (92 t/s) | ~6.2 t/s | 16 GB easily | fastest chat, shallow answers |
| **Qwen2.5-3B-Instruct** (default) | ~6.2 GB | 2.42× (49 t/s) | ~3.4 t/s | 16/32 GB | the sweet spot |
| Qwen2.5-7B-Instruct | ~15 GB | 2.95× (26 t/s) | ~1.6 t/s | 32 GB only | best answers, patient users |
| gpt-oss-20b (MXFP4, MoE) | ~11 GB | **1.0× — no win** | ~5.3 t/s | 32 GB | don't bother with the NPU |

Notes:
- **f16 gives the cleanest NPU offload** (the backend accelerates F16
  matmuls). Quantized GGUFs run fine but trade away the prefill win — that's
  the quality-vs-TTFT tradeoff to make consciously.
- **MoE models get no NPU benefit** (routed expert FFNs stay on the CPU).
- Avoid HF-gated repos for `MODEL_URL` (the in-cluster download has no
  token). If a URL dies, drop any GGUF onto the PVC by hand
  (`kubectl cp` into the pod's `/models`) and update `MODEL_FILE`.
- Raising `LLAMA_ARG_CTX_SIZE` costs RAM (~36 KiB/token at f16 for the 3B) —
  budget against the container's memory limit (see OOM math below).

## More than one RK1?

Multiple NPU nodes can each serve their own conversation at full speed —
the pattern is one llama-server per node with conversations pinned via
distinct model aliases (not distributed inference, which doesn't pay over
Ethernet). Design options, trade-offs, and a recipe:
[`docs/multi-node.md`](docs/multi-node.md).

## Performance expectations

Full measured tables (clock sweep, size sweep, MoE boundary, 200-vs-600 MHz):
[`results/README.md`](results/README.md). Highlights:

- 200 MHz (stock, no kernel build): 3B pp512 **1.84×**, pp2048 1.59×.
- 600 MHz (patched module): 3B pp512 **2.42×**, pp2048 1.97×.
- Above 600 MHz: nothing (prefill stops being NPU-clock-bound).
- Decode: always a tie. If someone tells you an RK3588 NPU speeds up token
  streaming for LLMs, they haven't measured it.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| llama-server pod `Pending` | No node labelled `npu.rocket-stack/enabled=true`, or the PVC's storage class can't provision there. `kubectl -n chat-rk1 describe pod ...` |
| Stuck in `Init:0/1` | Model downloading (fine — watch `-c fetch-model` logs) or no egress to huggingface.co. The download resumes across restarts. |
| Pod restarts with probe failures during first start | Very slow storage (NFS) making the ~6 GB model load exceed the startup probe — move the PVC to local disk, or raise `startupProbe.failureThreshold`. |
| `OOMKilled` | Memory limit vs model+context: f16 3B ≈ 6.2 GiB weights + ~1.2 GiB KV at 32k ctx. Bigger model or context ⇒ raise the limit in `30-llama-server.yaml` accordingly. Keep `LLAMA_ARG_N_PARALLEL=1`. |
| No NPU speedup | `GGML_BACKEND_PATH` unset/empty (check ConfigMap); MoE model (expected); NPU lost CMA after a cold power-on (one `talosctl reboot`); or you're at 200 MHz expecting 600 MHz numbers. |
| `load_backend` line missing from server logs | Normal — llama-server filters it. Use the Step 6 checks instead. |
| Node won't boot after DTB/module changes | [`docs/rescue.md`](docs/rescue.md). This is why you staged the TFTP kit. |
| Open WebUI "connection error" | `kubectl -n chat-rk1 exec deploy/open-webui -- curl -s http://llama-server:8080/health` — if that's fine, check the UI pod logs. |

## Repo map

| Path | What |
|---|---|
| `k8s/` | the numbered manifests (+ kustomize base) — see `k8s/README.md` |
| `kustomize/overlays/example/` | site-override template (storage class, host, model, image) |
| `docker/runtime/` | the inference image: llama.cpp + rocket-userspace + ggml-rocket, pinned |
| `docker/module/` | optional 600 MHz patched `rocket.ko`: patches, extension recipe, modprobe.d |
| `overlay/` | RK3588 NPU device-tree overlay (only needed on older sbc-rockchip DTBs) |
| `scripts/` | build infra, ghcr publish, TTFT checker (all read `scripts/config.env`) |
| `bench/` + `k8s/80,90` | the CPU-vs-NPU benchmark harness (llama-bench Job) |
| `results/` | the measured numbers this README quotes |
| `docs/` | Talos image guide, multi-node scaling, rescue runbook, provenance/pins, licensing |
| `tools/` | imager/binfmt compose files + the TFTP/HTTP rescue-kit servers |

## Provenance & licensing

Every upstream source is pinned — refs in
[`docs/PROVENANCE.md`](docs/PROVENANCE.md) and `scripts/config.env.example`.
Licensing map (MIT repo, GPL vendored bits, GPL-3.0-linked image):
[`docs/LICENSES.md`](docs/LICENSES.md).

The FOSS RK3588 NPU stack this stands on is
[gregordinary](https://github.com/gregordinary)'s work (rocket-userspace,
ggml-rocket, the driver patches), on top of the mainline `rocket` DRM-accel
driver by Tomeu Vizoso / Collabora. The measurements and the
Talos-integration path (extension, DT overlay, clock lever, this deployment)
come from the research effort this repo packages.
