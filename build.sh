#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The_MiNuS
set -Eeuo pipefail

# Reproducible U-Boot build for Linksys WRT1900ACS v2 Rev.A00 (Shelby).
# The build produces recovery-uart, final-uart and final-nand profiles.
#
# NAND writes are available but protected by a one-boot interlock:
#   setenv allow_nand_write WRT1900ACSV2
# The dedicated `linksys uboot install` command additionally validates the KWB
# NAND header, refuses bad blocks in mtd0, erases only mtd0, writes, then performs
# a full byte-for-byte readback verification before reporting success.
# The final NAND KWB container is post-processed to match the vendor Linksys /
# Armada 38x BootROM profile; the U-Boot payload itself is left unchanged.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
UBOOT_TAG="${UBOOT_TAG:-v2026.07}"
UBOOT_COMMIT="${UBOOT_COMMIT:-ece349ade2973e220f524ce59e59711cc919263f}"
WORKDIR="${WORKDIR:-$PWD/wrt1900acsv2-uboot-full}"
JOBS="${JOBS:-$(nproc)}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabi-}"
SRC="$WORKDIR/u-boot"
OUT="$WORKDIR/out"
BOARD_DIR="$SRC/board/Marvell/db-88f6820-gp"
BOARD_FILE="$BOARD_DIR/db-88f6820-gp.c"
ENV_FILE="$BOARD_DIR/wrt1900acsv2.env"
LINKSYS_DTSI="$SRC/dts/upstream/src/arm/marvell/armada-385-linksys.dtsi"
NAND_DRIVER="$SRC/drivers/mtd/nand/raw/pxa3xx_nand.c"
NAND_CMD="$SRC/cmd/nand.c"
I2C_MAKEFILE="$SRC/drivers/i2c/Makefile"
BUTTON_CMD="$SRC/cmd/button.c"
DSA_UCLASS="$SRC/net/dsa-uclass.c"
MDIO_UCLASS="$SRC/net/mdio-uclass.c"
MV88E_DRIVER="$SRC/drivers/net/mv88e6xxx.c"
BOARD_SOURCE="$SCRIPT_DIR/board/db-88f6820-gp.c"
ENV_SOURCE="$SCRIPT_DIR/board/wrt1900acsv2.env"
KWB_PATCHER="$SCRIPT_DIR/scripts/patch-kwb-linksys-nand.py"
MDIO_DSA_PATCH="$SCRIPT_DIR/patches/0001-mdio-skip-marvell-dsa-switch-node.patch"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

export LC_ALL=C

for tool in git make python3 bison flex bc "${CROSS_COMPILE}gcc"; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing command: $tool"
done

mkdir -p "$WORKDIR" "$OUT"

say "Downloading U-Boot $UBOOT_TAG"
if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 --branch "$UBOOT_TAG" https://github.com/u-boot/u-boot.git "$SRC"
else
    git -C "$SRC" fetch --depth 1 origin "refs/tags/$UBOOT_TAG:refs/tags/$UBOOT_TAG"
    git -C "$SRC" reset --hard "$UBOOT_TAG"
    git -C "$SRC" clean -fdx
fi

actual_commit="$(git -C "$SRC" rev-parse HEAD)"
[[ "$actual_commit" == "$UBOOT_COMMIT" ]] || \
    die "Tag $UBOOT_TAG resolves to $actual_commit, expected $UBOOT_COMMIT"
[[ "$PROJECT_VERSION" == "7.0.0" ]] || die "Unexpected repository version: $PROJECT_VERSION"
[[ -s "$BOARD_SOURCE" ]] || die "Missing board source: $BOARD_SOURCE"
[[ -s "$ENV_SOURCE" ]] || die "Missing board environment: $ENV_SOURCE"
[[ -s "$KWB_PATCHER" ]] || die "Missing KWB tool: $KWB_PATCHER"
[[ -s "$MDIO_DSA_PATCH" ]] || die "Missing MDIO patch: $MDIO_DSA_PATCH"

say "Installing the WRT1900ACSv2 board port"
install -m 0644 "$BOARD_SOURCE" "$BOARD_FILE"

say "Installing the default environment"
install -m 0644 "$ENV_SOURCE" "$ENV_FILE"

say "Adapting the NAND Device Tree and explicit NAND/MDIO/RGMII pin multiplexing"
python3 - "$LINKSYS_DTSI" <<'PY'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "\t\tmarvell,nand-keep-config;\n\t\tnand-on-flash-bbt;\n"
if old not in s:
    raise SystemExit("Expected NAND block not found in armada-385-linksys.dtsi")
s = s.replace(
    old,
    "\t\t/* U-Boot configures timings itself; do not create a persistent BBT yet. */\n",
    1,
)
anchor = "&nand_controller {\n\t/* 128MiB or 256MiB */\n\tstatus = \"okay\";\n"
replace = anchor + (
    "\tpinctrl-names = \"default\";\n"
    "\tpinctrl-0 = <&nand_pins &nand_rb>;\n"
    "\t/* pxa3xx_nand currently reads ECC properties on the controller. */\n"
    "\tnand-ecc-strength = <4>;\n"
    "\tnand-ecc-step-size = <512>;\n"
)
if anchor not in s:
    raise SystemExit("Expected nand_controller block not found")
s = s.replace(anchor, replace, 1)
# Make the I2C bus parameters explicit for the DM mvtwsi driver.
i2c_anchor = '&i2c0 {\n\tpinctrl-names = "default";\n'
if i2c_anchor not in s:
    raise SystemExit("Expected i2c0 block not found")
s = s.replace(
    i2c_anchor,
    '&i2c0 {\n\tpinctrl-names = "default";\n\tclock-frequency = <100000>;\n',
    1,
)
def add_default_pinctrl(text, node_ref, phandle):
    """Add one default pinctrl reference to an existing top-level &label node."""
    token = f"&{node_ref} {{"
    start = text.find(token)
    if start < 0:
        raise SystemExit(f"DTS node {token!r} not found")
    brace = text.find("{", start)
    depth = 0
    i = brace
    state = "code"
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if state == "code":
            if ch == '"':
                state = "string"
            elif ch == "/" and nxt == "*":
                state = "comment"
                i += 1
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    block = text[start:end]
                    wanted_names = 'pinctrl-names = "default";'
                    wanted_ref = f"pinctrl-0 = <&{phandle}>;"
                    if wanted_names in block or "pinctrl-0" in block:
                        if wanted_names not in block or wanted_ref not in block:
                            raise SystemExit(
                                f"Node &{node_ref}: incompatible existing pinctrl configuration"
                            )
                        return text
                    insert = (
                        "\n\tpinctrl-names = \"default\";"
                        f"\n\tpinctrl-0 = <&{phandle}>;"
                    )
                    return text[:brace + 1] + insert + text[brace + 1:]
        elif state == "string":
            if ch == "\\":
                i += 1
            elif ch == '"':
                state = "code"
        elif state == "comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 1
        i += 1
    raise SystemExit(f"Node &{node_ref}: closing brace not found")

# The Armada 38x pinctrl labels map exactly to the hardware-tested values:
# mdio_pins -> MPP4/5 function ge; ge0_rgmii_pins -> MPP6-17 function ge0.
s = add_default_pinctrl(s, "mdio", "mdio_pins")
s = add_default_pinctrl(s, "eth0", "ge0_rgmii_pins")

# Align the U-Boot DSA CPU conduit with the one used by OpenWrt on Shelby:
# GE0 / ethernet@70000 -> RGMII-ID -> MV88E6176 port 6. The physical
# front-panel mapping (ports 0..4) remains untouched.
def find_braced_block(text, token, start_at=0):
    start = text.find(token, start_at)
    if start < 0:
        raise SystemExit(f"DTS block not found: {token}")
    brace = text.find("{", start + len(token))
    if brace < 0:
        raise SystemExit(f"Opening brace not found: {token}")
    depth = 0
    state = "code"
    i = brace
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if state == "code":
            if ch == '"':
                state = "string"
            elif ch == "/" and nxt == "*":
                state = "comment"
                i += 1
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return start, i + 1
        elif state == "string":
            if ch == "\\":
                i += 1
            elif ch == '"':
                state = "code"
        elif state == "comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 1
        i += 1
    raise SystemExit(f"Closing brace not found: {token}")

eth2_start, eth2_end = find_braced_block(s, "&eth2 {")
eth2_block = s[eth2_start:eth2_end]
if len(re.findall(r'(?m)^\s*status\s*=\s*"okay";', eth2_block)) != 1:
    raise SystemExit("&eth2: expected exactly one status=okay property")
eth2_block = re.sub(
    r'(?m)^(\s*status\s*=\s*)"okay";',
    r'\1"disabled";',
    eth2_block,
    count=1,
)
s = s[:eth2_start] + eth2_block + s[eth2_end:]

switch_start, switch_end = find_braced_block(s, "ethernet-switch@0 {")
port5_start, port5_end = find_braced_block(s, "ethernet-port@5 {", switch_start)
if port5_end > switch_end:
    raise SystemExit("CPU port 5 is not inside the expected switch node")
cpu_block = s[port5_start:port5_end]
required = (
    r'(?m)^\s*reg\s*=\s*<5>;',
    r'(?m)^\s*phy-mode\s*=\s*"sgmii";',
    r'(?m)^\s*ethernet\s*=\s*<&eth2>;',
)
for pattern in required:
    if len(re.findall(pattern, cpu_block)) != 1:
        raise SystemExit(f"Unexpected upstream CPU-port pattern: {pattern}")
cpu_block = cpu_block.replace("ethernet-port@5", "ethernet-port@6", 1)
cpu_block = re.sub(r'(?m)^(\s*reg\s*=\s*)<5>;', r'\1<6>;', cpu_block, count=1)
cpu_block = re.sub(
    r'(?m)^(\s*phy-mode\s*=\s*)"sgmii";',
    r'\1"rgmii-id";',
    cpu_block,
    count=1,
)
cpu_block = re.sub(
    r'(?m)^(\s*ethernet\s*=\s*)<&eth2>;',
    r'\1<&eth0>;',
    cpu_block,
    count=1,
)
s = s[:port5_start] + cpu_block + s[port5_end:]

# U-Boot DSA requires one PHY object per front-panel port. The switch
# driver exposes its internal PHY MDIO bus through a child named "mdio".
switch_anchor = "\t\treg = <0>;\n\n\t\tethernet-ports {"
if switch_anchor not in s:
    raise SystemExit("Expected switch block not found")
internal_mdio = (
    "\t\treg = <0>;\n\n"
    "\t\tmdio {\n"
    "\t\t\t#address-cells = <1>;\n"
    "\t\t\t#size-cells = <0>;\n\n"
    "\t\t\tswphy0: ethernet-phy@0 { reg = <0>; };\n"
    "\t\t\tswphy1: ethernet-phy@1 { reg = <1>; };\n"
    "\t\t\tswphy2: ethernet-phy@2 { reg = <2>; };\n"
    "\t\t\tswphy3: ethernet-phy@3 { reg = <3>; };\n"
    "\t\t\tswphy4: ethernet-phy@4 { reg = <4>; };\n"
    "\t\t};\n\n"
    "\t\tethernet-ports {"
)
s = s.replace(switch_anchor, internal_mdio, 1)
labels = ("lan4", "lan3", "lan2", "lan1", "wan")
for port, label in enumerate(labels):
    old_port = (
        f"\t\t\tethernet-port@{port} {{\n"
        f"\t\t\t\treg = <{port}>;\n"
        f"\t\t\t\tlabel = \"{label}\";\n"
        "\t\t\t};"
    )
    new_port = (
        f"\t\t\tethernet-port@{port} {{\n"
        f"\t\t\t\treg = <{port}>;\n"
        f"\t\t\t\tlabel = \"{label}\";\n"
        "\t\t\t\tphy-mode = \"internal\";\n"
        f"\t\t\t\tphy-handle = <&swphy{port}>;\n"
        "\t\t\t};"
    )
    if old_port not in s:
        raise SystemExit(f"Expected DSA port {port} not found")
    s = s.replace(old_port, new_port, 1)
p.write_text(s)
PY

python3 - "$LINKSYS_DTSI" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
checks = {
    '&mdio': ('pinctrl-names = "default";', 'pinctrl-0 = <&mdio_pins>;'),
    '&eth0': ('pinctrl-names = "default";', 'pinctrl-0 = <&ge0_rgmii_pins>;'),
}
for node, props in checks.items():
    start = s.find(node + ' {')
    if start < 0:
        raise SystemExit(f'{node}: node missing after transformation')
    end = s.find('\n};', start)
    if end < 0:
        raise SystemExit(f'{node}: node end missing after transformation')
    block = s[start:end]
    for prop in props:
        if block.count(prop) != 1:
            raise SystemExit(f'{node}: expected property exactly once: {prop}')

eth2_start = s.find('&eth2 {')
eth2_end = s.find('\n};', eth2_start)
eth2_block = s[eth2_start:eth2_end]
if 'status = "disabled";' not in eth2_block:
    raise SystemExit('&eth2 must be disabled in the U-Boot Device Tree')

cpu_start = s.find('ethernet-port@6 {')
cpu_end = s.find('\n\t\t\t};', cpu_start)
if cpu_start < 0 or cpu_end < 0:
    raise SystemExit('CPU-port 6 block is missing or incomplete')
cpu_block = s[cpu_start:cpu_end]
mapping = (
    'reg = <6>;',
    'phy-mode = "rgmii-id";',
    'ethernet = <&eth0>;',
)
for marker in mapping:
    if cpu_block.count(marker) != 1:
        raise SystemExit(f'CPU-port 6: expected property exactly once: {marker}')
if 'ethernet-port@5 {' in s or 'ethernet = <&eth2>;' in s:
    raise SystemExit('Unexpected CPU-port 5 / GE2 mapping')
PY

say "Excluding the mvtwsi driver from SPL (I2C only in U-Boot proper)"
python3 - "$I2C_MAKEFILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "obj-$(CONFIG_SYS_I2C_MVTWSI) += mvtwsi.o\n"
new = (
    "# WRT1900ACSv2: I2C is not needed before U-Boot proper.\n"
    "# Use a phase-aware symbol: omit mvtwsi from SPL and keep it in\n"
    "# U-Boot proper, where DM_I2C is enabled.\n"
    "obj-$(CONFIG_$(PHASE_)SYS_I2C_MVTWSI) += mvtwsi.o\n"
)
if old not in s:
    raise SystemExit("Expected mvtwsi line not found in drivers/i2c/Makefile")
s = s.replace(old, new, 1)
p.write_text(s)
PY

say "Applying the MDIO/DSA fix and MV88E6176 handoff"
# Prevent the generic MDIO PHY binder from claiming the DSA switch node.
# The exact v2026.07 commit is pinned above. `git apply --check` aborts before
# touching the tree if any source context differs.
git -C "$SRC" apply --check "$MDIO_DSA_PATCH"
git -C "$SRC" apply "$MDIO_DSA_PATCH"

say "Making DSA/MV88E6176 probing idempotent"
python3 - "$DSA_UCLASS" "$MV88E_DRIVER" <<'PY'
from pathlib import Path
import sys

dsa = Path(sys.argv[1])
mv = Path(sys.argv[2])

def replace_c_function(text, signature, replacement):
    """Replace one C function by locating matching braces."""
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"function signature not found: {signature}")
    brace = text.find("{", start + len(signature))
    if brace < 0:
        raise SystemExit(f"opening brace not found: {signature}")

    depth = 0
    i = brace
    state = "code"
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if state == "code":
            if ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == "/" and nxt == "*":
                state = "block_comment"
                i += 1
            elif ch == "/" and nxt == "/":
                state = "line_comment"
                i += 1
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[:start] + replacement.rstrip() + text[i + 1:]
        elif state == "string":
            if ch == "\\":
                i += 1
            elif ch == '"':
                state = "code"
        elif state == "char":
            if ch == "\\":
                i += 1
            elif ch == "'":
                state = "code"
        elif state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 1
        elif state == "line_comment":
            if ch == "\n":
                state = "code"
        i += 1
    raise SystemExit(f"closing brace not found: {signature}")

s = dsa.read_text()
replacement = """static int dsa_pre_probe(struct udevice *dev)
{
	struct dsa_pdata *pdata = dev_get_uclass_plat(dev);
	struct dsa_priv *priv = dev_get_uclass_priv(dev);
	int err;

	priv->num_ports = pdata->num_ports;
	priv->cpu_port = pdata->cpu_port;

	/* A failed switch probe may be retried by each DSA port. */
	if (!priv->cpu_port_fixed_phy) {
		priv->cpu_port_fixed_phy = fixed_phy_create(pdata->cpu_port_node);
		if (!priv->cpu_port_fixed_phy) {
			dev_err(dev, "Failed to register fixed-link for CPU port\\n");
			return -ENOMEM;
		}
	}

	if (!priv->master_dev) {
		err = uclass_get_device_by_ofnode(UCLASS_ETH, pdata->master_node,
						  &priv->master_dev);
		if (err) {
			dev_err(dev, "Failed to resolve DSA master Ethernet: %d\\n", err);
			return err;
		}
	}

	return 0;
}
"""
s = replace_c_function(s, "static int dsa_pre_probe(struct udevice *dev)", replacement)
dsa.write_text(s)

s = mv.read_text()
new_func = """/* bind and probe the switch mdio exactly once */
static int mv88e6xxx_probe_mdio(struct udevice *dev)
{
	struct udevice *mdev;
	const char *name;
	o fnode node;
	int ret;

	node = dev_read_subnode(dev, \"mdio\");
	if (!ofnode_valid(node))
		return 0;
	name = ofnode_get_name(node);

	/* Switch probing can be retried by every DSA front port. Reuse the
	 * already-bound child instead of leaking another MDIO bus each time.
	 */
	for (device_find_first_child(dev, &mdev); mdev;
	     device_find_next_child(&mdev)) {
		if (!ofnode_equal(dev_ofnode(mdev), node))
			continue;
		ret = device_probe(mdev);
		if (ret)
			dev_err(dev, \"failed to re-probe %s: %d\\n\", name, ret);
		return ret;
	}

	ret = device_bind_driver_to_node(dev, \"mv88e6xxx_mdio\",
					 name, node, &mdev);
	if (ret) {
		dev_err(dev, \"failed to bind %s: %d\\n\", name, ret);
		return ret;
	}

	ret = device_probe(mdev);
	if (ret)
		dev_err(dev, \"failed to probe %s: %d\\n\", name, ret);

	return ret;
}
""".replace('o fnode', 'ofnode')
s = replace_c_function(s, "static int mv88e6xxx_probe_mdio(struct udevice *dev)", new_func)

# Keep the DSA fixed-PHY and switch MDIO-child creation idempotent.
# Do not alter mv88e6xxx_probe(); the pinned upstream implementation is used.
mv.write_text(s)
PY

say "Validating intermediate MDIO/DSA changes"
git -C "$SRC" diff --check
python3 - "$DSA_UCLASS" "$MDIO_UCLASS" "$MV88E_DRIVER" <<'PY'
from pathlib import Path
import sys
checks = {
    Path(sys.argv[1]): [
        "static int dsa_pre_probe(struct udevice *dev)",
        "A failed switch probe may be retried by each DSA port.",
    ],
    Path(sys.argv[2]): [
        "static int mdio_bind_phy_nodes(struct udevice *mdio_dev)",
        "skipping DSA switch node during generic PHY binding",
    ],
    Path(sys.argv[3]): [
        "static int mv88e6xxx_probe_mdio(struct udevice *dev)",
        "failed to re-probe",
    ],
}
for path, markers in checks.items():
    text = path.read_text()
    for marker in markers:
        if text.count(marker) != 1:
            raise SystemExit(f"{path}: expected exactly one marker: {marker!r}")
PY

say "Validating the GE0 / RGMII-ID / port-6 network mapping"
grep -q 'ethernet-port@6 {' "$LINKSYS_DTSI" || \
    die "DSA CPU port 6 is missing"
grep -q 'ethernet = <&eth0>;' "$LINKSYS_DTSI" || \
    die "The DSA CPU port is not connected to GE0"
grep -q 'phy-mode = "rgmii-id";' "$LINKSYS_DTSI" || \
    die "RGMII-ID mode is missing"
! grep -q 'ethernet-port@5 {' "$LINKSYS_DTSI" || \
    die "CPU port 5 must not be present"
grep -q 'GE0/RGMII-ID CPU port 6 primed' "$BOARD_FILE" || \
    die "CPU-port 6 hardware priming is missing"

say "Keeping upstream cmd/button.c; robust diagnostics are provided by 'linksys buttons'"
# Do not probe devices while using uclass_find_*(); it caused a data abort on
# this platform. The upstream command remains non-destructive.

say "Adding Winbond W29N01HV support and NAND diagnostics"
python3 - "$NAND_DRIVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

needle = "\t{ 0xda98,  8,  8, &timing[4] },\n"
replacement = needle + "\t/* Winbond W29N01HV: manufacturer 0xef, device 0xf1, x8. */\n\t{ 0xf1ef,  8,  8, &timing[3] },\n"
if needle not in s:
    raise SystemExit("Unexpected builtin_flash_types table")
s = s.replace(needle, replacement, 1)

old_decl = "\tint mode, id, ntypes, i;\n\n\tmode = onfi_get_async_timing_mode(chip);\n"
new_decl = "\tint mode, id, ntypes, i, j;\n\tu8 raw_id[READ_ID_BYTES];\n\n\tchip->cmdfunc(mtd, NAND_CMD_READID, 0x00, -1);\n\tprintf(\"pxa3xx NAND raw ID:\");\n\tfor (j = 0; j < READ_ID_BYTES; j++) {\n\t\traw_id[j] = chip->read_byte(mtd);\n\t\tprintf(\" %02x\", raw_id[j]);\n\t}\n\tputc('\\n');\n\n\tmode = onfi_get_async_timing_mode(chip);\n"
if old_decl not in s:
    raise SystemExit("Unexpected pxa3xx_nand_init_timings declaration")
s = s.replace(old_decl, new_decl, 1)

old_read = "\t\tchip->cmdfunc(mtd, NAND_CMD_READID, 0x00, -1);\n\n\t\tid = chip->read_byte(mtd);\n\t\tid |= chip->read_byte(mtd) << 0x8;\n"
new_read = "\t\tid = raw_id[0];\n\t\tid |= raw_id[1] << 8;\n"
if old_read not in s:
    raise SystemExit("Unexpected fallback READID sequence")
s = s.replace(old_read, new_read, 1)

s = s.replace(
    'dev_err(mtd->dev, "Error: timings not found\\n");',
    'dev_err(mtd->dev, "Error: timings not found for NAND ID 0x%04x\\n", id);',
    1,
)

old_timeout = "\t\t\tif (get_timer(ts) > CHIP_DELAY_TIMEOUT) {\n\t\t\t\tdev_err(mtd->dev, \"Ready timeout!!!\\n\");\n\t\t\t\treturn NAND_STATUS_FAIL;\n\t\t\t}\n"
new_timeout = "\t\t\tif (get_timer(ts) > CHIP_DELAY_TIMEOUT) {\n\t\t\t\tdev_err(mtd->dev,\n\t\t\t\t\t\"Ready timeout: NDSR=%08x NDCR=%08x NDTR0=%08x NDTR1=%08x\\n\",\n\t\t\t\t\tnand_readl(info, NDSR), nand_readl(info, NDCR),\n\t\t\t\t\tnand_readl(info, NDTR0CS0), nand_readl(info, NDTR1CS0));\n\t\t\t\treturn NAND_STATUS_FAIL;\n\t\t\t}\n"
if old_timeout not in s:
    raise SystemExit("Expected Ready-timeout block not found")
s = s.replace(old_timeout, new_timeout, 1)
p.write_text(s)
PY

say "Installing the safety interlock for destructive NAND commands"
python3 - "$NAND_CMD" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

# Add env access if not already included by this command file.
include_anchor = '#include <command.h>\n'
if '#include <env.h>\n' not in s:
    if include_anchor not in s:
        raise SystemExit("command.h include not found")
    s = s.replace(include_anchor, include_anchor + '#include <env.h>\n', 1)

needle = "\tcmd = argv[1];\n\n\t/* Only \"dump\" is repeatable. */\n"
replacement = r'''	cmd = argv[1];

	/*
	 * Safety interlock. Read-only NAND commands remain available. Any
	 * destructive command requires a deliberate one-boot token. The board
	 * code clears the token at every reset.
	 */
	if (!strncmp(cmd, "write", 5) || !strncmp(cmd, "erase", 5) ||
	    !strcmp(cmd, "scrub") || !strcmp(cmd, "markbad") ||
	    !strcmp(cmd, "biterr") || !strcmp(cmd, "lock") ||
	    !strcmp(cmd, "unlock")) {
		const char *token = env_get("allow_nand_write");

		if (!token || strcmp(token, "WRT1900ACSV2")) {
			printf("NAND write guard: 'nand %s' blocked.\n", cmd);
			puts("For this boot only: setenv allow_nand_write WRT1900ACSV2\n");
			return CMD_RET_FAILURE;
		}
	}

	/* Only "dump" is repeatable. */
'''
if needle not in s:
    raise SystemExit("Unexpected do_nand insertion point")
s = s.replace(needle, replacement, 1)
p.write_text(s)
PY

say "Final validation of all source changes"
git -C "$SRC" diff --check
grep -q 'static void linksys_network_pinmux_apply(bool verbose)' "$BOARD_FILE" || \
    die "The board-level network pinmux fix is missing"
grep -q '0x11110000U' "$BOARD_FILE" || \
    die "The MPP4-7 configuration is missing"
grep -q '0x11111111U' "$BOARD_FILE" || \
    die "The MPP8-15 configuration is missing"
grep -q '0x00000011U' "$BOARD_FILE" || \
    die "The MPP16-17 configuration is missing"

CFG="$SRC/scripts/config"

configure_common() {
    local build="$1"
    local ident="$2"
    local prompt="$3"

    rm -rf "$build"
    make -C "$SRC" O="$build" CROSS_COMPILE="$CROSS_COMPILE" db-88f6820-gp_defconfig

    "$CFG" --file "$build/.config" \
        --enable TARGET_DB_88F6820_GP \
        --disable DDR_IMMUTABLE_DEBUG_SETTINGS \
        --disable DDR_RESET_ON_TRAINING_FAILURE \
        --enable OF_UPSTREAM \
        --set-str DEFAULT_DEVICE_TREE "marvell/armada-385-linksys-shelby" \
        --set-str ENV_SOURCE_FILE "wrt1900acsv2" \
        --set-str IDENT_STRING " $ident" \
        --set-str SYS_PROMPT "$prompt" \
        --set-val BOOTDELAY 3 \
        --enable USE_PREBOOT \
        --enable BOARD_LATE_INIT \
        --enable ENV_OVERWRITE \
        --enable BOOTCOUNT_LIMIT \
        --enable BOOTCOUNT_ENV \
        --set-val BOOTCOUNT_BOOTLIMIT 3 \
        --enable MTD \
        --enable MTD_PARTITIONS \
        --enable CMD_MTDPARTS \
        --enable MTD_RAW_NAND \
        --enable NAND_PXA3XX \
        --enable CMD_NAND \
        --enable CMD_MTD \
        --disable SYS_NAND_USE_FLASH_BBT \
        --enable PINCTRL \
        --enable PINCTRL_ARMADA_38X \
        --enable CMD_DM \
        --enable CMD_FDT \
        --enable CMD_PINMUX \
        --enable CMD_MEMORY \
        --enable CMD_CRC32 \
        --enable CMD_HASH \
        --enable SHA256 \
        --enable CMD_BOOTM \
        --enable CMD_IMI \
        --enable LEGACY_IMAGE_FORMAT \
        --enable SUPPORT_PASSING_ATAGS \
        --enable SETUP_MEMORY_TAGS \
        --enable CMDLINE_TAG \
        --enable OF_LIBFDT \
        --enable CMDLINE \
        --enable HUSH_PARSER \
        --enable HUSH_OLD_PARSER \
        --enable CMD_RUN \
        --enable CMD_ITEST \
        --enable CMD_SETEXPR \
        --enable PCI \
        --enable PCI_MVEBU \
        --enable CMD_PCI \
        --enable AHCI \
        --enable AHCI_GENERIC \
        --enable SCSI \
        --enable CMD_SCSI \
        --enable USB \
        --enable USB_EHCI_HCD \
        --enable USB_XHCI_HCD \
        --enable USB_XHCI_MVEBU \
        --enable USB_STORAGE \
        --enable CMD_USB \
        --enable CMD_MMC \
        --enable I2C \
        --enable DM_I2C \
        --disable SYS_I2C_LEGACY \
        --disable SPL_SYS_I2C_LEGACY \
        --disable SPL_DM_I2C \
        --enable SYS_I2C_MVTWSI \
        --enable I2C_SET_DEFAULT_BUS_NUM \
        --set-val I2C_DEFAULT_BUS_NUMBER 0 \
        --enable CMD_I2C \
        --enable PHY_GIGE \
        --enable PHY_FIXED \
        --enable PHY_MARVELL \
        --enable MVNETA \
        --enable MVMDIO \
        --enable MII \
        --enable DM_MDIO \
        --enable DM_ETH_PHY \
        --enable DM_DSA \
        --enable MV88E6XXX \
        --enable CMD_MII \
        --enable CMD_DHCP \
        --enable CMD_PING \
        --enable CMD_TFTPPUT \
        --enable CMD_TFTPBOOT \
        --enable CMD_NET \
        --enable DM_GPIO \
        --enable BUTTON \
        --enable BUTTON_GPIO \
        --enable CMD_BUTTON \
        --enable LED \
        --enable LED_GPIO \
        --enable CMD_LED \
        --enable CMD_EXT2 \
        --enable CMD_EXT4 \
        --enable CMD_FAT \
        --enable FAT_WRITE \
        --enable CMD_FS_GENERIC \
        --enable EFI_PARTITION \
        --enable DEBUG_UART_ANNOUNCE \
        --set-val DEBUG_UART_CLOCK 200000000
}

# Safety check: on Armada 38x board_early_init_f() runs before the SPL
# internal-register translation offset is installed. Never access 0xf1xxxxxx
# registers from this hook or kwboot will stop after the KWB header.
if sed -n '/int board_early_init_f(void)/,/^}/p' "$BOARD_FILE" | grep -Eq 'readl|writel|0xf1[0-9a-fA-F]+'; then
    die "Forbidden register access in board_early_init_f (breaks A38x kwboot)"
fi

build_profile() {
    local profile="$1"
    local bootdev="$2"
    local env_backend="$3"
    local ident="$4"
    local prompt="$5"
    local build="$WORKDIR/build-$profile"
    local out_image="$OUT/u-boot-wrt1900acsv2-v${PROJECT_VERSION}-$profile-${UBOOT_TAG}.kwb"

    say "Configuring profile $profile"
    configure_common "$build" "$ident" "$prompt"

    "$CFG" --file "$build/.config" \
        --disable MVEBU_SPL_BOOT_DEVICE_SPI \
        --disable MVEBU_SPL_BOOT_DEVICE_NAND \
        --disable MVEBU_SPL_BOOT_DEVICE_MMC \
        --disable MVEBU_SPL_BOOT_DEVICE_SATA \
        --disable MVEBU_SPL_BOOT_DEVICE_PEX \
        --disable MVEBU_SPL_BOOT_DEVICE_UART

    case "$bootdev" in
        uart) "$CFG" --file "$build/.config" --enable MVEBU_SPL_BOOT_DEVICE_UART ;;
        nand)
            "$CFG" --file "$build/.config" \
                --enable MVEBU_SPL_BOOT_DEVICE_NAND \
                --set-val MVEBU_SPL_NAND_BADBLK_LOCATION 0x0
            ;;
        *) die "Unknown boot device: $bootdev" ;;
    esac

    case "$env_backend" in
        nowhere)
            "$CFG" --file "$build/.config" \
                --enable ENV_IS_NOWHERE \
                --disable ENV_IS_IN_NAND \
                --disable CMD_SAVEENV
            ;;
        nand)
            "$CFG" --file "$build/.config" \
                --disable ENV_IS_NOWHERE \
                --enable ENV_IS_IN_NAND \
                --enable CMD_SAVEENV \
                --set-val ENV_OFFSET 0x00200000 \
                --set-val ENV_SIZE 0x00020000 \
                --set-val ENV_RANGE 0x00040000
            ;;
        *) die "Unknown environment backend: $env_backend" ;;
    esac

    # These Kconfig symbols describe the physical NAND used by the SPL and
    # full U-Boot drivers. They are hex symbols, so keep explicit 0x prefixes.
    # Upstream kwbimage initially copies them into the KWB container; the final
    # NAND image is post-processed below to match Linksys' BootROM profile.
    "$CFG" --file "$build/.config" \
        --set-val SYS_NAND_PAGE_SIZE 0x800 \
        --set-val SYS_NAND_BLOCK_SIZE 0x20000

    # OOB size is not consumed by the MVEBU KWB header and its Kconfig
    # dependency may be absent for this profile; keep it best-effort only.
    "$CFG" --file "$build/.config" \
        --set-val SYS_NAND_OOBSIZE 0x40 || true

    # olddefconfig must be completely non-interactive. Redirecting stdin makes
    # any forgotten Kconfig symbol fail instead of silently blocking the build.
    make -C "$SRC" O="$build" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig </dev/null

    if [[ "$bootdev" == "nand" ]]; then
        grep -qx 'CONFIG_SYS_NAND_PAGE_SIZE=0x800' "$build/.config" || \
            die "Profile $profile encodes an invalid NAND page size (expected 0x800)"
        grep -qx 'CONFIG_SYS_NAND_BLOCK_SIZE=0x20000' "$build/.config" || \
            die "Profile $profile encodes an invalid NAND block size (expected 0x20000)"
    fi

    grep -qx 'CONFIG_SUPPORT_PASSING_ATAGS=y' "$build/.config" || \
        die "Profile $profile does not support ATAGS boot for legacy kernels"
    grep -qx 'CONFIG_CMDLINE_TAG=y' "$build/.config" || \
        die "Profile $profile does not pass the command line through ATAGS"
    grep -qx 'CONFIG_HUSH_PARSER=y' "$build/.config" || \
        die "Profile $profile does not include the Hush shell"
    grep -qx 'CONFIG_CMD_RUN=y' "$build/.config" || \
        die "Profile $profile does not include the run command"
    grep -qx 'CONFIG_HUSH_OLD_PARSER=y' "$build/.config" || \
        die "Profile $profile does not use the stable Hush parser"
    grep -qx 'CONFIG_DM_I2C=y' "$build/.config" || \
        die "Profile $profile does not use DM_I2C"
    grep -qx 'CONFIG_SYS_I2C_MVTWSI=y' "$build/.config" || \
        die "Profile $profile does not include the mvtwsi driver"
    if grep -qx 'CONFIG_SYS_I2C_LEGACY=y' "$build/.config"; then
        die "Profile $profile still enables the legacy I2C stack"
    fi
    grep -qx 'CONFIG_PHY_FIXED=y' "$build/.config" || \
        die "Profile $profile does not include the fixed PHY support required by DSA"
    grep -qx 'CONFIG_DM_ETH_PHY=y' "$build/.config" || \
        die "Profile $profile lost DM_ETH_PHY"
    grep -qx 'CONFIG_DM_DSA=y' "$build/.config" || \
        die "Profile $profile lost DM_DSA"
    grep -qx 'CONFIG_MV88E6XXX=y' "$build/.config" || \
        die "Profile $profile lost the MV88E6XXX driver"

    grep -qx 'CONFIG_TARGET_DB_88F6820_GP=y' "$build/.config" || \
        die "Profile $profile lost TARGET_DB_88F6820_GP"
    if [[ "$bootdev" == "uart" ]]; then
        grep -qx 'CONFIG_MVEBU_SPL_BOOT_DEVICE_UART=y' "$build/.config" || \
            die "Profile $profile is not configured for UART"
    else
        grep -qx 'CONFIG_MVEBU_SPL_BOOT_DEVICE_NAND=y' "$build/.config" || \
            die "Profile $profile is not configured for NAND"
        grep -Eq '^CONFIG_MVEBU_SPL_NAND_BADBLK_LOCATION=(0x)?0$' "$build/.config" || \
            die "Profile $profile does not use the SLC BBI=0 marker"
    fi

    say "Critical options ($profile)"
    grep -E '^(CONFIG_(TARGET_DB_88F6820_GP|DDR_IMMUTABLE_DEBUG_SETTINGS|DDR_RESET_ON_TRAINING_FAILURE|MVEBU_SPL_BOOT_DEVICE_(UART|NAND)|MVEBU_SPL_NAND_BADBLK_LOCATION|DEFAULT_DEVICE_TREE|ENV_SOURCE_FILE|ENV_IS_NOWHERE|ENV_IS_IN_NAND|ENV_OFFSET|ENV_SIZE|ENV_RANGE|NAND_PXA3XX|CMD_MTDPARTS|BOOTCOUNT_BOOTLIMIT|MVNETA|MV88E6XXX|DM_DSA|DM_ETH_PHY|PHY_FIXED|PHY_MARVELL|HUSH_PARSER|HUSH_OLD_PARSER|CMD_RUN|BOARD_LATE_INIT|SUPPORT_PASSING_ATAGS|CMDLINE_TAG|SETUP_MEMORY_TAGS|DM_I2C|SYS_I2C_MVTWSI|SYS_I2C_LEGACY))=' "$build/.config" || true

    say "Building profile $profile"
    make -C "$SRC" O="$build" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"

    [[ ! -e "$build/spl/drivers/i2c/mvtwsi.o" ]] || \
        die "Profile $profile still includes mvtwsi in SPL"
    [[ -e "$build/drivers/i2c/mvtwsi.o" ]] || \
        die "Profile $profile did not compile mvtwsi into U-Boot proper"

    [[ -e "$build/net/dsa-uclass.o" ]] || \
        die "Profile $profile did not compile the DSA uclass"
    [[ -e "$build/net/mdio-uclass.o" ]] || \
        die "Profile $profile did not compile the MDIO uclass"
    [[ -e "$build/drivers/net/mv88e6xxx.o" ]] || \
        die "Profile $profile did not compile the MV88E6XXX switch driver"
    grep -q 'failed to re-probe' "$MV88E_DRIVER" || \
        die "The MV88E6XXX MDIO idempotency guard is missing"
    grep -q 'if (!priv->cpu_port_fixed_phy)' "$DSA_UCLASS" || \
        die "The DSA fixed-PHY idempotency guard is missing"
    grep -q 'skipping DSA switch node during generic PHY binding' "$MDIO_UCLASS" || \
        die "The switch exclusion in mdio_bind_phy_nodes is missing"

    [[ -s "$build/u-boot-with-spl.kwb" ]] || die "Missing KWB image for $profile"
    if [[ "$bootdev" == "nand" ]]; then
        grep -Eq '^NAND_PAGE_SIZE[[:space:]]+0x800$' \
            "$build/arch/arm/mach-mvebu/kwbimage.cfg" || \
            die "kwbimage.cfg contains an invalid NAND page size"
        grep -Eq '^NAND_BLKSZ[[:space:]]+0x20000$' \
            "$build/arch/arm/mach-mvebu/kwbimage.cfg" || \
            die "kwbimage.cfg contains an invalid NAND block size"
    fi
    cp "$build/u-boot-with-spl.kwb" "$out_image"
    if [[ "$bootdev" == "nand" ]]; then
        local upstream_image="$OUT/u-boot-wrt1900acsv2-v${PROJECT_VERSION}-$profile-${UBOOT_TAG}-upstream-container.kwb"
        mv "$out_image" "$upstream_image"
        python3 "$KWB_PATCHER" \
            "$upstream_image" "$out_image" --force
        sha256sum "$upstream_image" > "$upstream_image.sha256"
    fi
    cp "$build/.config" "$OUT/config-v${PROJECT_VERSION}-$profile-${UBOOT_TAG}"

    python3 - "$out_image" "$bootdev" <<'PY_KWB'
from pathlib import Path
import sys
path = Path(sys.argv[1])
bootdev = sys.argv[2]
data = path.read_bytes()
if len(data) < 32:
    raise SystemExit(f"KWB file is too small: {path}")
blockid = data[0]
version = data[8]
header_size = (data[9] << 16) | int.from_bytes(data[10:12], 'little')
srcaddr = int.from_bytes(data[12:16], 'little')
expected = 0x69 if bootdev == 'uart' else 0x8b
if blockid != expected:
    raise SystemExit(f"Incorrect KWB block ID for {bootdev}: 0x{blockid:02x}, expected 0x{expected:02x}")
if version != 1 or header_size < 32 or header_size >= len(data):
    raise SystemExit(f"Invalid KWB header: version={version} header=0x{header_size:x} file=0x{len(data):x}")
if bootdev == 'nand':
    page_size = int.from_bytes(data[2:4], 'little')
    block_code = data[0x19]
    bbi = data[0x1a]
    if page_size != 0 or block_code != 4 or bbi != 0:
        raise SystemExit(
            f"Invalid Linksys NAND KWB profile: page=0x{page_size:x} "
            f"block_code=0x{block_code:x} bbi=0x{bbi:x}; "
            "expected page=0 block_code=4 bbi=0"
        )
    if header_size != srcaddr or srcaddr % 0x800:
        raise SystemExit(
            f"Invalid Linksys NAND KWB alignment: header=0x{header_size:x} "
            f"src=0x{srcaddr:x}; expected header == src and 0x800 alignment"
        )
    geom = (
        f" page_field=0x{page_size:x} block_code=0x{block_code:x} "
        f"bbi=0x{bbi:x} linksys_align=0x800"
    )
else:
    geom = ""
print(f"KWB {path.name}: blockid=0x{blockid:02x} version={version} header=0x{header_size:x} src=0x{srcaddr:x} file=0x{len(data):x}{geom}")
PY_KWB

    sha256sum "$out_image" > "$out_image.sha256"

    if [[ -x "$build/tools/mkimage" ]]; then
        "$build/tools/mkimage" -l "$out_image" > "$OUT/mkimage-v${PROJECT_VERSION}-$profile-${UBOOT_TAG}.txt" || true
    fi

    if [[ "$profile" == "recovery-uart" && -x "$build/tools/kwboot" ]]; then
        cp "$build/tools/kwboot" "$OUT/kwboot-${UBOOT_TAG}"
    fi
}

git -C "$SRC" diff --binary > "$OUT/u-boot-source-changes-v${PROJECT_VERSION}-${UBOOT_TAG}.patch"
cat > "$OUT/BUILD-METADATA.txt" <<EOF_META
project_version=$PROJECT_VERSION
uboot_tag=$UBOOT_TAG
uboot_commit=$UBOOT_COMMIT
cross_compile=$CROSS_COMPILE
build_host=$(uname -a)
build_date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_META

build_profile recovery-uart uart nowhere \
    "WRT1900ACS v2 Rev.A00 recovery UART" "WRT1900ACSv2(recovery)> "
build_profile final-uart uart nand \
    "WRT1900ACS v2 Rev.A00 final UART" "WRT1900ACSv2(final-uart)> "
build_profile final-nand nand nand \
    "WRT1900ACS v2 Rev.A00 final NAND" "WRT1900ACSv2(final)> "

say "Results"
ls -lh "$OUT"/*.kwb
sha256sum "$OUT"/*.kwb | tee "$OUT/SHA256SUMS"

cat <<EOF2

U-Boot WRT1900ACS v2 Rev.A00 v${PROJECT_VERSION} produced three images in:
  $OUT

Mandatory order:
  1. recovery-uart (kwboot, RAM-only environment)
  2. final-uart    (kwboot, NAND environment and final scripts)
  3. final-nand    (NAND image, install only after final-uart validation)

Validate the final-uart profile:
  sudo $OUT/kwboot-${UBOOT_TAG} \
    -b $OUT/u-boot-wrt1900acsv2-v${PROJECT_VERSION}-final-uart-${UBOOT_TAG}.kwb \
    -t -B 115200 /dev/ttyUSB0

Mandatory checks before installation:
  printenv bootcmd nandboot altnandboot mtdparts
  linksys status
  nand info
  nand bad
  run nandboot
  # then, after a new kwboot session: run altnandboot

Install U-Boot from a FAT USB drive (file in the root directory):
  usb start
  load usb 0:1 \\${loadaddr} /u-boot-wrt1900acsv2-v${PROJECT_VERSION}-final-nand-${UBOOT_TAG}.kwb
  linksys uboot check \\${loadaddr} \\${filesize}
  setenv allow_nand_write WRT1900ACSV2
  linksys uboot install \\${loadaddr} \\${filesize}

The installer locks itself again after the operation and verifies all readback data.
EOF2
