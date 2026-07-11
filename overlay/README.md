# RK3588 NPU device-tree overlay

`rk3588-turing-rk1-npu-rocket.dtso` enables what the mainline `rocket` driver
needs on Turing RK1, which the stock 6.18 device tree leaves off:

- `rknn_core_0/1/2` + `rknn_mmu_0/1/2` — `status = "okay"` (base DT has them
  `disabled`). This is what makes the three NPU cores bind.
- `npu-supply = <&vdd_npu_s0>` on each core — only needed for a future >600 MHz
  bring-up (the 082 voltage patch); harmless otherwise.

It deliberately leaves the compute clock at the DT default (200 MHz) and the
IOMMUs enabled — see the header comment in the `.dtso` for the full rationale.

## Build

```sh
make                # needs dtc on PATH
make docker         # compile in a container if no host dtc
make verify         # fdtdump the result
```

Produces `rk3588-turing-rk1-npu-rocket.dtbo` (gitignored; a build output). `-@`
emits a `__symbols__` node so the `&rknn_core_*` targets resolve against the base
DT at apply time.

## Deployed state (validated node)

**This overlay is already applied on the validated node.** `dmesg` shows all
three cores probing and binding to `rocket`:

```
platform fdab0000.npu: Adding to iommu group 7
platform fdac0000.npu: Adding to iommu group 8
platform fdad0000.npu: Adding to iommu group 9
[drm] Initialized rocket 0.0.0 for rknn on minor 0
rocket fdab0000.npu: Rockchip NPU core 0 version: 1179210309   (cores 1,2 likewise)
```

and `scmi_clk_npu` reads 200 MHz, shared by `npu@fdab/fdac/fdad0000`. So the
`.dtso` here is the reproducible source-of-truth for the DT state that is live on
the node.

## Injection mechanism on Talos (how to reproduce / extend to other nodes)

On Talos the boot DTB is supplied by the **sbc-rockchip overlay image**, not the
kernel package. The proven mechanism is to bake the change into that DTB rather
than apply an overlay at runtime:

1. Compile this `.dtso` → `.dtbo` (above).
2. Extract the base `rk3588-turing-rk1.dtb` from the stock sbc-rockchip overlay
   image and merge the overlay:
   ```sh
   fdtoverlay -i rk3588-turing-rk1.dtb -o rk3588-turing-rk1-npu.dtb \
     rk3588-turing-rk1-npu-rocket.dtbo
   ```
   (Equivalently, decompile + edit + recompile **with padding** `dtc -S 184320`
   so u-boot has fixup space — the size the rescue kit expects,
   `Bytes transferred = 184320`.)
3. Repack into a custom overlay image (`FROM <sbc-rockchip> / COPY the new .dtb`)
   and point Talos `imager --overlay-image` at it; upgrade the node with
   `talosctl upgrade --image <bare-tag>` (bump the tag every rebuild — nodes
   cache installer tags; never pass `tag@digest`).

### ⚠ Shared-ESP pitfall — this is why DTB apply is hardware-gated

The installer writes the DTB to the **shared vfat ESP**
(`mmcblk0p1:/dtb/rockchip/rk3588-turing-rk1.dtb`) used by **both** A/B slots, so a
bad DTB bricks both slots at once, and GRUB on this board ignores serial input —
you cannot pick the other slot remotely. u-boot *does* take serial input;
recovery is the pre-staged u-boot TFTP DTB-rescue kit:
```
dhcp; setenv serverip <fileserver>; tftpboot ${loadaddr} rk1-200mhz.dtb
fatwrite mmc 0:1 ${loadaddr} /dtb/rockchip/rk3588-turing-rk1.dtb ${filesize}; reset
```
Also: cold power-on fragments the EFI memmap so `cma=2G` can silently fail —
follow a cold boot with one `talosctl reboot` (kexec).
