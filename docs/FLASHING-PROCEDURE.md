# Testing with `kwboot` and installing U-Boot into NAND

This procedure describes the recommended method to test and then install this
U-Boot firmware on a **Linksys WRT1900ACS v2 Rev.A00 only**.

It covers two separate operations:

1. temporarily booting the image with `kwboot`, without modifying NAND;
2. permanently installing the image into the NAND U-Boot region.

> [!CAUTION]
> **Do not use this image on another model or hardware revision.** It is built
> exclusively for the **Linksys WRT1900ACS v2 Rev.A00**. The WRT1900AC,
> WRT1900ACS v1, WRT1200AC, WRT3200ACM, WRT32X, and other variants are not
> compatible.

---

## Disclaimer and no warranty

Replacing a bootloader is a high-risk operation. A wrong file, power loss,
incorrect command, unsuitable serial adapter, damaged NAND, or interruption
while erasing or writing may prevent the router from booting from NAND.

This project is provided **without warranty**, either express or implied. The
author, contributors, maintainers, and distributors do not guarantee that the
software will work on every device, every NAND condition, or every build
environment.

To the maximum extent permitted by applicable law, the user assumes all risks
related to building, testing, installing, and using this firmware, including:

- loss of configuration or data;
- temporary or permanent loss of connectivity;
- corruption of the bootloader or another NAND region;
- the need for BootROM serial recovery;
- loss of use of the router;
- hardware damage caused by incorrect wiring or voltage levels;
- any direct, indirect, incidental, or consequential loss.

The existence of a `kwboot` recovery path reduces the chance of a permanent
failure, but **does not guarantee recovery**. By continuing, the user confirms
that the risks and consequences are understood and accepts sole responsibility
for the operation.

---

## How the process works

The WRT1900ACS v2 contains a Marvell BootROM that can receive a KWB image over
the serial port. `kwboot` performs the BootROM handshake, transfers the image,
and then opens a serial terminal.

During a `kwboot` test:

- the image is sent temporarily through UART;
- it runs from RAM without replacing the bootloader stored in NAND;
- the image file on the PC is not modified;
- after a power cycle without `kwboot`, the router attempts to boot the
  bootloader currently stored in NAND.

This makes it possible to validate a new U-Boot image **before** accepting the
risk of a permanent NAND write.

NAND installation is a different operation. `linksys uboot install` erases and
rewrites the protected U-Boot region. Once erasing begins, a power failure or
reset may leave the NAND bootloader incomplete.

---

## Hardware and prerequisites

Prepare the following:

- one Linksys **WRT1900ACS v2 Rev.A00**;
- physical access to the router;
- a **3.3 V TTL** USB-to-UART adapter;
- three serial connections: GND, TX, and RX;
- a Linux PC;
- the `kwboot` binary built by this project;
- the KWB image to test;
- a FAT-formatted USB drive for permanent installation;
- a reliable and stable router power supply;
- verified backups of the critical NAND regions.

> [!WARNING]
> Never use a conventional RS-232 adapter or 5 V logic levels. Do not connect
> the adapter power pin to the router. Connect only GND, TX, and RX, with TX
> and RX crossed.

List serial devices on the Linux host:

```bash
ls -l /dev/ttyUSB*
```

The current user must have permission to access the serial device. Depending
on the host configuration, run `kwboot` with `sudo` or add the user to the
group that owns `/dev/ttyUSB0`.

---

## Step 1 — Verify the exact router identity

Before any test or write, confirm the label on the router:

```text
Model: WRT1900ACS
Hardware version: V2
Revision: Rev.A00
```

Stop immediately if the model or revision differs.

It is also recommended to retain:

- a readable photograph of the label;
- the complete boot log from the currently installed bootloader;
- an OpenWrt configuration backup;
- backups of all critical NAND regions.

Never publish a `devinfo` backup. It may contain device-specific information,
including MAC addresses and the serial number.

---

## Step 2 — Back up critical NAND regions

Before installation, back up at least:

- the U-Boot region;
- the primary environment;
- the secondary environment;
- the `devinfo` partition.

With the helpers provided by this firmware:

```text
run backup_uboot
run backup_uenv
run backup_senv
run backup_devinfo
```

Each backup must then be copied away from the router, for example through TFTP
or to USB, depending on the commands available in the running bootloader.

Example using TFTP:

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

Verify sizes and calculate SHA-256 sums on the PC:

```bash
sha256sum backup-*.bin
```

Store the backups on at least two independent storage devices.

> [!IMPORTANT]
> A backup is useful only after it has been transferred away from the router
> and its size and checksum have been verified.

---

## Step 3 — Prepare the image to test

The command currently used for this build refers to:

```text
wrt1900acsv2-uboot-full/out/u-boot-wrt1900acsv2-final-nand-v2026.07.kwb
```

Calculate and retain its SHA-256 sum:

```bash
sha256sum \
  wrt1900acsv2-uboot-full/out/u-boot-wrt1900acsv2-final-nand-v2026.07.kwb
```

Use the exact same file for the `kwboot` test and for the later USB copy. This
avoids testing one image and accidentally installing another.

Do not keep multiple different images under the same filename. Archive or
remove old builds to reduce the risk of confusion.

---

## Step 4 — Test the image with `kwboot`

### 4.1 Close every other serial terminal

Before starting `kwboot`, close `screen`, `minicom`, `picocom`, and any other
program using `/dev/ttyUSB0`. Only one program should control the port during
the BootROM handshake.

### 4.2 Start `kwboot`

From the project working directory, run:

```bash
./wrt1900acsv2-uboot-full/out/kwboot-v2026.07 \
  -b wrt1900acsv2-uboot-full/out/u-boot-wrt1900acsv2-final-nand-v2026.07.kwb \
  -t -B 115200 /dev/ttyUSB0
```

Option meanings:

- `-b <image>`: wait for the Marvell BootROM and transfer the KWB image;
- `-t`: open a serial terminal after the transfer;
- `-B 115200`: use 115200 baud for transfer and terminal mode;
- `/dev/ttyUSB0`: serial device connected to the router.

When required, `kwboot` adapts the KWB boot type in memory for UART loading.
It does not modify the source file stored on the PC.

### 4.3 Trigger the BootROM handshake

Start `kwboot` first, then:

1. switch the router off;
2. wait a few seconds;
3. switch the router on;
4. allow `kwboot` to detect the BootROM handshake window;
5. wait until the transfer is fully complete.

Several attempts may be required because the BootROM window is short. If the
handshake fails:

- do not write NAND;
- verify that TX and RX are crossed;
- verify the shared ground;
- verify that the adapter is 3.3 V TTL;
- verify that `/dev/ttyUSB0` is the correct device;
- close every other serial application;
- restart `kwboot` and perform a complete power cycle.

### 4.4 Interrupt autoboot

After the transfer, the U-Boot banner should appear. Press a key during the
countdown to obtain a prompt similar to:

```text
WRT1900ACSv2(final)>
```

At this point NAND has not been changed. Until an installation command is
executed, a normal power cycle returns to the bootloader already stored in
NAND.

### 4.5 Leave the `kwboot` terminal

The integrated `kwboot` terminal normally exits with:

```text
Ctrl-\ followed by c
```

This closes the terminal on the PC. It does not necessarily reset the router.

---

## Step 5 — Minimum validation before any installation

A visible U-Boot prompt is not sufficient. Test every function required for
normal boot and recovery.

### 5.1 General information

```text
version
bdinfo
linksys status
printenv
```

Verify:

- model `WRT1900ACS v2 Rev.A00`;
- expected RAM size;
- NAND detection;
- a valid factory MAC address;
- coherent boot variables;
- absence of critical boot errors.

### 5.2 NAND and partitions

```text
nand info
nand bad
mtd list
```

Do not run any erase or write command during this validation phase.

### 5.3 USB

Insert the FAT-formatted USB drive and run:

```text
usb start
usb storage
```

The drive must be detected as a storage device and its first partition must be
readable.

### 5.4 U-Boot network and switch

```text
net list
mdio list
linksys switch probe
net list
mdio list
```

Expected mapping:

| Component | Mapping |
|---|---|
| SoC master | GE0 / `ethernet@70000` |
| CPU link | RGMII-ID |
| MV88E6176 CPU port | port 6 |
| Switch port 0 | LAN4 |
| Switch port 1 | LAN3 |
| Switch port 2 | LAN2 |
| Switch port 3 | LAN1 |
| Switch port 4 | WAN |

The LAN and WAN PHYs should appear in `mdio list`.

When a TFTP server is available, also test:

```text
ping ${serverip}
tftpboot ${loadaddr} test.bin
crc32 ${loadaddr} ${filesize}
```

### 5.5 Boot OpenWrt

Boot OpenWrt from the image loaded through `kwboot`:

```text
linksys boot
```

Validate:

- complete OpenWrt boot;
- access through a LAN port;
- Ethernet transmit and receive paths;
- `br-lan` operation;
- ARP resolution;
- ping in both directions;
- access from a PC attached to the router;
- boot of every firmware slot used by the device.

Example on OpenWrt:

```sh
ip link
ip addr
ip neigh show
ping -c 3 192.168.1.100
```

Example on the connected PC:

```bash
ping -c 3 192.168.1.1
sudo tcpdump -eni INTERFACE 'arp or icmp'
```

> [!CAUTION]
> Continue only if the `kwboot` image starts OpenWrt correctly and network
> traffic works in both directions. A displayed `Link is Up` state alone does
> not prove that frames cross the RGMII/DSA path.

### 5.6 Test both firmware slots

Each command below boots immediately. Maintain serial access:

```text
linksys slot 1
linksys boot
```

After a new `kwboot` session:

```text
linksys slot 2
linksys boot
```

Confirm that both intended OpenWrt slots reach userspace and have functional
LAN networking before installing the bootloader permanently.

---

## Step 6 — Prepare the USB drive

Create a compatible partition table and a FAT first partition readable by
U-Boot.

Copy the image to the root of the first partition:

```text
/u-boot-wrt1900acsv2-final-nand-v2026.07.kwb
```

After copying:

1. flush write caches with `sync`;
2. unmount the drive cleanly;
3. reconnect it to the PC;
4. calculate the SHA-256 sum of the file on the drive;
5. verify that it exactly matches the image tested through `kwboot`.

Example:

```bash
sync
sha256sum /media/$USER/USB_DRIVE/u-boot-wrt1900acsv2-final-nand-v2026.07.kwb
```

---

## Step 7 — Load the image from USB

Boot the already validated U-Boot image through `kwboot`, interrupt autoboot,
and insert the USB drive.

Initialize USB:

```text
usb start
```

This initializes the USB controllers, enumerates devices, and scans for
storage.

Load the image into RAM:

```text
load usb 0:1 ${loadaddr} /u-boot-wrt1900acsv2-final-nand-v2026.07.kwb
```

Command fields:

- `usb`: storage interface;
- `0:1`: USB device 0, partition 1;
- `${loadaddr}`: destination RAM address from the environment;
- the final argument: file path on the FAT partition.

After a successful load, U-Boot sets at least:

- `${fileaddr}` to the load address;
- `${filesize}` to the exact number of bytes read.

Do not type a size copied from another build. Both the validation and install
commands must use the `${filesize}` produced when this exact file was loaded.

Check the result:

```text
echo ${fileaddr}
echo ${filesize}
echo $?
```

Stop if the file is not found, the size is zero, the read fails, or the USB
device disconnects.

---

## Step 8 — Validate the image before writing

Run:

```text
linksys uboot check ${loadaddr} ${filesize}
```

This command is read-only with respect to NAND. It examines the image in RAM
and verifies that it matches the expected format for this router.

The current implementation checks, among other items:

- a compatible KWB image is present;
- KWB version 1 and NAND boot type;
- the Linksys Armada-38x BootROM profile;
- supplied size consistency;
- alignment constraints;
- header checksum;
- payload checksum;
- image size against the protected U-Boot region.

Continue only after an explicit successful result without warnings.

> [!WARNING]
> A file that loads successfully from USB is not necessarily a valid U-Boot
> image. `linksys uboot check` is a mandatory safety barrier, not an optional
> step.

---

## Step 9 — Temporarily authorize NAND writes

Sensitive NAND writes are locked by default. To authorize installation for
the current boot session only, run:

```text
setenv allow_nand_write WRT1900ACSV2
```

This deliberately explicit value is a safety token intended to prevent an
accidental installation command.

`setenv` changes the environment in RAM. **Do not run `saveenv` after defining
this token.** The write permission must never become persistent.

Verify it:

```text
printenv allow_nand_write
```

The result must be exactly:

```text
allow_nand_write=WRT1900ACSV2
```

Stop if the value differs.

---

## Step 10 — Install the image into NAND

Run:

```text
linksys uboot install ${loadaddr} ${filesize}
```

This command is destructive. After erase begins, power loss or reset may leave
the U-Boot region incomplete.

The protected installer performs the following operations:

1. verifies `allow_nand_write`;
2. revalidates the source address and size;
3. checks NAND geometry and the protected region;
4. checks for bad blocks in the U-Boot region;
5. erases only the intended U-Boot region;
6. writes a NAND-page-aligned image size;
7. reads the written data back;
8. compares the complete result with the image still held in RAM;
9. clears the authorization token.

During the operation:

- do not touch the power supply or serial cable;
- do not remove the USB drive or USB-to-UART adapter;
- do not type another command;
- do not close the terminal;
- do not reset or power-cycle the router.

Success must be reported explicitly, for example:

```text
U-Boot installation and byte-for-byte verification: OK
```

Do not reboot after an error, verification failure, bad-block report,
incorrect-size report, or ambiguous result. Keep the router powered and save
the complete serial log for diagnosis.

---

## Step 11 — Possible consequences of failure

### Failure before erase begins

If `usb start`, `load`, `linksys uboot check`, or token validation fails, NAND
should not have been changed. Correct the problem and start again from the USB
load step.

### Power loss or error during erase or write

The NAND bootloader may become partial or invalid. Possible symptoms include:

- no U-Boot banner after power-on;
- BootROM messages reporting invalid headers;
- repeated scans at different NAND offsets;
- boot possible only through `kwboot`;
- inability to boot OpenWrt without serial recovery.

Do not attempt random write commands. Return to `kwboot`, boot the previously
validated image temporarily, examine the logs, and reinstall only after the
cause has been identified.

### Verification failure after write

A comparison failure means the data read from NAND does not match the source
image. **Do not consider the installation valid and do not perform a normal
reboot.** While the `kwboot` U-Boot instance is still running in RAM, keep the
router powered and prepare a controlled recovery.

---

## Step 12 — First reboot after installation

After the complete success message:

1. keep the serial terminal open;
2. save the current serial log;
3. optionally remove the USB drive to avoid an unintended USB operation;
4. run:

```text
reset
```

The router should now boot the new NAND image without a `kwboot` transfer.

Interrupt autoboot and run:

```text
version
linksys status
net list
mdio list
printenv
```

Verify:

- expected U-Boot version;
- successful NAND environment load;
- factory MAC address is present;
- GE0 is the Ethernet master;
- MV88E6176 and all five PHYs are visible;
- no checksum, NAND, or KWB error is reported;
- `allow_nand_write` was not persisted.

The following command should normally report that the variable is undefined:

```text
printenv allow_nand_write
```

Then allow OpenWrt to boot and repeat complete network validation.

---

## Step 13 — Final OpenWrt validation

After the first NAND boot:

```sh
ubus call system board
ip link
ip addr
ip neigh show
dmesg | grep -Ei 'mvneta|mv88|dsa|mdio'
```

Validate at least:

- all four LAN ports;
- the WAN port;
- the LAN bridge;
- DHCP or the intended static configuration;
- ARP and ping in both directions;
- LuCI or SSH access;
- both firmware partitions if A/B booting is used;
- one software reboot;
- one complete power cycle.

Retain a validation record containing:

- U-Boot version;
- SHA-256 sum of the installed image;
- test date;
- model and hardware revision;
- network-test results;
- any observed anomaly.

Do not include the MAC address, serial number, or `devinfo` contents in a public
report.

---

## Command summary

### Temporary test through `kwboot`

```bash
./wrt1900acsv2-uboot-full/out/kwboot-v2026.07 \
  -b wrt1900acsv2-uboot-full/out/u-boot-wrt1900acsv2-final-nand-v2026.07.kwb \
  -t -B 115200 /dev/ttyUSB0
```

### Installation from a FAT-formatted USB drive

```text
usb start
load usb 0:1 ${loadaddr} /u-boot-wrt1900acsv2-final-nand-v2026.07.kwb
linksys uboot check ${loadaddr} ${filesize}
setenv allow_nand_write WRT1900ACSV2
linksys uboot install ${loadaddr} ${filesize}
```

Run these commands one at a time. Read and verify the result of each command
before entering the next one.

> [!CAUTION]
> Do not combine the installation commands on one semicolon-separated line.
> Depending on command-parser behavior, later commands may still run after an
> earlier command fails. Bootloader writing must remain deliberate,
> sequential, and supervised.

---

## Commands not to use for this installation

Do not replace the protected installer with a manual sequence such as:

```text
nand erase 0 200000
nand write ${loadaddr} 0 200000
```

A manual write bypasses some or all router-specific protections:

- KWB format validation;
- size validation;
- allowed-region validation;
- bad-block check;
- readback;
- byte-for-byte comparison;
- confirmation-token handling.

Never write a NAND image intended for another profile, another router, or
another hardware revision.

---

## When in doubt

Do not install. Keep the current NAND bootloader and continue testing with
`kwboot`, which is specifically intended to support validation and recovery
without a prior NAND write.

Before requesting assistance, provide:

- model and hardware revision, without the serial number;
- exact image version;
- image SHA-256 sum;
- exact `kwboot` command;
- complete serial log from power-on;
- output from `linksys uboot check`;
- output from `linksys status`, `net list`, and `mdio list`;
- the exact step at which the procedure stopped.

Remove every MAC address, serial number, `devinfo` value, certificate, and
other personal or device-unique information before publishing logs.

---

## Technical references

- `kwboot` manual:
  <https://manpages.debian.org/unstable/u-boot-tools/kwboot.1.en.html>
- U-Boot `load` command:
  <https://docs.u-boot.org/en/stable/usage/cmd/load.html>
- U-Boot environment:
  <https://docs.u-boot.org/en/stable/usage/environment.html>
- U-Boot `env` command:
  <https://docs.u-boot.org/en/stable/usage/cmd/env.html>
