# Benchmark: Qwen2.5-3B-Instruct-f16.gguf
NPU clock: **200MHz**  ·  label: `rk1-32gb`

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill) | 20.27 | 37.23 | 1.84 |
| pp2048 (prefill) | 18.35 | 29.22 | 1.59 |
| tg128 (decode) | 3.38 | 3.37 | 1.0 |
