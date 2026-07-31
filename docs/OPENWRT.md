# OpenWrt integration

## Environment tools

Install `uboot-envtools`, then copy the sample configuration:

```sh
opkg update
opkg install uboot-envtools
cp /tmp/fw_env.config.example /etc/fw_env.config
fw_printenv boot_part upgrade_available bootcount boot_part_ready
```

The supplied configuration targets `/dev/mtd1`, using a 128 KiB environment
inside a 256 KiB erase range. Verify the local MTD names before copying it.

## Confirming a new slot

Install the service:

```sh
install -m 0755 /tmp/uboot-mark-good /etc/init.d/uboot-mark-good
/etc/init.d/uboot-mark-good enable
/etc/init.d/uboot-mark-good start
```

The service does nothing during a normal boot. When `upgrade_available=1`, it
writes the following values in one transaction:

```text
upgrade_available=0
bootcount=0
boot_part_ready=3
```

The condition prevents a NAND environment write on every boot.

## Network diagnostics

`tests/openwrt-network-check.sh` is compatible with the minimal BusyBox `ip`
implementation. It does not use `ip -br`, `bridge`, or `ip -s`.

Run it on the router with the peer PC address:

```sh
sh /tmp/openwrt-network-check.sh 192.168.1.100
```

Run a capture on the PC at the same time:

```bash
sudo tcpdump -eni INTERFACE 'arp or icmp'
```
