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
| 050 | x11 | drives the GUI with xdotool mouse events interleaved with send/expect (`if: linux`) |
| 060 | dnull | send, then `close_stdin` (EOF) + `wait` for magic to exit; changes the timeout on the fly |
| 070 | dnull | `exec` external commands against the live process via `{pid}`; `{{…}}` escaping (`if: linux`) |

## test.yaml format

See the header of `scripts/smoketest/magictest.py` for the full schema.  In
brief: top-level `mode` (dnull|x11), `tech`, `cwd` (magic's working directory;
default is the test's own directory = the `{default}` placeholder — override
with `{work}`/`{testdir}`/`{src}` or an absolute path), `timeout` (overall cap,
s), `timeout_ms` (inherited per-op timeout, default 30000), `inputs` (files
staged into the per-test work dir), `tags`/`metadata` (see below), `expect_exit`,
and a list of `steps`.  Every setting resets to its default for each test —
nothing carries between tests.  Each step may combine:

- `send:` a command line to magic's stdin
- `close_stdin: true` — send EOF (ends magic where it runs batch, e.g. -dnull)
- `expect:` a regex to wait for; `timeout_ms:` (or legacy `timeout:` in s) overrides for this step
- `wait: true` — block until magic exits (uses the current timeout)
- `set_timeout_ms:` N — change the inherited blocking timeout from here on
- `sleep:` seconds
- `xdotool:` `[args...]` (x11) — `{win}` is the layout window id
- `exec:` `[argv...]` / `"cmd"` / `{run, exit, stdout_matches, stdout_contains}` — run any
  command (e.g. against the live process via `{pid}`); fails on non-zero exit unless told otherwise
- `assert:` `{ exists|nonempty|absent, contains: {file, pattern}, min_lines: {file, n} }`
- `validate:` `{ run: [argv...], exit, stdout_matches, stdout_contains }` — an external checker

### Placeholders & escaping

Strings take `{work}` `{src}` `{testdir}` `{cwd}` `{tech}` `{cell}` `{display}`
`{win}` `{pid}`/`{MAGICPID}` (the live magic pid), and `{default}` in `cwd:`.
Only identifier-shaped `{name}` tokens are substituted, so Tcl braces and regex
quantifiers (`{4}`, `{$x}`, `{a b}`) pass through untouched.  Write `{{name}}`
for a literal `{name}`; an unknown `{identifier}` is left as-is and warned once
on stderr (so typos surface).

Progress lines carry a `0000.000` elapsed-time prefix (seconds since the session
started) and PASS/FAIL reports the total session duration.

## Cross-platform gating (`if:`)

One catalog is meant to run on any platform (`unix` = linux/macos/\*bsd/solaris/
cygwin…, plus windows).  A test — or an individual step — carries `if:` naming
the platform(s) it applies to and is **skipped** elsewhere:

```yaml
if: linux                 # only Linux (test-level)
if: [linux, macos]        # either
if: unix                  # any non-Windows
if: "!windows"            # everywhere except Windows
steps:
  - if: linux             # a single step, gated
    exec: ["cat", "/proc/{pid}/comm"]
```

Tokens: an OS name (`linux macos windows freebsd openbsd netbsd solaris cygwin`
…), a family (`unix`/`posix`), `any`/`*`, or `!name`; a string or list.  The
detected platform is the `{platform}` placeholder; set `MAGICTEST_OS` to force
it (for testing).  So on macOS the x11 tests run against XQuartz while the
Linux-only ones (050 xdotool, 070 `/proc`) skip automatically.

## Tags & metadata (cataloguing / filtering)

A test can carry labels and a key/value store, used to subselect which tests run:

```yaml
tags: [x11, gui, slow]        # or nested as metadata.tags
metadata:
  area: extraction
  owner: dmiles
```

```sh
magictest.py run  tests --tag x11              # only tests tagged x11 (any of them)
magictest.py run  tests --tag dnull,smoke      # tagged dnull OR smoke
magictest.py run  tests --filter area=gui      # metadata area == gui
magictest.py list tests --tag x11              # list with tags/metadata shown
```

`--tag` and `--filter` are repeatable; a test must match every `--filter` and at
least one requested tag.  Each test's launch banner also prints its tags/metadata,
its working directory (flagged when non-default), the full launch command, and
the relevant environment.

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

Core selection is disciplined: because a test's `cwd` is reused between runs,
only a core whose mtime is **>= the process start time** counts as this crash
(older ones are flagged `[stale: pre-start]`), and among those the one carrying
the pid in its name (`core.<exe>.<pid>`) is preferred.  For the selected core a
**non-interactive all-thread backtrace** is dumped with `gdb` (Linux) or `lldb`
(macOS) — e.g. `gdb -batch -ex 'thread apply all bt'` — so a crash is actionable
straight from the CI log.  Install gdb/lldb for it (the debugger is only invoked
when a core file actually exists).

## Adding a test

Create `NNN-slug/test.yaml` with the next free number.  Put any input layouts
under `inputs:` (paths relative to the repo root; they are copied into `{work}`).
Prefer loose, functional checks (a token is present, a sane line count, a
validator's exit status) over byte-exact matches — outputs differ in embedded
paths/timestamps between runs and devices.
