---
name: npu-rescue
description: Recover an RK1 node that boot-loops or dies mid-boot (e.g. after a bad DTB) using the BMC serial console, u-boot, and the TFTP rescue kit. Use when a Talos RK1 node won't come up after an upgrade or DTB change.
---

# RK1 node rescue via u-boot + TFTP (no reflash)

Context: the boot DTB lives on the SHARED vfat ESP (`mmcblk0p1:
/dtb/rockchip/rk3588-turing-rk1.dtb`) — a bad DTB kills BOTH A/B slots.
GRUB does NOT accept serial input on this board; u-boot DOES.

## Diagnose first

- `tpi uart --node N get` — drains the 16 KB ring buffer (small! stream it
  in a loop during boot or you lose the crash point).
- Boot dying shortly after the `rocket`/`rknn` core probe (`[drm] Initialized
  rocket ... for rknn`, `rocket fdab0000.npu: ... NPU core 0`) = an NPU clock/DT
  issue. DDR training banner = full SoC reset (SCMI/EL3), not a kernel panic —
  the signature of a bad NPU clock program.
- **Phase-B clock-raise wedge (no DTB change):** the 600 MHz lever is a MODULE
  PARAM (`rocket_npu_clk_hz`) set from runtime-resume, delivered via the
  `rocket-patched` extension's modprobe.d — it does NOT touch the DTB. If a
  raise hangs the box, first try the cheap revert: `talosctl upgrade` back to
  an installer without the `rocket-patched` extension (stock 200 MHz module),
  or live-write 200000000 to `/sys/module/rocket/parameters/rocket_npu_clk_hz`
  if the node still boots. Fall back to the TFTP DTB procedure below only if
  the node won't boot far enough.

## Rescue kit (pre-staged)

- TFTP server: `docker compose -f tools/tftp/compose.yml up -d`
  (rootful docker, host network, serves `tools/fileserver/data/` on udp/69)
- `rk1-200mhz.dtb` — known-good DTB: 3 mainline `rknn-core`s + IOMMUs enabled at
  the safe 200 MHz DT default (the rocket baseline; matches
  `overlay/rk3588-turing-rk1-npu-rocket.dtso`).
- `rk1-stock.dtb` — untouched upstream overlay DTB (boots; NPU cores stay
  `disabled`, driver idle).

## Procedure

1. Get a u-boot prompt: `tpi power reset --node N`, then send any key
   during the 2 s "Hit any key to stop autoboot" window
   (`tpi uart --node N set --cmd "x"` in a poll loop watching for the
   banner; drain the buffer BEFORE resetting so you don't match stale
   output).
2. At the `=>` prompt (via `tpi uart set --cmd '<line>'`, read with `get`):

   ```
   dhcp
   setenv serverip <tftp-server-ip>
   tftpboot ${loadaddr} rk1-200mhz.dtb
   fatwrite mmc 0:1 ${loadaddr} /dtb/rockchip/rk3588-turing-rk1.dtb ${filesize}
   reset
   ```

   Expect `Bytes transferred = 184320` from tftpboot — abort if different.
3. Node boots either slot fine (the fix is shared, like the breakage).
4. **After the node is up: one `talosctl reboot`** (cold boots reserve no
   CMA — see npu-deploy skill).

## Escalation if u-boot/TFTP unavailable

- `tpi advanced msd --node N` exposes the node's eMMC to the BMC as USB
  storage (needs BMC shell or physical access to use).
- Reflash (imager 'metal' output + `tpi flash`) is last resort: wipes the
  OS (machine config must be re-applied); LVM data on the SATA drive
  survives.
