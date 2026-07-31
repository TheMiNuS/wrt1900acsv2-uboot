#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The_MiNuS
"""Convert an upstream U-Boot KWB v1 NAND image to the Linksys/Armada-38x
BootROM profile observed in WRT1900ACS v2 Rev.A00 vendor images.

The transformation is intentionally limited to the KWB container:
  * NAND page-size field = 0
  * NAND block-size code = 4
  * bad-block marker field = 0
  * header and payload source offset are made equal and aligned to 2048 bytes
  * the main-header checksum is recomputed

The binary payload and its 32-bit checksum are not modified.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from pathlib import Path

KWB_NAND_ID = 0x8B
KWB_V1 = 0x01
MAIN_HEADER_SIZE = 0x20
HEADER_CHECKSUM_OFFSET = 0x1F
LINKSYS_HEADER_ALIGN = 0x800
LINKSYS_NAND_PAGE_FIELD = 0x0000
LINKSYS_NAND_BLOCK_CODE = 0x04
LINKSYS_NAND_BBI = 0x00
MAX_HEADER_SIZE = 192 * 1024


class KwbError(ValueError):
    pass


def u24_header_size(data: bytes | bytearray) -> int:
    return (data[9] << 16) | int.from_bytes(data[10:12], "little")


def set_u24_header_size(data: bytearray, value: int) -> None:
    if not 0 <= value <= 0xFFFFFF:
        raise KwbError(f"header size out of range: 0x{value:x}")
    data[9] = (value >> 16) & 0xFF
    data[10:12] = (value & 0xFFFF).to_bytes(2, "little")


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def header_checksum_ok(data: bytes | bytearray, header_size: int) -> bool:
    expected = data[HEADER_CHECKSUM_OFFSET]
    calculated = (sum(data[:header_size]) - expected) & 0xFF
    return calculated == expected


def payload_checksum(data: bytes | bytearray, source: int, block_size: int) -> tuple[int, int]:
    if block_size < 4 or block_size % 4:
        raise KwbError(f"payload block size is not a positive multiple of four: 0x{block_size:x}")
    end = source + block_size
    if source < 0 or end > len(data):
        raise KwbError(
            f"payload outside file: source=0x{source:x} block=0x{block_size:x} file=0x{len(data):x}"
        )
    words = struct.unpack_from(f"<{(block_size - 4) // 4}I", data, source)
    calculated = sum(words) & 0xFFFFFFFF
    expected = int.from_bytes(data[end - 4:end], "little")
    return calculated, expected


def describe(data: bytes | bytearray) -> dict[str, int]:
    if len(data) < MAIN_HEADER_SIZE:
        raise KwbError("file is smaller than a KWB main header")
    return {
        "blockid": data[0],
        "flags": data[1],
        "page": int.from_bytes(data[2:4], "little"),
        "block_size": int.from_bytes(data[4:8], "little"),
        "version": data[8],
        "header_size": u24_header_size(data),
        "source": int.from_bytes(data[12:16], "little"),
        "dest": int.from_bytes(data[16:20], "little"),
        "exec": int.from_bytes(data[20:24], "little"),
        "options": data[24],
        "nand_block_code": data[25],
        "bbi": data[26],
        "ext": data[30],
        "header_checksum": data[31],
        "file_size": len(data),
    }


def validate_input(data: bytes | bytearray) -> dict[str, int]:
    info = describe(data)
    if info["blockid"] != KWB_NAND_ID:
        raise KwbError(f"not a NAND KWB image: block ID 0x{info['blockid']:02x}")
    if info["version"] != KWB_V1:
        raise KwbError(f"unsupported KWB version: {info['version']}")
    header_size = info["header_size"]
    source = info["source"]
    block_size = info["block_size"]
    if not MAIN_HEADER_SIZE <= header_size <= MAX_HEADER_SIZE:
        raise KwbError(f"invalid header size: 0x{header_size:x}")
    if source < header_size or source > len(data):
        raise KwbError(f"invalid source offset: 0x{source:x} for header 0x{header_size:x}")
    if not header_checksum_ok(data, header_size):
        raise KwbError("input KWB header checksum is invalid")
    calculated, expected = payload_checksum(data, source, block_size)
    if calculated != expected:
        raise KwbError(
            f"input payload checksum is invalid: calculated 0x{calculated:08x}, expected 0x{expected:08x}"
        )
    return info


def convert(data: bytes) -> tuple[bytes, dict[str, int], dict[str, int]]:
    before = validate_input(data)
    old_source = before["source"]
    target = align_up(max(before["header_size"], old_source), LINKSYS_HEADER_ALIGN)
    if target > MAX_HEADER_SIZE:
        raise KwbError(
            f"Linksys-aligned header would exceed 192 KiB: 0x{target:x}"
        )

    # Preserve the complete existing header/gap, add zero padding, then move
    # the payload and any trailing bytes as one unchanged byte sequence.
    output = bytearray(data[:old_source])
    output.extend(b"\x00" * (target - old_source))
    output.extend(data[old_source:])

    output[2:4] = LINKSYS_NAND_PAGE_FIELD.to_bytes(2, "little")
    output[25] = LINKSYS_NAND_BLOCK_CODE
    output[26] = LINKSYS_NAND_BBI
    set_u24_header_size(output, target)
    output[12:16] = target.to_bytes(4, "little")

    output[HEADER_CHECKSUM_OFFSET] = 0
    output[HEADER_CHECKSUM_OFFSET] = sum(output[:target]) & 0xFF

    after = validate_input(output)
    if after["header_size"] != after["source"]:
        raise KwbError("internal error: header size and source offset differ")
    if after["source"] % LINKSYS_HEADER_ALIGN:
        raise KwbError("internal error: source offset is not 2 KiB aligned")
    if after["page"] != 0 or after["nand_block_code"] != 4 or after["bbi"] != 0:
        raise KwbError("internal error: Linksys NAND fields were not applied")

    old_payload = data[before["source"]:before["source"] + before["block_size"]]
    new_payload = output[after["source"]:after["source"] + after["block_size"]]
    if old_payload != new_payload:
        raise KwbError("internal error: payload changed during conversion")

    return bytes(output), before, after


def print_info(label: str, info: dict[str, int]) -> None:
    print(
        f"{label}: file=0x{info['file_size']:x}, header=0x{info['header_size']:x}, "
        f"source=0x{info['source']:x}, payload=0x{info['block_size']:x}, "
        f"page=0x{info['page']:x}, block_code=0x{info['nand_block_code']:x}, "
        f"bbi=0x{info['bbi']:x}, checksum=0x{info['header_checksum']:02x}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="upstream NAND .kwb image")
    parser.add_argument("output", type=Path, help="Linksys-compatible NAND .kwb image")
    parser.add_argument(
        "--force", action="store_true", help="overwrite the output file if it already exists"
    )
    args = parser.parse_args()

    if not args.input.is_file():
        parser.error(f"input file does not exist: {args.input}")
    if args.output.exists() and not args.force:
        parser.error(f"output file already exists: {args.output} (use --force)")
    if args.input.resolve() == args.output.resolve():
        parser.error("input and output must be different files")

    try:
        original = args.input.read_bytes()
        converted, before, after = convert(original)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(converted)
    except (OSError, KwbError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print_info("Before", before)
    print_info("After ", after)
    print(f"Payload: unchanged ({before['block_size']} bytes including checksum)")
    print(f"SHA256: {hashlib.sha256(converted).hexdigest()}")
    print(f"Written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
