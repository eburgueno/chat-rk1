---
name: npu-deploy
description: Runbook for the mainline `rocket` NPU stack on RK1 nodes — the rockchip-rknn Talos extension + rocket DT overlay (baseline), the aarch64 runtime image + benchmark, and the Phase-B patched rocket.ko (600 MHz clock lever). Use when rebuilding the runtime image, (re)deploying the extension/overlay to a node, extending to another RK1, building the patched module, or when NPU inference breaks after an upgrade or power cycle.
---

# NPU deploy/upgrade runbook — mainline `rocket` (Turing Pi RK1 / Talos)

State & history: `docs/PROVENANCE.md` (sources, pins, on-device validation),
`README.md` (deploy end-to-end), `docs/talos-image.md` (OS-layer guide). This
runbook is the mainline **`rocket`** path (DRM-accel); the earlier BSP-`rknpu`
approach is dead and not vendored here.

## The stack (baseline → benchmark → optional clock lever)

**Baseline (already on the RK1 — the given starting point):** the node boots a
Talos image carrying the **`rockchip-rknn` system extension** (delivers/autoloads
the stock in-tree `rocket.ko`; `CONFIG_DRM_ACCEL_ROCKET=m`) plus a DT overlay that
enables the three mainline `rockchip,rk3588-rknn-core` cores + their IOMMUs. Net
effect: all 3 cores bind, `/dev/accel/accel0` is present, `scmi_clk_npu` = 200 MHz
(DT default; unpatched driver has no clock knob). The overlay source of truth is
`overlay/rk3588-turing-rk1-npu-rocket.dtso` (compile: `make -C overlay docker`;
injection mechanism + shared-ESP pitfall: `overlay/README.md`). You normally do
NOT rebuild this — it's the baseline. Rebuild only to restore it, or to extend to
another RK1.

**Runtime image + benchmark (per-run):**
1. `scripts/00-infra.sh` — binfmt + local registry + buildx (idempotent).
2. `scripts/10-build-runtime.sh` — build+push the aarch64 `rocket-runtime` image
   (llama.cpp shared+`GGML_BACKEND_DL` + rocket-userspace + ggml-rocket). Validate
   off-hardware with `scripts/20-smoke-local.sh`.
3. Node needs to pull the plain-HTTP image: apply
   `talos/registry-insecure.patch.yaml` (machineconfig, no reboot) if not already.
4. Label the NPU node `npu.rocket-stack/enabled=true`; deploy the chat stack
   (`kubectl apply -k kustomize/overlays/<site>/` or `kubectl apply -f k8s/`,
   namespace `chat-rk1`, PSS=privileged for the `/dev/accel` hostPath). CPU vs
   NPU = whether `GGML_BACKEND_PATH` loads the rocket backend (ConfigMap
   `llama-server-config`). Optional bench Job: `k8s/80+90`; results land on the
   model-cache PVC under `/models/results/`.

**Phase B — the 600 MHz clock lever (optional, gated):** a patched `rocket.ko`
(081 clock / 083 IOMMU-keepattach / 084 BO-UAF) delivered via the
`rocket-patched` system extension, with the durable clock set via the
extension's `modprobe.d` `options rocket rocket_npu_clk_hz=600000000`
(machineconfig `kernel.modules` params do NOT stick — udev coldplug loads the
module first). Build recipe + pins + gotchas: `docker/module/README.md` +
`docker/module/pkg.yaml`. First build compiles the whole arm64 kernel under
QEMU (hours; siderolabs ships no kernel-devel image) — one-time, then module
rebuilds are minutes.

## (Re)deploy the extension/overlay (only to restore/extend — the pkgs+imager cycle)

Order matters:
1. Build the extension (rocket module already in-tree, so an extension is only
   needed if shipping a **patched** module — see Phase B) → note the image digest.
2. `docker compose -f tools/imager/compose.yml run --rm imager` to assemble the
   installer, bumping the extension digest + overlay tag. For a patched module,
   add `--extra-kernel-arg=-module.sig_enforce` (out-of-tree modules can't satisfy
   sig-enforce).
3. `podman load` the installer tar → tag with a **FRESH** `-rN` tag (nodes cache
   installer tags) → `podman push --tls-verify=false`.
4. `talosctl -n <node> upgrade --image <repo@digest>` (bare tag or `repo@digest`,
   never `tag@digest`).
5. On **legacy-GRUB** installs only: the installer resets GRUB kernel args and
   rewrites the shared-ESP DTB every upgrade — re-apply args (drop
   `module.sig_enforce=1`, set `cma=2G`) with a one-off privileged pod that
   mounts the BOOT partition and edits `grub.cfg` in place (see
   `docker/module/README.md` "signature enforcement"). UKI/sd-boot installs
   honor imager kernel args directly.
6. `talosctl reboot` (kexec).

## Verify

- `talosctl -n <node> list /dev/accel` → `accel0` present.
- `talosctl -n <node> dmesg | grep -i rocket` → 3 cores
  (`fdab/fdac/fdad0000.npu`) bound; `[drm] Initialized rocket ... for rknn`.
- `talosctl -n <node> read /sys/kernel/debug/clk/clk_summary | grep npu` →
  `scmi_clk_npu` rate (200 MHz stock; 600 MHz after Phase B).
- Phase B only: `/sys/module/rocket/parameters/rocket_npu_clk_hz` exists and reads
  the target (absent ⇒ stock/unpatched module).
- Inference: `kubectl -n chat-rk1 logs job/rocket-bench` — the `bench.sh`
  summary (CPU vs NPU pp/tg t/s). Interactive/server path:
  `scripts/ttft-check.sh` against llama-server (TTFT A/B).

## ⚠️ DO NOT (hard-won on real hardware)

- **Never raise the NPU clock via DTB `assigned-clock-rates`.** That programs the
  rate COLD (power domain off), which wedges the SoC's SCMI/EL3 firmware — and
  because the DTB lives on the SHARED vfat ESP (not per-A/B-slot), a bad one
  bricks BOTH boot slots. The safe lever is the `081` patch's `rocket_npu_clk_hz`
  module param, which sets the rate from `runtime_resume` with the domain already
  powered, and parks back at 200 MHz on idle. (Proven on hardware 2026-07-11:
  200→600 MHz with no SCMI reset — see `docs/PROVENANCE.md`.)
- **Never trust A/B slots to protect DTB changes** (shared ESP); GRUB ignores
  serial input on this board — recovery is the `npu-rescue` skill.
- **Cold power-on loses CMA** (EFI memmap fragmentation → `cma=2G` fails → large
  models can't load). Follow a cold boot with one `talosctl reboot`.
- `module.sig_enforce` is `bool_enable_only` — the arg must be REMOVED, not set to 0.
- Don't ship a patched module under the name `rocket` while `rockchip-rknn` still
  delivers the stock one — blacklist the stock one or replace it, so only one
  `rocket.ko` is a load candidate.
