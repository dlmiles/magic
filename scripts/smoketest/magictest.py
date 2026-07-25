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
executes every test.yaml under it in sorted (numbered) order and exits non-zero
if any fails.  --tag / --filter subselect which tests run (both repeatable): a
test matches --tag if it carries any of the named tags, and --filter K=V if its
metadata[K] == V.

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
    sleep:   seconds
    xdotool: [args...]           -- run xdotool (x11 only); {win} = layout window
    assert:  { exists|nonempty|absent: path,
               contains: {file, pattern}, min_lines: {file, n} }
    validate:{ run: [argv...]|"cmd", exit: 0, stdout_matches: "regex",
               stdout_contains: "str" }

Placeholders in strings: {work} {src} {testdir} {tech} {cell} {display} {win}
(and {default} in `cwd:`).  magic's cwd is logged with the launch/env, flagged
when non-default.

At the start of each test the full launch command line and the relevant
environment (MAGIC_*, SMOKE_*, CAD_*, DISPLAY, ...) are logged.  Progress lines
are prefixed with elapsed time since the session started as 0000.000 (seconds),
and PASS/FAIL prints the total session duration.
"""

import os, sys, re, pty, time, shlex, select, signal, subprocess, tempfile, shutil, glob, resource

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
        signal, and any core file found is described (path, size, mtime)."""
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
        cores = _find_cores(coredirs)
        for p, size, mt in cores:
            ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(mt))
            lines.append(f"CORE: {p}  size={size} bytes  mtime={ts}")
            summary += f"; core {p} ({size} bytes)"
        if is_crash and not cores:
            lines.append(f"CORE: no core file in {coredirs} (kernel.core_pattern={_core_pattern()!r})")
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


def _subst(val, ctx):
    # Targeted replacement of {work},{src},{tech},{cell},{display},{win} only --
    # NOT str.format, so Tcl's own braces (expr {...}, list {...}) pass through.
    if isinstance(val, str):
        for k, v in ctx.items():
            val = val.replace("{" + k + "}", str(v))
        return val
    if isinstance(val, list):
        return [_subst(v, ctx) for v in val]
    if isinstance(val, dict):
        return {k: _subst(v, ctx) for k, v in val.items()}
    return val


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

    if mode == "x11" and not os.environ.get("DISPLAY"):
        print(_c("33", "   SKIP  mode x11 but no DISPLAY (start scripts/smoketest/x11-start.sh)"))
        return None
    launcher = os.path.join(builddir, "run_magic.sh" if mode == "x11" else "run_magicnull.sh")
    if not os.access(launcher, os.X_OK):
        raise TestError(f"{launcher} not built (set builddir / MAGIC_BUILDDIR)")

    work = tempfile.mkdtemp(prefix="magictest.")
    testdir = os.path.dirname(os.path.abspath(path))
    cell = None
    for inp in spec.get("inputs", []) or []:
        srcp = inp if os.path.isabs(inp) else os.path.join(SRCROOT, inp)
        shutil.copy(srcp, work)
        if inp.endswith(".mag") and cell is None:
            cell = os.path.basename(inp)[:-4]

    ctx = dict(work=work, src=SRCROOT, tech=tech, cell=cell or "", testdir=testdir,
               display=os.environ.get("DISPLAY", ""), win="")

    # magic's working directory.  The default -- and the {default} placeholder --
    # is the directory holding this test's YAML, so a test can reference fixture
    # files next to it.  Override per-test with `cwd:` (placeholders incl. {work},
    # {testdir}, {src}); `cwd: {default}` resets it.  Reset happens per test: each
    # test starts from the default (this is read fresh from every test's YAML).
    cwd_raw = str(spec.get("cwd", "{default}")).replace("{default}", testdir)
    cwd = os.path.abspath(_subst(cwd_raw, ctx))

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
            ctx["win"] = sess.find_window(timeout=min(timeout, 40))
            if not ctx["win"]:
                raise TestError("no magic layout window appeared")
            if verbose:
                prog(f"layout window {ctx['win']}")

        for i, step in enumerate(spec.get("steps", []) or []):
            label = step.get("name", f"step{i+1}")
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
        return True
    except TestError as e:
        # If magic died by a signal mid-run (e.g. expect saw it exit), surface
        # the crash + core details even though a step raised first.
        dr = sess.death_report([cwd, work])
        if dr:
            for line in dr[2]:
                prog(_c("31", line) if dr[0] else line)
        print(_c("31", f"   [{sess.ts()}] FAIL  {e}"))
        print(f"         (session {time.time()-started:.3f}s)  log: {logpath}")
        return False
    finally:
        sess.close()


def find_tests(target):
    if os.path.isfile(target):
        return [target]
    if os.path.isdir(target):
        found = sorted(glob.glob(os.path.join(target, "**", "test.yaml"), recursive=True))
        return found
    return []


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

    passed = failed = skipped = 0
    for t in tests:
        r = run_test(t, verbose=verbose)
        if r is True:
            passed += 1
        elif r is None:
            skipped += 1
        else:
            failed += 1
    extra = f", {skipped} skipped" if skipped else ""
    print(_c("1", f"\n{passed} passed, {failed} failed{extra}  (of {len(tests)})"))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
