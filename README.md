# U-Boot v7 for Linksys WRT1900ACS v2 Rev.A00

A reproducible community port of **Das U-Boot v2026.07** for the
**Linksys WRT1900ACS v2, hardware revision Rev.A00**, code name **Shelby**.

> [!CAUTION]
> This project applies exclusively to the **WRT1900ACS v2 Rev.A00**.
> Do not use it on the WRT1900AC v2 (Cobra), WRT1900ACS v1, WRT1200AC,
> WRT3200ACM, WRT32X, or any other model or hardware revision.
>
> Installing an incompatible bootloader may leave the router unable to boot
> without serial access and BootROM recovery.

## Why this project exists

Like many useful projects, this one began with a questionable decision:
I erased the original U-Boot from my router without making a backup first.

In my defence, it seemed like a perfectly reasonable idea at the time.

I initially tried several U-Boot dumps shared by members of the OpenWrt
community. Unfortunately, every image I tested ended in an infinite boot loop
with the following error:

```text
NAND: mvNfcInit() failed
```

Further hardware investigation showed that these images did not support the
NAND flash fitted to my particular WRT1900ACS v2 Rev.A00 (W29N01HVSINF).

I also considered rebuilding the original Linksys U-Boot release. However, its
toolchain and dependencies are now sufficiently old that reproducing the
original build environment would have required installing a small software
museum on my workstation. As I am not particularly fan of outdated and
unsupported software, I decided to take a different approach.

The goal became to build a modern, reproducible U-Boot port based on the
current upstream codebase, while preserving the Linksys dual-firmware layout,
factory data, recovery capabilities, and full OpenWrt compatibility.

This project was developed through an extended collaboration with ChatGPT,
combined with repeated source-code reviews, hardware tests, serial-console
diagnostics, and more than a few iterations where the router strongly
disagreed with our assumptions.

The resulting implementation is based on upstream **U-Boot v2026.07** and has
been validated on real hardware.

Although the WRT1900ACS is no longer a recent device, it remains a capable and
well-built router. I hope this project helps other owners recover damaged
bootloaders, reproduce a working firmware environment, or experiment with
features available in newer U-Boot releases.

## Validation status

Version 7.0.0 preserves the hardware-tested functional path:

- boot from NAND through the Armada 38x BootROM;
- initialization of 512 MiB DDR3;
- detection of the 128 MiB Winbond W29N01HV NAND with 2 KiB pages;
- reading the U-Boot environment and the `devinfo` partition;
- booting OpenWrt from the Linksys dual-firmware layout;
- working Marvell 88E6176 switch, DSA, and LAN networking under OpenWrt;
- CPU connection mapped as **GE0 / RGMII-ID / switch port 6**;
- protected U-Boot installation with KWB validation, a one-boot write
  interlock, and complete post-write verification.

USB, eSATA/SATA, MMC, I2C, buttons, TFTP, and automatic A/B fallback are
compiled and have documented test procedures. They must still be validated
on each target device before publishing a binary as fully tested. See
[docs/VALIDATION.md](docs/VALIDATION.md).

## Network mapping

| Component | Connection |
|---|---|
| SoC Ethernet master | `ethernet@70000`, GE0 |
| CPU link mode | RGMII-ID, 1 Gbit/s, full duplex |
| MV88E6176 CPU port | port 6 |
| Switch port 0 | LAN4 |
| Switch port 1 | LAN3 |
| Switch port 2 | LAN2 |
| Switch port 3 | LAN1 |
| Switch port 4 | WAN |
| GE2 / `ethernet@34000` | disabled in the U-Boot Device Tree |

The DSA handoff and MAC-address behavior are described in
[docs/NETWORK-MAPPING.md](docs/NETWORK-MAPPING.md).

## Repository contents

- `build.sh`: downloads the pinned U-Boot source, applies the board port, and
  builds all profiles;
- `board/`: board code and default environment;
- `patches/`: minimal MDIO fix applied to the pinned upstream commit;
- `scripts/`: KWB conversion, repository validation, and release packaging;
- `openwrt/`: sample `fw_env.config` and an upgrade-confirmation service;
- `tests/`: host-side checks and hardware diagnostic procedures;
- `docs/`: build, installation, recovery, validation, and command reference.

The repository does not redistribute Linksys firmware, `devinfo` contents,
MAC addresses, serial numbers, Wi-Fi calibration data, or any other
per-device data.

## Debian/Ubuntu prerequisites

```bash
sudo apt update
sudo apt install -y \
  git make gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
  bc bison flex libssl-dev libgnutls28-dev pkg-config \
  device-tree-compiler python3 python3-setuptools python3-pyelftools \
  swig u-boot-tools zip
```

U-Boot is cross-compiled through `CROSS_COMPILE`. The build script defaults to
`arm-linux-gnueabi-` and uses an out-of-tree build directory.

## Static validation

```bash
make validate
```

This command checks, among other items:

- Bash, POSIX shell, and Python syntax;
- absence of obsolete development-history files;
- the `wrt1900acsv2-v7.0.0` environment schema;
- the GE0/RGMII-ID/port-6 mapping;
- A/B boot and DSA handoff settings;
- the KWB converter using a synthetic image and payload-integrity check;
- absence of French text in project documentation, comments, and user-facing
  messages, except third-party license text or unavoidable proper names.

## Build

```bash
make build
```

The script downloads exactly:

- U-Boot tag: `v2026.07`;
- commit: `ece349ade2973e220f524ce59e59711cc919263f`.

Generated files are placed in `wrt1900acsv2-uboot-full/out/`:

| Profile | Purpose |
|---|---|
| `recovery-uart` | BootROM recovery through `kwboot`, volatile environment |
| `final-uart` | Validation of final code through `kwboot`, NAND environment |
| `final-nand` | NAND BootROM image, install only after UART validation |

The output also includes `.config` files, SHA-256 sums, build metadata, and the
exact diff applied to the upstream U-Boot source.

Optional variables:

```bash
JOBS=8 CROSS_COMPILE=arm-linux-gnueabi- WORKDIR="$PWD/work" make build
```

## Mandatory deployment order

1. Back up `u-boot`, `u_env`, `s_env`, and `devinfo`.
2. Test `recovery-uart` with `kwboot`.
3. Test `final-uart` with `kwboot` without writing NAND.
4. Boot both OpenWrt slots and validate networking.
5. Complete the non-destructive validation checklist.
6. Load `final-nand` and run `linksys uboot check`.
7. Unlock writes for the current boot only and run `linksys uboot install`.
8. Never install the `final-uart` image into NAND.

The full procedure is in
[docs/FLASHING-PROCEDURE.md](docs/FLASHING-PROCEDURE.md).

## Booting `final-uart` with kwboot

```bash
sudo wrt1900acsv2-uboot-full/out/kwboot-v2026.07 \
  -b wrt1900acsv2-uboot-full/out/u-boot-wrt1900acsv2-v7.0.0-final-uart-v2026.07.kwb \
  -t -B 115200 /dev/ttyUSB0
```

The serial port uses **3.3 V TTL**, `115200 8N1`. Never use an RS-232 adapter
or 5 V logic levels.

## Protected NAND installation

After fully validating `final-uart`, copy the `final-nand` image to the root
of a FAT-formatted USB drive and run each command separately:

```text
usb start
load usb 0:1 ${loadaddr} /u-boot-wrt1900acsv2-v7.0.0-final-nand-v2026.07.kwb
linksys uboot check ${loadaddr} ${filesize}
setenv allow_nand_write WRT1900ACSV2
linksys uboot install ${loadaddr} ${filesize}
```

The installer rejects an incompatible NAND geometry, invalid KWB header,
oversized image, or bad block in the U-Boot region. It erases only the first
2 MiB, writes the image, reads the complete written region back, and compares
every byte before reporting success.

## OpenWrt integration

The `openwrt/` directory provides:

- a sample `/etc/fw_env.config` for `uboot-envtools`;
- an `uboot-mark-good` service that confirms a new slot only when
  `upgrade_available=1`, using a single `fw_setenv -s` transaction.

See [docs/OPENWRT.md](docs/OPENWRT.md).

## Documentation

- [Reproducible build](docs/BUILD.md)
- [Complete flashing procedure](docs/FLASHING-PROCEDURE.md)
- [Concise installation guide](docs/INSTALLATION.md)
- [Network and switch mapping](docs/NETWORK-MAPPING.md)
- [Command reference](docs/COMMANDS.md)
- [Recovery](docs/RECOVERY.md)
- [OpenWrt integration](docs/OPENWRT.md)

## Publishing a release

```bash
make release
```

Source archives and `SHA256SUMS` are written to `dist/`. U-Boot binaries
should be published separately with their SHA-256 sums and a build log that
identifies the compiler, U-Boot tag, and pinned commit.

## References

- Das U-Boot — building with GCC:
  https://docs.u-boot.org/en/stable/build/gcc.html
- Das U-Boot — release cycle:
  https://docs.u-boot.org/en/stable/develop/release_cycle.html
- U-Boot v2026.07 source:
  https://github.com/u-boot/u-boot/tree/v2026.07
- OpenWrt — Linksys WRT1900ACS:
  https://openwrt.org/toh/linksys/wrt1900acs

## License

This repository is distributed under **GPL-2.0-or-later**. Das U-Boot and
imported upstream files retain their respective licenses and copyrights. See
`LICENSE`, `LICENSES/`, and `NOTICE`.
