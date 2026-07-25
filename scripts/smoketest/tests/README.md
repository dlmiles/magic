# magic test catalog

YAML-driven tests run by `scripts/smoketest/magictest.py`.  Each test is a
`NNN-name/test.yaml`; the numeric prefix orders them.  Run one, or the whole
catalog:

```sh
# headless (-dnull) tests run anywhere; x11 tests need a display
python3 scripts/smoketest/magictest.py run scripts/smoketest/tests            # all (x11 skipped w/o DISPLAY)
eval "$(scripts/smoketest/x11-start.sh)"                                        # ... then x11 too
python3 scripts/smoketest/magictest.py run scripts/smoketest/tests -v          # verbose
python3 scripts/smoketest/magictest.py run scripts/smoketest/tests/020-workflow-dnull
python3 scripts/smoketest/magictest.py list scripts/smoketest/tests
```

The runner exits non-zero if any test fails; x11 tests **skip** (not fail) when
`DISPLAY` is unset, so the same catalog runs in both the headless and the GUI CI
phase.  Set `MAGIC_BUILDDIR` to the out-of-tree build (default `build-tmp`).

## Current tests

| # | mode | what it covers |
|---|------|----------------|
| 010 | dnull | boots, loads tech, core commands registered |
| 020 | dnull | extract → ext2spice → gds → cif → drc on min.mag; asserts + a GDSII validator |
| 030 | x11 | boots under -d X11 on a headless Xvfb; a layout window appears |
| 040 | x11 | the 020 workflow through the real GUI; outputs functionally identical |
| 050 | x11 | drives the GUI with xdotool mouse events interleaved with send/expect |
| 060 | dnull | send, then `close_stdin` (EOF) + `wait` for magic to exit; changes the timeout on the fly |

## test.yaml format

See the header of `scripts/smoketest/magictest.py` for the full schema.  In
brief: top-level `mode` (dnull|x11), `tech`, `timeout` (overall cap, s),
`timeout_ms` (inherited per-op timeout, default 30000), `inputs` (files staged
into the per-test work dir), `expect_exit`, and a list of `steps`.  Each step
may combine:

- `send:` a command line to magic's stdin
- `close_stdin: true` — send EOF (ends magic where it runs batch, e.g. -dnull)
- `expect:` a regex to wait for; `timeout_ms:` (or legacy `timeout:` in s) overrides for this step
- `wait: true` — block until magic exits (uses the current timeout)
- `set_timeout_ms:` N — change the inherited blocking timeout from here on
- `sleep:` seconds
- `xdotool:` `[args...]` (x11) — `{win}` is the layout window id
- `assert:` `{ exists|nonempty|absent, contains: {file, pattern}, min_lines: {file, n} }`
- `validate:` `{ run: [argv...], exit, stdout_matches, stdout_contains }` — an external checker

Progress lines carry a `0000.000` elapsed-time prefix (seconds since the session
started) and PASS/FAIL reports the total session duration.

## Crash detection

Core dumps are enabled for magic (`RLIMIT_CORE` is set in the child, and it runs
with `cwd` = the per-test dir).  If magic dies by a crash signal
(`SIGSEGV`/`SIGABRT`/`SIGBUS`/`SIGFPE`/`SIGILL`/…) the run is reported as a
crash and **fails**, logging the signal plus any `core*` file found (path, size,
mtime):

```
CRASH: magic CRASHED by SIGSEGV (signal 11)
CORE: /tmp/magictest.xxxx/core.magicexec.12345  size=... bytes  mtime=...
```

For a core to be a *file* the kernel's `core_pattern` must point at one; CI does
`sudo sysctl -w kernel.core_pattern='core.%e.%p'` before the tests.  If no file
is found the report prints the active `core_pattern` so you can see why (e.g. it
was piped to systemd-coredump/apport).  A test that *expects* a particular
signal death can set `expect_exit:` to the negative signal code (e.g. `-11`).

Placeholders in strings: `{work}` (per-test dir), `{src}` (repo root), `{tech}`,
`{cell}` (first `.mag` input's basename), `{display}`, `{win}`.  Tcl's own `{...}`
braces pass through untouched.

## Adding a test

Create `NNN-slug/test.yaml` with the next free number.  Put any input layouts
under `inputs:` (paths relative to the repo root; they are copied into `{work}`).
Prefer loose, functional checks (a token is present, a sane line count, a
validator's exit status) over byte-exact matches — outputs differ in embedded
paths/timestamps between runs and devices.
