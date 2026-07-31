# Ethernet and switch mapping

## Selected topology

```text
Armada 385 GE0 / ethernet@70000
              |
          RGMII-ID
              |
     MV88E6176 CPU port 6
      |    |    |    |    |
      0    1    2    3    4
    LAN4 LAN3 LAN2 LAN1  WAN
```

`ethernet@34000`/GE2 is disabled in the U-Boot Device Tree. The DSA CPU link
is described on port 6, attached to `&eth0`, in `rgmii-id` mode, with a fixed
1 Gbit/s full-duplex link.

## Armada 38x pin multiplexing

- MPP4 and MPP5: MDC/MDIO;
- MPP6 through MPP17: GE0 RGMII;
- all other MPP fields are preserved.

The board code applies these values before MDIO/DSA probing and again during
late initialization. The operation is idempotent.

## Linux handoff

A simple DSA probe resets the switch but does not necessarily enable the CPU
fixed link. The handoff therefore starts the `lan1` DSA interface. The DSA
core enables both the user port and CPU port 6, causing the RGMII-ID delays to
be programmed. The board code then stops only the GE0 master DMA engine; it
does not disable the CPU port before `bootm`.

## MAC addresses

`devinfo` supplies the factory address to `ethaddr`. Variables `eth1addr`
through `eth6addr` are removed before probing. U-Boot DSA ports therefore
inherit the GE0 master MAC address. This is expected and does not bridge LAN
and WAN. OpenWrt later applies its logical network configuration and
interface-specific addresses.

## Expected result

```text
eth0 : ethernet@70000 <factory MAC> active
eth1 : lan4           <master MAC>
eth2 : lan3           <master MAC>
eth3 : lan2           <master MAC>
eth4 : lan1           <master MAC>
eth5 : wan            <master MAC>
```

`mdio list` should display the switch internal MDIO bus and PHY addresses 0
through 4 associated with the five physical ports.
