#!/usr/bin/env bash
# rocket-stack benchmark harness — CPU vs NPU prefill/decode via llama-bench.
#
# Runs INSIDE the rocket-runtime image (locally via `docker run`, or as the k8s
# Job on the Talos RK1 node). Produces one merged JSON results file plus a short
# markdown summary. llama-bench does its own warmup + repetitions and reports
# median t/s, so cold runs are excluded by construction.
#
# The whole point of the project is the PREFILL comparison: prompt-processing
# (pp) is the batched GEMM the NPU accelerates; token-generation (tg) is the
# memory-bound decode that stays on the CPU. We measure both, both backends.
#
# Config via env (all optional except a model):
#   MODEL_PATH   path to a .gguf already on disk (PVC / local). Takes priority.
#   MODEL_URL    URL to download a .gguf to $LLAMA_CACHE if MODEL_PATH unset.
#   PP           prefill prompt sizes, comma list      (default 512,2048)
#   TG           decode token counts, comma list       (default 128)
#   BATCH        logical batch -b                       (default 512)
#   REPS         repetitions per case -r                (default 5)
#   BACKENDS     which to run: "cpu npu" | "cpu" | "npu"   (default "cpu npu")
#   ROCKET_BACKEND  path to libggml-rocket.so           (default /opt/rocket/...)
#   CLK_LABEL    free-text NPU clock note for the report (e.g. "200MHz","600MHz")
#   OUT_DIR      results directory                      (default /results)
#   EXTRA_ROCKET extra ROCKET_* env for the NPU run (e.g. "ROCKET_INT4=1")
#   LABEL        run label used in filenames            (default auto timestamp-less)
#
# Exit non-zero only on harness/model errors; a backend that produces no rows is
# reported as such, not fatal.
set -uo pipefail

PP="${PP:-512,2048}"
TG="${TG:-128}"
BATCH="${BATCH:-512}"
REPS="${REPS:-5}"
BACKENDS="${BACKENDS:-cpu npu}"
ROCKET_BACKEND="${ROCKET_BACKEND:-/opt/rocket/libggml-rocket.so}"
CLK_LABEL="${CLK_LABEL:-unknown}"
OUT_DIR="${OUT_DIR:-/results}"
LABEL="${LABEL:-run}"
mkdir -p "$OUT_DIR"

log() { echo "[bench] $*" >&2; }

# ---- resolve model ------------------------------------------------------------
model="${MODEL_PATH:-}"
if [ -z "$model" ] && [ -n "${MODEL_URL:-}" ]; then
  model="${LLAMA_CACHE:-/models}/$(basename "${MODEL_URL%%\?*}")"
  if [ ! -f "$model" ]; then
    log "downloading $MODEL_URL -> $model"
    mkdir -p "$(dirname "$model")"
    if command -v curl >/dev/null; then
      curl -fL --retry 3 -o "$model.part" "$MODEL_URL" && mv "$model.part" "$model"
    else
      wget -O "$model.part" "$MODEL_URL" && mv "$model.part" "$model"
    fi
  fi
fi
if [ -z "$model" ] || [ ! -f "$model" ]; then
  log "ERROR: no model. Set MODEL_PATH=/path/to.gguf or MODEL_URL=https://..."
  exit 2
fi
model_name="$(basename "$model")"
log "model: $model_name  pp=$PP tg=$TG batch=$BATCH reps=$REPS backends='$BACKENDS'"

# ---- run one backend ----------------------------------------------------------
# $1 = tag (cpu|npu). Emits $OUT_DIR/<LABEL>.<tag>.json
run_backend() {
  local tag="$1" out="$OUT_DIR/$LABEL.$1.json"
  local -a cmd=(llama-bench -m "$model" -p "$PP" -n "$TG" -b "$BATCH" -r "$REPS" -o json)
  if [ "$tag" = npu ]; then
    if [ ! -f "$ROCKET_BACKEND" ]; then
      log "SKIP npu: $ROCKET_BACKEND not found"; return 3
    fi
    # -ngl 0: NPU offload is scheduler-driven (BLAS-style), not layer-offload.
    cmd+=(-ngl 0)
    log "NPU run (GGML_BACKEND_PATH=$ROCKET_BACKEND ${EXTRA_ROCKET:-})"
    env GGML_BACKEND_PATH="$ROCKET_BACKEND" ROCKET_MM_PROFILE="${ROCKET_MM_PROFILE:-1}" \
        ${EXTRA_ROCKET:-} "${cmd[@]}" > "$out" 2> "$OUT_DIR/$LABEL.$tag.stderr"
  else
    log "CPU run"
    "${cmd[@]}" > "$out" 2> "$OUT_DIR/$LABEL.$tag.stderr"
  fi
  local rc=$?
  if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
    log "backend '$tag' produced no results (rc=$rc); see $LABEL.$tag.stderr"
    return 1
  fi
  log "wrote $out"
}

for b in $BACKENDS; do run_backend "$b" || true; done

# ---- merge + summarize (python; llama-bench -o json is a list of case rows) ----
python3 - "$OUT_DIR" "$LABEL" "$model_name" "$CLK_LABEL" <<'PY'
import json, os, sys, glob
out_dir, label, model_name, clk = sys.argv[1:5]
merged = {"model": model_name, "npu_clock": clk, "label": label, "backends": {}}
for f in sorted(glob.glob(os.path.join(out_dir, f"{label}.*.json"))):
    tag = os.path.basename(f).split(".")[-2]
    if tag not in ("cpu", "npu"):
        continue
    try:
        rows = json.load(open(f))
    except Exception as e:
        merged["backends"][tag] = {"error": str(e)}
        continue
    cases = {}
    for r in rows:
        # llama-bench: n_prompt>0 => prefill (pp), else n_gen>0 => decode (tg)
        if r.get("n_prompt", 0):
            key = f"pp{r['n_prompt']}"
        elif r.get("n_gen", 0):
            key = f"tg{r['n_gen']}"
        else:
            continue
        cases[key] = round(r.get("avg_ts", 0.0), 2)
    merged["backends"][tag] = cases

# speedups (npu / cpu) per case
cpu = merged["backends"].get("cpu", {})
npu = merged["backends"].get("npu", {})
speedup = {}
for k in sorted(set(cpu) | set(npu)):
    if isinstance(cpu, dict) and isinstance(npu, dict) and cpu.get(k) and npu.get(k):
        speedup[k] = round(npu[k] / cpu[k], 2)
merged["speedup_npu_over_cpu"] = speedup

mj = os.path.join(out_dir, f"{label}.merged.json")
json.dump(merged, open(mj, "w"), indent=2)

# markdown summary
lines = [f"# Benchmark: {model_name}",
         f"NPU clock: **{clk}**  ·  label: `{label}`", "",
         "| case | CPU t/s | NPU t/s | NPU×CPU |", "|---|---|---|---|"]
for k in sorted(set(cpu) | set(npu), key=lambda s: (s[:2], int(''.join(c for c in s if c.isdigit()) or 0))):
    c = cpu.get(k, "—") if isinstance(cpu, dict) else "—"
    n = npu.get(k, "—") if isinstance(npu, dict) else "—"
    s = speedup.get(k, "—")
    tag = "prefill" if k.startswith("pp") else "decode"
    lines.append(f"| {k} ({tag}) | {c} | {n} | {s} |")
md = os.path.join(out_dir, f"{label}.summary.md")
open(md, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
print(f"\n[bench] merged -> {mj}\n[bench] summary -> {md}")
PY
