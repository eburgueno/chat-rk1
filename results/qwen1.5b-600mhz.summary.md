# Benchmark: qwen2.5-1.5b-instruct-fp16.gguf
NPU clock: **600MHz**  ·  label: `qwen1-5b-600`

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill) | 42.35 | 91.94 | 2.17 |
| pp2048 (prefill) | 38.73 | 59.82 | 1.54 |
| tg128 (decode) | 6.21 | 6.2 | 1.0 |
