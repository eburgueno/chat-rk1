# Benchmark: gpt-oss-20b-mxfp4.gguf
NPU clock: **600MHz**  ·  label: `gptoss20b-600`

| case | CPU t/s | NPU t/s | NPU×CPU |
|---|---|---|---|
| pp512 (prefill) | 17.66 | 17.59 | 1.0 |
| pp2048 (prefill) | 16.69 | 15.48 | 0.93 |
| tg128 (decode) | 5.25 | 5.25 | 1.0 |
