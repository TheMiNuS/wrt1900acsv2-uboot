# Recovery

## Serial access

Use a **3.3 V TTL** USB-to-UART adapter at `115200 8N1` with a shared ground.
Cross TX and RX between the adapter and router. Do not connect 5 V or the
adapter power pin.

## kwboot

Power the router off, then start:

```bash
sudo ./wrt1900acsv2-uboot-full/out/kwboot-v2026.07 \
  -b ./wrt1900acsv2-uboot-full/out/u-boot-wrt1900acsv2-v7.0.0-recovery-uart-v2026.07.kwb \
  -t -B 115200 /dev/ttyUSB0
```

Power the router on and allow `kwboot` to send the image. The recovery profile
uses a RAM-only environment and cannot accidentally save it.

## Boot OpenWrt without modifying NAND

For slot 1:

```text
nand info
linksys devinfo import
linksys slot 1
linksys boot
```

For slot 2:

```text
linksys slot 2
linksys boot
```

## Restoring the bootloader

First boot `final-uart` through `kwboot`. Restore only a backup from the same
device and the same NAND region. Prefer `linksys uboot install` for a v7 KWB
image. Raw restoration of a 2 MiB dump is a last-resort operation and requires
prior bad-block analysis.

## BootROM rejects every NAND header

Repeated `Bad header at offset ...` messages mean the BootROM cannot find a
valid container. Use `kwboot`. Do not attempt additional NAND writes until the
file, SHA-256 sum, target profile, and KWB format have been verified.
