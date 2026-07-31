# Command reference

## `linksys` command

| Command | Function |
|---|---|
| `linksys status` | Show identity, slot, bootcount, MAC, and NAND lock state |
| `linksys select` | Build the boot script for the selected slot |
| `linksys boot` | Prepare the switch and boot the current slot |
| `linksys fallback` | Switch to the other slot and boot it |
| `linksys buttons` | Read WPS GPIO24 and Reset GPIO29 directly |
| `linksys switch probe` | Probe the switch and prepare its CPU port |
| `linksys switch handoff` | Perform the DSA handoff to Linux |
| `linksys switch skip` | Disable the handoff for the current boot only |
| `linksys switch enable` | Re-enable the handoff in RAM |
| `linksys devinfo show` | Display recognized ASCII fields from `devinfo` |
| `linksys devinfo import` | Import recognized fields without displaying them |
| `linksys env migrate` | Normalize the environment in RAM |
| `linksys env save` | Normalize and save the environment |
| `linksys slot 1|2` | Select a slot in RAM |
| `linksys upgrade 1|2` | Arm a slot trial using bootcount |
| `linksys markgood` | Mark the current slot as good in RAM |
| `linksys uboot check A S` | Validate a KWB image at address A with size S |
| `linksys uboot install A S` | Write and verify the image after unlocking NAND |

## Environment scripts

- `nandboot`, `altnandboot`: boot slots 1 and 2;
- `netboot`, `usbboot`, `sataboot`, `mmcboot`: external recovery paths;
- `backup_uboot`, `backup_uenv`, `backup_senv`, `backup_devinfo`: read critical
  regions into RAM;
- `load_uboot_usb`, `load_uboot_tftp`, `check_uboot`, `install_uboot`: protected
  U-Boot installation helpers;
- `update_pri_image`, `update_alt_image`, `update_both_images`: firmware-write
  helpers, still protected by the NAND write interlock.

## NAND write interlock

Destructive commands require the following one-boot token:

```text
setenv allow_nand_write WRT1900ACSV2
```

The token is cleared at every boot and after the protected installer finishes.
Never run `saveenv` after defining the token.
