#!/usr/bin/env python3
"""
magictest.py -- YAML-driven orchestration for magic smoke/interaction tests.

A test is a YAML file that says which mode to run magic in and lists a sequence
of steps: send a command, expect output, assert on produced files, run an
external validator, or (X11 mode) drive the GUI with xdotool.  Magic runs under
a pseudo-terminal so it line-buffers like an interactive session, which is what
makes send/expect reliable.

Usage:
    magictest.py run   <test.yaml | catalog-dir> [-v] [--tag T[,T]] [--filter K=V]
    magictest.py list  <catalog-dir> [--tag T[,T]] [--filter K=V]

A "catalog" is a directory of NNN-name/test.yaml tests; `run` on a directory
executes every test.yaml under it in sorted (numbered) order.  A failing test
does NOT stop the run -- every remaining test is still attempted -- but the run
exits non-zero if any failed, so CI reports the whole catalog yet the step still
fails.  --tag / --filter subselect which tests run (both repeatable): a test
matches --tag if it carries any of the named tags, and --filter K=V if its
metadata[K] == V.

Under GitHub Actions ($GITHUB_STEP_SUMMARY set) a Markdown summary of the run is
appended to the job summary -- pass/fail/skip counts plus tables of the FAILED
and SKIPPED tests with reasons -- so they are visible at a glance without
scrolling the log.  Set SMOKE_SUMMARY_LABEL to title the section (default is
"<platform> <machine>", e.g. "linux aarch64").

Test YAML schema (all keys optional unless noted; per-test -- every setting
resets to its default for each test, nothing carries between tests):
    name:        short name (defaults to the file/dir name)
    description: free text
    mode:        dnull (default) | x11        -- graphics device
    tech:        technology to preload substitutions with (e.g. scmos)
    cwd:         magic's working directory; default is the test's own directory
                 (= the {default} placeholder).  Accepts placeholders ({work},
                 {testdir}, {src}); `cwd: {default}` resets it to the default.
    timeout:     per-test wall-clock cap, seconds (default 180); also magic's
                 own -timeout watchdog for x11
    timeout_ms:  inherited timeout for blocking steps (expect/wait), ms
                 (default 30000); a step can change it live (set_timeout_ms)
    builddir:    out-of-tree build dir (default $MAGIC_BUILDDIR or build-tmp)
    inputs:      [paths]  -- files copied into the work dir before the run
    tags:        [labels] -- for --tag subselection (also metadata.tags)
    metadata:    { key: value, ... } -- catalogue store; --filter matches on it
    if:          environment gate: an OS name (linux, macos, windows, freebsd,
                 openbsd, netbsd, solaris, cygwin, ...), a family (unix/posix =
                 any non-Windows), an x11 tag detected at run time (x11,
                 xquartz, openbox and other WM names), any/*, or !name; a string
                 or list.  The test is skipped where it does not match, so one
                 catalog is portable.
    steps:       [ ... ]  -- see below
    expect_exit: int      -- required magic exit status (default 0)

Each step is a mapping with one or more of:
    send:    "command"           -- write a line to magic's stdin
    close_stdin: true            -- close stdin (EOF); ends magic where it runs batch
    expect:  "regex"             -- read until it matches (fails on timeout)
    wait:    true                -- block until magic exits (uses current timeout)
    timeout_ms: N                -- per-step override for this expect/wait (ms)
    timeout: seconds             -- same, in seconds (legacy)
    set_timeout_ms: N            -- change the inherited blocking timeout from here on
    if:      <env>               -- run this step only in matching env (OS/x11 tag)
    echo:    "message"           -- print a message (with placeholders)
    sleep:   seconds
    xdotool: [args...]           -- run xdotool (x11 only); {win} = layout window
    exec:    [argv...]|"cmd"|{run:..., exit:0, stdout_matches, stdout_contains}
             -- run an arbitrary command (e.g. against the live process via
                {pid}); fails on non-zero exit unless `exit:` says otherwise
    assert:  { exists|nonempty|absent: path,
               contains: {file, pattern}, min_lines: {file, n} }
    validate:{ run: [argv...]|"cmd", exit: 0, stdout_matches: "regex",
               stdout_contains: "str" }

Placeholders in strings: {work} {src} {testdir} {cwd} {tech} {cell} {display}
{win} {pid}/{MAGICPID} (magic's process id) {platform}, and {default} in `cwd:`.
(Set MAGICTEST_OS to force the detected platform, for testing the gating.)  Only
identifier-shaped {name} tokens are substituted, so Tcl braces and regex
quantifiers ({4}, {$x}, {a b}) pass through; write {{name}} for a literal
{name}, and an unknown {identifier} is left as-is with a stderr warning.
magic's cwd is logged with the launch/env, flagged when non-default.

At the start of each test the full launch command line and the relevant
environment (MAGIC_*, SMOKE_*, CAD_*, DISPLAY, ...) are logged.  Progress lines
are prefixed with elapsed time since the session started as 0000.000 (seconds),
and PASS/FAIL prints the total session duration.
"""

import os, sys, re, pty, time, shlex, select, signal, subprocess, tempfile, shutil, glob, resource, platform

HERE = os.path.dirname(os.path.abspath(__file__))
SRCROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

try:
    import yaml
except ImportError:
    sys.exit("magictest: PyYAML is required (pip install pyyaml / apt install python3-yaml)")

# Signals that mean magic *crashed* (as opposed to being torn down by us).
CRASH_SIGNALS = {getattr(signal, s, None) for s in
                 ("SIGSEGV", "SIGABRT", "SIGBUS", "SIGFPE", "SIGILL", "SIGSYS", "SIGTRAP")} - {None}


class TestError(Exception):
    pass


def _c(code, s):
    return s if not sys.stdout.isatty() else f"\033[{code}m{s}\033[0m"


def _core_pattern():
    try:
        return open("/proc/sys/kernel/core_pattern").read().strip()
    except OSError:
        return "?"


def _find_cores(dirs):
    """Return [(path, size, mtime)] for core files in dirs (core, core.*)."""
    out = []
    for d in dirs:
        if not d:
            continue
        for pat in ("core", "core.*", "*.core"):
            for p in sorted(glob.glob(os.path.join(d, pat))):
                try:
                    st = os.stat(p)
                    out.append((p, st.st_size, st.st_mtime))
                except OSError:
                    pass
    return out


def _exe_for_core(core, dirs):
    """Best-effort executable path for a core named core.<exe>.<pid>, so the
    debugger has the symbols; None lets it auto-detect from the core."""
    m = re.match(r"core\.([A-Za-z0-9_.+-]+)\.\d+$", os.path.basename(core))
    if not m:
        return None
    exe = m.group(1)
    builddir = os.path.abspath(os.environ.get("MAGIC_BUILDDIR", "build-tmp"))
    for d in list(dirs) + [os.path.join(builddir, "tcltk"), os.path.join(builddir, "magic")]:
        cand = os.path.join(d or ".", exe)
        if os.path.isfile(cand):
            return cand
    return None


def _backtrace(core, exe=None, timeout=90):
    """Dump every thread's backtrace from a core, non-interactively, with gdb
    (Linux) or lldb (macOS).  Returns (tool, text), or (None, reason)."""
    if shutil.which("gdb"):
        cmd = ["gdb", "-batch", "-nx",
               "-ex", "set pagination off", "-ex", "set width 0",
               "-ex", "thread apply all bt", "-ex", "quit"]
        cmd += ([exe, core] if exe else ["-c", core])
        tool = "gdb"
    elif shutil.which("lldb"):
        cmd = ["lldb", "--batch", "-o", "thread backtrace all", "-o", "quit"]
        cmd += ([exe, "--core", core] if exe else ["--core", core])
        tool = "lldb"
    else:
        return (None, "no debugger (install gdb or lldb) for a backtrace")
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (r.stdout + ("\n" + r.stderr if r.returncode and r.stderr else "")).strip()
        return (tool, out or f"({tool} produced no output)")
    except Exception as e:
        return (tool, f"({tool} failed: {e})")


# Cross-platform gating.  A test or step may carry `if:` naming the platform(s)
# it applies to; it is skipped elsewhere.  Tokens: an OS name (linux, macos,
# windows, freebsd, openbsd, netbsd, solaris, cygwin, ...), a family (unix/posix
# = any non-Windows), any/* (always), or !name to exclude.  A string or a list.
_UNIX = {"linux", "macos", "freebsd", "openbsd", "netbsd", "dragonfly",
         "solaris", "cygwin", "aix", "gnu", "hurd"}


def _platform_now():
    forced = os.environ.get("MAGICTEST_OS")   # override, for testing the gating
    if forced:
        return forced.strip().lower()
    s = platform.system().lower()
    if s.startswith("cygwin") or s.startswith("mingw") or s.startswith("msys"):
        return "cygwin"
    return {"darwin": "macos", "sunos": "solaris", "": "unknown"}.get(s, s)


def _tool(name):
    """Find a tool on PATH, or in the usual X11 bin dirs (macOS keeps them out
    of the default PATH)."""
    p = shutil.which(name)
    if p:
        return p
    for d in ("/opt/X11/bin", "/usr/X11/bin", "/usr/X11R6/bin"):
        c = os.path.join(d, name)
        if os.access(c, os.X_OK):
            return c
    return None


_X11TAGS_CACHE = {}


def _x11_tags(display):
    """Identity tags for the running X environment, so `if:` can gate on the
    server/WM: 'x11' (a display exists), 'xquartz' (macOS X server, via the
    Apple-WM extension), and the window-manager name from wmctrl (e.g.
    'openbox').  Empty when there is no display.  Cached per display."""
    if not display:
        return set()
    if display in _X11TAGS_CACHE:
        return _X11TAGS_CACHE[display]
    tags = {"x11"}
    env = {**os.environ, "DISPLAY": display}
    xdpy = _tool("xdpyinfo")
    if xdpy:
        try:
            out = subprocess.run([xdpy], capture_output=True, text=True,
                                 timeout=10, env=env).stdout.lower()
            if "apple-wm" in out or "xquartz" in out:
                tags.add("xquartz")
        except Exception:
            pass
    wmc = _tool("wmctrl")
    if wmc:
        try:
            out = subprocess.run([wmc, "-m"], capture_output=True, text=True,
                                 timeout=8, env=env).stdout
            m = re.search(r"(?im)^Name:\s*(\S+)", out)
            if m:
                tags.add(m.group(1).lower())     # e.g. 'openbox'
        except Exception:
            pass
    _X11TAGS_CACHE[display] = tags
    return tags


def _when_ok(spec, tags, plat):
    """Match an `if:` clause against the run's tag set (the platform plus the
    x11 env tags).  Tokens: an OS/family (unix/posix), an env tag (x11, xquartz,
    openbox, ...), any/*, or !name; a string or list."""
    if spec is None:
        return True
    toks = [spec] if isinstance(spec, str) else list(spec)
    pos, neg = [], []
    for t in toks:
        t = str(t).strip().lower()
        (neg if t.startswith("!") else pos).append(t.lstrip("!").strip())

    def hit(tok):
        if tok in ("unix", "posix"):
            return plat in _UNIX
        if tok in ("any", "all", "*"):
            return True
        return tok in tags

    if any(hit(t) for t in neg):
        return False
    return True if not pos else any(hit(t) for t in pos)


def _tags_meta(spec):
    """(sorted tag list, metadata dict) for a test spec.  Tags come from the
    top-level `tags:` and/or `metadata.tags`; metadata is the `metadata:` dict
    minus its `tags` key -- a plain key/value store for cataloguing."""
    md = dict(spec.get("metadata") or {})
    tags = set(spec.get("tags") or []) | set(md.pop("tags", []) or [])
    return (sorted(str(t) for t in tags), md)


def _selected(path, want_tags, want_meta):
    """True if the test at path matches the tag/metadata filters (used to
    subselect which tests to run)."""
    try:
        spec = yaml.safe_load(open(path)) or {}
    except Exception:
        return not (want_tags or want_meta)
    tags, md = _tags_meta(spec)
    if want_tags and not (set(tags) & want_tags):
        return False
    for k, v in want_meta:
        if str(md.get(k)) != v:
            return False
    return True


class MagicSession:
    """Drives one magic process.  stdin is a pipe we can close (to send EOF
    without disturbing output); stdout+stderr are a PTY, so magic line-buffers
    like an interactive terminal.  Every blocking wait uses the *current*
    timeout (milliseconds), which the YAML can change on the fly."""

    def __init__(self, cmd, env, logpath, t0, timeout_ms, cwd=None, display=None):
        self.t0 = t0
        self.timeout_ms = timeout_ms          # inherited default for blocking ops
        self.master, slave = pty.openpty()    # magic's stdout+stderr (a tty)
        self.stdin_r, self.stdin_w = os.pipe() # magic's stdin (closable for EOF)
        self.log = open(logpath, "wb")
        self.buf = ""                          # output not yet consumed by expect
        self.display = display
        self.win = ""
        self.stdin_open = True

        def _preexec():
            # Enable core dumps for magic so a crash leaves a core file, then
            # start a new session so we can signal the whole group on teardown.
            try:
                resource.setrlimit(resource.RLIMIT_CORE,
                                   (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
            except Exception:
                pass
            os.setsid()

        self.proc = subprocess.Popen(
            cmd, stdin=self.stdin_r, stdout=slave, stderr=slave,
            env=env, cwd=cwd, close_fds=True, preexec_fn=_preexec)
        os.close(slave)
        os.close(self.stdin_r)                 # the child owns the read end now

    def ts(self):
        """Seconds.milliseconds elapsed since session start, as 0000.000."""
        return f"{time.time() - self.t0:08.3f}"

    def _secs(self, timeout_ms):
        return (self.timeout_ms if timeout_ms is None else timeout_ms) / 1000.0

    def _drain(self, budget=0.2):
        r, _, _ = select.select([self.master], [], [], budget)
        if not r:
            return False
        try:
            data = os.read(self.master, 65536)
        except OSError:
            return False
        if not data:
            return False
        self.log.write(data); self.log.flush()
        self.buf += data.decode("utf-8", "replace")
        return True

    def send(self, line):
        if not self.stdin_open:
            raise TestError("send after close_stdin")
        os.write(self.stdin_w, (line + "\n").encode())

    def close_stdin(self):
        """Send EOF to magic's stdin (where magic runs batch, this ends it)."""
        if self.stdin_open:
            os.close(self.stdin_w)
            self.stdin_open = False

    def expect(self, pattern, timeout_ms=None):
        rx = re.compile(pattern)
        secs = self._secs(timeout_ms)
        deadline = time.time() + secs
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            if time.time() > deadline:
                tail = self.buf[-400:].replace("\n", "\\n")
                raise TestError(f"expect timeout ({secs*1000:.0f}ms) for /{pattern}/; recent: ...{tail}")
            if not self._drain(0.2) and self.proc.poll() is not None:
                if rx.search(self.buf):
                    return rx.search(self.buf)
                raise TestError(f"magic exited before /{pattern}/ matched (rc={self.proc.returncode})")

    def wait(self, timeout_ms=None):
        """Wait for magic to exit (draining stdout); returns rc, or None on timeout."""
        deadline = time.time() + self._secs(timeout_ms)
        while time.time() < deadline:
            if self.proc.poll() is not None:
                while self._drain(0.02):
                    pass
                return self.proc.returncode
            self._drain(0.1)
        return None

    def death_report(self, coredirs):
        """If magic has exited by a signal, return (is_crash, summary, [lines]);
        else None.  A crash (SIGSEGV/SIGABRT/...) is distinguished from a plain
        signal.  Core files are listed; the one that belongs to THIS run (mtime
        >= process start, and preferring the pid in its name) is selected and a
        non-interactive all-thread backtrace is dumped for it."""
        rc = self.proc.poll()
        if rc is None or rc >= 0:
            return None
        sig = -rc
        try:
            name = signal.Signals(sig).name
        except ValueError:
            name = f"signal {sig}"
        is_crash = sig in CRASH_SIGNALS
        summary = f"magic {'CRASHED' if is_crash else 'killed'} by {name} (signal {sig})"
        lines = [("CRASH: " if is_crash else "KILLED: ") + summary]

        pid = str(self.proc.pid)
        cores = _find_cores(coredirs)
        # A core is ours only if written at/after the process started (self.t0);
        # cwd is reused between runs, so an older core must not be mistaken for
        # this crash.  Allow a small tolerance for coarse mtime granularity.
        fresh = [c for c in cores if c[2] >= self.t0 - 2.0]
        pidmatch = [c for c in fresh if pid in os.path.basename(c[0])]
        chosen = (max(pidmatch, key=lambda c: c[2]) if pidmatch else
                  max(fresh, key=lambda c: c[2]) if fresh else None)

        for p, size, mt in cores:
            ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(mt))
            tag = (" [selected]" if chosen and p == chosen[0]
                   else "" if mt >= self.t0 - 2.0 else " [stale: pre-start]")
            lines.append(f"CORE: {p}  size={size} bytes  mtime={ts}{tag}")
        if chosen:
            summary += f"; core {chosen[0]} ({chosen[1]} bytes)"
        elif is_crash and not cores:
            lines.append(f"CORE: none found in {coredirs} (core_pattern={_core_pattern()!r})")
        elif is_crash and fresh == []:
            lines.append("CORE: only stale cores (none written since the process started)")

        # Only when a core for this run exists: dump every thread's backtrace.
        if chosen:
            tool, bt = _backtrace(chosen[0], _exe_for_core(chosen[0], coredirs))
            lines.append(f"BACKTRACE ({tool or 'n/a'}):")
            lines += ["  " + ln for ln in bt.splitlines()]
        return (is_crash, summary, lines)

    def find_window(self, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            out = self._xdotool_raw(["search", "--name", "^layout[0-9]"])
            wid = out.split()[0] if out else ""
            if wid:
                self.win = wid
                return wid
            time.sleep(0.5)
        return ""

    def _xdotool_raw(self, args):
        try:
            r = subprocess.run(["xdotool"] + args, capture_output=True, text=True,
                               timeout=8, env={**os.environ, "DISPLAY": self.display or ""})
            return r.stdout.strip()
        except Exception:
            return ""

    def xdotool(self, args):
        self._xdotool_raw(args)

    def close(self):
        try:
            if self.stdin_open:
                os.close(self.stdin_w); self.stdin_open = False
        except Exception:
            pass
        try:
            if self.proc.poll() is None:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
        except Exception:
            pass
        try: os.close(self.master)
        except Exception: pass
        self.log.close()


# Placeholders: {{name}} -> literal {name} (escape); {name} -> ctx[name] when
# known.  Only identifier-shaped names are treated as placeholders, so Tcl braces
# and regex quantifiers ({4}, {2,3}, {$x}, {a b}) pass straight through.  An
# unknown {identifier} is left as-is and warned once (per name) to stderr.
_PH_RE = re.compile(r"\{\{(\w+)\}\}|\{([A-Za-z_]\w*)\}")
_WARNED = set()


def _subst(val, ctx):
    if isinstance(val, list):
        return [_subst(v, ctx) for v in val]
    if isinstance(val, dict):
        return {k: _subst(v, ctx) for k, v in val.items()}
    if not isinstance(val, str):
        return val

    def repl(m):
        if m.group(1) is not None:                 # {{name}} -> literal {name}
            return "{" + m.group(1) + "}"
        name = m.group(2)
        if name in ctx:
            return str(ctx[name])
        if name not in _WARNED:                    # unknown -> pass through, warn once
            _WARNED.add(name)
            sys.stderr.write(f"magictest: warning: unknown placeholder '{{{name}}}' left as-is\n")
        return m.group(0)

    return _PH_RE.sub(repl, val)


def _do_assert(spec, ctx):
    spec = _subst(spec, ctx)
    if "exists" in spec and not os.path.exists(spec["exists"]):
        raise TestError(f"assert exists: {spec['exists']} missing")
    if "absent" in spec and os.path.exists(spec["absent"]):
        raise TestError(f"assert absent: {spec['absent']} exists")
    if "nonempty" in spec:
        p = spec["nonempty"]
        if not (os.path.isfile(p) and os.path.getsize(p) > 0):
            raise TestError(f"assert nonempty: {p} missing or empty")
    if "contains" in spec:
        c = spec["contains"]
        data = open(c["file"], "r", errors="replace").read()
        if not re.search(c["pattern"], data, re.M):
            raise TestError(f"assert contains: /{c['pattern']}/ not in {c['file']}")
    if "min_lines" in spec:
        c = spec["min_lines"]
        n = sum(1 for _ in open(c["file"], "r", errors="replace"))
        if n < int(c["n"]):
            raise TestError(f"assert min_lines: {c['file']} has {n} < {c['n']}")


def _do_validate(spec, ctx, work):
    spec = _subst(spec, ctx)
    run = spec["run"]
    argv = shlex.split(run) if isinstance(run, str) else run
    r = subprocess.run(argv, capture_output=True, text=True, cwd=work, timeout=60)
    want = int(spec.get("exit", 0))
    if r.returncode != want:
        raise TestError(f"validate: {argv} exit {r.returncode} != {want}; stderr={r.stderr[:200]}")
    if "stdout_matches" in spec and not re.search(spec["stdout_matches"], r.stdout):
        raise TestError(f"validate: stdout !~ /{spec['stdout_matches']}/ (got {r.stdout[:200]!r})")
    if "stdout_contains" in spec and spec["stdout_contains"] not in r.stdout:
        raise TestError(f"validate: stdout lacks {spec['stdout_contains']!r}")
    return r.stdout.strip()


def run_test(path, verbose=False):
    with open(path) as f:
        spec = yaml.safe_load(f) or {}
    name = spec.get("name") or os.path.basename(os.path.dirname(os.path.abspath(path))) or path
    mode = spec.get("mode", "dnull")
    tech = spec.get("tech", "scmos")
    timeout = int(spec.get("timeout", 180))               # overall wall-clock cap (s)
    timeout_ms = int(spec.get("timeout_ms", 30000))       # inherited per-op timeout
    builddir = os.path.abspath(spec.get("builddir") or os.environ.get("MAGIC_BUILDDIR", "build-tmp"))

    print(_c("1", f"── test: {name} [{mode}]") + f"  ({spec.get('description','')})")
    _tags, _meta = _tags_meta(spec)
    if _tags or _meta:
        bits = []
        if _tags: bits.append("tags=" + ",".join(_tags))
        if _meta: bits.append("meta=" + " ".join(f"{k}={v}" for k, v in _meta.items()))
        print("   " + "  ".join(bits))

    plat = _platform_now()
    # Tag set an `if:` clause matches against: the platform plus the running
    # x11 environment (x11 / xquartz / openbox / ...).
    tags = {plat} | _x11_tags(os.environ.get("DISPLAY", ""))
    if not _when_ok(spec.get("if"), tags, plat):
        reason = f"if:{spec.get('if')} -- env is {','.join(sorted(tags))}"
        print(_c("33", f"   SKIP  {reason}"))
        return ("skip", name, reason)

    if mode == "x11" and not os.environ.get("DISPLAY"):
        reason = "mode x11 but no DISPLAY (start scripts/smoketest/x11-start.sh)"
        print(_c("33", f"   SKIP  {reason}"))
        return ("skip", name, reason)
    launcher = os.path.join(builddir, "run_magic.sh" if mode == "x11" else "run_magicnull.sh")
    if not os.access(launcher, os.X_OK):
        reason = f"{launcher} not built (set builddir / MAGIC_BUILDDIR)"
        print(_c("31", f"   FAIL  {reason}"))
        return ("fail", name, reason)

    work = tempfile.mkdtemp(prefix="magictest.")
    testdir = os.path.dirname(os.path.abspath(path))
    cell = None
    for inp in spec.get("inputs", []) or []:
        srcp = inp if os.path.isabs(inp) else os.path.join(SRCROOT, inp)
        shutil.copy(srcp, work)
        if inp.endswith(".mag") and cell is None:
            cell = os.path.basename(inp)[:-4]

    _WARNED.clear()                            # unknown-placeholder warnings are per test
    ctx = dict(work=work, src=SRCROOT, tech=tech, cell=cell or "", testdir=testdir,
               display=os.environ.get("DISPLAY", ""), win="", platform=plat)

    # magic's working directory.  The default -- and the {default} placeholder --
    # is the directory holding this test's YAML, so a test can reference fixture
    # files next to it.  Override per-test with `cwd:` (placeholders incl. {work},
    # {testdir}, {src}); `cwd: {default}` resets it.  Reset happens per test: each
    # test starts from the default (this is read fresh from every test's YAML).
    cwd_raw = str(spec.get("cwd", "{default}")).replace("{default}", testdir)
    cwd = os.path.abspath(_subst(cwd_raw, ctx))
    ctx["cwd"] = cwd

    env = dict(os.environ, MAGIC_BUILDDIR=builddir)
    cmd = [launcher]
    if mode == "x11":
        cmd += ["-d", "X11", "-noconsole", "-timeout", str(min(timeout, 120))]

    logpath = os.path.join(work, "magic.log")
    started = time.time()
    # Core dumps are enabled in the child; a relative core_pattern writes the
    # core into magic's cwd (searched below alongside the work dir).
    sess = MagicSession(cmd, env, logpath, t0=started, timeout_ms=timeout_ms,
                        cwd=cwd, display=ctx["display"])
    # The launcher exec's magic in place, so the child pid IS magic's pid --
    # available as {pid}/{MAGICPID} so an exec step can target the live process.
    ctx["pid"] = ctx["MAGICPID"] = str(sess.proc.pid)

    def prog(msg):                       # timestamped progress: "[0000.000] ..."
        print(f"   [{sess.ts()}] {msg}")

    # Show exactly how magic is being launched and the env that shapes it (the
    # launcher exec's magicexec/magicdnull with these args + a staged CAD_ROOT).
    prog("launch: " + " ".join(shlex.quote(c) for c in cmd))
    relenv = {k: v for k, v in env.items()
              if k in ("DISPLAY", "CAD_ROOT", "WISH", "TCLSH", "TMPDIR")
              or k.startswith(("MAGIC_", "SMOKE_", "CAD_"))}
    prog("env: " + (" ".join(f"{k}={relenv[k]}" for k in sorted(relenv)) or "(none relevant)"))
    # cwd is part of the test environment -- log it, and flag a non-default one.
    prog(f"cwd: {cwd}" + ("" if cwd == testdir else "  (non-default; default is the test dir)"))
    prog(f"timeout_ms={sess.timeout_ms} cap={timeout}s work={work}")
    prog(f"coredump: RLIMIT_CORE=unlimited (in child)  core_pattern={_core_pattern()!r}")

    def step_ms(step):                   # per-step timeout override: ms or (legacy) s
        if "timeout_ms" in step:
            return int(step["timeout_ms"])
        if "timeout" in step:
            return int(float(step["timeout"]) * 1000)
        return None                      # inherit sess.timeout_ms

    try:
        if mode == "x11":
            if shutil.which("xdotool"):
                ctx["win"] = sess.find_window(timeout=min(timeout, 40))
                if not ctx["win"]:
                    raise TestError("no magic layout window appeared")
                if verbose:
                    prog(f"layout window {ctx['win']}")
            else:
                # No xdotool (e.g. macOS/XQuartz): can't find or drive the window,
                # but the scripted send/expect part still exercises -d X11.
                prog("xdotool not found -- skipping window confirmation")
                ctx["win"] = ""

        for i, step in enumerate(spec.get("steps", []) or []):
            label = step.get("name", f"step{i+1}")
            if "if" in step and not _when_ok(step["if"], tags, plat):   # env-gated step
                if verbose:
                    prog(f"skip {label} (if:{step['if']} not in {','.join(sorted(tags))})")
                continue
            if "echo" in step:
                prog(str(_subst(step["echo"], ctx)))
            if time.time() - started > timeout:
                raise TestError("overall test timeout exceeded")
            if "set_timeout_ms" in step:         # change the inherited timeout on the fly
                sess.timeout_ms = int(step["set_timeout_ms"])
                if verbose:
                    prog(f"timeout_ms := {sess.timeout_ms}")
            if "send" in step:
                sess.send(_subst(step["send"], ctx))
            if "expect" in step:
                sess.expect(_subst(step["expect"], ctx), step_ms(step))
            if "close_stdin" in step:
                sess.close_stdin()
            if "sleep" in step:
                time.sleep(float(step["sleep"]))
            if "xdotool" in step:
                # Run as given; the test references {win} explicitly where it
                # wants events aimed at magic's window (e.g. mousemove --window
                # {win}).  A bare "key ..." goes to the focused window (dialogs).
                sess.xdotool([str(a) for a in _subst(step["xdotool"], ctx)])
            if "wait" in step:                   # wait for magic to exit here
                rc = sess.wait(step_ms(step))
                if rc is None:
                    raise TestError(f"wait: magic did not exit within {sess._secs(step_ms(step))*1000:.0f}ms")
                if verbose:
                    prog(f"magic exited rc={rc}")
            if "exec" in step:               # run an arbitrary external command
                xspec = step["exec"]
                if isinstance(xspec, (str, list)):
                    xspec = {"run": xspec}
                shown = _subst(xspec["run"], ctx)         # resolved form, for the log
                shown = shlex.split(shown) if isinstance(shown, str) else [str(a) for a in shown]
                prog("exec: " + " ".join(shlex.quote(a) for a in shown))
                out = _do_validate(xspec, ctx, cwd)       # substitutes + runs (in cwd)
                if verbose and out:
                    prog(f"[{label}] exec -> {out[:80]}")
            if "assert" in step:
                _do_assert(step["assert"], ctx)
            if "validate" in step:
                out = _do_validate(step["validate"], ctx, work)
                if verbose and out:
                    prog(f"[{label}] validate -> {out[:80]}")
            if verbose:
                prog(_c("32", f"✓ {label}"))

        want_exit = int(spec.get("expect_exit", 0))
        rc = sess.proc.returncode
        if rc is None:                            # not waited yet -> wait now
            rc = sess.wait()
        if rc is None:
            raise TestError("magic did not exit within the test timeout")
        # A crash (SIGSEGV/SIGABRT/...) is always reported with core details and
        # fails, unless the test explicitly expects that signal's exit code.
        dr = sess.death_report([cwd, work])
        if dr:
            for line in dr[2]:
                prog(_c("31", line) if dr[0] else line)
        if rc != want_exit:
            raise TestError(dr[1] if dr else f"magic exit {rc} != expected {want_exit} (see {logpath})")
        print(_c("32", f"   [{sess.ts()}] PASS  (session {time.time()-started:.3f}s)"))
        return ("pass", name, "")
    except TestError as e:
        # If magic died by a signal mid-run (e.g. expect saw it exit), surface
        # the crash + core details even though a step raised first.
        dr = sess.death_report([cwd, work])
        if dr:
            for line in dr[2]:
                prog(_c("31", line) if dr[0] else line)
        print(_c("31", f"   [{sess.ts()}] FAIL  {e}"))
        print(f"         (session {time.time()-started:.3f}s)  log: {logpath}")
        return ("fail", name, str(e))
    finally:
        sess.close()


def find_tests(target):
    if os.path.isfile(target):
        return [target]
    if os.path.isdir(target):
        found = sorted(glob.glob(os.path.join(target, "**", "test.yaml"), recursive=True))
        return found
    return []


def _md_cell(s, limit=200):
    """Make a string safe (and short) for a single Markdown table cell -- the
    full reason is already in the step log, the summary just needs to scan."""
    s = " ".join(str(s).split()).replace("|", "\\|").strip()
    return s if len(s) <= limit else s[:limit - 1] + "…"


def _write_step_summary(target, results, passed, failed, skipped):
    """Append a Markdown summary of the run to $GITHUB_STEP_SUMMARY (GitHub
    Actions renders it in the job summary), so SKIP and FAIL tests are visible
    at a glance without scrolling the log.  A no-op off CI.  The failing tests
    still fail the run -- this only reports; main() returns non-zero on any
    failure, halting the workflow after the whole catalog has been attempted."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    fails = [r for r in results if r[0] == "fail"]
    skips = [r for r in results if r[0] == "skip"]
    label = os.environ.get("SMOKE_SUMMARY_LABEL") or f"{_platform_now()} {platform.machine()}"
    icon = "❌" if failed else "✅"
    out = [f"### {icon} magic smoke catalog — {label}", "",
           f"**{passed} passed · {failed} failed · {skipped} skipped** "
           f"(of {len(results)}) — `{target}`", ""]
    for title, rows in (("❌ Failed", fails), ("⏭️ Skipped", skips)):
        if not rows:
            continue
        out += [f"#### {title}", "", "| test | reason |", "|------|--------|"]
        out += [f"| {_md_cell(r[1])} | {_md_cell(r[2])} |" for r in rows]
        out.append("")
    try:
        with open(path, "a") as fh:
            fh.write("\n".join(out) + "\n")
    except OSError as e:
        print(f"magictest: could not write GITHUB_STEP_SUMMARY: {e}", file=sys.stderr)


def main(argv):
    if len(argv) < 3 or argv[1] not in ("run", "list"):
        sys.exit(__doc__)
    action, target = argv[1], argv[2]

    # Parse: -v, --tag T[,T...] (repeatable), --filter KEY=VALUE (repeatable).
    verbose = False
    want_tags, want_meta = set(), []
    it = iter(argv[3:])
    for a in it:
        if a == "-v":
            verbose = True
        elif a == "--tag":
            want_tags |= set(next(it, "").split(","))
        elif a.startswith("--tag="):
            want_tags |= set(a[len("--tag="):].split(","))
        elif a == "--filter":
            k, _, v = next(it, "").partition("=")
            if k: want_meta.append((k, v))
        elif a.startswith("--filter="):
            k, _, v = a[len("--filter="):].partition("=")
            if k: want_meta.append((k, v))
    want_tags.discard("")

    tests = find_tests(target)
    if not tests:
        sys.exit(f"magictest: no tests found at {target}")
    total_found = len(tests)
    if want_tags or want_meta:
        tests = [t for t in tests if _selected(t, want_tags, want_meta)]
        sel = []
        if want_tags: sel.append("tags=" + ",".join(sorted(want_tags)))
        if want_meta: sel.append("filter=" + ",".join(f"{k}={v}" for k, v in want_meta))
        print(_c("1", f"filter {'; '.join(sel)} -> {len(tests)}/{total_found} tests"))
        if not tests:
            print("(no tests matched)")
            return 0

    if action == "list":
        for t in tests:
            tags, md = _tags_meta(yaml.safe_load(open(t)) or {})
            extra = ("  tags=" + ",".join(tags) if tags else "") + \
                    ("  " + " ".join(f"{k}={v}" for k, v in md.items()) if md else "")
            print(t + extra)
        return 0

    results = [run_test(t, verbose=verbose) for t in tests]
    passed = sum(1 for r in results if r[0] == "pass")
    failed = sum(1 for r in results if r[0] == "fail")
    skipped = sum(1 for r in results if r[0] == "skip")
    extra = f", {skipped} skipped" if skipped else ""
    print(_c("1", f"\n{passed} passed, {failed} failed{extra}  (of {len(tests)})"))
    _write_step_summary(target, results, passed, failed, skipped)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
