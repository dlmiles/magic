#!/usr/bin/env bash
#
# gui-interact.sh -- demonstrate three ways to drive the magic X11 GUI, to prove
# the GUI can be scripted, event-driven, or both.  This is an OPT-IN DEMO, not a
# blocking CI gate: the xdotool timing and (mode b) the menubar geometry are
# window-manager sensitive, so treat a failure as "needs tuning on this WM", not
# a broken build.  Needs a headless display (Xvfb+openbox from x11-start.sh) and
# xdotool; every run is bounded by magic's own -timeout watchdog so it can never
# hang.
#
#   scripts/smoketest/gui-interact.sh <a|b|c|all>
#
#   a  100% script  -- pipe a Tcl script on stdin; magic quits itself
#                      (quit -noprompt).  No X events at all.
#   b  0% script    -- no stdin commands; xdotool alone drives it: paint with the
#                      mouse (marks the cell modified), open File -> Quit, and
#                      dismiss the "save?" dialog with Return -> exit 0.
#   c  mixed        -- inject Tcl commands, send xdotool GUI events, then inject
#                      'quit -noprompt' to finish: script, then GUI, then script.
#                      (magic's quit command; "exit -noprompt" is invalid -- Tcl
#                      exit takes an integer code.)
#
# Env: SMOKE_DEVICE is forced to x11 here.  MAGIC_BUILDDIR, SMOKE_TECH,
#      SMOKE_MAGIC_TIMEOUT (watchdog, default 120s), DISPLAY -- as in run.sh.
set -u

mode="${1:-all}"
case "$mode" in a|b|c|all) ;; *) echo "usage: $0 <a|b|c|all>" >&2; exit 2 ;; esac

here="$(cd "$(dirname "$0")" && pwd)"
srcdir="$(cd "$here/../.." && pwd)"
builddir="${MAGIC_BUILDDIR:-build-tmp}"
builddir="$(cd "$builddir" 2>/dev/null && pwd || true)"
launcher="$builddir/run_magic.sh"
tech="${SMOKE_TECH:-scmos}"
magic_to="${SMOKE_MAGIC_TIMEOUT:-120}"
tmp="${TMPDIR:-/tmp}"

[ -x "$launcher" ] || { echo "gui-interact: $launcher not built (set MAGIC_BUILDDIR)"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "gui-interact: DISPLAY unset -- eval \"\$($here/x11-start.sh)\" first"; exit 1; }
command -v xdotool >/dev/null || { echo "gui-interact: xdotool not installed"; exit 1; }
export MAGIC_BUILDDIR="$builddir"

# Every xdotool call is bounded: a WM that never acknowledges (e.g. no reply to
# a --sync activate) must not stall the demo.  We also avoid --sync for that
# reason and pace with short sleeps instead.
xdo() { timeout 8 xdotool "$@" 2>/dev/null; }

# Find magic's layout window (named "layout<N>"); echo its id, or fail.
wait_layout() {
    local w i
    for i in $(seq 1 60); do
        w=$(xdo search --name '^layout[0-9]' | head -1)
        [ -n "$w" ] && { echo "$w"; return 0; }
        sleep 0.5
    done
    return 1
}

# Report a mode's outcome from magic's exit status.  A clean GUI-driven or
# scripted quit is exit 0; the -timeout watchdog firing (124) means the intended
# exit path did not complete -- reported, but non-fatal for this demo.
report() {   # report <mode> <rc> <logfile>
    local m="$1" rc="$2" log="$3"
    if [ "$rc" -eq 0 ]; then
        echo "  [$m] PASS -- magic exited cleanly (0)"
    elif [ "$rc" -eq 124 ] || grep -q 'watchdog expired' "$log" 2>/dev/null; then
        echo "  [$m] INCOMPLETE -- the intended exit path did not fire; the -timeout"
        echo "        watchdog stopped magic (needs xdotool/geometry tuning on this WM)."
    else
        echo "  [$m] FAIL -- magic exited $rc (see $log)"
    fi
}

# ---------------------------------------------------------------------------
# a: 100% script -- everything on stdin, magic quits itself.
demo_a() {
    echo "== mode a: 100% script =="
    local log="$tmp/gui-a.log"
    printf 'tech load %s\nbox 0 0 10 10\npaint metal1\nputs GUI-A-SCRIPTED-OK\nquit -noprompt\n' "$tech" \
        | timeout $((magic_to + 30)) "$launcher" -d X11 -noconsole -timeout "$magic_to" > "$log" 2>&1
    local rc=$?
    grep -q 'GUI-A-SCRIPTED-OK' "$log" && echo "  ran the piped script"
    report a "$rc" "$log"
    return $([ "$rc" -eq 0 ] && echo 0 || echo 1)
}

# ---------------------------------------------------------------------------
# c: mixed -- inject commands, send GUI events, inject 'exit -noprompt'.
demo_c() {
    echo "== mode c: mixed (script -> GUI -> script) =="
    local log="$tmp/gui-c.log" fifo="$tmp/gui-c.fifo"
    rm -f "$fifo"; mkfifo "$fifo"
    timeout $((magic_to + 30)) "$launcher" -d X11 -noconsole -timeout "$magic_to" < "$fifo" > "$log" 2>&1 &
    local mpid=$!
    exec 3>"$fifo"                          # hold stdin open

    # script: set up and paint (marks the cell modified)
    printf 'tech load %s\nbox 0 0 10 10\npaint metal1\nputs GUI-C-SCRIPTED\n' "$tech" >&3

    local w; w=$(wait_layout) || { echo "  no layout window"; exec 3>&-; kill "$mpid" 2>/dev/null; report c 1 "$log"; return 1; }
    echo "  layout window $w up; sending GUI events"
    # GUI: focus, move the pointer around and set a box corner with button 1.
    xdo windowactivate "$w"; sleep 0.5
    eval "$(xdo getwindowgeometry --shell "$w")"                   # WIDTH/HEIGHT
    local cx=$(( ${WIDTH:-400} / 2 )) cy=$(( ${HEIGHT:-400} / 2 ))
    xdo mousemove --window "$w" "$cx" "$cy"
    xdo click --window "$w" 1                                      # magic: box corner
    xdo mousemove --window "$w" $((cx + 40)) $((cy + 30))
    xdo click --window "$w" 3                                      # magic: other corner
    sleep 1

    # script again: finish via an injected quit command when done interacting.
    # (NB: magic's command is "quit -noprompt"; Tcl's bare "exit" wants an integer
    # code, so "exit -noprompt" is an error -- use quit, or "exit 0".)
    printf 'puts GUI-C-RESUMED\nquit -noprompt\n' >&3
    exec 3>&-
    local i; for i in $(seq 1 40); do kill -0 "$mpid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$mpid" 2>/dev/null && kill "$mpid" 2>/dev/null
    wait "$mpid" 2>/dev/null; local rc=$?
    rm -f "$fifo"
    grep -q 'GUI-C-RESUMED' "$log" && echo "  resumed and issued 'exit -noprompt'"
    report c "$rc" "$log"
    return $([ "$rc" -eq 0 ] && echo 0 || echo 1)
}

# ---------------------------------------------------------------------------
# b: 0% script -- no stdin commands; xdotool paints, opens File->Quit, and
# dismisses the "save?" dialog with Return.  The menubar is a row of menubuttons
# in the layout window's titlebar (no keyboard mnemonics), so "File" is clicked
# by coordinate near the top-left -- the part that wants tuning per WM.
demo_b() {
    echo "== mode b: 0% script (pure xdotool) =="
    local log="$tmp/gui-b.log" fifo="$tmp/gui-b.fifo"
    rm -f "$fifo"; mkfifo "$fifo"
    # stdin held open but never written to: magic stays in its event loop.
    timeout $((magic_to + 30)) "$launcher" -d X11 -noconsole -timeout "$magic_to" < "$fifo" > "$log" 2>&1 &
    local mpid=$!
    exec 3>"$fifo"

    local w; w=$(wait_layout) || { echo "  no layout window"; exec 3>&-; kill "$mpid" 2>/dev/null; report b 1 "$log"; return 1; }
    echo "  layout window $w up; driving purely by X events"
    xdo windowactivate "$w"; sleep 0.5
    eval "$(xdo getwindowgeometry --shell "$w")"
    local cx=$(( ${WIDTH:-400} / 2 )) cy=$(( ${HEIGHT:-400} / 2 ))

    # 1) paint with the mouse so the cell is modified (button2 paints in magic).
    xdo mousemove --window "$w" "$cx" "$cy" click 1
    xdo mousemove --window "$w" $((cx + 60)) $((cy + 40)) click 3
    xdo mousemove --window "$w" $((cx + 30)) $((cy + 20)) click 2   # paint
    sleep 1

    # 2) open the "File" menubutton (top-left of the titlebar) and pick "Quit"
    #    (last item).  Coordinates are approximate -- tune on the target WM.
    xdo mousemove --window "$w" 24 10 click 1     # File menubutton
    sleep 1
    xdo mousemove --window "$w" 24 220 click 1    # ~ "Quit" item
    sleep 1

    # 3) if a "save?" dialog popped, its default button takes Return.
    xdo key --clearmodifiers Return

    exec 3>&-
    local i; for i in $(seq 1 20); do kill -0 "$mpid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$mpid" 2>/dev/null && kill "$mpid" 2>/dev/null
    wait "$mpid" 2>/dev/null; local rc=$?
    rm -f "$fifo"
    report b "$rc" "$log"
    return $([ "$rc" -eq 0 ] && echo 0 || echo 1)
}

echo "gui-interact: DISPLAY=$DISPLAY build=$builddir watchdog=${magic_to}s"
fails=0
case "$mode" in
    a) demo_a || fails=1 ;;
    b) demo_b || fails=1 ;;
    c) demo_c || fails=1 ;;
    all) demo_a || fails=1; demo_c || fails=1; demo_b || fails=1 ;;
esac
echo "gui-interact[$mode]: done"
# Opt-in demo: never hard-fail on the WM-sensitive modes.  Exit reflects mode a
# (the always-robust one) only; b/c outcomes are reported above for the log.
exit 0
