# Provenance — RK3588 NPU LLM inference on Talos via the mainline `rocket` driver

Where every piece of the NPU stack comes from: upstream sources, exact pins,
and the on-hardware validation record behind the numbers in `results/`. The
NPU enablement (runtime image, DT overlay, patched module, benchmark harness)
was developed and validated in a research effort this repo packages; the
findings and pins below are carried over verbatim.

## Why this path (vs the earlier BSP-rknpu effort)

An earlier attempt built the out-of-tree BSP `rknpu`/`rknn` driver and concluded
NPU-for-LLM was closed. This path is different:
it uses the **mainline `rocket` DRM-accel driver** + gregordinary's FOSS userspace,
which sidesteps the three walls that effort hit — the driver is already in-kernel,
cores stay separate (multi-fd, no DTB repack), and the clock is a runtime lever,
not a firmware fight. It also targets **prefill/TTFT** (the NPU's real strength),
which the earlier decode-only benchmarks never isolated.

## Upstream sources (public repos)

| Source | Role | License |
|---|---|---|
| gregordinary/rockchip-npu-notes | RE notes / benchmarks (reference) | CC-BY-4.0 |
| gregordinary/rocket-userspace | userspace matmul/op lib (`librocketnpu`) | GPL-3.0 |
| gregordinary/ggml-rocket | ggml backend `.so` (llama.cpp + whisper.cpp) | GPL-3.0 |
| gregordinary/tflite-rocket | TFLite delegate (vision; optional) | GPL-3.0 |
| gregordinary/patches (rocket/) | out-of-tree driver patches 081–086 | GPL-2.0 |
| kernel 6.18 `drivers/accel/rocket` | the driver (mainline, in siderolabs pkgs) | GPL-2.0 |

## Validation done off-hardware (2026-07-10)

- **Driver in-kernel:** `drivers/accel/rocket` present at kernel v6.18 (absent
  v6.16/6.17). `CONFIG_DRM_ACCEL_ROCKET=m` already set in stock siderolabs/pkgs
  and our pkgs fork → no kernel-config PR needed.
- **Patches rebase clean to 6.18:** 081 (clock) 3/3 hunks, 082 (voltage, after
  081) 5/5 hunks, against torvalds v6.18 `rocket_{core.c,core.h,drv.c}`. No manual
  rebase required.
- **DT wiring present:** each `rknn_core_*` node has `clock-names` incl. `"npu"` =
  `<&scmi_clk SCMI_CLK_NPU>`, so 081's `devm_clk_get_optional(dev,"npu")` engages.
  Cores + IOMMUs are `status="disabled"` in rk3588-base.dtsi; `vdd_npu_s0` exists
  in the board DT but isn't wired as `npu-supply`. → `overlay/*.dtso` closes both.

## Platform baseline (GIVEN — the RK1's starting state, not our deliverables)

The target node boots with the `rockchip-rknn` system extension already in the
Talos image, which is what gives us the working NPU platform:

- **Stock in-tree `rocket.ko`** (`CONFIG_DRM_ACCEL_ROCKET=m`) — shipped in the
  Talos kernel package and delivered/autoloaded by the extension.
- **DT overlay** enabling the 3 mainline `rknn-core`s + IOMMUs at 200 MHz. Source
  of truth kept for reference / restore / other-node rollout:
  `overlay/rk3588-turing-rk1-npu-rocket.dtso` (compiles clean, DTC 1.7.2, 6
  fragments; `overlay/Makefile`; injection mechanism in `overlay/README.md`).
- Patches `081`/`082` rebase clean to 6.18; the 6.18 DT wires the `"npu"` SCMI
  clock the 081 lever hooks. (081 not yet applied — that's Phase B.)

## Components (status)

- [x] **Runtime container** (aarch64) — `docker/runtime/Dockerfile`: rocket-userspace
      → ggml-rocket → llama.cpp (shared + `GGML_BACKEND_DL`); `rocket_accel.h`
      installed from the pinned patches repo; `/dev/accel` mounted at run time.
- [x] **Manifests** — `k8s/` Job exposes `/dev/accel` (hostPath), pins the NPU node
      by label, model-cache PVC on local SSD (`csi-driver-lvm-linear`), `chat-rk1`
       ns (PSS=privileged). Plus `talos/registry-insecure.patch.yaml` so containerd
      pulls the local image. Device-plugin alternative documented.
- [x] **Phase A — deploy + benchmark @200 MHz** — DONE. Prefill NPU beats CPU
      1.84×/1.59× (pp512/pp2048), decode ties. See `results/`.
- [x] **Phase B — patched `rocket.ko` + 600 MHz** — DONE. Built 081+083+084 (084
      rebased to 6.18.34), delivered via the `rocket-patched` extension + a
      locally-baked installer (`-module.sig_enforce`), loaded after a legacy-GRUB
      grub.cfg `sig_enforce=0` edit. Clock raised 200→600 MHz via the 081 lever;
      **no SCMI reset**. Prefill 2.42× (pp512) / 1.97× (pp2048) NPU-over-CPU
      @600 MHz. See `results/rk1-600mhz.*`. **600 MHz is durable across reboots**
      via an extension modprobe.d `options` line (`kernel.modules` params don't
      stick — coldplug load-order); see `docker/module/README.md`.

## Open hardware questions

1. Does the 081 runtime-resume `clk_set_rate(npu, 600M)` avoid the SCMI/EL3
   SoC-reset our cold sets triggered? → **ANSWERED (2026-07-11): YES.** On the
   patched module, the first NPU job raised `scmi_clk_npu` 200→600 MHz and parked
   it back at 200 on idle; the node stayed up (no reset). Domain-powered
   runtime-resume set avoids the fault — the prior effort's cold/domain-off sets
   were the cause.
2. At 200 MHz, is prefill a net CPU win? → **ANSWERED (2026-07-10): NO — the NPU
   wins.** Qwen2.5-3B F16, warm: prefill pp512 1.84× / pp2048 1.59× NPU-over-CPU;
   decode ties (1.0×). See `results/`.

## Validation log — 2026-07-10 (on-device, read-only baseline confirmation)

Confirmed the given baseline via `talosctl` (read-only): kernel `6.18.34-talos`
(`clang 22.1.2, LLD 22.1.2`). `rocket.ko` Live; `dmesg` shows
`fdab/fdac/fdad0000.npu` → IOMMU groups 7/8/9,
`[drm] Initialized rocket 0.0.0 for rknn on minor 0`, each core
`version: 1179210309`; `/dev/accel/accel0` present. `scmi_clk_npu` = 200 MHz
shared by all three cores. `/sys/module/rocket/parameters` absent ⇒ stock
(unpatched) module. Extensions: `rockchip-rknn` v1.13.4, `modules.dep` VERSION
`6.18.34-talos`.

## Upstream source pins (for the reproducible build)

| Source | Ref | Note |
|---|---|---|
| gregordinary/rocket-userspace | `e7bf520f16119556a6bbfffbb3859acf0cb15750` | Initial public release |
| gregordinary/ggml-rocket | `b3c7af2ec46ef4b46c06ee38d72734f6be46eee2` | targets GGML_BACKEND_API_VERSION 2 / ggml v0.14.0 |
| gregordinary/patches | `a402fd101afad8bb1d5cfe2e99fc78e2bd35b940` | rocket 081–086 + uapi header |
| ggml-org/llama.cpp | `ee445f93d8a0a5033a46d1960e901ef5caec9a41` | 2026-07-06; vendors ggml v0.14.0 (ABI match) |
| siderolabs/pkgs (kernel) | `v1.13.0-28-g54ec9fc` | Talos v1.13.4 → kernel 6.18.34 |
