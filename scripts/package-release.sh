#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NAME="wrt1900acsv2-uboot-v${VERSION}"
DIST="$ROOT/dist"

python3 "$ROOT/scripts/validate-release.py" "$ROOT"
rm -rf "$DIST"
mkdir -p "$DIST"

parent="$(dirname "$ROOT")"
base="$(basename "$ROOT")"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='UTC 2026-07-30' \
    --exclude="$base/.git" \
    --exclude="$base/dist" \
    --exclude="$base/wrt1900acsv2-uboot-full" \
    --exclude='*/__pycache__' \
    --exclude='*/__pycache__/*' \
    --exclude='*.pyc' \
    -C "$parent" -czf "$DIST/$NAME.tar.gz" "$base"

if command -v zip >/dev/null 2>&1; then
    (cd "$parent" && zip -qr "$DIST/$NAME.zip" "$base" \
        -x "$base/.git/*" "$base/dist/*" "$base/wrt1900acsv2-uboot-full/*" \
           "*/__pycache__/*" "*.pyc")
fi

(cd "$DIST" && sha256sum "$NAME".* > SHA256SUMS)
cat "$DIST/SHA256SUMS"
