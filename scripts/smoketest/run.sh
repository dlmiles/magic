#!/usr/bin/env bash
#
# run.sh -- drive a magic build-tree smoke test (Step A "startup" / Step B
# "workflow") against an out-of-tree build, and validate the result.
#
# It feeds a smoke Tcl script (prefixed with _prelude.tcl) into a build-tree
# launcher, captures the combined stdout+stderr to a log, checks the launcher's
# exit status, then hands the log (and, where relevant, the output directory) to
# validate.sh.  The launcher depends on the mode:
#   startup/workflow -- run_magicnull.sh (magicdnull, null graphics: no X, no wish)
#   gui              -- run_magic.sh -d X11 -noconsole (real X11 graphics on a
#                       headless Xvfb+openbox; -noconsole so stdin is scriptable)
#
# Usage:
#   scripts/smoketest/run.sh <startup|workflow|gui|shutdown>
#
# 'shutdown' tears down the headless X server started for the GUI mode (delegates
# to x11-stop.sh); it needs no build.
#
# Environment (all optional):
#   MAGIC_BUILDDIR  out-of-tree build dir with the launchers        (default: build-tmp)
#   SMOKE_TECH      technology to load                              (default: scmos)
#   SMOKE_MAG       input layout .mag for the workflow/gui modes     (default: npm/examples/min.mag)
#   SMOKE_WORKDIR   scratch + output dir                            (default: fresh mktemp dir)
#   DISPLAY         (gui mode) headless X display from x11-start.sh (required for gui)
#
# Exits 0 only if the smoke script reached its success sentinel, the launcher
# exited cleanly, and validate.sh passed.
set -euo pipefail

mode="${1:-}"
case "$mode" in
    startup|workflow|gui|shutdown) ;;
    *) echo "usage: $0 <startup|workflow|gui|shutdown>" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"       # scripts/smoketest
srcdir="$(cd "$here/../.." && pwd)"         # source tree top

# 'shutdown' just stops the headless X server (Xvfb+openbox) for this DISPLAY --
# no build tree, tech or launcher involved.
if [ "$mode" = "shutdown" ]; then
    exec "$here/x11-stop.sh"
fi

builddir="${MAGIC_BUILDDIR:-build-tmp}"
# Resolve builddir to an absolute path (relative names are taken from $PWD, the
# usual CI case where build-tmp sits next to the checkout).
builddir="$(cd "$builddir" 2>/dev/null && pwd || true)"
if [ "$mode" = "gui" ]; then
    launcher="$builddir/run_magic.sh"
else
    launcher="$builddir/run_magicnull.sh"
fi
if [ ! -x "$launcher" ]; then
    echo "smoketest: $launcher not found or not executable" >&2
    echo "           set MAGIC_BUILDDIR to the out-of-tree build directory." >&2
    exit 1
fi
if [ "$mode" = "gui" ] && [ -z "${DISPLAY:-}" ]; then
    echo "smoketest[gui]: DISPLAY is not set -- start the headless X server first:" >&2
    echo "                eval \"\$($here/x11-start.sh)\"   # then re-run" >&2
    exit 1
fi
# Hand the launcher the *absolute* build dir.  magic_run_common.sh stages
# CAD_DIR as symlinks built from $MAGIC_BUILDDIR; a relative value there makes
# them resolve relative to CAD_DIR itself (i.e. dangling), so the launcher's
# magicdnull symlink would break.  Passing the resolved path keeps them valid.
export MAGIC_BUILDDIR="$builddir"

tech="${SMOKE_TECH:-scmos}"
mag="${SMOKE_MAG:-$srcdir/npm/examples/min.mag}"

if [ -n "${SMOKE_WORKDIR:-}" ]; then
    workdir="$SMOKE_WORKDIR"
    mkdir -p "$workdir"
else
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/magic-smoke.XXXXXX")"
fi
log="$workdir/${mode}.log"

# Assemble the script: shared prelude first, then the mode's body.
script="$workdir/${mode}.tcl"
cat "$here/_prelude.tcl" "$here/${mode}.tcl" > "$script"

export SMOKE_TECH="$tech"
export SMOKE_OUT="$workdir"
# workflow and gui both load a real layout, so stage the .mag into the workdir.
if [ "$mode" = "workflow" ] || [ "$mode" = "gui" ]; then
    if [ ! -f "$mag" ]; then
        echo "smoketest: input layout '$mag' not found" >&2
        exit 1
    fi
    cell="$(basename "$mag" .mag)"
    cp "$mag" "$workdir/$cell.mag"
    export SMOKE_CELL="$workdir/$cell"
fi

echo "smoketest[$mode]: build=$builddir tech=$tech workdir=$workdir${DISPLAY:+ display=$DISPLAY}"

# Guard against a hang (a GUI that never quits would otherwise stall CI until
# the job timeout): cap the run with `timeout` when it is available.  A timeout
# surfaces as a non-zero status (124) and fails validation, rather than hanging.
run_pfx=()
if command -v timeout >/dev/null 2>&1; then
    run_pfx=(timeout -k 5 "${SMOKE_TIMEOUT:-120}")
fi

# Run the smoke script.  Do not let a non-zero launcher status abort this script
# before we have reported it -- capture it and continue to validation.
set +e
if [ "$mode" = "gui" ]; then
    # -d X11 selects X11 graphics; -noconsole keeps the Tk console from
    # capturing stdin so the piped script drives the interpreter directly.
    "${run_pfx[@]}" "$launcher" -d X11 -noconsole < "$script" > "$log" 2>&1
else
    "${run_pfx[@]}" "$launcher" < "$script" > "$log" 2>&1
fi
rc=$?
set -e
echo "smoketest[$mode]: launcher exit=$rc"

"$here/validate.sh" "$mode" "$workdir" "$log" "$rc"
