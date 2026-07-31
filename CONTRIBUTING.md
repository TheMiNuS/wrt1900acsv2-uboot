# Contributing

Contributions are welcome when they remain strictly targeted at the
Linksys WRT1900ACS v2 Rev.A00.

1. Open an issue containing the exact model, hardware revision, complete
   sanitized serial log, and command that was executed.
2. Never publish an unsanitized `devinfo` dump. It contains at least the MAC
   address and serial number.
3. Run `make validate` before every commit.
4. Test an UART image with `kwboot` before any NAND write. Do not propose a
   NAND change without a reproducible recovery procedure.
5. Keep functional changes separate from documentation-only changes.
6. Use LF text files, SPDX headers, and U-Boot coding style for C code.
7. Keep documentation, comments, diagnostics, templates, and user-facing
   messages in English.

A contribution that adds another hardware revision or model must create a
clearly separate port and must not reuse this project's binary images.
