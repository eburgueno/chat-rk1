# Benchmark: Qwen2.5-3B-Instruct-f16.gguf
NPU clock: **600MHz**  ·  label: `rk1-600mhz`

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill) | 20.27 | 48.97 | 2.42 |
| pp2048 (prefill) | 18.39 | 36.19 | 1.97 |
| tg128 (decode) | 3.39 | 3.38 | 1.0 |
