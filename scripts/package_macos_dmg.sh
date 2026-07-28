#!/usr/bin/env bash
#
# package_macos_dmg.sh -- build a relocatable, drag-and-drop Magic.app and wrap
# it in a .dmg (Magic.app + an /Applications symlink), with a custom icon.
#
# ITERATION 1 -- this is the first cut of the "Mac-native" packaging.  It is
# best-effort (never fatal to the CI job) and logs `otool` before/after so the
# CI run shows exactly what relocated and what still points at an absolute path.
# Expect to refine the @rpath rewrites and the launcher from that output.
#
# WHY relocatable: magic is built --prefix=/opt/magic, so its dylibs carry
# absolute install-names (/opt/magic/lib/...) and would only load from there.
# We copy the tree into Magic.app/Contents/Resources/magic and rewrite every
# Mach-O so its own id and its /opt/magic dependencies become @rpath-relative,
# then add an @loader_path rpath -- so the bundle runs from wherever it is
# dragged (e.g. /Applications).  magic.tcl already derives CAD_ROOT from
# [info script], so the tech/tcl side follows the bundle automatically.
#
# Env in:
#   PREFIX       installed magic tree           (default /opt/magic)
#   VERSION      magic version string           (default: cat VERSION)
#   DMG_NAME     output .dmg filename           (required)
#   ICON_SVG     source icon                    (default appimage/rsc/magic.svg)
#   WORKDIR      scratch dir                    (default $PWD/dmg-build)
# On success the .dmg named $DMG_NAME is written to $PWD.
set -u

PREFIX="${PREFIX:-/opt/magic}"
SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(cat "${SRCROOT}/VERSION" 2>/dev/null || echo 0.0.0)}"
ICON_ICNS="${ICON_ICNS:-${SRCROOT}/scripts/rsc/magic.icns}"   # committed static icon
ICON_SVG="${ICON_SVG:-${SRCROOT}/appimage/rsc/magic.svg}"     # source (fallback convert)
WORKDIR="${WORKDIR:-$PWD/dmg-build}"
: "${DMG_NAME:?DMG_NAME must be set}"

log() { printf '=== %s\n' "$*"; }
die() { echo "package_macos_dmg: $*" 1>&2; exit 1; }

[ -d "$PREFIX" ] || die "PREFIX $PREFIX not found (nothing to package)"

APP="Magic.app"
STAGE="$WORKDIR/stage"          # holds Magic.app + Applications symlink for the DMG
APPDIR="$STAGE/$APP"
RES="$APPDIR/Contents/Resources"
MACOS="$APPDIR/Contents/MacOS"

rm -rf "$WORKDIR"
mkdir -p "$RES" "$MACOS"

# --- 1) copy the installed tree into the bundle ------------------------------
log "staging $PREFIX -> $RES/magic ($(du -sh "$PREFIX" 2>/dev/null | cut -f1))"
# ditto preserves symlinks/perms/xattrs (Tcl/Tk ships lib symlinks).
ditto "$PREFIX" "$RES/magic"

# --- 2) icon: prefer the committed static .icns (scripts/gen_magic_icns.sh
# builds it once); fall back to converting on the fly only if it is absent -----
if [ -f "$ICON_ICNS" ]; then
    cp "$ICON_ICNS" "$RES/magic.icns"
    log "icon -> $RES/magic.icns (static $ICON_ICNS)"
elif command -v rsvg-convert >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$ICON_SVG" ]; then
    log "static icns absent -- converting $ICON_SVG on the fly"
    iconset="$WORKDIR/Magic.iconset"; mkdir -p "$iconset"
    for s in 16 32 128 256 512; do
        rsvg-convert -w "$s"       -h "$s"       "$ICON_SVG" -o "$iconset/icon_${s}x${s}.png"    2>/dev/null
        rsvg-convert -w "$((s*2))" -h "$((s*2))" "$ICON_SVG" -o "$iconset/icon_${s}x${s}@2x.png" 2>/dev/null
    done
    iconutil -c icns "$iconset" -o "$RES/magic.icns" 2>/dev/null \
        && log "icon -> $RES/magic.icns (converted)" || log "iconutil failed -- no custom icon"
else
    log "no static icns ($ICON_ICNS) and no converter -- bundle will have no custom icon"
fi

# --- 3) relocate every Mach-O: absolute /opt/magic deps -> @rpath ------------
# Find dylibs + Mach-O executables under the staged tree.  For each: set its id
# (dylibs) to @rpath/<name>, rewrite any dependency under $PREFIX to @rpath, and
# add an @loader_path-relative rpath so the loader finds sibling dylibs.
log "relocating Mach-O install-names to @rpath (was $PREFIX)"
libroot="$RES/magic"
is_macho() { file -b "$1" 2>/dev/null | grep -qiE 'mach-o'; }

# Installed dylibs are often read-only, which makes install_name_tool -id fail
# silently -- make the staged tree writable first.
chmod -R u+w "$libroot" 2>/dev/null || true

find "$libroot" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null | while IFS= read -r f; do
    is_macho "$f" || continue
    echo "--- $f"
    echo "  BEFORE:"; otool -L "$f" 2>/dev/null | sed -n '2,14p' | sed 's/^/    /'
    # Strip the code signature before editing: install_name_tool invalidates it
    # anyway, and a stale signature can make it refuse to modify.
    codesign --remove-signature "$f" 2>/dev/null || true
    # dylib id -> @rpath/<basename>  (errors now VISIBLE)
    case "$f" in *.dylib)
        install_name_tool -id "@rpath/$(basename "$f")" "$f" || echo "  ID-CHANGE FAILED" ;;
    esac
    # rewrite each dependency that lives under $PREFIX
    otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | while IFS= read -r dep; do
        case "$dep" in
            "$PREFIX"/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" \
                           || echo "  CHANGE FAILED: $dep" ;;
        esac
    done
    # rpath -> the lib dir, relative to this binary's location
    reldir=$(cd "$(dirname "$f")" && python3 -c "import os; print(os.path.relpath('$libroot/lib', os.getcwd()))" 2>/dev/null || echo "../lib")
    install_name_tool -add_rpath "@loader_path/$reldir" "$f" 2>/dev/null || true
    # Re-ad-hoc-sign: install_name_tool broke the signature, and arm64 KILLS any
    # binary with an invalid signature on load -- without this the .app crashes.
    codesign --force --sign - "$f" 2>/dev/null || echo "  codesign FAILED"
    echo "  AFTER:";  otool -L "$f" 2>/dev/null | sed -n '2,14p' | sed 's/^/    /'
done

# any remaining absolute references are the things still to fix next iteration
log "remaining absolute $PREFIX references after relocation:"
find "$libroot" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null | while IFS= read -r f; do
    is_macho "$f" || continue
    otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^$PREFIX/" \
        && echo "  STILL-ABSOLUTE: $f"
done || true

# --- 4) launcher + Info.plist ------------------------------------------------
# The launcher computes the bundle root, points CAD_ROOT + PATH + DYLD at the
# embedded tree and execs magicexec (the Tk binary) directly (bypassing the
# baked-path magic.sh wrapper).  Needs XQuartz for -d X11.
log "writing launcher + Info.plist"
cat > "$MACOS/Magic" <<'LAUNCH'
#!/bin/bash
here="$(cd "$(dirname "$0")" && pwd)"
res="$(cd "$here/../Resources/magic" && pwd)"
export CAD_ROOT="$res/lib/magic"
export PATH="$res/bin:$PATH"
# magicexec is the Tk (wish) binary; run it so magic opens its GUI.
exec="$res/lib/magic/tcl/magicexec"
[ -x "$exec" ] || exec="$res/bin/magic"     # fallback to the wrapper
exec "$exec" "$@"
LAUNCH
chmod +x "$MACOS/Magic"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Magic</string>
  <key>CFBundleDisplayName</key><string>Magic</string>
  <key>CFBundleIdentifier</key><string>org.opencircuitdesign.magic</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key><string>Magic</string>
  <key>CFBundleIconFile</key><string>magic.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# --- 5) drag-and-drop DMG (Magic.app + /Applications) ------------------------
ln -s /Applications "$STAGE/Applications"
[ -f "$RES/magic.icns" ] && cp "$RES/magic.icns" "$STAGE/.VolumeIcon.icns"

log "building DMG $DMG_NAME (makehybrid -> UDZO; no mount, CI-safe)"
raw="$WORKDIR/raw.dmg"
TO=""; command -v gtimeout >/dev/null 2>&1 && TO="gtimeout -k 30 600"
rc=0
$TO hdiutil makehybrid -hfs -hfs-volume-name "Magic ${VERSION}" -o "$raw" "$STAGE" || rc=$?
if [ $rc -eq 0 ]; then
    $TO hdiutil convert "$raw" -format UDZO -o "$DMG_NAME" || rc=$?
fi
rm -f "$raw"
if [ $rc -ne 0 ] || [ ! -f "$DMG_NAME" ]; then
    die "DMG build failed/timed out (rc=$rc)"
fi
ls -la "$DMG_NAME"
log "done: $DMG_NAME (Magic.app drag-and-drop bundle)"
