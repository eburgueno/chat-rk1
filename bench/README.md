# Benchmark harnesses

Two complementary harnesses. Both run inside the `rocket-runtime` image.

## `bench.sh` — the definitive prefill-vs-decode measurement (primary)

Wraps `llama-bench` (llama.cpp's own benchmark), which does warmup +
repetitions and reports **median** t/s, so cold runs are excluded by
construction. Runs each backend and merges the results:

- **prefill** (`ppN`) — prompt processing, the batched GEMM the NPU accelerates.
  This is the whole point of the project.
- **decode** (`tgN`) — token generation, memory-bandwidth-bound, stays on the
  CPU on both backends.

CPU vs NPU is selected purely by whether the rocket backend `.so` is loaded:

```sh
# CPU baseline
llama-bench -m model.gguf -p 512,2048 -n 128
# NPU (scheduler-driven offload; -ngl 0 because it's BLAS-style, not layer-offload)
GGML_BACKEND_PATH=/opt/rocket/libggml-rocket.so llama-bench -m model.gguf -p 512,2048 -n 128 -ngl 0
```

`bench.sh` runs both, writes `<LABEL>.{cpu,npu}.json`, and produces
`<LABEL>.merged.json` + `<LABEL>.summary.md` with the NPU/CPU speedup per case.
Configure via env (see the header of `bench.sh`): `MODEL_URL`/`MODEL_PATH`,
`PP`, `TG`, `BATCH`, `REPS`, `BACKENDS`, `CLK_LABEL`, `EXTRA_ROCKET`.

On the cluster it runs as `k8s/30-bench-job.yaml`; locally it runs under
`docker run` against the same image (emulated numbers are meaningless — use it
only to validate the harness off-hardware).

## `../tools/bench/llm-bench.py` — the interactive / server path (secondary)

Drives an Ollama-compatible HTTP API (`/api/generate`) and reports the
prefill/decode split from the server's `*_duration` fields, with a wall-clock
fallback. Use it to measure the **interactive turn** (time-to-first-token +
stream rate) through a running `llama-server` or `rkllama`, which is the latency
a user actually feels — complementary to `bench.sh`'s raw throughput numbers.
