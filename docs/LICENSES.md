# Licensing map

**This repository's own content** — manifests, scripts, docs, configuration —
is MIT-licensed (see `LICENSE`). A few vendored pieces carry their own
licenses, and the container image built from `docker/runtime/Dockerfile` links
GPL code:

| Thing | License | Why |
|---|---|---|
| repo content (k8s/, kustomize/, scripts/, docs/, tools/) | MIT | ours |
| `overlay/rk3588-turing-rk1-npu-rocket.dtso` | GPL-2.0 | device-tree source derived from the kernel DT |
| `docker/module/patches/084-*.patch` | GPL-2.0 | kernel-derived (patch to `drivers/accel/rocket`) |
| `docker/module/` recipes (pkg.yaml, extension) | MIT | build recipes, ours |
| **rocket-runtime image** (built artifact) | effectively **GPL-3.0** | statically combines the pieces below |
| └ [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | MIT | inference engine |
| └ [gregordinary/rocket-userspace](https://github.com/gregordinary/rocket-userspace) | GPL-3.0 | NPU userspace (`librocketnpu`) |
| └ [gregordinary/ggml-rocket](https://github.com/gregordinary/ggml-rocket) | GPL-3.0 | the ggml NPU backend |
| └ [gregordinary/patches](https://github.com/gregordinary/patches) (uapi header) | GPL-2.0 | `rocket_accel.h` |
| kernel `drivers/accel/rocket` (mainline) | GPL-2.0 | the driver itself |

GPL source availability for the published image is satisfied by construction:
the Dockerfile builds from **pinned public upstream sources** (exact refs in
`docs/PROVENANCE.md` and `scripts/config.env.example`) — the Dockerfile *is*
the corresponding source recipe.

Credit where due: the entire FOSS RK3588 NPU userspace/backend stack this
repo stands on is **[gregordinary](https://github.com/gregordinary)**'s work,
on top of the mainline `rocket` driver by Tomeu Vizoso / Collabora.
