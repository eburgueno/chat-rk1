# Building a patched `rocket.ko` for the 600 MHz clock lever (Phase B)

**You do not need this to benchmark at the stock 200 MHz baseline.** The stock,
in-tree `rocket.ko` (`CONFIG_DRM_ACCEL_ROCKET=m`) already ships in the Talos
kernel package and is delivered/loaded by the `rockchip-rknn` system extension —
on our validated node all three NPU cores bind and `/dev/accel/accel0` is
present out of the box. Phase A (functional + 200 MHz baseline) needs no module
build at all.

This directory is for **Phase B**: a `rocket.ko` carrying `081` (clock lever) +
`083` (IOMMU keep-attach) + `084` (BO-UAF-on-close fix) so the NPU compute clock
can be raised from its 200 MHz DT default to 600 MHz (~1.43× throughput) via the
`rocket_npu_clk_hz` module parameter. Loading it and raising the clock is a
**hardware-gated** step (SCMI-reset risk — recover with the u-boot TFTP DTB-rescue
procedure, `docs/rescue.md`); on our validated node the runtime-resume clock set
was proven stable (no reset).

> **084 rebased to 6.18.34.** Upstream `084` targets v7.1-rc2, where `create_bo`
> has an sgt-fetch + `if (ret) goto err` block that 6.18.34 lacks, so its gem.c
> hunk #4 doesn't apply. The rebased copy is `patches/084-*.6.18.34.patch` (same
> intent: anchor the IOVA allocator to the refcounted IOMMU domain). It matters
> here because the UAF was reproduced with exactly our workload — the multicore
> matmul's many short-lived worker fds.

## Why the build is heavier than the runtime image

An out-of-tree module must match the running kernel's **vermagic** and — because
Talos builds with `CONFIG_MODVERSIONS=y` — its **symbol CRCs** (`Module.symvers`),
using the **same compiler** (clang/LLVM; the running kernel reports
`clang version 22.1.2, LLD 22.1.2`). Siderolabs publishes only the final
`kernel` package (vmlinuz + modules; the build tree is deleted), **not** a
kernel-headers/devel image. So the proven path rebuilds the kernel tree from
source and builds the module against it with `M=`.

## Version pins (Talos v1.13.4)

| Thing | Value |
|---|---|
| Talos | v1.13.4 |
| kernel release (vermagic) | `6.18.34-talos` |
| siderolabs/pkgs tag | `v1.13.0-28-g54ec9fc` |
| toolchain | clang/LLD 22.1.x, `ARCH=arm64 LLVM=1` |
| kernel config | `pkgs/kernel/build/config-arm64` (`CONFIG_MODVERSIONS=y`, `CONFIG_MODULE_SIG=y`) |
| kernel source | `linux-6.18.34.tar.xz` — official kernel.org CDN is live again (`https://cdn.kernel.org/pub/linux/kernel/v6.x/`, sha256 `640c4732…`). The prior effort used a github-mirror recompress (sha256 `2b6871…`) served from a local fileserver during the 2026-07 CDN outage; same source tree, different byte-stream. For a self-contained build, point the pkgs `kernel-prepare` source at the CDN URL + official sha256/sha512 (drops the local-fileserver dependency). |

Confirm the vermagic against reality before trusting a build:
`talosctl -n <node> read /proc/version` and
`talosctl -n <node> get extensions` (the `modules.dep` row VERSION == kernel release).

## Proven mechanism (siderolabs/pkgs fork + bldr)

This is the path used successfully for a different (out-of-tree BSP) module in an
earlier attempt. Adapted for rocket:

1. Fork `siderolabs/pkgs`, check out tag `v1.13.0-28-g54ec9fc`.
2. Add `pkgs/rocket-patched/pkg.yaml` (see `pkg.yaml` here) — it depends on the
   in-graph `kernel-build` stage (which leaves the built tree at `/src`:
   `.config`, generated headers, `Module.symvers`), patches the in-tree
   `drivers/accel/rocket/` sources with `081`/`083`/`084`, and builds just that
   module:
   ```sh
   make ARCH=arm64 LLVM=1 -C /src M=/src/drivers/accel/rocket modules -j"$(nproc)"
   make -C /src M=/src/drivers/accel/rocket modules_install \
        INSTALL_MOD_PATH=/rootfs/usr INSTALL_MOD_DIR=extra/rocket INSTALL_MOD_STRIP=1
   ```
3. `TARGETS += rocket-patched-pkg` in `pkgs/Makefile`; build+push:
   ```sh
   make -C pkgs rocket-patched-pkg PLATFORM=linux/arm64 \
     REGISTRY=$REGISTRY USERNAME=siderolabs TAG=v1.13.0-28-g54ec9fc PUSH=true
   ```
   The **first** build compiles the whole arm64 kernel under QEMU (hours; ~40 GB
   buildx cache) — subsequent module iterations are ~minutes off the cache.

## Delivery + autoload on Talos (all hardware-gated) — as done on our node

- Package the `.ko` in a Talos **system extension** — the recipe is vendored here
  under `extension/` (`pkg.yaml` + `manifest.yaml.tmpl` + `vars.yaml`) plus
  `modprobe.d/rocket-patched.conf`; drop it into a `siderolabs/extensions` fork as
  `drm/rocket-patched/` (the modprobe.d goes in that dir's `files/modprobe.d/`).
  It installs to
  `/rootfs/usr/lib/modules/6.18.34-talos/extra/rocket/rocket.ko` (the `extra/`
  path outranks the stock in-tree `rocket.ko` in depmod's search order, so
  `modprobe rocket` picks the patched one — this **replaces `rockchip-rknn`** in
  the schematic). It also ships the durable clock config (next point). Bake it into
  a local installer with imager (stock `sbc-rockchip:v0.2.0` turingrk1 overlay so
  the **DTB is unchanged**), fresh `-rN` tag, `talosctl upgrade`.
- **Durable clock param — via modprobe.d, NOT `kernel.modules`.** A machineconfig
  `machine.kernel.modules` parameter does **not** stick: udev coldplug loads the
  NPU module param-less before Talos's module controller runs, even across
  reboots. The mechanism that works is a `modprobe.d` drop-in the extension ships
  at `/usr/local/lib/modprobe.d/rocket-patched.conf` (see `modprobe.d/` here):
  ```
  options rocket rocket_npu_clk_hz=600000000
  ```
  modprobe applies this at every load (coldplug included), so `rocket_npu_clk_hz`
  is 600000000 at boot, persistently. Verified: after a clean reboot the param
  reads 600000000 with no manual write, and `scmi_clk_npu` rises to 600 MHz on the
  first NPU job. Override live with
  `echo <hz> > /sys/module/rocket/parameters/rocket_npu_clk_hz` (reverts on
  reboot), or a higher-priority `/etc/modprobe.d` drop-in.
- **Signature enforcement — the legacy-GRUB tax.** Talos boots with
  `module.sig_enforce=1`; an out-of-tree module can't satisfy it. Imager's
  `--extra-kernel-arg=-module.sig_enforce` only affects UKI/sd-boot installs. Our
  node is a **legacy-GRUB** install, where the upgrade regenerates `grub.cfg` with
  `sig_enforce=1` **every time** — so after each upgrade you must edit `grub.cfg`
  on the BOOT partition (`/dev/mmcblk0p3`) replacing `module.sig_enforce=1`→`=0`
  and reboot (privileged pod, `sed -i`; keep a backup). Two reboots per module
  change. (A UKI/sd-boot reinstall would remove this tax — out of scope.)
- **Do not ship the patched module under the name `rocket`** if the stock module
  is still delivered by `rockchip-rknn` — either blacklist the stock one or build
  the extension to replace it, so only one `rocket.ko` is a load candidate.

## The 200 MHz vs 600 MHz A/B

1. Baseline: stock module (already loaded), `CLK_LABEL=200MHz`, run the bench Job.
2. Raise: apply the machineconfig patch above → `scmi_clk_npu` should read
   600 MHz (`talosctl read /sys/kernel/debug/clk/clk_summary | grep npu`); confirm
   `/sys/module/rocket/parameters/rocket_npu_clk_hz` == 600000000. Re-run the Job
   with `CLK_LABEL=600MHz` and a new `LABEL`. The two `*.merged.json` are directly
   comparable.
3. The open experiment: whether the 081 runtime-resume `clk_set_rate` avoids the
   SCMI/EL3 reset our prior cold sets hit (domain-powered hypothesis). If it
   wedges, recover via the u-boot TFTP DTB-rescue procedure.
