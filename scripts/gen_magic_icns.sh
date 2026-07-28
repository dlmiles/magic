#!/usr/bin/env bash
#
# gen_magic_icns.sh -- ONE-TIME developer tool: rasterise appimage/rsc/magic.svg
# into a multi-resolution macOS .icns committed at scripts/rsc/magic.icns.
#
# The committed .icns is what the CI DMG build ships, so the build server needs
# NO librsvg / iconutil.  Re-run this (on any machine with rsvg-convert + python3
# -- e.g. `brew install librsvg` or `apt install librsvg2-bin`) only when the
# source SVG changes, then commit the updated scripts/rsc/magic.icns.
#
# Portable: builds the .icns container directly (typed PNG blocks), so it works
# on Linux too -- no macOS-only iconutil required.
set -euo pipefail

SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="${1:-$SRCROOT/appimage/rsc/magic.svg}"
OUT="${2:-$SRCROOT/scripts/rsc/magic.icns}"

command -v rsvg-convert >/dev/null 2>&1 || { echo "need rsvg-convert (librsvg)"; exit 1; }
[ -f "$SVG" ] || { echo "SVG not found: $SVG"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$(dirname "$OUT")"
for s in 16 32 64 128 256 512 1024; do
    rsvg-convert -w "$s" -h "$s" "$SVG" -o "$tmp/$s.png"
done

python3 - "$tmp" "$OUT" <<'PY'
import struct, sys, os
tmp, out = sys.argv[1], sys.argv[2]
# OSType -> pixel size.  Modern PNG-based icns entries (retina @2x reuse the
# doubled pixel size): icp4/5 = 16/32, ic07-ic10 = 128/256/512/1024,
# ic11-ic14 = 32/64/256/512 (@2x variants).
entries = [('icp4',16),('icp5',32),('ic07',128),('ic08',256),('ic09',512),
           ('ic10',1024),('ic11',32),('ic12',64),('ic13',256),('ic14',512)]
blocks = b''
for typ, size in entries:
    with open(os.path.join(tmp, f'{size}.png'), 'rb') as f:
        data = f.read()
    blocks += typ.encode('ascii') + struct.pack('>I', len(data) + 8) + data
icns = b'icns' + struct.pack('>I', len(blocks) + 8) + blocks
with open(out, 'wb') as f:
    f.write(icns)
print(f"wrote {out} ({len(icns)} bytes, {len(entries)} sizes)")
PY
echo "icns -> $OUT"
