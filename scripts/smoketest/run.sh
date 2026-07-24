#!/usr/bin/env bash
#
# run.sh -- drive a magic build-tree smoke test (Step A "startup" / Step B
# "workflow") against an out-of-tree build, and validate the result.
#
# It feeds a smoke Tcl script (prefixed with _prelude.tcl) into the build's
# run_magicnull.sh -- i.e. magicdnull with the null graphics device, fully
# headless, no X and no wish -- captures the combined stdout+stderr to a log,
# checks the launcher's exit status, then hands the log (and, for the workflow
# mode, the output directory) to validate.sh.
#
# Usage:
#   scripts/smoketest/run.sh <startup|workflow>
#
# Environment (all optional):
#   MAGIC_BUILDDIR  out-of-tree build dir with run_magicnull.sh   (default: build-tmp)
#   SMOKE_TECH      technology to load                            (default: scmos)
#   SMOKE_MAG       input layout .mag for the workflow mode       (default: npm/examples/min.mag)
#   SMOKE_WORKDIR   scratch + output dir                          (default: fresh mktemp dir)
#
# Exits 0 only if the smoke script reached its success sentinel, the launcher
# exited cleanly, and validate.sh passed.
set -euo pipefail

mode="${1:-}"
case "$mode" in
    startup|workflow) ;;
    *) echo "usage: $0 <startup|workflow>" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"       # scripts/smoketest
srcdir="$(cd "$here/../.." && pwd)"         # source tree top

builddir="${MAGIC_BUILDDIR:-build-tmp}"
# Resolve builddir to an absolute path (relative names are taken from $PWD, the
# usual CI case where build-tmp sits next to the checkout).
builddir="$(cd "$builddir" 2>/dev/null && pwd || true)"
launcher="$builddir/run_magicnull.sh"
if [ ! -x "$launcher" ]; then
    echo "smoketest: $launcher not found or not executable" >&2
    echo "           set MAGIC_BUILDDIR to the out-of-tree build directory." >&2
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
if [ "$mode" = "workflow" ]; then
    if [ ! -f "$mag" ]; then
        echo "smoketest: input layout '$mag' not found" >&2
        exit 1
    fi
    cell="$(basename "$mag" .mag)"
    cp "$mag" "$workdir/$cell.mag"
    export SMOKE_CELL="$workdir/$cell"
fi

echo "smoketest[$mode]: build=$builddir tech=$tech workdir=$workdir"

# Run headless.  Do not let a non-zero launcher status abort the script before
# we have reported it -- capture it and continue to validation.
set +e
"$launcher" < "$script" > "$log" 2>&1
rc=$?
set -e
echo "smoketest[$mode]: launcher exit=$rc"

"$here/validate.sh" "$mode" "$workdir" "$log" "$rc"
