# Build-tree smoke tests

Fast, headless sanity checks that a freshly built `magic` actually boots and
does real work.  They run the `-dnull` build (no X, no `wish`) straight from an
out-of-tree build directory via its generated `run_magicnull.sh`, so they need
no `make install`.  CI (`.github/workflows/main.yml`, `main-aarch64.yml`) runs
them after an out-of-tree build in `build-tmp`, but they are equally useful
locally.

## Modes

| Mode       | What it proves                                                         |
|------------|------------------------------------------------------------------------|
| `startup`  | The binary boots under Tcl, loads a technology, and the core command surface is registered (`startup.tcl`). Reads/writes nothing. |
| `workflow` | The extract → `ext2spice` → `gds` → `cif` → `drc` pipeline runs against the *same* `npm/examples/min.mag` the WASM CI uses, and the generated artifacts look valid (`workflow.tcl` + `validate.sh`). |

## Running locally

```sh
# from the source tree, after an out-of-tree build in ./build-tmp
./configure && make prepare && make -j"$(nproc)"        # (or a build-tmp dir)
scripts/smoketest/run.sh startup
scripts/smoketest/run.sh workflow
```

Both exit non-zero on any failure and print a per-check summary.

### Knobs (environment)

| Variable         | Default                  | Meaning                                  |
|------------------|--------------------------|------------------------------------------|
| `MAGIC_BUILDDIR` | `build-tmp`              | out-of-tree build dir with `run_magicnull.sh` |
| `SMOKE_TECH`     | `scmos`                  | technology to load                       |
| `SMOKE_MAG`      | `npm/examples/min.mag`   | input layout for the workflow mode       |
| `SMOKE_WORKDIR`  | fresh `mktemp` dir       | scratch + output directory (kept for inspection if set) |

## Why a separate validator

In `-dnull` batch mode magic prints command failures on stderr but leaves the
process **exit status at 0** — a bad command does not abort the run.  So the
tests do not trust the exit code alone.  Instead:

1. `_prelude.tcl` gives the Tcl scripts `require`/`expect_true` helpers that
   call Tcl `[exit 1]` (which *does* propagate) the moment an assertion fails,
   and each script ends with a unique `SMOKE-*-OK` sentinel.
2. `validate.sh` independently re-checks the run: launcher exit status, absence
   of fatal markers in the log, the sentinel was reached, and (workflow) that
   every expected artifact exists, is non-empty, and carries a format signature
   (SPICE header, GDSII `HEADER` record, CIF/`.ext` tokens, a DRC total).

## Files

- `_prelude.tcl` — shared Tcl helpers, prepended to each script by `run.sh`.
- `startup.tcl` / `workflow.tcl` — the two smoke scripts.
- `run.sh` — driver: assembles the script, runs it headless, captures the log.
- `validate.sh` — checks the log and artifacts; the sole arbiter of pass/fail.

X11 / GUI interaction smoke tests are intended as a later addition (a separate
step driving `run_magic.sh` against a virtual display).
