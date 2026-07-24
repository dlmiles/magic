#!/usr/bin/env bash
#
# x11-stop.sh -- tear down the Xvfb + openbox that x11-start.sh launched for a
# given $DISPLAY, using the per-display pidfile it wrote (never `ps`).  Each PID
# is verified against /proc/<pid>/comm before it is signalled, so a recycled PID
# that now belongs to some unrelated process is left alone.  Signals TERM first,
# then KILL only if it does not go away.  CI does not need this (the runner is
# ephemeral); it is here for local runs and for `run.sh shutdown`.
#
# Display resolution: SMOKE_DISPLAY, else DISPLAY, else :99.
# Env: SMOKE_X11_LOGDIR (default $TMPDIR) -- where the pidfile lives.
set -uo pipefail

disp="${SMOKE_DISPLAY:-${DISPLAY:-:99}}"
logdir="${SMOKE_X11_LOGDIR:-${TMPDIR:-/tmp}}"
dnum="${disp#:}"; dnum="${dnum%%.*}"
pidfile="$logdir/magic-x11-$dnum.pids"

log() { printf 'x11-stop: %s\n' "$*" >&2; }

# _stop NAME PID -- signal PID (TERM, then KILL) but only if it really is NAME.
_stop() {
    local name="$1" pid="${2:-}" comm
    [ -n "$pid" ] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then log "$name pid $pid already gone"; return 0; fi
    # Safety: confirm the live process is the one we recorded (guards against a
    # PID that has since been recycled).  Read /proc, not ps.
    if [ -r "/proc/$pid/comm" ]; then
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        if [ "$comm" != "$name" ]; then
            log "skip pid $pid: /proc comm '$comm' != '$name' (recycled?)"
            return 0
        fi
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        log "$name pid $pid force-killed"
    else
        log "$name pid $pid stopped"
    fi
}

if [ -f "$pidfile" ]; then
    log "stopping display $disp from $pidfile"
    while read -r name pid; do
        [ -n "${name:-}" ] || continue
        _stop "$name" "${pid:-}"
    done < "$pidfile"
    rm -f "$pidfile"
else
    log "no pidfile $pidfile (nothing to stop for $disp)"
fi

# Clean up the X server's lock + socket in case the server did not.
rm -f "/tmp/.X${dnum}-lock" "/tmp/.X11-unix/X${dnum}" 2>/dev/null || true
