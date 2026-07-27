#!/usr/bin/env bash
#
# build_tcltk_macos.sh -- build an X11 Tcl/Tk from source, on top of XQuartz,
# into a magic-specific prefix, so magic's Tk graphics driver (graphics/grTk*.c)
# and its own raw Xlib calls resolve against ONE consistent XQuartz libX11.
#
# Why this exists: Homebrew's tcl-tk is an Aqua (Cocoa) Tk -- it has no X11, so
# under `-d X11` magic takes a non-X11 display from Tk_Display() and hangs on the
# first Xlib call (see scripts/configure_mac notes on the XQuartz vs Homebrew
# libX11 mismatch).  Building Tk with `--enable-aqua=no --with-x` against
# /opt/X11 makes Tk a real X11 Tk on XQuartz.
#
# The source-selection mechanism mirrors the Linux AppImage workflows
# (.github/workflows/appimage*.yml + appimage/*/Dockerfile): tarball via
# codeload.github.com, or a git checkout of the tcltk/{tcl,tk} repos.
#
# Configured entirely by environment variables (all optional):
#   TCLTK_SOURCE   homebrew | tarball | github   (default: homebrew -> no-op)
#   TCLTK_VERSION  e.g. 8.6.16 or 9.0.4           (default: 8.6.16)
#   TCLTK_REF      github tag, e.g. core-9-0-4    (default: core-<version dashed>)
#   TCLTK_PREFIX   install prefix                 (default: /opt/magic)
#   X11_PREFIX     XQuartz prefix                 (default: /opt/X11)
#   TCLTK_BUILD_DIR scratch dir for sources       (default: $PWD/tcltk-build)
#   DRYRUN         1 -> print the plan, do not fetch or build (for local checks)
#
# On success prints  TCLTK_PREFIX=<prefix>  as the last line so a caller (the
# workflow) can capture it and hand it to scripts/configure_mac.
set -euo pipefail

SOURCE="${TCLTK_SOURCE:-homebrew}"
VERSION="${TCLTK_VERSION:-8.6.16}"
PREFIX="${TCLTK_PREFIX:-/opt/magic}"
X11="${X11_PREFIX:-/opt/X11}"
BUILD_DIR="${TCLTK_BUILD_DIR:-$PWD/tcltk-build}"
DRYRUN="${DRYRUN:-0}"

# core-8-6-16 <- 8.6.16 ; reverse of the AppImage ref math.
REF="${TCLTK_REF:-core-${VERSION//./-}}"
# If a github ref was given as core-X-Y-Z, keep VERSION in sync for wish/tclsh
# suffixes and the tclConfig.sh location.
if printf '%s' "$REF" | grep -Eq '^core-[0-9]+-[0-9]+-[0-9]+$'; then
    VERSION="$(printf '%s' "$REF" | sed -E 's/^core-([0-9]+)-([0-9]+)-([0-9]+)$/\1.\2.\3/')"
fi
ABI="$(printf '%s' "$VERSION" | cut -d. -f1-2)"      # 8.6 or 9.0 -> wish8.6 / libtk9.0

TCL_TARBALL_URL="https://codeload.github.com/tcltk/tcl/tar.gz/refs/tags/${REF}"
TK_TARBALL_URL="https://codeload.github.com/tcltk/tk/tar.gz/refs/tags/${REF}"
TCL_GIT="https://github.com/tcltk/tcl.git"
TK_GIT="https://github.com/tcltk/tk.git"

log() { printf '=== %s\n' "$*"; }

if [ "$SOURCE" = "homebrew" ]; then
    log "TCLTK_SOURCE=homebrew -- nothing to build; magic uses the Homebrew tcl-tk (Aqua)."
    exit 0
fi

log "Building X11 Tcl/Tk from source"
log "source=$SOURCE  version=$VERSION  ref=$REF  abi=$ABI"
log "prefix=$PREFIX  x11=$X11  build_dir=$BUILD_DIR"

if [ ! -d "$X11/include/X11" ] || [ ! -d "$X11/lib" ]; then
    echo "WARNING: XQuartz not found under $X11 (missing include/X11 or lib);" 1>&2
    echo "         the Tk X11 build needs XQuartz -- install it (brew install --cask xquartz)." 1>&2
fi

if [ "$DRYRUN" = "1" ]; then
    log "DRYRUN: would fetch and build with:"
    if [ "$SOURCE" = "github" ]; then
        echo "  git clone --filter=blob:none $TCL_GIT && git checkout --detach $REF"
        echo "  git clone --filter=blob:none $TK_GIT  && git checkout --detach $REF"
    else
        echo "  curl -fsSL $TCL_TARBALL_URL"
        echo "  curl -fsSL $TK_TARBALL_URL"
    fi
    echo "  (tcl) ./configure --prefix=$PREFIX --enable-shared --enable-threads && make && make install"
    echo "  (tk)  ./configure --prefix=$PREFIX --with-tcl=$PREFIX/lib --enable-aqua=no --with-x \\"
    echo "           --x-includes=$X11/include --x-libraries=$X11/lib --enable-shared && make && make install"
    echo "TCLTK_PREFIX=$PREFIX"
    exit 0
fi

# fetch <component> <destdir>  -- git checkout or tarball extract into destdir/.
fetch() {
    comp="$1"; dest="$2"
    rm -rf "$dest"; mkdir -p "$dest"
    if [ "$SOURCE" = "github" ]; then
        git_url="$TCL_GIT"; [ "$comp" = "tk" ] && git_url="$TK_GIT"
        log "git clone $comp @ $REF"
        git clone --filter=blob:none "$git_url" "$dest"
        ( cd "$dest" && git checkout --detach "$REF" )
    else
        url="$TCL_TARBALL_URL"; [ "$comp" = "tk" ] && url="$TK_TARBALL_URL"
        log "download $comp tarball: $url"
        curl -fsSL "$url" -o "$dest.tar.gz"
        tar --strip-components=1 -xzf "$dest.tar.gz" -C "$dest"
    fi
}

mkdir -p "$BUILD_DIR"

# --- Tcl -----------------------------------------------------------------
fetch tcl "$BUILD_DIR/tcl"
log "configure + build Tcl -> $PREFIX"
(
    cd "$BUILD_DIR/tcl/unix"
    ./configure --prefix="$PREFIX" --enable-shared --enable-threads
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    make install
    # Best-effort extras (targets vary by Tcl series); never fatal.
    make install-libraries install-msgs install-tzdata 2>/dev/null || true
)

# --- Tk (X11 on XQuartz, NOT Aqua) --------------------------------------
fetch tk "$BUILD_DIR/tk"
log "configure + build Tk (X11) -> $PREFIX"
(
    cd "$BUILD_DIR/tk/unix"
    ./configure --prefix="$PREFIX" --with-tcl="$PREFIX/lib" \
        --enable-aqua=no --with-x \
        --x-includes="$X11/include" --x-libraries="$X11/lib" \
        --enable-shared
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    make install
    make install-libraries 2>/dev/null || true
)

# Generic wish/tclsh names (magic's configure/launchers look for `wish`/`tclsh`).
if [ -d "$PREFIX/bin" ]; then
    [ -e "$PREFIX/bin/wish$ABI" ]  && cp -f "$PREFIX/bin/wish$ABI"  "$PREFIX/bin/wish"  || true
    [ -e "$PREFIX/bin/tclsh$ABI" ] && cp -f "$PREFIX/bin/tclsh$ABI" "$PREFIX/bin/tclsh" || true
fi

log "verify Tk linked XQuartz libX11 (expect $X11/lib/libX11 in otool -L)"
for f in "$PREFIX"/lib/libtk*.dylib; do
    [ -e "$f" ] || continue
    echo "[$f]"
    otool -L "$f" 2>/dev/null | grep -iE 'x11|libx11' || echo "  WARNING: libtk has no libX11 reference (is it Aqua?)"
done

log "done: X11 Tcl/Tk installed under $PREFIX"
echo "TCLTK_PREFIX=$PREFIX"
