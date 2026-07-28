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
PREREQ_SRC="${PREREQ_SRC:-${SRCROOT}/scripts/macos_runtime_prereq_check.command}"
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
    # A Tcl 9 zipfs dylib has its script-library ZIP appended AFTER the Mach-O,
    # so the Mach-O does not cover the end of the file; install_name_tool +
    # codesign then REFUSE it ("__LINKEDIT segment does not cover the end of the
    # file").  Detect that precisely (Mach-O end < file size) and SKIP relocating
    # it: it has NO /opt/magic dependencies (only its own id), nothing loads it
    # by absolute path (clients use @rpath, rewritten below), and it keeps its
    # original valid signature -- so it still loads from the bundle via @rpath.
    # Tcl 8 dylibs / plain binaries have NO trailing data -> relocated normally.
    mend=$(python3 "$SRCROOT/scripts/macho_zipfs.py" end "$f" 2>/dev/null)
    fsize=$(stat -f%z "$f" 2>/dev/null || wc -c < "$f")
    if [ -n "$mend" ] && [ "$mend" -lt "$fsize" ] 2>/dev/null; then
        echo "  SKIP: $((fsize - mend)) bytes trailing data (Tcl zipfs) -- left as-is"
        echo "        (no /opt/magic deps; loads via @rpath; original signature kept)"
        continue
    fi
    echo "  BEFORE:"; otool -L "$f" 2>/dev/null | sed -n '2,14p' | sed 's/^/    /'
    # Strip the code signature before editing (capture the real error too:
    # Tcl 9's libtcl/libtk carry an embedded zipfs appended after the Mach-O,
    # which is what makes codesign / install_name_tool fail on exactly them).
    e=$(codesign --remove-signature "$f" 2>&1) || echo "  remove-sig: $e"
    # dylib id -> @rpath/<basename>  (capture the actual tool error)
    case "$f" in *.dylib)
        e=$(install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>&1) \
            || echo "  ID-CHANGE FAILED: $e" ;;
    esac
    # rewrite each dependency that lives under $PREFIX
    otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | while IFS= read -r dep; do
        case "$dep" in
            "$PREFIX"/*) e=$(install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>&1) \
                           || echo "  CHANGE FAILED ($dep): $e" ;;
        esac
    done
    # rpath -> the lib dir, relative to this binary's location
    reldir=$(cd "$(dirname "$f")" && python3 -c "import os; print(os.path.relpath('$libroot/lib', os.getcwd()))" 2>/dev/null || echo "../lib")
    install_name_tool -add_rpath "@loader_path/$reldir" "$f" 2>/dev/null || true
    # Re-ad-hoc-sign: install_name_tool broke the signature, and arm64 KILLS any
    # binary with an invalid signature on load -- without this the .app crashes.
    e=$(codesign --force --sign - "$f" 2>&1) || echo "  codesign FAILED: $e"
    echo "  AFTER:";  otool -L "$f" 2>/dev/null | sed -n '2,14p' | sed 's/^/    /'
done

# Remaining absolute references: a zipfs dylib keeping its own id is expected
# and harmless; anything else is a real relocation bug to fix.
log "remaining absolute $PREFIX references (zipfs = expected/harmless):"
find "$libroot" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null | while IFS= read -r f; do
    is_macho "$f" || continue
    otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^$PREFIX/" || continue
    mend=$(python3 "$SRCROOT/scripts/macho_zipfs.py" end "$f" 2>/dev/null)
    fsize=$(stat -f%z "$f" 2>/dev/null || wc -c < "$f")
    if [ -n "$mend" ] && [ "$mend" -lt "$fsize" ] 2>/dev/null; then
        echo "  zipfs (expected; only its own id): $f"
    else
        echo "  STILL-ABSOLUTE (UNEXPECTED -- needs fixing): $f"
    fi
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
checker="$here/../Resources/macos_runtime_prereq_check.command"

# The magic binary we exec -- also the "have we upgraded?" reference below.
magicbin="$res/lib/magic/tcl/magicexec"
[ -x "$magicbin" ] || magicbin="$res/bin/magic"

# Runtime-prerequisite check (XQuartz/cairo).  Runs on EVERY launch UNTIL it
# reports all prerequisites OK -- the marker is written only when the check
# passes (exit 0) -- and again after an upgrade, detected by the magic binary
# being newer than the marker (an overwrite bumps its mtime; no reset needed).
# No terminal here, so the checker shows its osascript pop-up and blocks until
# dismissed, then magic starts.  Set MAGIC_DISABLE_STARTUP_CHECK (non-empty) to
# inhibit the start-up check entirely.  CAVEAT: a Finder-launched .app inherits
# launchd's environment, NOT your shell's -- so exporting it in ~/.zshrc/.profile
# only affects magic started from a terminal.  To inhibit Finder launches too:
#   launchctl setenv MAGIC_DISABLE_STARTUP_CHECK 1      (or use a LaunchAgent)
marker="$HOME/Library/Application Support/Magic/.prereq_ok"
if [ -n "$MAGIC_DISABLE_STARTUP_CHECK" ]; then
    :                                        # inhibited by the environment
elif [ -f "$marker" ] && [ "$marker" -nt "$magicbin" ]; then
    :                                        # already confirmed OK, not upgraded since
elif [ -x "$checker" ]; then
    if "$checker" </dev/null >/dev/null 2>&1; then
        mkdir -p "$(dirname "$marker")" 2>/dev/null && : > "$marker" 2>/dev/null || true
    fi
fi

# CAD_ROOT is <prefix>/lib (magic.tcl derives it as <tcl-dir>/../..); point it at
# the bundle so magic finds its sys/tech under Resources/magic/lib/magic/.
export CAD_ROOT="$res/lib"
export PATH="$res/bin:$PATH"
exec "$magicbin" "$@"                         # magicexec (Tk GUI), or the wrapper
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

# --- 4b) runtime prerequisite check, filled with THIS build's versions -------
# Magic.app does not bundle XQuartz or cairo (external runtime deps), so ship a
# checker that tells the user whether they are installed at the versions this
# build linked, with the brew commands to install/upgrade.  Also placed at the
# DMG root so it is visible without opening the bundle.
if [ -f "$PREREQ_SRC" ]; then
    cairo_want="$(brew list --versions cairo 2>/dev/null | awk '{print $NF}')"
    xq_want="${XQUARTZ_ACTUAL:-$(defaults read /Applications/Utilities/XQuartz.app/Contents/Info CFBundleShortVersionString 2>/dev/null)}"
    build_label="macOS $(sw_vers -productVersion 2>/dev/null | cut -d. -f1) $(uname -m)"
    sed -e "s|@CAIRO_WANT@|${cairo_want}|g" \
        -e "s|@XQUARTZ_WANT@|${xq_want}|g" \
        -e "s|@BUILD_LABEL@|${build_label}|g" \
        "$PREREQ_SRC" > "$RES/macos_runtime_prereq_check.command"
    chmod +x "$RES/macos_runtime_prereq_check.command"
    cp "$RES/macos_runtime_prereq_check.command" "$STAGE/macos_runtime_prereq_check.command"
    log "prereq check -> Resources/macos_runtime_prereq_check.command (cairo=${cairo_want:-?} xquartz=${xq_want:-?})"
else
    log "prereq check source $PREREQ_SRC missing -- not bundled"
fi

# --- 4c) load smoke-test: run the BUNDLED magicdnull ------------------------
# Prove the relocation worked: run magicdnull from inside the bundle and check
# it resolves its dylibs via @rpath to Resources/magic/lib (NOT /opt/magic,
# which still exists on the runner).  --version runs the Tcl layer and exits
# without a display, exactly like the "magic --version" earlier steps.  This is
# a diagnostic -- a failure logs loudly but never fails the packaging.
log "load smoke-test: bundled magicdnull --version (verifies @rpath loading)"
smoke="$RES/magic/lib/magic/tcl/magicdnull"
if [ -x "$smoke" ]; then
    # DYLD_PRINT_LIBRARIES shows the ACTUAL path each dylib loaded from.
    so=$(CAD_ROOT="$RES/magic/lib" DYLD_PRINT_LIBRARIES=1 \
         "$smoke" -nowrapper --version 2>&1)
    echo "$so" | grep -iE 'libtcl|libtk|Library not loaded|image not found|code signature|Killed' \
               | sed 's/^/    /' | head -20
    printf '%s\n' "$so" | grep -vE '^dyld' | grep -vE '^\s*$' | head -8 | sed 's/^/    out: /'
    if printf '%s' "$so" | grep -qiE 'Library not loaded|image not found|code signature|Killed'; then
        log "load smoke-test: FAIL -- dyld/@rpath/signature error (see above)"
    elif printf '%s' "$so" | grep -qE "$(basename "$RES")|Resources/magic/lib/libtcl"; then
        log "load smoke-test: PASS -- loaded libtcl from the bundle via @rpath"
    else
        log "load smoke-test: check the output above (did it print a version?)"
    fi
else
    log "load smoke-test: bundled magicdnull not found at $smoke -- skipped"
fi

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
