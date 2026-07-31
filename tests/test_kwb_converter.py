#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from pathlib import Path
import importlib.util
import sys
import tempfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "patch-kwb-linksys-nand.py"
spec = importlib.util.spec_from_file_location("kwbpatch", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def make_fixture() -> bytes:
    header = bytearray(0x20)
    payload_data = bytes((index * 17 + 3) & 0xFF for index in range(0x100))
    words = [int.from_bytes(payload_data[i:i + 4], "little") for i in range(0, len(payload_data), 4)]
    checksum = (sum(words) & 0xFFFFFFFF).to_bytes(4, "little")
    payload = payload_data + checksum

    header[0] = module.KWB_NAND_ID
    header[2:4] = (0x800).to_bytes(2, "little")
    header[4:8] = len(payload).to_bytes(4, "little")
    header[8] = module.KWB_V1
    module.set_u24_header_size(header, len(header))
    header[12:16] = len(header).to_bytes(4, "little")
    header[module.HEADER_CHECKSUM_OFFSET] = 0
    header[module.HEADER_CHECKSUM_OFFSET] = sum(header) & 0xFF
    return bytes(header) + payload


def main() -> None:
    original = make_fixture()
    converted, before, after = module.convert(original)
    assert before["source"] == 0x20
    assert after["source"] == 0x800
    assert after["header_size"] == 0x800
    assert after["page"] == 0
    assert after["nand_block_code"] == 4
    assert after["bbi"] == 0
    assert original[before["source"]:before["source"] + before["block_size"]] == \
        converted[after["source"]:after["source"] + after["block_size"]]
    print("KWB converter fixture: PASS")


if __name__ == "__main__":
    main()
