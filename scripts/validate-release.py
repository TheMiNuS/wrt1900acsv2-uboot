#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The_MiNuS
from pathlib import Path
import ast
import re
import subprocess
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]).resolve()

required = [
    "README.md", "VERSION", "LICENSE", "NOTICE", "CHANGELOG.md", "CONTRIBUTING.md",
    "SECURITY.md", "Makefile", "build.sh", "board/db-88f6820-gp.c",
    "board/wrt1900acsv2.env", "scripts/patch-kwb-linksys-nand.py",
    "patches/0001-mdio-skip-marvell-dsa-switch-node.patch",
    "openwrt/etc/fw_env.config.example", "openwrt/etc/init.d/uboot-mark-good",
    "docs/BUILD.md", "docs/FLASHING-PROCEDURE.md", "docs/INSTALLATION.md",
    "docs/VALIDATION.md",
    "docs/NETWORK-MAPPING.md", "docs/RECOVERY.md", "docs/COMMANDS.md",
]
errors = []
for rel in required:
    if not (root / rel).is_file():
        errors.append(f"missing required file: {rel}")

text_files = []
for path in root.rglob("*"):
    if path.resolve() == Path(__file__).resolve():
        continue
    if path.is_file() and ".git" not in path.parts and path.suffix.lower() not in {".kwb", ".png", ".jpg", ".zip", ".gz"}:
        try:
            text_files.append((path, path.read_text()))
        except UnicodeDecodeError:
            pass

forbidden = [
    re.compile(r"v5\.[0-9]", re.I),
    re.compile(r"rc6(?:\.|\b)", re.I),
    re.compile(r"conversation", re.I),
    re.compile(r"chatgpt", re.I),
    re.compile(r"audit-only", re.I),
]
for path, content in text_files:
    for pattern in forbidden:
        if pattern.search(content):
            errors.append(f"historical marker {pattern.pattern!r} in {path.relative_to(root)}")

# Repository policy: project-owned documentation, comments, templates, and
# user-facing diagnostics must remain in English. Third-party license texts are
# excluded because their wording must not be modified.
french_patterns = [
    re.compile(r"[À-ÖØ-öø-ÿŒœ]"),
    re.compile(
        r"\b(?:réseau|reseau|démarrage|demarrage|écriture|ecriture|"
        r"environnement|sauvegarde|récupération|recuperation|dépannage|"
        r"depannage|sécurité|securite|contribuer|construction|attendu|"
        r"attendue|introuvable|inattendu|inattendue|nœud|noeud|propriété|"
        r"propriete|accolade|profil|profils|résultats|resultats|depuis|"
        r"uniquement|désactivé|desactive|doit être|ne pas|aucun|aucune)\b",
        re.I,
    ),
]
for path, content in text_files:
    rel = path.relative_to(root)
    if rel == Path("LICENSE") or "LICENSES" in rel.parts:
        continue
    for pattern in french_patterns:
        match = pattern.search(content)
        if match:
            line = content.count("\n", 0, match.start()) + 1
            errors.append(
                f"non-English project text {match.group(0)!r} in {rel}:{line}"
            )

version = (root / "VERSION").read_text().strip()
if version != "7.0.0":
    errors.append(f"unexpected VERSION value: {version!r}")
board = (root / "board/db-88f6820-gp.c").read_text()
env = (root / "board/wrt1900acsv2.env").read_text()
build = (root / "build.sh").read_text()
dts_expectations = [
    'ENV_SCHEMA          "wrt1900acsv2-v7.0.0"',
    'uclass_get_device_by_name(UCLASS_ETH, "lan1", &port)',
    'GE0/RGMII-ID CPU port 6 primed',
    'Board: Linksys WRT1900ACS v2 Rev.A00 (Shelby)',
]
for marker in dts_expectations:
    if marker not in board:
        errors.append(f"board mapping marker missing: {marker}")
for marker in [
    "env_schema=wrt1900acsv2-v7.0.0",
    "ethprime=lan1",
    "switch_handoff=probe",
    "bootcmd=linksys boot",
    "altbootcmd=linksys fallback",
]:
    if marker not in env:
        errors.append(f"environment marker missing: {marker}")
for marker in [
    'ethernet-port@6', 'phy-mode = "rgmii-id"', 'ethernet = <&eth0>',
    'status = "disabled"', '0001-mdio-skip-marvell-dsa-switch-node.patch',
]:
    if marker not in build:
        errors.append(f"build mapping marker missing: {marker}")

shell_checks = [
    (["bash", "-n", str(root / "build.sh")], "build.sh"),
    (["bash", "-n", str(root / "scripts/package-release.sh")], "package-release.sh"),
    (["sh", "-n", str(root / "openwrt/etc/init.d/uboot-mark-good")], "uboot-mark-good"),
    (["sh", "-n", str(root / "tests/openwrt-network-check.sh")], "openwrt-network-check.sh"),
]
for command, label in shell_checks:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        errors.append(f"syntax error in {label}: {result.stderr.strip()}")

for rel in ["scripts/patch-kwb-linksys-nand.py", "scripts/validate-release.py", "tests/test_kwb_converter.py"]:
    try:
        ast.parse((root / rel).read_text(), filename=rel)
    except SyntaxError as exc:
        errors.append(f"Python syntax error in {rel}: {exc}")

if not errors:
    result = subprocess.run([sys.executable, str(root / "tests/test_kwb_converter.py")], capture_output=True, text=True)
    if result.returncode:
        errors.append(f"KWB unit test failed: {result.stdout}{result.stderr}")
    else:
        print(result.stdout.strip())

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Release tree validation: PASS ({len(text_files)} text files inspected)")
