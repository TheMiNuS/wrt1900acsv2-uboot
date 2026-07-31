# Concise installation guide

For the complete explanation, failure consequences, disclaimer, and recovery
information, read [FLASHING-PROCEDURE.md](FLASHING-PROCEDURE.md) first.

## Warnings

Bootloader installation is destructive. Keep serial access, `kwboot`, backups
of all critical partitions, and a stable power supply available. Do not
perform the operation remotely.

This image is only for the **Linksys WRT1900ACS v2 Rev.A00**.

## 1. Back up critical regions

From U-Boot:

```text
run backup_uboot
tftpput ${loadaddr} ${filesize} backup-uboot-2MiB.bin
run backup_uenv
tftpput ${loadaddr} ${filesize} backup-uenv.bin
run backup_senv
tftpput ${loadaddr} ${filesize} backup-senv.bin
run backup_devinfo
tftpput ${loadaddr} ${filesize} backup-devinfo.bin
```

Store the backups away from the router. Never publish `devinfo`.

## 2. Validate through UART

Boot the image with `kwboot` before writing NAND:

```bash
./wrt1900acsv2-uboot-full/out/kwboot-v2026.07 \
  -b wrt1900acsv2-uboot-full/out/u-boot-wrt1900acsv2-final-nand-v2026.07.kwb \
  -t -B 115200 /dev/ttyUSB0
```

Test both OpenWrt slots, bidirectional networking, NAND detection, switch
mapping, and every peripheral required for recovery.

## 3. Load and validate the NAND image

Copy the exact image tested with `kwboot` to the root of a FAT-formatted USB
drive, then run:

```text
usb start
load usb 0:1 ${loadaddr} /u-boot-wrt1900acsv2-final-nand-v2026.07.kwb
linksys uboot check ${loadaddr} ${filesize}
```

The check must recognize a NAND KWB v1 image with the Linksys BootROM profile,
2 KiB source alignment, a valid header checksum, and a valid payload. Stop at
any warning or error.

## 4. Install

```text
setenv allow_nand_write WRT1900ACSV2
linksys uboot install ${loadaddr} ${filesize}
```

Wait for the explicit success message:

```text
U-Boot installation and byte-for-byte verification: OK
```

The installer checks the first 2 MiB for bad blocks, erases only that region,
writes a NAND-page-aligned size, reads the data back, performs a complete
`memcmp`, and then clears the write token.

## 5. First reboot

Keep the serial terminal open. Run `reset`, verify the BootROM header,
environment, `linksys status`, `net list`, and `mdio list`, then let OpenWrt
boot. Do not modify any other partition during this first test.

## Prohibited actions

- Do not write an UART image to NAND.
- Do not replace the protected installer with a manual `nand erase` and
  `nand write` sequence.
- Do not write beyond the first 2 MiB U-Boot region.
- Do not restore `devinfo` from another device.
- Do not save the `allow_nand_write` token.
