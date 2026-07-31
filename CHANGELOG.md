# Changelog

## 7.0.0 — 2026-07-30

Initial public release of the WRT1900ACS v2 Rev.A00 port:

- U-Boot v2026.07 pinned to the commit listed in the README;
- DDR3, NAND, environment, and `devinfo` identity initialization;
- Linksys dual-firmware layout and A/B slot selection;
- GE0/RGMII-ID DSA mapping to MV88E6176 CPU port 6;
- user ports 0 through 4 mapped to LAN4, LAN3, LAN2, LAN1, and WAN;
- hardware-validated Linux switch handoff and OpenWrt networking;
- UART and NAND images with protected and verified NAND installation;
- documentation, static tests, OpenWrt integration, and GitHub CI;
- all project documentation, source comments, diagnostics, and templates
  standardized in English.
