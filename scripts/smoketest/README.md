# Build-tree smoke tests

Fast, headless sanity checks that a freshly built `magic` actually boots and
does real work.  They run the `-dnull` build (no X, no `wish`) straight from an
out-of-tree build directory via its generated `run_magicnull.sh`, so they need
no `make install`.  CI (`.github/workflows/main.yml`, `main-aarch64.yml`) runs
them after an out-of-tree build in `build-tmp`, but they are equally useful
locally.

## Modes

| Mode       | Launcher                        | What it proves                          |
|------------|---------------------------------|-----------------------------------------|
| `startup`  | `run_magicnull.sh` (`-dnull`)   | The binary boots under Tcl, loads a technology, and the core command surface is registered (`startup.tcl`). Reads/writes nothing. |
| `workflow` | `run_magicnull.sh` (`-dnull`)   | The extract → `ext2spice` → `gds` → `cif` → `drc` pipeline runs against the *same* `npm/examples/min.mag` the WASM CI uses, and the generated artifacts look valid (`workflow.tcl` + `validate.sh`). |
| `gui`      | `run_magic.sh -d X11 -noconsole`| The real GUI binary connects to a headless X display, brings up its X11 graphics, and loads a tech + layout, then exits cleanly (`gui.tcl`). Needs a running Xvfb+openbox (see below). |

## Running locally

```sh
# from the source tree, after an out-of-tree build in ./build-tmp
./configure && make prepare && make -j"$(nproc)"        # (or a build-tmp dir)
scripts/smoketest/run.sh startup
scripts/smoketest/run.sh workflow
```

All modes exit non-zero on any failure and print a per-check summary.

### The `gui` mode (headless X11)

`gui` runs the real `magic` GUI against a headless X server, so it first needs
Xvfb + a window manager.  On Debian/Ubuntu:

```sh
sudo apt-get install -y xvfb openbox wmctrl xdotool

eval "$(scripts/smoketest/x11-start.sh)"   # starts Xvfb+openbox, exports DISPLAY
scripts/smoketest/run.sh gui
scripts/smoketest/run.sh shutdown          # tear the server down again
```

`run.sh shutdown` (a thin wrapper over `x11-stop.sh`) stops the Xvfb+openbox for
the current `$DISPLAY` using the PIDs `x11-start.sh` recorded in a per-display
pidfile (`$TMPDIR/magic-x11-<n>.pids`) — never `ps` — and verifies each PID via
`/proc` before signalling it (TERM, then KILL).  Because the pidfile is keyed by
display, servers can run in parallel: give each `SMOKE_DISPLAY=:99`, `:100`, …
and stop each independently with the same `SMOKE_DISPLAY`.

`x11-start.sh` prints `export DISPLAY=:99` on stdout (diagnostics go to stderr),
so `eval "$(...)"` *exports* it to child processes.  Under GitHub Actions it
also writes the plain `DISPLAY=:99` line to `$GITHUB_ENV` itself, so later steps
inherit it with no redirect needed.  Window-level *interaction* (driving magic
with xdotool/wmctrl) is a planned follow-up; those tools are installed now so it
has what it needs.

### Knobs (environment)

| Variable         | Default                  | Meaning                                  |
|------------------|--------------------------|------------------------------------------|
| `MAGIC_BUILDDIR` | `build-tmp`              | out-of-tree build dir with `run_magicnull.sh` |
| `SMOKE_TECH`     | `scmos`                  | technology to load                       |
| `SMOKE_MAG`      | `npm/examples/min.mag`   | input layout for the workflow mode       |
| `SMOKE_WORKDIR`  | fresh `mktemp` dir       | scratch + output directory (kept for inspection if set) |
| `SMOKE_MAGIC_TIMEOUT` | `60`                | (gui) magic's own `-timeout` watchdog, in seconds; `0` disables it |

## Why a separate validator

In `-dnull` batch mode magic prints command failures on stderr but leaves the
process **exit status at 0** — a bad command does not abort the run.  So the
tests do not trust the exit code alone.  Instead:

1. `_prelude.tcl` gives the Tcl scripts `require`/`expect_true` helpers that
   call Tcl `[exit 1]` (which *does* propagate) the moment an assertion fails,
   and each script ends with a unique `SMOKE-*-OK` sentinel.
   For the `gui` mode there is a second line of defence against a *hang* (a GUI
   stalled waiting for input): the driver passes magic's own `-timeout <secs>`
   option (`SMOKE_MAGIC_TIMEOUT`, default 60), which arms a Tcl `after` watchdog
   inside magic that prints a cause message and exits 124 if it fires — a softer,
   self-explaining backstop below the external `timeout` that otherwise SIGKILLs.
2. `validate.sh` independently re-checks the run: launcher exit status, absence
   of fatal markers in the log, the sentinel was reached, and (workflow) that
   every expected artifact exists, is non-empty, and carries a format signature
   (SPICE header, GDSII `HEADER` record, CIF/`.ext` tokens, a DRC total).

## Files

- `_prelude.tcl` — shared Tcl helpers, prepended to each script by `run.sh`.
- `startup.tcl` / `workflow.tcl` / `gui.tcl` — the smoke scripts.
- `run.sh` — driver: assembles the script, runs it, captures the log.
- `validate.sh` — checks the log and artifacts; the sole arbiter of pass/fail.
- `x11-start.sh` / `x11-stop.sh` — bring up / tear down the headless Xvfb+openbox
  used by the `gui` mode.

The `gui` mode currently proves the GUI *starts* on a headless display.
Driving actual window interaction (xdotool/wmctrl clicking, drawing, screenshot
comparison) is a planned follow-up built on the same Xvfb+openbox setup.
