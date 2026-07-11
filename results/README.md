# Benchmark results — CPU vs NPU, Talos RK1 32GB node

Measured on the Talos RK1 32GB node (RK3588, 4×A76 + 4×A55, kernel `6.18.34-talos`)
via `bench/bench.sh` (`llama-bench`, warm median of repetitions). CPU vs NPU is the
same image + same GGUF; the NPU is selected only by loading the rocket ggml
backend (`GGML_BACKEND_PATH`). `pp` = prefill (prompt processing, batched GEMM —
the NPU's job); `tg` = decode (token generation, memory-bandwidth-bound).

## Headline (200 MHz, stock in-tree `rocket.ko`)

Model: Qwen2.5-3B-Instruct **F16**. NPU compute clock at the DT default **200 MHz**
(unpatched driver — the clock lever is Phase B).

Sanity pass (`rk1-fast`, reps=1):

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill) | 20.23 | 38.05 | **1.88×** |
| tg32 (decode)   | 3.34  | 3.38  | 1.01×   |

**The NPU beats the CPU on prefill (1.88×) even at the un-raised 200 MHz clock;
decode ties (memory-bound).** This is the prefill-vs-decode distinction the prior
"closed" verdict (which measured only decode) never isolated — overturned here on
our own hardware.

Full run (`rk1-32gb`, pp512+pp2048, reps=5, warm medians):

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill)  | 20.27 | 37.23 | **1.84×** |
| pp2048 (prefill) | 18.35 | 29.22 | **1.59×** |
| tg128 (decode)   | 3.38  | 3.37  | 1.00×   |

The prefill win holds across prompt sizes; the ratio tapers from pp512→pp2048
(1.84→1.59) — the same trend ggml-rocket reports (per-submit + K-accum readback
overhead grows with the prompt, and at 200 MHz the NPU's compute, not the CPU, is
the ceiling). Decode is a dead tie, as predicted (bandwidth-bound, off the NPU).

## 600 MHz (Phase B, patched module — clock lever confirmed)

The 081 patch raised the NPU compute clock 200→600 MHz from `runtime_resume`
(domain powered), and **the node stayed stable — no SCMI/EL3 reset** (the wall the
prior effort hit with cold, domain-off sets). Full run (`rk1-600mhz`, reps=5):

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill)  | 20.27 | 48.97 | **2.42×** |
| pp2048 (prefill) | 18.39 | 36.19 | **1.97×** |
| tg128 (decode)   | 3.39  | 3.38  | 1.00×   |

## 200 vs 600 MHz — the clock lever's effect (NPU t/s)

CPU is clock-independent (unchanged); the NPU prefill scales with the clock,
turning a ~1.8× win into ~2.4×:

| case | NPU @200 | NPU @600 | clock scaling | ×CPU @200 → @600 |
|---|---|---|---|---|
| pp512  | 37.23 | 48.97 | 1.32× | 1.84× → 2.42× |
| pp2048 | 29.22 | 36.19 | 1.24× | 1.59× → 1.97× |

The ~1.3× prefill gain tracks the 200→600 MHz clock ratio (sublinear — larger
prompts lean more on per-submit/readback overhead and DRAM), and the ~2.4× win at
pp512 is in line with ggml-rocket's published ~2.6× for the similar-size
Llama-3.2-3B. Decode ties at every clock (bandwidth-bound, off the NPU).

> 600 MHz is now the **durable** default (modprobe.d `options` shipped in the
> `rocket-patched` extension — see `docker/module/README.md`); the param stays
> sysfs-writable to change it live.

## Clock sweep — 600 MHz is the sweet spot (diminishing returns above it)

Raising `rocket_npu_clk_hz` past 600 MHz (at the fixed 0.80 V rail, no voltage
patch) and re-measuring pp512 prefill on the NPU:

| NPU clock | pp512 NPU t/s | node |
|---|---|---|
| 600 MHz | ~50.0 | stable |
| 700 MHz | 49.5 | stable |
| 800 MHz | 49.6 | stable (no lock at 0.80 V) |

Throughput is **flat from 600→800 MHz** — above ~600 MHz LLM prefill is no longer
NPU-compute-bound; the bottleneck is CPU-side K-accumulation / output readback /
DRAM traffic / per-submit dispatch, none of which the NPU clock touches. So there
is **no reason to chase higher clocks or add the 082 voltage-coupling patch for
this workload** (a more compute-dense op — e.g. large batched vision conv — could
differ). The clock set itself was stable and reversible at every step (the sysfs
param reverts to the durable 600 on reboot).

## Model sweep — does the prefill win scale with size? (Qwen2.5 F16, 600 MHz)

Same family, same backend/clock, varying parameter count (pp512/pp2048 reps=5):

| model | pp512 CPU→NPU (×) | pp2048 CPU→NPU (×) | decode t/s |
|---|---|---|---|
| Qwen2.5-1.5B | 42.4 → 91.9 (**2.17×**) | 38.7 → 59.8 (**1.54×**) | 6.2 |
| Qwen2.5-3B   | 20.3 → 49.0 (**2.42×**) | 18.4 → 36.2 (**1.97×**) | 3.4 |
| Qwen2.5-7B   | 9.0 → 26.4 (**2.95×**)  | 8.6 → 21.5 (**2.50×**)  | 1.6 |

The NPU prefill advantage **grows monotonically with model size** — pp512
2.17× → 2.42× → 2.95× and pp2048 1.54× → 1.97× → 2.50× across 1.5B → 3B → 7B —
matching ggml-rocket's observation: larger dense matmuls keep more of the prefill
FLOPs on the NPU. Absolute NPU prefill falls with size (91.9 → 49.0 → 26.4 t/s at
pp512, more FLOPs per token) but the CPU falls faster, so the *ratio* climbs.
Decode ties at every size (bandwidth-bound, off the NPU). So the NPU is most worth
it exactly where prefill hurts most — the larger the model, the bigger the
time-to-first-token win.

### The boundary — MoE gets no benefit (gpt-oss-20b, MXFP4, 600 MHz)

| model | pp512 (NPU×CPU) | pp2048 (NPU×CPU) | decode |
|---|---|---|---|
| gpt-oss-20b (MoE, ~3.6B active) | 17.7 → 17.6 (**1.00×**) | 16.7 → 15.5 (**0.93×**) | tie |

The dense 2–3× win **does not extend to Mixture-of-Experts**. By default
(`ROCKET_MOE=0`) the routed expert FFNs — which are the bulk of MoE prefill FLOPs —
stay on the CPU; only the dense projections + attention offload, so there's nothing
left for the NPU to win on, and at pp2048 the offload overhead makes it marginally
*slower* (0.93×). (ggml-rocket reports the same, ~1.04×; forcing experts onto the
NPU with `ROCKET_MOE=1` is numerically faithful but slower still.) This marks the
edge of the result: **the NPU-prefill win is a dense-model phenomenon** — it scales
up with dense size and vanishes for MoE. Decode ties as always.

## Files

- `rk1-fast.200MHz.*` — reps=1 sanity pass @200 MHz.
- `rk1-32gb.200MHz.*` — reps=5 full run @200 MHz (pp512+pp2048).
- `rk1-600-fast.merged.json` — reps=1 NPU-only trigger @600 MHz.
- `rk1-600mhz.*` — reps=5 full run @600 MHz (pp512+pp2048).

## Reproduce

See the top-level `README.md` → "Reproduce end-to-end" and `k8s/README.md`. In
short: build the runtime image, apply `k8s/`, read the results off the model-cache
PVC.
