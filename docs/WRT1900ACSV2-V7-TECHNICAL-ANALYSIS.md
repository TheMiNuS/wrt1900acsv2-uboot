# WRT1900ACS v2 Rev.A00 U-Boot v7.0.0 — Technical Design and Code Analysis

## 1. Purpose of this document

This document explains how the project adapts U-Boot 2026.07 for the **Linksys WRT1900ACS v2 Rev.A00 (Shelby)**, what each source modification does, which hardware assumptions it relies on, and why those changes are necessary.

It is intended as an engineering reference rather than an installation guide. The installation procedure is documented separately in `docs/FLASHING-PROCEDURE.md`.

The project is deliberately limited to:

```text
Linksys WRT1900ACS v2
Hardware revision: Rev.A00
Platform codename: Shelby
SoC: Marvell Armada 385 / MV88F6820-A0
Switch: Marvell 88E6176
NAND: 128 MiB SLC, 2 KiB pages, 128 KiB erase blocks
```

The code should not be assumed to be correct for a WRT1900AC, WRT1900ACS v1, WRT1200AC, WRT3200ACM, WRT32X, or any other hardware revision.

---

## 2. High-level architecture

The project starts from an unmodified, pinned U-Boot release:

```text
U-Boot tag:    v2026.07
Pinned commit: ece349ade2973e220f524ce59e59711cc919263f
```

The build script then applies board-specific changes in four broad areas:

1. **Board support**
   - DDR topology
   - SerDes topology
   - factory data import
   - button access
   - dual-firmware selection
   - safe bootloader installation

2. **Device Tree adaptation**
   - NAND controller properties
   - pin multiplexing
   - I²C clock
   - Ethernet/DSA CPU-port mapping
   - internal switch PHY nodes

3. **Driver fixes and safety changes**
   - MDIO/DSA binding fixes
   - retry-safe DSA probing
   - idempotent MV88E6xxx internal MDIO creation
   - Winbond NAND identification and diagnostics
   - destructive NAND-command interlock

4. **Build and image generation**
   - three independent profiles
   - Linksys-compatible NAND KWB conversion
   - static validation of critical configuration symbols
   - source diff and checksums for reproducibility

The resulting boot path is:

```text
Marvell BootROM
      |
      v
U-Boot SPL
  - early UART
  - DDR training
  - image loading from UART or NAND
      |
      v
U-Boot proper
  - environment
  - NAND
  - USB / SATA / PCIe / I²C
  - Ethernet / MDIO / DSA
  - Linksys-specific commands
      |
      v
OpenWrt Linux
  - GE0 / RGMII-ID
  - MV88E6176 CPU port 6
  - DSA front-panel ports 0..4
```

---

## 3. Board source replacement

The project installs its board implementation as:

```text
board/Marvell/db-88f6820-gp/db-88f6820-gp.c
```

The upstream `db-88f6820-gp` target is used as a practical Armada 38x base, but the board source is replaced with a WRT1900ACS v2 implementation.

This gives access to the mature Armada 38x SPL, DDR, NAND, PCIe, SATA, USB and network infrastructure while allowing the Linksys-specific behavior to live in one board file.

---

## 4. DDR configuration

### 4.1 Physical memory layout

The board code defines two SK hynix DDR3 devices:

```text
2 × H5TQ2G63FFR-PBC
Each device: 2 Gbit ×16
Combined bus: 32-bit
Total memory: 512 MiB
Operating rate: DDR3-1600 effective / 800 MHz clock
ECC: disabled
```

The topology passed to the Marvell DDR library uses:

```c
SPEED_BIN_DDR_1600K
MV_DDR_DEV_WIDTH_16BIT
MV_DDR_DIE_CAP_2GBIT
MV_DDR_FREQ_800
BUS_MASK_32BIT
```

### 4.2 Why explicit DDR topology is required

SPL executes before normal U-Boot and must initialize DRAM before the full image can be relocated and executed. A wrong device width, capacity, frequency, or bus mask may cause:

- immediate SPL failure;
- unstable relocation;
- random crashes under load;
- silent memory corruption;
- failures that appear unrelated, such as NAND or network errors.

The project therefore supplies a fixed topology matching the tested Rev.A00 board rather than relying on generic discovery.

### 4.3 Early-access restriction

The build contains a safety check that rejects direct access to `0xf1xxxxxx` internal registers from `board_early_init_f()`.

On Armada 38x, this hook runs before the SPL internal-register translation is fully established. Accessing final relocated addresses from this stage can stop `kwboot` immediately after the KWB header transfer. All board register access is therefore delayed until U-Boot proper or a safe later initialization stage.

---

## 5. SerDes topology

The board defines six high-speed lanes:

| Lane function | Speed | Purpose |
|---|---:|---|
| SATA0 | 6 Gbit/s | First SATA/eSATA path |
| PCIe 0 | 5 Gbit/s | First PCIe root-complex lane |
| SATA1 | 6 Gbit/s | Second SATA path |
| USB3 host 1 | 5 Gbit/s | USB 3 host controller |
| PCIe 1 | 5 Gbit/s | Second PCIe root-complex lane |
| SGMII2 | 1.25 Gbit/s | Secondary Ethernet/SerDes path retained by the SoC topology |

The SerDes map is consumed by the Armada high-speed initialization library before normal peripheral probing.

Even though OpenWrt uses **GE0 through RGMII** as the switch CPU conduit, the SoC board topology still contains SGMII2. Keeping the tested SerDes topology avoids unintentionally changing unrelated high-speed lanes or breaking PCIe/SATA/USB initialization.

---

## 6. Factory `devinfo` import

### 6.1 NAND location

The Linksys factory-information region is read from:

```text
Offset: 0x00900000
Size:   0x00100000 (1 MiB)
RAM:    0x1d000000
```

The board code scans printable ASCII ranges and looks for `key=value` strings.

### 6.2 Imported fields

| Factory key | U-Boot variable |
|---|---|
| `hw_mac_addr` | `ethaddr` |
| `serial_number` | `linksys_serial` |
| `modelNumber` | `linksys_model` |
| `hardware_version` | `linksys_hw_version` |
| `cert_region` | `linksys_cert_region` |
| `region` | `linksys_region` |

### 6.3 MAC-address handling

The hardware MAC is assigned to the Ethernet master through `ethaddr`.

The project explicitly removes `eth1addr` through `eth6addr` before Ethernet probing. This is important because U-Boot numbers the DSA front-panel interfaces as additional Ethernet devices. Per-port variables would override normal DSA inheritance and can create misleading or inconsistent mappings.

The intended U-Boot view is therefore:

```text
eth0  GE0 master         factory MAC
eth1  lan4 DSA port      inherits master MAC
eth2  lan3 DSA port      inherits master MAC
eth3  lan2 DSA port      inherits master MAC
eth4  lan1 DSA port      inherits master MAC
eth5  wan  DSA port      inherits master MAC
```

This does **not** bridge WAN and LAN. These entries are logical U-Boot network devices sharing one CPU conduit. OpenWrt creates the actual LAN bridge and WAN interface and may assign a locally administered WAN MAC according to its board scripts.

---

## 7. Environment normalization

### 7.1 Why the environment is normalized in C

Existing Linksys environments can contain old variable names, incompatible partition definitions, or shell strings containing literal quote characters. Depending only on the persistent environment would make behavior vary from one router to another.

`linksys_env_migrate()` therefore repairs critical variables in RAM at every boot.

The environment schema is identified by:

```text
env_schema=wrt1900acsv2-v7.0.0
```

### 7.2 NAND partition map

The project configures:

```text
0x00000000  2 MiB   uboot       read-only through MTD definition
             256 KiB u_env
             256 KiB s_env
0x00900000  1 MiB   devinfo
0x00a00000 40 MiB   kernel / primary firmware region
0x01000000 34 MiB   rootfs view inside primary region
0x03200000 40 MiB   alt_kernel / alternate firmware region
0x03800000 34 MiB   alt_rootfs view inside alternate region
0x00a00000 80 MiB   ubifs aggregate view
0x05a00000 remaining syscfg
```

Some MTD entries intentionally overlap. They are alternative views of the same physical storage used by Linksys/OpenWrt tooling, not independent writable regions.

### 7.3 Load addresses

| Variable | Address | Use |
|---|---:|---|
| `loadaddr` | `0x02000000` | kernel, firmware or U-Boot image loading |
| `defaultLoadAddr` | `0x02000000` | compatibility alias |
| `fdtaddr` | `0x03000000` | external FDT work area |
| KWB verification buffer | `0x1c000000` | NAND readback verification |
| `devinfo` buffer | `0x1d000000` | factory-data parsing |

These addresses are kept far from relocated U-Boot and from each other within the 512 MiB DRAM range.

### 7.4 Firmware slots

The primary kernel starts at:

```text
priKernAddr=0x00a00000
priKernSize=0x00600000
```

The alternate kernel starts at:

```text
altKernAddr=0x03200000
altKernSize=0x00600000
```

`boot_part` selects slot 1 or 2. `linksys_select_slot()` translates this into either `nandboot` or `altnandboot`.

### 7.5 ATAGS versus explicit FDT boot

The default boot command is:

```text
bootm ${loadaddr}
```

This retains the ARM ATAGS-compatible path expected by existing Linksys/OpenWrt uImages with appended board data.

A diagnostic alternative is also retained:

```text
bootm ${loadaddr} - ${fdtcontroladdr}
```

This permits explicit testing with U-Boot's control FDT, but it is not used as the normal path because changing the kernel handoff format can break otherwise valid installed images.

### 7.6 Why critical boot selection is implemented in C

The actual automatic boot and fallback decisions are performed by the `linksys` command implementation rather than by long shell expressions. This reduces dependency on environment quoting, Hush parsing, and legacy vendor strings.

Shell support remains enabled for recovery operations and manual diagnostics.

---

## 8. Dual-firmware and boot-count behavior

The project enables U-Boot's environment-backed boot counter:

```text
bootlimit=3
bootcount=<current count>
upgrade_available=0 or 1
```

Normal behavior:

- when no upgrade is pending, `bootcount` is reset to zero during normalization;
- when `upgrade_available=1`, failed boots can accumulate;
- after the configured limit, `altbootcmd=linksys fallback` executes;
- fallback switches `boot_part`, clears `bootcount` and `upgrade_available`, saves the new environment, and boots the other slot.

This follows the dual-firmware recovery model without making every ordinary reboot consume the boot limit.

---

## 9. Network hardware mapping

### 9.1 Correct physical topology

The working topology is:

```text
Armada 385 GE0
ethernet@70000
phy-mode = rgmii-id
        |
        | RGMII with internal RX/TX delay at the switch side
        v
MV88E6176 CPU port 6
        |
        +-- port 0: LAN4
        +-- port 1: LAN3
        +-- port 2: LAN2
        +-- port 3: LAN1
        +-- port 4: WAN
```

The unused secondary Ethernet controller is disabled in the U-Boot Device Tree:

```text
ethernet@34000 / GE2 / SGMII: disabled
```

### 9.2 Why the upstream mapping must be changed

The generic upstream Linksys Device Tree uses a CPU link based on:

```text
GE2 / ethernet@34000 -> SGMII -> switch port 5
```

OpenWrt on this hardware uses:

```text
GE0 / ethernet@70000 -> RGMII -> switch port 6
```

A bootloader that initializes only port 5/SGMII can leave port 6/RGMII in an incomplete state. Linux may still detect the switch and report a logical link, while transmitted frames fail to leave the physical LAN ports.

The project therefore aligns the U-Boot topology with the hardware path later used by OpenWrt.

---

## 10. Network pin multiplexing registers

### 10.1 Register addresses

The board code accesses Armada 38x MPP registers after relocation:

| Register | Address | MPP range |
|---|---:|---|
| `MPP_CTRL_0_7` | `0xf1018000` | MPP0–7 |
| `MPP_CTRL_8_15` | `0xf1018004` | MPP8–15 |
| `MPP_CTRL_16_23` | `0xf1018008` | MPP16–23 |
| `MPP_CTRL_24_31` | `0xf101800c` | MPP24–31 |

Each MPP uses a four-bit function selector.

### 10.2 Values written

The network function computes:

```c
new0 = (mpp0 & 0x0000ffffU) | 0x11110000U;
new1 = 0x11111111U;
new2 = (mpp2 & 0xffffff00U) | 0x00000011U;
```

This means:

| Pins | Function selector | Purpose |
|---|---:|---|
| MPP4–5 | `1` | Ethernet MDC and MDIO |
| MPP6–7 | `1` | First GE0 RGMII signals |
| MPP8–15 | `1` | GE0 RGMII signals |
| MPP16–17 | `1` | Remaining GE0 RGMII signals |

Unrelated fields are preserved:

- MPP0–3 remain unchanged through `mpp0 & 0x0000ffff`;
- MPP18–23 remain unchanged through `mpp2 & 0xffffff00`.

### 10.3 Why this is done both in the Device Tree and board code

The Device Tree contains normal pinctrl references:

```text
&mdio -> mdio_pins
&eth0 -> ge0_rgmii_pins
```

The board code also applies the tested register values before MDIO/DSA probing.

This duplication is intentional:

- pinctrl describes the correct topology to the driver model;
- the explicit late write guarantees that the exact electrical mux is present before the MDIO parent and switch are probed;
- it avoids depending on probe order or on inherited BootROM/vendor-loader state.

Without MPP4/5, MDIO transactions cannot reach the switch. Without MPP6–17, GE0 cannot exchange RGMII data with CPU port 6.

---

## 11. DSA Device Tree changes

### 11.1 CPU-port relocation

The build transforms the switch CPU node from:

```dts
ethernet-port@5 {
    reg = <5>;
    phy-mode = "sgmii";
    ethernet = <&eth2>;
};
```

into:

```dts
ethernet-port@6 {
    reg = <6>;
    phy-mode = "rgmii-id";
    ethernet = <&eth0>;
};
```

`rgmii-id` means that both receive and transmit clock delays are expected to be inserted internally on the PHY/switch side. This is essential because raw RGMII clock and data edges otherwise have insufficient timing margin at 1 Gbit/s.

### 11.2 Internal PHY nodes

The MV88E6176 contains PHYs for the five front-panel copper ports. The project adds an internal MDIO child with PHY addresses 0 through 4:

```dts
mdio {
    swphy0: ethernet-phy@0 { reg = <0>; };
    swphy1: ethernet-phy@1 { reg = <1>; };
    swphy2: ethernet-phy@2 { reg = <2>; };
    swphy3: ethernet-phy@3 { reg = <3>; };
    swphy4: ethernet-phy@4 { reg = <4>; };
};
```

Each front-panel DSA port receives:

```dts
phy-mode = "internal";
phy-handle = <&swphyN>;
```

This gives U-Boot one explicit PHY object per user port and allows commands such as `mdio list`, `ping`, DHCP and TFTP to operate through a selected DSA front port.

### 11.3 Front-panel mapping

The front-panel mapping is deliberately not reordered:

| MV88E6176 port | DSA label |
|---:|---|
| 0 | `lan4` |
| 1 | `lan3` |
| 2 | `lan2` |
| 3 | `lan1` |
| 4 | `wan` |
| 6 | CPU port to GE0 |

This matches the working OpenWrt board definition.

---

## 12. MDIO and DSA source fixes

### 12.1 Preventing a switch node from being bound as a generic PHY

The generic MDIO uclass normally iterates over every child of an MDIO controller and attempts to bind it through the generic Ethernet PHY driver.

A DSA switch node is not a Clause 22/45 PHY. Binding the `marvell,mv88e6085` switch node as a generic PHY creates an invalid device hierarchy and interferes with the real DSA driver.

The patch adds a compatibility check:

```c
if (ofnode_device_is_compatible(phy_node, "marvell,mv88e6085"))
    continue;
```

The switch remains available for the MV88E6xxx DSA driver, while genuine PHY children continue to be bound normally.

### 12.2 Retry-safe DSA pre-probe

One switch can be reached indirectly through several DSA Ethernet-port probes. If an early probe fails and later code retries, resource creation must not be repeated blindly.

The project changes DSA pre-probe behavior so that creation of the CPU fixed PHY and related objects is idempotent. Existing objects are reused instead of duplicated.

This prevents failures such as:

- duplicate fixed-PHY registration;
- stale partially initialized devices;
- different results depending on which `lanX` interface probes first.

### 12.3 Idempotent MV88E6xxx internal MDIO probing

The MV88E6xxx driver exposes an internal MDIO bus for its integrated PHYs. Repeated switch probes must reuse or re-probe the existing child instead of binding another child with the same role.

The project replaces `mv88e6xxx_probe_mdio()` with logic that:

1. searches for an existing `mdio` child;
2. probes it again safely if present;
3. otherwise binds and probes it once;
4. reports an explicit error when re-probing fails.

This is required because Ethernet enumeration, `net list`, and per-port access can trigger multiple related probe paths.

---

## 13. Switch initialization and Linux handoff

### 13.1 Why a simple DSA probe is not enough

Probing the MV88E6176 identifies and resets the switch, but does not necessarily leave the CPU fixed link and a user port enabled.

A Linux boot can therefore begin with:

- switch detected;
- PHYs detected;
- software link reported as up;
- receive traffic partly working;
- transmit traffic failing because the CPU-port electrical mode was not fully initialized.

### 13.2 Priming the exact OpenWrt path

`linksys_switch_prepare()` performs the following sequence:

1. applies the MPP network pinmux;
2. probes the DSA switch;
3. obtains the GE0 master;
4. probes the `lan1` DSA interface;
5. calls the DSA port `start()` operation;
6. lets DSA enable both LAN1 and CPU port 6;
7. stops only the GE0 DMA engine.

Starting `lan1` causes the DSA/MV88E6xxx stack to configure:

- the user port;
- CPU port 6;
- the fixed 1 Gbit/s full-duplex CPU link;
- RGMII-ID receive and transmit delay settings;
- the master Ethernet path.

### 13.3 Why only the master is stopped

Calling the normal DSA port stop path would undo the port enabling and leave the switch in the same incomplete state the handoff is intended to fix.

The project instead stops only the GE0 master DMA engine. This prevents U-Boot descriptor rings or DMA activity from remaining active while preserving the switch-side physical control settings until Linux resets and configures the switch itself.

### 13.4 Escape hatch

The environment variable:

```text
switch_handoff=skip
```

bypasses switch preparation for serial-recovery diagnostics. It is intentionally RAM-oriented and should not be used as the normal configuration.

---

## 14. Button-register handling

The project reads two active-low buttons:

| Button | GPIO |
|---|---:|
| WPS | GPIO24 |
| Reset | GPIO29 |

Before reading them, MPP24 and MPP29 are changed to GPIO function 0 by clearing their four-bit MPP selectors in `MPP_CTRL_24_31`.

The GPIO direction register is:

```text
GPIO0_IO_CONF = 0xf1018104
```

On this controller, a set bit selects input mode. The code therefore sets bits 24 and 29.

Input state is read from:

```text
GPIO0_DATA_IN = 0xf1018110
```

Because the buttons are active-low:

```text
bit = 1 -> released
bit = 0 -> pressed
```

The dedicated `linksys buttons` command avoids relying on generic button probing behavior that previously caused unsafe device probing on this platform.

---

## 15. NAND controller adaptation

### 15.1 Geometry

The installer requires exactly:

```text
Total size:  0x08000000 = 128 MiB
Page size:   2048 bytes
Erase size:  131072 bytes = 128 KiB
OOB size:    64 bytes
```

The Device Tree sets:

```text
ECC strength:  4 bits
ECC step size: 512 bytes
```

These properties are placed where the current PXA3xx NAND driver reads them.

### 15.2 `nand-keep-config` and flash BBT

The build removes the inherited `marvell,nand-keep-config` / persistent BBT assumptions from the upstream DTS and lets U-Boot configure timings itself.

A persistent flash bad-block table is not enabled for this bootloader profile. This avoids modifying reserved NAND metadata unexpectedly during recovery and keeps the bootloader focused on the factory bad-block markers.

### 15.3 Winbond NAND table entry

The project adds support for the raw ID:

```text
ef f1 00 95 ...
```

The two-byte driver ID is represented as:

```text
0xf1ef
```

An explicit timing-table entry is added for this x8 device.

### 15.4 Diagnostic improvements

At NAND initialization, the driver prints the complete raw ID bytes. If timing lookup fails, the error includes the detected ID.

On ready/busy timeout, the driver reports:

- `NDSR` — NAND status register;
- `NDCR` — NAND control register;
- `NDTR0CS0` — first timing register;
- `NDTR1CS0` — second timing register.

These values are useful for distinguishing an unsupported device, incorrect pinmux, invalid timing, and a controller state-machine failure.

---

## 16. NAND write protection

### 16.1 Global destructive-command guard

The generic `nand` command is modified so destructive operations require:

```text
setenv allow_nand_write WRT1900ACSV2
```

The guard applies to commands beginning with or equal to:

```text
write
erase
scrub
markbad
biterr
lock
unlock
```

Read-only commands remain available without the token.

### 16.2 Why the token is intentionally temporary

`setenv` modifies the in-memory environment only unless the user explicitly calls `saveenv`. The board code clears or consumes the token, and the dedicated installer always removes it on exit.

The token is not cryptographic authorization. It is a deliberate safety interlock against accidental destructive commands, copy-and-paste mistakes, and scripts running with the wrong assumptions.

### 16.3 Dedicated U-Boot installer

The preferred installation command is:

```text
linksys uboot install ${loadaddr} ${filesize}
```

It performs more checks than a manual `nand erase` followed by `nand write`.

---

## 17. KWB image validation

### 17.1 Accepted format

The installer accepts only a Linksys-compatible Armada 38x NAND KWB v1 image.

Required identifiers include:

```text
Block ID:       0x8b (NAND)
Header version: 0x01
Page field:     0
Block code:     4
BBI field:      0
```

The page field and block code are BootROM container values, not a direct copy of the Linux MTD geometry.

### 17.2 RAM-range validation

The image must be loaded into a safe DRAM region:

```text
minimum address: 0x00100000
maximum end:     0x1f000000
```

The code also detects unsigned overflow in `addr + size`.

### 17.3 File-size validation

Allowed image size:

```text
minimum: 0x00040000 (256 KiB)
maximum: 0x00200000 (2 MiB)
```

This rejects obviously wrong files while ensuring the image fits completely in the U-Boot partition.

### 17.4 Header validation

The code checks:

- minimum and maximum header size;
- source offset equals header size;
- source offset is 2 KiB aligned;
- payload boundaries stay inside the file;
- payload size is a multiple of four;
- the one-byte KWB header checksum.

### 17.5 Payload validation

The payload checksum is calculated as a 32-bit little-endian additive sum over all payload words except the final checksum word. The computed sum must equal the stored final word.

This catches truncated, corrupted, or incorrectly converted images before NAND erase begins.

---

## 18. Safe U-Boot partition installation

### 18.1 Geometry confirmation

Before writing, the installer confirms that NAND device 0 is exactly the expected 128 MiB device with 2 KiB pages and 128 KiB erase blocks.

This prevents installation on a different NAND geometry even if the board otherwise boots.

### 18.2 Bad-block scan

The complete first 2 MiB U-Boot partition is checked one erase block at a time.

With a 128 KiB erase size, this means 16 blocks:

```text
0x00000000 through 0x001fffff
```

Installation is refused if any block is marked bad or reserved.

The BootROM can scan multiple candidate headers, but this installer deliberately refuses to invent a bad-block placement strategy. A bad block in the bootloader partition requires a separate recovery design and must not be handled implicitly.

### 18.3 Page alignment

If the image is not an exact multiple of 2048 bytes, the RAM buffer is padded with `0xff` to the next page boundary.

`0xff` represents erased NAND and avoids programming arbitrary trailing bytes.

### 18.4 Write sequence

The installer performs:

1. erase the full 2 MiB U-Boot partition;
2. write the page-aligned image at offset zero;
3. read the written bytes into `0x1c000000`;
4. compare every byte with the source RAM buffer;
5. report success only after exact verification;
6. clear the write token in all success and failure paths.

The full partition is erased so stale historical BootROM headers are not left at later offsets.

### 18.5 Remaining unavoidable risk

A power failure after erase and before successful write completion can leave the router unable to boot from NAND. The serial BootROM recovery path and a tested `kwboot` image are therefore mandatory prerequisites.

Software validation cannot eliminate electrical failure, unstable power, USB/UART faults, defective NAND, or use on the wrong board revision.

---

## 19. KWB container conversion

U-Boot's normal NAND KWB output is post-processed by:

```text
scripts/patch-kwb-linksys-nand.py
```

The converter produces the profile expected by the Linksys Armada 38x BootROM 1.73 implementation:

```text
page field = 0
block code = 4
BBI = 0
header/source alignment = 0x800
```

After conversion, the build script independently reopens the image and validates:

- KWB block ID;
- version;
- header size;
- source offset;
- Linksys NAND profile fields;
- 2 KiB alignment.

The unmodified upstream container is also preserved with its own checksum for comparison and debugging.

---

## 20. I²C configuration

The Device Tree adds:

```text
clock-frequency = 100000
```

for the primary I²C controller.

The build enables driver-model I²C and the Marvell `mvtwsi` driver while disabling the legacy I²C stack.

The driver is intentionally excluded from SPL and compiled only into U-Boot proper. This keeps SPL small and avoids early I²C accesses before the full runtime environment is ready.

The build verifies both conditions by checking object-file presence after compilation.

---

## 21. U-Boot feature configuration

### 21.1 Core boot and shell

Enabled features include:

- legacy uImage support;
- `bootm` and image inspection;
- ATAGS command-line and memory tags;
- libfdt and Device Tree commands;
- Hush shell, `run`, tests and expressions;
- environment overwrite;
- board late initialization;
- boot-count limit with environment backend.

The older stable Hush parser is selected explicitly because boot and recovery scripts depend on predictable shell behavior.

### 21.2 Storage

Enabled:

- raw NAND and PXA3xx NAND controller;
- MTD and partition commands;
- USB EHCI/XHCI and USB mass storage;
- AHCI/SCSI for SATA/eSATA;
- MMC commands;
- FAT read/write;
- ext2/ext4 and generic filesystem loading;
- EFI partition parsing.

### 21.3 Networking

Enabled:

- MVNETA Ethernet MAC;
- Marvell MDIO;
- driver-model MDIO and Ethernet PHY;
- fixed PHY;
- Marvell PHY driver;
- driver-model DSA;
- MV88E6xxx switch driver;
- ping, DHCP, TFTP download and TFTP upload;
- MII and MDIO diagnostics.

### 21.4 Hardware diagnostics

Enabled:

- PCI and MVEBU PCIe commands;
- pinctrl and pinmux commands;
- memory display/write/test commands;
- CRC32, SHA-256 and hash commands;
- GPIO, buttons and LEDs;
- device-model inspection;
- I²C diagnostics.

This configuration is intentionally broader than the minimum required to boot OpenWrt because the firmware is also designed as a recovery and hardware-diagnostic environment.

---

## 22. Build profiles

The project produces three images.

### 22.1 `recovery-uart`

```text
Boot source: UART
Environment: nowhere / RAM only
```

Purpose:

- first-stage BootROM validation;
- recovery from damaged NAND environment;
- safest hardware test profile;
- source of the compiled `kwboot` utility.

No environment writes should persist from this profile.

### 22.2 `final-uart`

```text
Boot source: UART
Environment: NAND
```

Purpose:

- test the exact final feature set through `kwboot`;
- verify reading and optionally saving the real NAND environment;
- test both installed OpenWrt slots before flashing U-Boot itself.

This is the mandatory final validation profile.

### 22.3 `final-nand`

```text
Boot source: NAND
Environment: NAND
```

Purpose:

- permanent installation in the first 2 MiB NAND partition.

This image is converted to the Linksys-specific KWB profile and must only be installed after the two UART profiles have been validated.

---

## 23. Build reproducibility and defensive checks

The build script does not merely invoke `make`. It verifies assumptions before and after every critical transformation.

Examples include:

- exact U-Boot commit verification;
- presence of project source files;
- exact-match checks before Device Tree replacements;
- parser-based braced-block extraction for CPU-port relocation;
- validation that port 5 is gone and port 6 exists;
- validation that GE0, RGMII-ID and `eth0` are connected;
- `git diff --check` after source modifications;
- explicit checks for required Kconfig symbols;
- object-file checks proving the intended drivers were compiled;
- rejection of an I²C driver accidentally linked into SPL;
- KWB binary-field validation after image generation;
- SHA-256 creation for every final image;
- generation of the complete source-change patch and build metadata.

These checks are designed to fail early if upstream source layout or configuration semantics change.

---

## 24. `linksys` command set

The project adds one board-specific command namespace.

### Status and factory data

```text
linksys status
linksys devinfo show
linksys devinfo import
```

These expose the normalized environment, board identity, factory MAC and current safety state.

### Environment

```text
linksys env migrate
linksys env save
```

Migration repairs the critical variables in RAM. Save performs normalization before writing the persistent environment.

### Firmware slots

```text
linksys slot 1
linksys slot 2
linksys select
linksys boot
linksys fallback
```

These commands centralize dual-firmware selection and reduce reliance on handwritten shell expressions.

### Network handoff

```text
linksys switch probe
linksys switch handoff
linksys switch skip
linksys switch enable
```

They permit explicit testing of DSA initialization and controlled bypass during serial recovery.

### Buttons

```text
linksys buttons
```

Reads WPS and Reset through the board-specific safe GPIO implementation.

### Bootloader image operations

```text
linksys uboot check <address> <size>
linksys uboot install <address> <size>
```

These implement the KWB validator and guarded installation procedure.

---

## 25. Board initialization sequence

### `board_early_init_f()`

Kept free of unsafe final-address register accesses. Its role is intentionally minimal because it executes during the sensitive SPL phase.

### `board_init()`

Performs standard board-level setup after DRAM and relocation prerequisites are satisfied.

### `board_late_init()`

This is the key Linksys setup stage. It:

1. clears the NAND write token;
2. imports `devinfo` factory values;
3. normalizes the environment schema and boot scripts;
4. repairs slot selection;
5. prepares runtime values before autoboot.

Doing this in late initialization ensures that normal U-Boot services and the NAND driver are available.

### `checkboard()`

Prints the exact supported target:

```text
Linksys WRT1900ACS v2 Rev.A00 (Shelby)
```

The explicit revision string is a safety reminder, not only cosmetic identification.

---

## 26. Maintenance rules for future changes

Any future change should preserve these invariants:

1. `ethernet@70000` remains the active DSA master.
2. `ethernet@34000` remains disabled for the DSA path.
3. switch CPU port 6 remains connected to `eth0` in `rgmii-id` mode.
4. front-panel ports 0–4 retain their current labels.
5. MPP4–5 remain MDC/MDIO.
6. MPP6–17 remain GE0 RGMII.
7. the five internal PHY nodes remain available.
8. DSA and internal-MDIO creation remain retry-safe.
9. `eth1addr` and later per-port overrides are not synthesized.
10. the NAND installer continues to validate geometry, bad blocks, checksums and readback.
11. destructive NAND commands remain locked by default.
12. no direct `0xf1xxxxxx` register access is introduced in `board_early_init_f()`.
13. `final-nand` is never considered safe until `final-uart` has booted and run both OpenWrt slots on the target router.

---

## 27. Limits of the implementation

The project is based on the tested Rev.A00 unit and the known Linksys/OpenWrt NAND layout. It does not dynamically prove every board-level assumption.

In particular:

- it does not support an unexpected NAND geometry;
- it refuses rather than relocates around a bad block in the first 2 MiB;
- it does not guarantee compatibility with another hardware revision;
- it cannot protect against power failure during erase/write;
- it cannot validate analog signal integrity of RGMII, USB, SATA or PCIe;
- it cannot replace a serial console and BootROM recovery path during development;
- it does not make manual low-level NAND writes safe merely because a token was set.

The firmware should therefore be treated as board-specific recovery software, not as a generic Linksys bootloader.

---

## 28. Recommended source-reading order

To understand or audit the implementation, read the repository in this order:

1. `README.md`
2. `docs/NETWORK-MAPPING.md`
3. `board/db-88f6820-gp.c`
4. `board/wrt1900acsv2.env`
5. `build.sh`
6. `patches/0001-mdio-skip-marvell-dsa-switch-node.patch`
7. `scripts/patch-kwb-linksys-nand.py`
8. `docs/FLASHING-PROCEDURE.md`
9. `docs/VALIDATION.md`
10. `tests/uboot-validation.txt`

The generated file:

```text
out/u-boot-source-changes-v7.0.0-v2026.07.patch
```

is the definitive build-time diff against the pinned upstream U-Boot commit and should be kept with release artifacts.
