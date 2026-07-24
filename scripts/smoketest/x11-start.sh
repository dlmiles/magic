#!/usr/bin/env bash
#
# x11-start.sh -- bring up a headless X server (Xvfb) plus a minimal window
# manager (openbox) for the GUI smoke test, wait until it is ready, and publish
# the DISPLAY assignment.
#
#   CI:     scripts/smoketest/x11-start.sh              # writes DISPLAY to $GITHUB_ENV
#   local:  eval "$(scripts/smoketest/x11-start.sh)"    # exports DISPLAY in this shell
#
# stdout carries exactly one line, "export DISPLAY=...", so `eval` exports it
# (a bare assignment would only set a shell variable, not pass it to children
# like run.sh).  When running under GitHub Actions ($GITHUB_ENV set) the script
# *also* appends the plain "DISPLAY=..." line that $GITHUB_ENV expects, so later
# steps inherit it -- no shell-level export survives between steps anyway.  All
# diagnostics go to stderr.  Each server is started with nohup so it survives
# this script exiting (and into the next CI step) while $! stays the *real* pid
# (nohup exec's the program in place -- unlike `setsid &`, whose $! is the
# short-lived setsid parent).  The pids are written to a per-$DISPLAY pidfile so
# `x11-stop.sh` / `run.sh shutdown` can tear this exact server down without ps,
# and so several servers can run in parallel on different displays.
#
# Env:
#   SMOKE_DISPLAY   X display to use        (default: :99)
#   SMOKE_XVFB_WHD  Xvfb screen WxHxDepth   (default: 1280x1024x24)
#   SMOKE_X11_LOGDIR  where to put xvfb/openbox logs + pidfile (default: $TMPDIR)
set -euo pipefail

disp="${SMOKE_DISPLAY:-:99}"
whd="${SMOKE_XVFB_WHD:-1280x1024x24}"
logdir="${SMOKE_X11_LOGDIR:-${TMPDIR:-/tmp}}"
dnum="${disp#:}"; dnum="${dnum%%.*}"
pidfile="$logdir/magic-x11-$dnum.pids"

log() { printf 'x11-start: %s\n' "$*" >&2; }

for tool in Xvfb openbox xdotool; do
    command -v "$tool" >/dev/null 2>&1 || { log "ERROR: '$tool' not found on PATH"; exit 1; }
done

# -ac disables host-based access control (no xauth cookie needed for a throwaway
# CI display); -nolisten tcp keeps it to the local unix socket.
log "starting Xvfb on $disp ($whd)"
nohup Xvfb "$disp" -screen 0 "$whd" -ac -nolisten tcp \
    > "$logdir/xvfb.log" 2>&1 < /dev/null &
xvfb_pid=$!

export DISPLAY="$disp"

# Wait for the server to accept connections (xdotool talks to $DISPLAY).
ready=0
for _ in $(seq 1 50); do
    if xdotool getdisplaygeometry >/dev/null 2>&1; then ready=1; break; fi
    if ! kill -0 "$xvfb_pid" 2>/dev/null; then
        log "ERROR: Xvfb exited early -- log follows:"
        sed 's/^/  xvfb| /' "$logdir/xvfb.log" >&2 2>/dev/null || true
        exit 1
    fi
    sleep 0.2
done
[ "$ready" -eq 1 ] || { log "ERROR: X server on $disp never became ready"; exit 1; }
log "X server ready: geometry $(xdotool getdisplaygeometry 2>/dev/null | tr ' ' 'x')"

# A window manager so top-levels are mapped/managed -- needed for meaningful GUI
# interaction later, harmless for a bare startup check.
log "starting openbox"
nohup openbox > "$logdir/openbox.log" 2>&1 < /dev/null &
openbox_pid=$!
for _ in $(seq 1 25); do
    wmctrl -m >/dev/null 2>&1 && break
    sleep 0.2
done
log "window manager: $(wmctrl -m 2>/dev/null | sed -n 's/^Name: //p' | head -1 || echo '(none reported)')"

# One "NAME PID" line per process, in a file keyed to this $DISPLAY so parallel
# servers on other displays each get their own.  x11-stop.sh reads NAME to
# verify each PID via /proc before signalling it.
{ printf 'Xvfb %s\n' "$xvfb_pid"; printf 'openbox %s\n' "$openbox_pid"; } > "$pidfile"
log "pids in $pidfile (Xvfb=$xvfb_pid openbox=$openbox_pid)"

# Publish DISPLAY.  Under GitHub Actions, append the plain assignment to
# $GITHUB_ENV so subsequent steps inherit it (Actions does not understand
# "export"); a shell-level export would not survive to the next step anyway.
if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'DISPLAY=%s\n' "$disp" >> "$GITHUB_ENV"
    log "wrote DISPLAY=$disp to \$GITHUB_ENV"
fi
# stdout: an exported assignment, so `eval "$(x11-start.sh)"` exports DISPLAY.
printf 'export DISPLAY=%s\n' "$disp"
