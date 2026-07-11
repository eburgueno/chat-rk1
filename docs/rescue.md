# RK1 node rescue via u-boot + TFTP (no reflash)

For when a Turing RK1 node boot-loops or dies mid-boot after a DTB change or a
bad upgrade. This exists because of one sharp edge:

> The boot DTB lives on the **shared vfat ESP**
> (`mmcblk0p1:/dtb/rockchip/rk3588-turing-rk1.dtb`) used by **both** A/B boot
> slots — a bad DTB kills both at once. GRUB on this board does **not** accept
> serial input, so you can't pick the other slot; u-boot **does**.

All console access goes through the Turing Pi 2 BMC (`tpi` CLI).

## Stage the kit BEFORE you need it

1. Rescue DTBs in `tools/fileserver/data/` — see the README there for how to
   produce `rk1-stock.dtb` (NPU cores disabled, always boots) and
   `rk1-200mhz.dtb` (cores enabled at the safe 200 MHz default).
2. TFTP server on a LAN host the nodes can reach:
   ```sh
   docker compose -f tools/tftp/compose.yml up -d   # rootful; serves udp/69
   ```

## Diagnose first

- `tpi uart --node N get` drains the BMC's 16 KB serial ring buffer — it's
  small, so stream it in a loop *during* boot or you lose the crash point.
- Boot dying right after the rocket probe lines (`[drm] Initialized rocket …`,
  `rocket fdab0000.npu: … NPU core 0`) → NPU clock/DT issue.
- A DDR-training banner mid-boot = full SoC reset (SCMI/EL3), not a kernel
  panic — the signature of a bad NPU clock program.
- **600 MHz module wedge (no DTB change involved):** the clock lever is a
  module param, not a DT edit. Try the cheap revert first — remove the
  `rocket-patched` extension / modprobe.d config from the machine config and
  reboot to the stock 200 MHz module. Use the DTB procedure below only when
  the node won't boot far enough to take a config.

## Procedure

1. Get a u-boot prompt: `tpi power reset --node N`, then send any key during
   the 2-second "Hit any key to stop autoboot" window
   (`tpi uart --node N set --cmd "x"` in a poll loop watching for the banner;
   drain the buffer before resetting so you don't match stale output).
2. At the `=>` prompt (send lines with `tpi uart set --cmd '<line>'`, read
   with `get`):
   ```
   dhcp
   setenv serverip <tftp-server-ip>
   tftpboot ${loadaddr} rk1-200mhz.dtb
   fatwrite mmc 0:1 ${loadaddr} /dtb/rockchip/rk3588-turing-rk1.dtb ${filesize}
   reset
   ```
   Expect `Bytes transferred = 184320` from tftpboot — **abort if different**
   (the DTBs are padded to the size u-boot expects; see `overlay/README.md`).
3. The node now boots either slot (the fix is shared, like the breakage was).
4. Once up: **one `talosctl reboot`** — cold power-ons reserve no CMA for the
   NPU (see `docs/talos-image.md` "Verify").

## Escalation if u-boot/TFTP is unavailable

- `tpi advanced msd --node N` exposes the node's eMMC to the BMC as USB mass
  storage (needs BMC shell or physical access).
- Last resort: reflash (imager `metal` output + `tpi flash`). Wipes the OS —
  machine config must be re-applied; data on a separate SATA/NVMe drive
  survives.
