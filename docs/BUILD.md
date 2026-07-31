# Reproducible build

## Recommended host

Use a Debian or Ubuntu x86-64 host with the ARM EABI cross-compiler. The build
uses `O=` output directories and does not modify the project repository.

```bash
sudo apt install -y git make gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
  bc bison flex libssl-dev libgnutls28-dev pkg-config device-tree-compiler \
  python3 python3-setuptools python3-pyelftools swig u-boot-tools
```

## Pinned upstream source

`build.sh` clones tag `v2026.07` and refuses to continue unless `HEAD` is
exactly `ece349ade2973e220f524ce59e59711cc919263f`. This prevents the board
changes from being applied to a moved tag, another branch, or an unexpected
source revision.

## Build stages

1. Clone or clean the U-Boot source tree.
2. Install the board code and default environment.
3. Adapt the Shelby Device Tree for NAND, MDIO, GE0, and the switch.
4. Apply the minimal MDIO patch to the pinned commit.
5. Apply idempotent DSA/MV88E6xxx structural changes.
6. Add NAND support and protect destructive NAND commands.
7. Generate three build profiles.
8. Compile and verify required objects and Kconfig options.
9. Convert the NAND KWB container to the Linksys BootROM profile.
10. Generate SHA-256 sums, metadata, and the complete upstream-source diff.

## Commands

```bash
make validate
make build
```

Custom build:

```bash
PROJECT_VERSION=7.0.0 \
CROSS_COMPILE=arm-linux-gnueabi- \
JOBS="$(nproc)" \
WORKDIR="$PWD/wrt1900acsv2-uboot-full" \
./build.sh
```

## Profiles

- `recovery-uart` uses `ENV_IS_NOWHERE` and does not include `saveenv`.
- `final-uart` uses the final board code and NAND environment, packaged in an
  UART KWB container for `kwboot` validation.
- `final-nand` uses the post-processed NAND container intended for the Armada
  BootROM.

## Artifacts to retain

Publish the matching `.sha256`, `BUILD-METADATA.txt`, `.config`, and
`u-boot-source-changes-*.patch` with every binary. Do not publish the complete
working directory.
