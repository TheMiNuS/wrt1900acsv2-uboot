// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Linksys WRT1900ACS v2 Rev.A00 (Shelby) board support.
 *
 * NAND writes are protected by a one-boot interlock. The dedicated
 * installer validates a NAND KWB v1 image, checks the first 2 MiB for bad
 * blocks, writes only the u-boot partition and verifies the complete image.
 */

#include <command.h>
#include <dm.h>
#include <dm/uclass.h>
#include <env.h>
#include <init.h>
#include <net.h>
#include <net/dsa.h>
#include <nand.h>
#include <asm/global_data.h>
#include <asm/io.h>
#include <asm/arch/cpu.h>
#include <linux/ctype.h>
#include <linux/kernel.h>
#include <linux/mtd/mtd.h>
#include <linux/mtd/rawnand.h>
#include <linux/string.h>
#include <../serdes/a38x/high_speed_env_spec.h>
#include "../drivers/ddr/marvell/a38x/ddr3_init.h"

DECLARE_GLOBAL_DATA_PTR;

#define DEVINFO_LOAD_ADDR   0x1d000000UL
#define DEVINFO_OFFSET      0x00900000UL
#define DEVINFO_SIZE        0x00100000UL
#define UBOOT_PART_OFFSET   0x00000000UL
#define UBOOT_PART_SIZE     0x00200000UL
#define UBOOT_VERIFY_ADDR   0x1c000000UL
#define UBOOT_IMAGE_MIN     0x00040000UL
#define UBOOT_IMAGE_MAX     UBOOT_PART_SIZE
#define NAND_WRITE_TOKEN    "WRT1900ACSV2"
#define ENV_SCHEMA          "wrt1900acsv2-v7.0.0"

/* Armada 38x GPIO0 / MPP registers, used only from relocated U-Boot. */
#define MPP_CTRL_0_7        0xf1018000UL
#define MPP_CTRL_8_15       0xf1018004UL
#define MPP_CTRL_16_23      0xf1018008UL
#define MPP_CTRL_24_31      0xf101800cUL
#define GPIO0_IO_CONF       0xf1018104UL
#define GPIO0_DATA_IN       0xf1018110UL
#define BUTTON_WPS_GPIO     24
#define BUTTON_RESET_GPIO   29

/* Armada 38x KWB v1 constants used for the installation safety check. */
#define KWB_NAND_BLOCK_ID   0x8b
#define KWB_V1              0x01

/* Stock RD-NAS / Linksys Armada 385 SerDes topology. */
static struct serdes_map board_serdes_map[] = {
    { SATA0,      SERDES_SPEED_6_GBPS,    SERDES_DEFAULT_MODE, 0, 0 },
    { PEX0,       SERDES_SPEED_5_GBPS,    PEX_ROOT_COMPLEX_X1, 0, 0 },
    { SATA1,      SERDES_SPEED_6_GBPS,    SERDES_DEFAULT_MODE, 0, 0 },
    { USB3_HOST1, SERDES_SPEED_5_GBPS,    SERDES_DEFAULT_MODE, 0, 0 },
    { PEX1,       SERDES_SPEED_5_GBPS,    PEX_ROOT_COMPLEX_X1, 0, 0 },
    { SGMII2,     SERDES_SPEED_1_25_GBPS, SERDES_DEFAULT_MODE, 0, 0 },
};

int hws_board_topology_load(struct serdes_map **serdes_map_array, u8 *count)
{
    *serdes_map_array = board_serdes_map;
    *count = ARRAY_SIZE(board_serdes_map);
    return 0;
}

/*
 * 2 x SK hynix H5TQ2G63FFR-PBC
 * each device: 2 Gbit x16; total: 512 MiB, 32-bit, DDR3-1600 / 800 MHz.
 */
static struct mv_ddr_topology_map board_topology_map = {
    DEBUG_LEVEL_ERROR,
    0x1,
    { { { { 0x1, 0, 0, 0 },
          { 0x1, 0, 0, 0 },
          { 0x1, 0, 0, 0 },
          { 0x1, 0, 0, 0 },
          { 0x1, 0, 0, 0 } },
        SPEED_BIN_DDR_1600K,
        MV_DDR_DEV_WIDTH_16BIT,
        MV_DDR_DIE_CAP_2GBIT,
        MV_DDR_FREQ_800,
        0, 0,
        MV_DDR_TEMP_LOW,
        MV_DDR_TIM_DEFAULT } },
    BUS_MASK_32BIT,
    MV_DDR_CFG_DEFAULT,
    NOT_COMBINED,
    { { 0 } },
    { 0 }
};

struct mv_ddr_topology_map *mv_ddr_topology_map_get(void)
{
    return &board_topology_map;
}

static bool devinfo_extract(const u8 *data, size_t size, const char *key,
                            char *value, size_t value_size)
{
    size_t i = 0;
    size_t key_len = strlen(key);

    while (i < size) {
        size_t start, len, value_len;

        while (i < size && (data[i] < 0x20 || data[i] > 0x7e))
            i++;
        start = i;
        while (i < size && data[i] >= 0x20 && data[i] <= 0x7e)
            i++;
        len = i - start;

        if (len <= key_len + 1)
            continue;
        if (memcmp(data + start, key, key_len) || data[start + key_len] != '=')
            continue;

        value_len = len - key_len - 1;
        if (value_len >= value_size)
            value_len = value_size - 1;
        memcpy(value, data + start + key_len + 1, value_len);
        value[value_len] = '\0';
        return true;
    }

    return false;
}

static int linksys_devinfo_load(void)
{
    return run_commandf("nand read 0x%lx 0x%lx 0x%lx",
                        DEVINFO_LOAD_ADDR, DEVINFO_OFFSET, DEVINFO_SIZE);
}

static void linksys_clear_port_macs(void)
{
    char name[16];
    unsigned int index;

    /*
     * U-Boot numbers the GE0 master as eth0 and the five DSA front ports
     * as eth1..eth5. Clear per-port overrides before Ethernet probing so
     * every DSA port inherits the factory address from the GE0 master.
     */
    for (index = 1; index <= 6; index++) {
        snprintf(name, sizeof(name), "eth%uaddr", index);
        env_set(name, NULL);
    }
}

static int linksys_devinfo_import(bool verbose)
{
    static const struct {
        const char *source;
        const char *target;
    } keys[] = {
        { "hw_mac_addr",      "ethaddr" },
        { "serial_number",    "linksys_serial" },
        { "modelNumber",      "linksys_model" },
        { "hardware_version", "linksys_hw_version" },
        { "cert_region",      "linksys_cert_region" },
        { "region",           "linksys_region" },
    };
    const u8 *data = (const u8 *)(uintptr_t)DEVINFO_LOAD_ADDR;
    char value[128];
    unsigned int i;
    int found = 0;

    if (linksys_devinfo_load()) {
        if (verbose)
            puts("Unable to read devinfo from NAND\n");
        return CMD_RET_FAILURE;
    }

    for (i = 0; i < ARRAY_SIZE(keys); i++) {
        if (!devinfo_extract(data, DEVINFO_SIZE, keys[i].source,
                             value, sizeof(value)))
            continue;

        found++;
        if (verbose)
            printf("%s=%s\n", keys[i].source, value);
        env_set(keys[i].target, value);
    }

    /* DSA front ports inherit the factory MAC from the GE0 master. */
    linksys_clear_port_macs();

    if (!found && verbose)
        puts("No known ASCII key=value field found in devinfo\n");

    return found ? CMD_RET_SUCCESS : CMD_RET_FAILURE;
}

static int linksys_buttons_show(void)
{
    u32 data;

    /* MPP24 and MPP29: function 0 = GPIO. */
    clrbits_le32((void __iomem *)MPP_CTRL_24_31,
                 0x0000000fU | 0x00f00000U);

    /* In MVEBU GPIO, a set IO_CONF bit selects input direction. */
    setbits_le32((void __iomem *)GPIO0_IO_CONF,
                 BIT(BUTTON_WPS_GPIO) | BIT(BUTTON_RESET_GPIO));
    data = readl((void __iomem *)GPIO0_DATA_IN);

    printf("WPS:   %s (GPIO24 raw=%u, active-low)\n",
           data & BIT(BUTTON_WPS_GPIO) ? "released" : "PRESSED",
           !!(data & BIT(BUTTON_WPS_GPIO)));
    printf("Reset: %s (GPIO29 raw=%u, active-low)\n",
           data & BIT(BUTTON_RESET_GPIO) ? "released" : "PRESSED",
           !!(data & BIT(BUTTON_RESET_GPIO)));

    return CMD_RET_SUCCESS;
}

static void set_if_missing(const char *name, const char *value)
{
    if (!env_get(name))
        env_set(name, value);
}

static int linksys_select_slot(void);

/*
 * Normalize the persistent Linksys environment in RAM on every boot. Critical
 * scripts are replaced deliberately because vendor values may contain literal
 * quote characters, for example bootcmd=\"run nandboot\".
 */
static void linksys_env_migrate(bool verbose)
{
    const char *slot = env_get("boot_part");

    env_set("env_schema", ENV_SCHEMA);
    env_set("mtdids", "nand0=armada-nand");
    env_set("mtdparts",
            "mtdparts=armada-nand:2048K(uboot)ro,256K(u_env),"
            "256K(s_env),1m@9m(devinfo),40m@10m(kernel),"
            "34m@16m(rootfs),40m@50m(alt_kernel),"
            "34m@56m(alt_rootfs),80m@10m(ubifs),-@90m(syscfg)");

    env_set("loadaddr", "0x02000000");
    env_set("defaultLoadAddr", "0x02000000");
    env_set("fdtaddr", "0x03000000");
    env_set("priKernAddr", "0x00a00000");
    env_set("priKernSize", "0x00600000");
    env_set("priFwSize", "0x02800000");
    env_set("altKernAddr", "0x03200000");
    env_set("altKernSize", "0x00600000");
    env_set("altFwSize", "0x02800000");

    if (!slot || (strcmp(slot, "1") && strcmp(slot, "2")))
        env_set("boot_part", "1");
    set_if_missing("boot_part_ready", "3");
    env_set("auto_recovery", "modern");
    set_if_missing("upgrade_available", "0");
    if (strcmp(env_get("upgrade_available") ?: "0", "1"))
        env_set("bootcount", "0");
    else
        set_if_missing("bootcount", "0");
    env_set("bootlimit", "3");

    /*
     * Keep the critical boot path independent of shell parsing. Hush remains
     * enabled for recovery/update scripts, but autoboot and fallback use C.
     */
    env_set("set_slot1", "linksys slot 1; linksys select");
    env_set("set_slot2", "linksys slot 2; linksys select");
    env_set("select_slot", "linksys select");
    /*
     * Existing Linksys/OpenWrt uImages contain an appended DTB and use the
     * ARM ATAGS boot path. Keep it as the default while retaining an explicit
     * FDT test path for diagnostics.
     */
    env_set("boot_kernel_atags",
            "iminfo ${loadaddr}; bootm ${loadaddr}");
    env_set("boot_kernel_fdt",
            "iminfo ${loadaddr}; bootm ${loadaddr} - ${fdtcontroladdr}");
    env_set("boot_kernel", "run boot_kernel_atags");
    env_set("nandboot",
            "setenv bootargs console=ttyS0,115200 root=/dev/mtdblock5 ro "
            "rootdelay=1 rootfstype=jffs2 earlyprintk ${mtdparts}; "
            "nand read ${loadaddr} ${priKernAddr} ${priKernSize}; "
            "run boot_kernel");
    env_set("altnandboot",
            "setenv bootargs console=ttyS0,115200 root=/dev/mtdblock7 ro "
            "rootdelay=1 rootfstype=jffs2 earlyprintk ${mtdparts}; "
            "nand read ${loadaddr} ${altKernAddr} ${altKernSize}; "
            "run boot_kernel");
    env_set("bootcmd", "linksys boot");
    env_set("altbootcmd", "linksys fallback");

    set_if_missing("ipaddr", "192.168.1.1");
    set_if_missing("serverip", "192.168.1.254");
    set_if_missing("netmask", "255.255.255.0");
    set_if_missing("autoload", "no");
    env_set("ethprime", "lan1");
    env_set("ethrotate", "no");
    /*
     * The U-Boot DSA topology is aligned with OpenWrt: GE0/RGMII-ID is the
     * master and switch port 6 is the CPU port. Probe and prime that exact
     * path before Linux, while retaining an escape hatch for serial recovery.
     */
    set_if_missing("switch_handoff", "probe");
    linksys_clear_port_macs();
    /* board_late_init() already imports devinfo and repairs MAC values. */
    env_set("preboot", "");
    linksys_select_slot();

    if (verbose)
        printf("Environment normalized in RAM to schema %s\n", ENV_SCHEMA);
}

static int linksys_select_slot(void)
{
    const char *slot = env_get("boot_part");

    if (slot && !strcmp(slot, "2")) {
        env_set("boot_part", "2");
        env_set("selected_nandboot", "altnandboot");
    } else {
        env_set("boot_part", "1");
        env_set("selected_nandboot", "nandboot");
    }

    return CMD_RET_SUCCESS;
}

static void linksys_network_pinmux_apply(bool verbose)
{
    u32 mpp0 = readl((void __iomem *)MPP_CTRL_0_7);
    u32 mpp1 = readl((void __iomem *)MPP_CTRL_8_15);
    u32 mpp2 = readl((void __iomem *)MPP_CTRL_16_23);
    u32 new0 = (mpp0 & 0x0000ffffU) | 0x11110000U;
    u32 new1 = 0x11111111U;
    u32 new2 = (mpp2 & 0xffffff00U) | 0x00000011U;

    /*
     * MPP4/5:  MDC/MDIO (function "ge")
     * MPP6-17: GE0 RGMII (function "ge0")
     *
     * These exact values were validated on WRT1900ACSv2 hardware: without
     * MPP4/5 the MV88E6176 returns -ENODEV; after applying them the DSA
     * probe succeeds. Preserve unrelated MPP0-3 and MPP18-23 fields.
     */
    if (mpp0 != new0)
        writel(new0, (void __iomem *)MPP_CTRL_0_7);
    if (mpp1 != new1)
        writel(new1, (void __iomem *)MPP_CTRL_8_15);
    if (mpp2 != new2)
        writel(new2, (void __iomem *)MPP_CTRL_16_23);

    if (verbose)
        printf("Linksys network pinmux: MPP0=%08x MPP1=%08x MPP2=%08x\n",
               readl((void __iomem *)MPP_CTRL_0_7),
               readl((void __iomem *)MPP_CTRL_8_15),
               readl((void __iomem *)MPP_CTRL_16_23));
}

static int linksys_switch_prepare(bool verbose)
{
    struct udevice *master;
    struct udevice *port;
    struct udevice *sw;
    int ret;

    /* Apply the board MPP setup before the MDIO parent or DSA child probes. */
    linksys_network_pinmux_apply(verbose);

    /*
     * OpenWrt uses GE0 / ethernet@70000 and switch port 6.  The switch-side
     * electrical mode is RGMII, so the U-Boot CPU fixed-link is deliberately
     * described as RGMII-ID. Linux may retain an inherited phy-mode string
     * on the relocated CPU-port node, but the physical GE0 link is RGMII.
     */
    ret = uclass_get_device(UCLASS_DSA, 0, &sw);
    if (ret) {
        printf("Linksys switch handoff: DSA probe failed (%d)\n", ret);
        return ret;
    }

    /*
     * A DSA probe resets the switch but does not enable its CPU fixed-link.
     * Starting one front port invokes port_enable() for both LAN1 and CPU
     * port 6, which programs the RGMII-ID timing and forced 1-Gbit link.
     * Stop only the GE0 master afterwards so no U-Boot DMA rings remain
     * active.  Do not call the DSA port stop path here: Linux will reset and
     * rebuild forwarding, while the switch physical-control timing survives
     * the handoff exactly as it does after the vendor loader.
     */
    master = dsa_get_master(sw);
    if (!master || !eth_get_ops(master)->stop) {
        printf("Linksys switch handoff: GE0 master is incomplete\n");
        return -ENODEV;
    }

    ret = uclass_get_device_by_name(UCLASS_ETH, "lan1", &port);
    if (ret) {
        printf("Linksys switch handoff: unable to probe lan1 (%d)\n", ret);
        return ret;
    }
    if (!eth_get_ops(port)->start) {
        printf("Linksys switch handoff: lan1 has no start operation\n");
        return -ENOSYS;
    }

    ret = eth_get_ops(port)->start(port);
    if (ret) {
        printf("Linksys switch handoff: lan1 start failed (%d)\n", ret);
        return ret;
    }

    /* dsa_port_start() has started GE0; stop only its DMA engine. */
    eth_get_ops(master)->stop(master);

    if (verbose)
        printf("Linksys switch handoff: %s, GE0/RGMII-ID CPU port 6 primed\n",
               sw->name);

    return 0;
}

static int linksys_switch_handoff(bool verbose)
{
    const char *mode = env_get("switch_handoff");

    if (mode && !strcmp(mode, "skip")) {
        if (verbose)
            puts("Linksys switch handoff skipped by environment\n");
        return 0;
    }

    return linksys_switch_prepare(verbose);
}

static int linksys_boot_selected(void)
{
    const char *script;

    linksys_select_slot();
    script = env_get("selected_nandboot");
    if (!script) {
        puts("Unable to select a firmware boot script\n");
        return CMD_RET_FAILURE;
    }

    printf("Booting firmware slot %s using '%s'\n",
           env_get("boot_part") ?: "1", script);

    if (linksys_switch_handoff(true))
        puts("WARNING: switch handoff failed; continuing for serial recovery\n");

    return run_commandf("run %s", script) ? CMD_RET_FAILURE : CMD_RET_SUCCESS;
}

static int linksys_fallback_boot(void)
{
    const char *slot = env_get("boot_part");

    puts("Boot limit exceeded - switching firmware slot\n");
    env_set("boot_part", slot && !strcmp(slot, "1") ? "2" : "1");
    env_set("bootcount", "0");
    env_set("upgrade_available", "0");

    if (env_save()) {
        puts("Unable to save fallback slot in NAND environment\n");
        return CMD_RET_FAILURE;
    }

    return linksys_boot_selected();
}

static u16 get_le16(const u8 *p)
{
    return (u16)p[0] | ((u16)p[1] << 8);
}

static u32 get_le32(const u8 *p)
{
    return (u32)p[0] | ((u32)p[1] << 8) |
           ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static bool kwb_header_checksum_ok(const u8 *image, u32 header_size)
{
    u8 sum = 0;
    u32 i;

    for (i = 0; i < header_size; i++)
        sum += image[i];

    sum -= image[0x1f];
    return sum == image[0x1f];
}

static bool kwb_payload_checksum_ok(const u8 *payload, u32 block_size)
{
    u32 sum = 0, expected, i;

    if (block_size < 4 || (block_size & 3))
        return false;

    for (i = 0; i < block_size - 4; i += 4)
        sum += get_le32(payload + i);

    expected = get_le32(payload + block_size - 4);
    return sum == expected;
}

static int linksys_kwb_check(ulong addr, ulong size, bool verbose)
{
    const u8 *image = (const u8 *)(uintptr_t)addr;
    u16 page_size;
    u32 block_size, header_size, source_offset;

    if (addr < 0x00100000 || addr + size < addr || addr + size > 0x1f000000) {
        puts("Invalid or unsafe RAM address range\n");
        return CMD_RET_FAILURE;
    }
    if (size < UBOOT_IMAGE_MIN || size > UBOOT_IMAGE_MAX) {
        printf("Invalid image size 0x%lx (expected 0x%lx..0x%lx)\n",
               size, UBOOT_IMAGE_MIN, UBOOT_IMAGE_MAX);
        return CMD_RET_FAILURE;
    }
    if (image[0] != KWB_NAND_BLOCK_ID) {
        printf("Not a NAND KWB image: block ID 0x%02x, expected 0x%02x\n",
               image[0], KWB_NAND_BLOCK_ID);
        return CMD_RET_FAILURE;
    }
    if (image[8] != KWB_V1) {
        printf("Unsupported KWB header version 0x%02x, expected 0x%02x\n",
               image[8], KWB_V1);
        return CMD_RET_FAILURE;
    }

    page_size = get_le16(image + 2);
    block_size = get_le32(image + 4);
    header_size = ((u32)image[9] << 16) | get_le16(image + 10);
    source_offset = get_le32(image + 12);

    /*
     * Linksys' Armada-38x BootROM 1.73 vendor image uses page field 0,
     * block code 4 and BBI 0. These are BootROM-container values, not the
     * physical MTD geometry, which is checked separately below.
     */
    if (page_size != 0 || image[0x19] != 4 || image[0x1a] != 0) {
        printf("Unexpected Linksys NAND KWB profile: page=0x%x "
               "block_code=%u BBI=%u (expected 0, 4, 0)\n",
               page_size, image[0x19], image[0x1a]);
        return CMD_RET_FAILURE;
    }
    if (header_size < 32 || header_size > 192 * 1024 ||
        header_size >= size) {
        printf("Invalid KWB header size 0x%x for file size 0x%lx\n",
               header_size, size);
        return CMD_RET_FAILURE;
    }
    if (source_offset != header_size ||
        (source_offset & (2048 - 1)) ||
        source_offset > size ||
        block_size < 4 || (block_size & 3) ||
        source_offset + block_size < source_offset ||
        source_offset + block_size > size) {
        printf("Invalid KWB payload: offset=0x%x size=0x%x file=0x%lx\n",
               source_offset, block_size, size);
        return CMD_RET_FAILURE;
    }
    if (!kwb_header_checksum_ok(image, header_size)) {
        puts("Invalid KWB header checksum\n");
        return CMD_RET_FAILURE;
    }
    if (!kwb_payload_checksum_ok(image + source_offset, block_size)) {
        puts("Invalid KWB payload checksum\n");
        return CMD_RET_FAILURE;
    }

    if (verbose) {
        printf("KWB NAND v1 image accepted\n");
        printf("  load address : 0x%08lx\n", addr);
        printf("  file size    : 0x%08lx (%lu bytes)\n", size, size);
        puts("  NAND profile : Linksys Armada-38x BootROM 1.73\n");
        printf("  page field   : 0x%04x\n", page_size);
        printf("  header/source: 0x%08x (2 KiB aligned)\n", header_size);
        printf("  payload size : 0x%08x\n", block_size);
        puts("  header/payload checksums: OK\n");
    }

    return CMD_RET_SUCCESS;
}

static int linksys_uboot_partition_check(void)
{
    struct mtd_info *mtd = get_nand_dev_by_index(0);
    loff_t off;
    int ret;

    if (!mtd) {
        puts("NAND device 0 is unavailable\n");
        return CMD_RET_FAILURE;
    }
    if (mtd->writesize != 2048 || mtd->erasesize != 131072 ||
        mtd->size != 0x08000000ULL) {
        printf("Unexpected NAND geometry: size=0x%llx page=%u erase=%u\n",
               (unsigned long long)mtd->size,
               mtd->writesize, mtd->erasesize);
        return CMD_RET_FAILURE;
    }

    for (off = UBOOT_PART_OFFSET; off < UBOOT_PART_SIZE;
         off += mtd->erasesize) {
        ret = nand_block_isbad(mtd, off);
        if (ret) {
            printf("Refusing install: bad/reserved block at 0x%08llx\n",
                   (unsigned long long)off);
            return CMD_RET_FAILURE;
        }
    }

    return CMD_RET_SUCCESS;
}

static int linksys_uboot_install(ulong addr, ulong size)
{
    struct mtd_info *mtd = get_nand_dev_by_index(0);
    const void *source = (const void *)(uintptr_t)addr;
    const void *verify = (const void *)(uintptr_t)UBOOT_VERIFY_ADDR;
    const char *token = env_get("allow_nand_write");
    ulong write_size;
    int ret = CMD_RET_FAILURE;

    if (!token || strcmp(token, NAND_WRITE_TOKEN)) {
        puts("Installation locked. For this boot only run:\n");
        printf("  setenv allow_nand_write %s\n", NAND_WRITE_TOKEN);
        return CMD_RET_FAILURE;
    }

    if (linksys_kwb_check(addr, size, true) ||
        linksys_uboot_partition_check())
        goto out_lock;

    if (!mtd) {
        puts("NAND device 0 is unavailable\n");
        goto out_lock;
    }
    write_size = ALIGN(size, mtd->writesize);
    if (write_size > UBOOT_PART_SIZE || addr + write_size < addr ||
        addr + write_size > 0x1f000000) {
        puts("Aligned image size exceeds safe RAM/NAND bounds\n");
        goto out_lock;
    }
    if (write_size != size) {
        memset((void *)(uintptr_t)(addr + size), 0xff, write_size - size);
        printf("Padding image with 0xFF from 0x%08lx to page-aligned 0x%08lx bytes\n",
               size, write_size);
    }

    puts("WARNING: writing the first 2 MiB NAND U-Boot partition.\n");
    puts("Do not remove power until readback verification has completed.\n");

    if (run_commandf("nand erase 0x%lx 0x%lx",
                     UBOOT_PART_OFFSET, UBOOT_PART_SIZE)) {
        puts("U-Boot partition erase failed\n");
        goto out_lock;
    }
    if (run_commandf("nand write 0x%lx 0x%lx 0x%lx",
                     addr, UBOOT_PART_OFFSET, write_size)) {
        puts("U-Boot NAND write failed\n");
        goto out_lock;
    }
    if (run_commandf("nand read 0x%lx 0x%lx 0x%lx",
                     UBOOT_VERIFY_ADDR, UBOOT_PART_OFFSET, write_size)) {
        puts("U-Boot NAND readback failed\n");
        goto out_lock;
    }
    if (memcmp(source, verify, write_size)) {
        puts("FATAL: byte-for-byte verification failed\n");
        goto out_lock;
    }

    puts("U-Boot installation and byte-for-byte verification: OK\n");
    puts("The write interlock is locked again. Use 'reset' when ready.\n");
    ret = CMD_RET_SUCCESS;

out_lock:
    env_set("allow_nand_write", NULL);
    return ret;
}

static int do_linksys(struct cmd_tbl *cmdtp, int flag, int argc,
                      char *const argv[])
{
    if (argc == 2 && !strcmp(argv[1], "status")) {
        printf("env_schema=%s\n", env_get("env_schema") ?: "<unset>");
        printf("boot_part=%s\n", env_get("boot_part") ?: "<unset>");
        printf("boot_part_ready=%s\n",
               env_get("boot_part_ready") ?: "<unset>");
        printf("upgrade_available=%s\n",
               env_get("upgrade_available") ?: "<unset>");
        printf("bootcount=%s\n", env_get("bootcount") ?: "<unset>");
        printf("bootlimit=%s\n", env_get("bootlimit") ?: "<unset>");
        printf("ethaddr=%s\n", env_get("ethaddr") ?: "<unset>");
        printf("model=%s\n", env_get("linksys_model") ?: "<unset>");
        printf("hardware_version=%s\n",
               env_get("linksys_hw_version") ?: "<unset>");
        printf("serial=%s\n", env_get("linksys_serial") ?: "<unset>");
        printf("dsa_port_mac_overrides=%s\n",
               env_get("eth1addr") ? "present" : "none");
        printf("switch_handoff=%s\n",
               env_get("switch_handoff") ?: "probe");
        printf("allow_nand_write=%s\n",
               env_get("allow_nand_write") ?: "<locked>");
        return CMD_RET_SUCCESS;
    }

    if (argc == 2 && !strcmp(argv[1], "select"))
        return linksys_select_slot();

    if (argc == 2 && !strcmp(argv[1], "boot"))
        return linksys_boot_selected();

    if (argc == 2 && !strcmp(argv[1], "fallback"))
        return linksys_fallback_boot();

    if (argc == 2 && !strcmp(argv[1], "buttons"))
        return linksys_buttons_show();

    if (argc == 3 && !strcmp(argv[1], "switch")) {
        if (!strcmp(argv[2], "probe"))
            return linksys_switch_prepare(true) ?
                   CMD_RET_FAILURE : CMD_RET_SUCCESS;
        if (!strcmp(argv[2], "handoff"))
            return linksys_switch_handoff(true) ?
                   CMD_RET_FAILURE : CMD_RET_SUCCESS;
        if (!strcmp(argv[2], "skip")) {
            env_set("switch_handoff", "skip");
            puts("Switch handoff disabled in RAM only\n");
            return CMD_RET_SUCCESS;
        }
        if (!strcmp(argv[2], "enable")) {
            env_set("switch_handoff", "probe");
            puts("Switch handoff enabled in RAM\n");
            return CMD_RET_SUCCESS;
        }
    }

    if (argc == 3 && !strcmp(argv[1], "devinfo")) {
        if (!strcmp(argv[2], "show"))
            return linksys_devinfo_import(true);
        if (!strcmp(argv[2], "import"))
            return linksys_devinfo_import(false);
    }

    if (argc == 3 && !strcmp(argv[1], "env")) {
        if (!strcmp(argv[2], "migrate")) {
            linksys_env_migrate(true);
            return CMD_RET_SUCCESS;
        }
        if (!strcmp(argv[2], "save")) {
            linksys_env_migrate(true);
            return env_save() ? CMD_RET_FAILURE : CMD_RET_SUCCESS;
        }
    }

    if (argc == 3 && !strcmp(argv[1], "slot")) {
        if (!strcmp(argv[2], "1") || !strcmp(argv[2], "2")) {
            env_set("boot_part", argv[2]);
            return linksys_select_slot();
        }
    }

    if (argc == 3 && !strcmp(argv[1], "upgrade")) {
        if (strcmp(argv[2], "1") && strcmp(argv[2], "2"))
            return CMD_RET_USAGE;
        env_set("boot_part", argv[2]);
        env_set("upgrade_available", "1");
        env_set("bootcount", "0");
        puts("Upgrade trial armed in RAM; run 'linksys env save' to persist.\n");
        return CMD_RET_SUCCESS;
    }

    if (argc == 2 && !strcmp(argv[1], "markgood")) {
        env_set("upgrade_available", "0");
        env_set("bootcount", "0");
        env_set("boot_part_ready", "3");
        puts("Current slot marked good in RAM; run 'linksys env save'.\n");
        return CMD_RET_SUCCESS;
    }

    if (argc == 5 && !strcmp(argv[1], "uboot")) {
        ulong addr = simple_strtoul(argv[3], NULL, 16);
        ulong size = simple_strtoul(argv[4], NULL, 16);

        if (!strcmp(argv[2], "check"))
            return linksys_kwb_check(addr, size, true);
        if (!strcmp(argv[2], "install"))
            return linksys_uboot_install(addr, size);
    }

    return CMD_RET_USAGE;
}

U_BOOT_CMD(
    linksys, 5, 0, do_linksys,
    "WRT1900ACS v2 board, recovery and safe installer helpers",
    "status\n"
    "linksys select\n"
    "linksys boot\n"
    "linksys fallback\n"
    "linksys buttons\n"
    "linksys switch probe|handoff|enable|skip\n"
    "linksys devinfo show|import\n"
    "linksys env migrate|save\n"
    "linksys slot 1|2\n"
    "linksys upgrade 1|2\n"
    "linksys markgood\n"
    "linksys uboot check <addr> <size>\n"
    "linksys uboot install <addr> <size>"
);

int board_early_init_f(void)
{
    /*
     * Keep SPL early init free of direct accesses to 0xf1xxxxxx.
     * Armada 38x calls this hook before installing the SPL internal-register
     * translation offset. UART0 is already configured by BootROM and the
     * remaining pinmux groups are applied later by driver-model pinctrl.
     */
    return 0;
}

int board_init(void)
{
    gd->bd->bi_boot_params = mvebu_sdram_bar(0) + 0x100;
    return 0;
}

int board_late_init(void)
{
    /* Never persist an unlocked NAND command line across resets. */
    env_set("allow_nand_write", NULL);

    /*
     * Establish the board network MPP state even when switch_handoff=skip.
     * Driver-model pinctrl carries the same declarations in the DT; this is
     * an idempotent board-level safety net matching the validated registers.
     */
    linksys_network_pinmux_apply(false);

    /* Import board identity, normalize DSA MACs and boot scripts. */
    linksys_devinfo_import(false);
    linksys_env_migrate(false);
    return 0;
}

int checkboard(void)
{
    puts("Board: Linksys WRT1900ACS v2 Rev.A00 (Shelby)\n");
    return 0;
}
