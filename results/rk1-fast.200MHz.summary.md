# Benchmark: Qwen2.5-3B-Instruct-f16.gguf
NPU clock: **200MHz**  ·  label: `rk1-fast`

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill) | 20.23 | 38.05 | 1.88 |
| tg32 (decode) | 3.34 | 3.38 | 1.01 |
