# Benchmark: Qwen2.5-7B-Instruct-f16.gguf
NPU clock: **600MHz**  ·  label: `qwen7b-600`

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill) | 8.97 | 26.42 | 2.95 |
| pp2048 (prefill) | 8.6 | 21.47 | 2.5 |
| tg128 (decode) | 1.6 | 1.59 | 0.99 |
