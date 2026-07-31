# Security

Issues that may allow NAND writes outside the intended partition, insufficient
KWB validation, or bypass of the NAND write interlock are considered critical.

Report them through a GitHub issue labeled `security` without attaching a
complete NAND dump. Always remove MAC addresses, serial numbers, certificates,
and calibration data. For an upstream U-Boot vulnerability, also follow the
Das U-Boot security process.

No private key or secret data is required to build this project. The build
script downloads only a public, pinned U-Boot commit.
