# Rescue / build-source staging area

Files in this directory are served by the two helper servers (gitignored —
stage them locally before you need them):

- `tools/fileserver/compose.yml` — HTTP on :8018 (build sources, e.g. a kernel
  tarball if the kernel.org CDN is unreachable)
- `tools/tftp/compose.yml` — TFTP on :69 (u-boot rescue; see `docs/rescue.md`)

## Stage rescue DTBs BEFORE flashing anything

If a bad device tree wedges boot, u-boot can `tftpboot` a known-good DTB and
`fatwrite` it back to the ESP — but only if you staged one. Produce both
variants from a running (or freshly-built) Talos image:

```sh
# stock DTB straight out of the sbc-rockchip overlay image
# (path inside the overlay image: artifacts/arm64/dtb/rockchip/rk3588-turing-rk1.dtb)
cp rk3588-turing-rk1.dtb tools/fileserver/data/rk1-stock.dtb

# stock + the NPU overlay from this repo (200 MHz, cores enabled)
make -C overlay            # builds rk3588-turing-rk1-npu-rocket.dtbo
fdtoverlay -i rk1-stock.dtb \
  -o tools/fileserver/data/rk1-200mhz.dtb \
  overlay/rk3588-turing-rk1-npu-rocket.dtbo
```

Then keep the TFTP server reachable from the nodes' LAN. Recovery procedure:
`docs/rescue.md`.
