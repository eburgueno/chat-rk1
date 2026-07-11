# A Talos image with the NPU enabled

Goal: your Turing RK1 node boots Talos with the mainline `rocket` DRM-accel
driver bound to the RK3588 NPU, i.e. `/dev/accel/accel0` exists. Everything in
the k8s layer builds on that one fact.

There are two levels:

| Path | NPU clock | Prefill win (Qwen2.5-3B f16, pp512) | Effort |
|---|---|---|---|
| **A — stock extension** (start here) | 200 MHz | ~1.8× vs CPU | a factory schematic; no builds |
| **B — patched module** (optional) | 600 MHz | ~2.4× vs CPU | kernel-module build, hours; sig-enforce caveats |

Path A is all most people need. Do Path A first regardless — Path B stacks on
top of it.

## Path A — stock `rockchip-rknn` extension (200 MHz)

Talos ≥ v1.13 (kernel 6.18+) carries the in-tree `rocket` driver
(`CONFIG_DRM_ACCEL_ROCKET=m`), and the official **`siderolabs/rockchip-rknn`**
system extension loads it and enables the NPU cores. No custom images to build.

1. Go to [factory.talos.dev](https://factory.talos.dev), pick your Talos
   version (≥ v1.13.4), hardware type **Single Board Computers** → overlay
   **turingrk1**, and add the **`siderolabs/rockchip-rknn`** extension to the
   schematic.
2. Install fresh from the factory image, or upgrade an existing node to the
   schematic's installer image:
   ```sh
   talosctl upgrade --nodes <node-ip> --image factory.talos.dev/installer/<schematic-id>:v1.13.4
   ```
3. Verify after boot (see also "Verify" below):
   ```sh
   talosctl -n <node-ip> get extensions        # rockchip-rknn listed
   talosctl -n <node-ip> ls /dev/accel         # accel0 present
   ```

Validated: on this project's cluster, RK1 nodes running exactly this (stock
schematic + `rockchip-rknn` v1.13.4) expose `/dev/accel/accel0` out of the box.

### If `/dev/accel` is missing: the device-tree fallback

On older sbc-rockchip overlays the base device tree leaves the
`rknn_core_0/1/2` nodes `disabled`, so the driver has nothing to bind. This
repo vendors the fix as a DT overlay — `overlay/rk3588-turing-rk1-npu-rocket.dtso`
(enables the 3 cores + MMUs, leaves clock and IOMMUs stock). To apply it you
bake it into the sbc-rockchip overlay image and build a custom installer:

1. Compile: `make -C overlay docker` → `rk3588-turing-rk1-npu-rocket.dtbo`.
2. Merge into the base DTB and repack a custom overlay image — the full
   procedure, including the `fdtoverlay` command and padding requirements, is
   in `overlay/README.md`.
3. Build an installer with the imager (`tools/imager/compose.yml` is a
   template) pointing `--overlay-image` at your repacked image, push it to a
   registry your nodes can pull from (see `talos/registry-insecure.patch.yaml`
   for a plain-HTTP LAN registry), and `talosctl upgrade` to it.

> ⚠ **Shared-ESP warning.** On the RK1 the boot DTB lives on a vfat ESP shared
> by BOTH A/B boot slots — a bad DTB bricks both at once, and GRUB on this
> board ignores serial input. **Before** flashing any DTB change, stage the
> TFTP rescue kit (`tools/fileserver/data/README.md`) and read
> [`docs/rescue.md`](rescue.md).

## Path B — patched `rocket.ko` at 600 MHz (optional, +35% prefill)

The DT default NPU compute clock is 200 MHz. Raising it to 600 MHz is worth
another ~1.35× prefill (measured; above 600 MHz gains nothing) but requires an
out-of-tree build of the `rocket` module with the clock-lever patch, delivered
as a custom system extension, plus disabling kernel module signature
enforcement.

The complete recipe — pkgs-fork build, extension packaging, the durable
`modprobe.d` clock config, and the legacy-GRUB `module.sig_enforce` tax — is
vendored in [`docker/module/README.md`](../docker/module/README.md) with all
sources under `docker/module/`.

Cost/benefit honestly: hours of one-time kernel compile (QEMU-emulated on x86),
plus on legacy-GRUB installs a `grub.cfg` edit after every Talos upgrade. Skip
it until you've seen the 200 MHz stack work end to end.

## Verify (either path)

```sh
# driver bound, device present
talosctl -n <node-ip> ls /dev/accel                        # accel0
talosctl -n <node-ip> read /proc/modules | grep rocket     # rocket ... (live)
talosctl -n <node-ip> dmesg | grep -i 'rocket\|rknn'       # "Initialized rocket ... for rknn"
                                                           # + "NPU core 0/1/2 version" lines

# NPU clock (200000000 stock; 600000000 after Path B)
talosctl -n <node-ip> read /sys/kernel/debug/clk/clk_summary | grep npu
```

> **After a cold power-on, reboot once.** A cold boot can fragment the EFI
> memory map so the CMA pool the NPU allocates from silently fails; a
> `talosctl reboot` (kexec) restores it. If NPU inference ever degrades right
> after a power cut, this is why.

Then continue with the top-level README: label the node
(`kubectl label node <node> npu.rocket-stack/enabled=true`) and deploy the
chat stack.
