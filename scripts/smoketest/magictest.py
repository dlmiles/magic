#!/usr/bin/env python3
"""
magictest.py -- YAML-driven orchestration for magic smoke/interaction tests.

A test is a YAML file that says which mode to run magic in and lists a sequence
of steps: send a command, expect output, assert on produced files, run an
external validator, or (X11 mode) drive the GUI with xdotool.  Magic runs under
a pseudo-terminal so it line-buffers like an interactive session, which is what
makes send/expect reliable.

Usage:
    magictest.py run   <test.yaml | catalog-dir> [-v]
    magictest.py list  <catalog-dir>

A "catalog" is a directory of NNN-name/test.yaml tests; `run` on a directory
executes every test.yaml under it in sorted (numbered) order and exits non-zero
if any fails.

Test YAML schema (all keys optional unless noted):
    name:        short name (defaults to the file/dir name)
    description: free text
    mode:        dnull (default) | x11        -- graphics device
    tech:        technology to preload substitutions with (e.g. scmos)
    timeout:     per-test wall-clock cap, seconds (default 180); also magic's
                 own -timeout watchdog for x11
    builddir:    out-of-tree build dir (default $MAGIC_BUILDDIR or build-tmp)
    inputs:      [paths]  -- files copied into the work dir before the run
    steps:       [ ... ]  -- see below
    expect_exit: int      -- required magic exit status (default 0)

Each step is a mapping with one or more of:
    send:    "command"            -- write a line to magic
    expect:  "regex"             -- read until it matches (fails on timeout)
    expect_not: "regex"          -- fail if it appears before the next expect
    timeout: seconds             -- override for this step's expect
    sleep:   seconds
    xdotool: [args...]           -- run xdotool (x11 only); {win} = layout window
    assert:  { exists|nonempty|absent: path,
               contains: {file, pattern}, min_lines: {file, n} }
    validate:{ run: [argv...]|"cmd", exit: 0, stdout_matches: "regex",
               stdout_contains: "str" }

Placeholders substituted in strings: {work} {src} {tech} {cell} {display} {win}.
"""

import os, sys, re, pty, time, shlex, select, signal, subprocess, tempfile, shutil, glob

HERE = os.path.dirname(os.path.abspath(__file__))
SRCROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

try:
    import yaml
except ImportError:
    sys.exit("magictest: PyYAML is required (pip install pyyaml / apt install python3-yaml)")


class TestError(Exception):
    pass


def _c(code, s):
    return s if not sys.stdout.isatty() else f"\033[{code}m{s}\033[0m"


class MagicSession:
    """Drives one magic process over a PTY, with expect + xdotool helpers."""

    def __init__(self, cmd, env, logpath, display=None):
        self.master, slave = pty.openpty()
        self.log = open(logpath, "wb")
        self.buf = ""          # decoded output not yet consumed by expect
        self.display = display
        self.win = ""
        self.proc = subprocess.Popen(
            cmd, stdin=slave, stdout=slave, stderr=slave,
            env=env, close_fds=True, preexec_fn=os.setsid)
        os.close(slave)

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
        os.write(self.master, (line + "\n").encode())

    def expect(self, pattern, timeout):
        rx = re.compile(pattern)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            if time.time() > deadline:
                tail = self.buf[-400:].replace("\n", "\\n")
                raise TestError(f"expect timeout ({timeout}s) for /{pattern}/; recent: ...{tail}")
            if not self._drain(0.2) and self.proc.poll() is not None:
                # process gone: one last look then give up
                if rx.search(self.buf):
                    return rx.search(self.buf)
                raise TestError(f"magic exited before /{pattern}/ matched (rc={self.proc.returncode})")

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

    def wait(self, timeout):
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return None
        # drain any final output
        for _ in range(20):
            if not self._drain(0.05):
                break
        return self.proc.returncode

    def close(self):
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
    timeout = int(spec.get("timeout", 180))
    builddir = os.path.abspath(spec.get("builddir") or os.environ.get("MAGIC_BUILDDIR", "build-tmp"))

    print(_c("1", f"── test: {name} [{mode}]") + f"  ({spec.get('description','')})")

    if mode == "x11" and not os.environ.get("DISPLAY"):
        print(_c("33", "   SKIP  mode x11 but no DISPLAY (start scripts/smoketest/x11-start.sh)"))
        return None
    launcher = os.path.join(builddir, "run_magic.sh" if mode == "x11" else "run_magicnull.sh")
    if not os.access(launcher, os.X_OK):
        raise TestError(f"{launcher} not built (set builddir / MAGIC_BUILDDIR)")

    work = tempfile.mkdtemp(prefix="magictest.")
    cell = None
    for inp in spec.get("inputs", []) or []:
        srcp = inp if os.path.isabs(inp) else os.path.join(SRCROOT, inp)
        shutil.copy(srcp, work)
        if inp.endswith(".mag") and cell is None:
            cell = os.path.basename(inp)[:-4]

    ctx = dict(work=work, src=SRCROOT, tech=tech, cell=cell or "",
               display=os.environ.get("DISPLAY", ""), win="")

    env = dict(os.environ, MAGIC_BUILDDIR=builddir)
    cmd = [launcher]
    if mode == "x11":
        cmd += ["-d", "X11", "-noconsole", "-timeout", str(min(timeout, 120))]

    logpath = os.path.join(work, "magic.log")
    sess = MagicSession(cmd, env, logpath, display=ctx["display"])
    started = time.time()
    try:
        if mode == "x11":
            ctx["win"] = sess.find_window(timeout=min(timeout, 40))
            if not ctx["win"]:
                raise TestError("no magic layout window appeared")
            if verbose:
                print(f"   layout window {ctx['win']}")

        for i, step in enumerate(spec.get("steps", []) or []):
            label = step.get("name", f"step{i+1}")
            if time.time() - started > timeout:
                raise TestError("overall test timeout exceeded")
            if "send" in step:
                sess.send(_subst(step["send"], ctx))
            if "expect" in step:
                sess.expect(_subst(step["expect"], ctx), int(step.get("timeout", 30)))
            if "sleep" in step:
                time.sleep(float(step["sleep"]))
            if "xdotool" in step:
                # Run as given; the test references {win} explicitly where it
                # wants events aimed at magic's window (e.g. mousemove --window
                # {win}).  A bare "key ..." goes to the focused window (dialogs).
                sess.xdotool([str(a) for a in _subst(step["xdotool"], ctx)])
            if "assert" in step:
                _do_assert(step["assert"], ctx)
            if "validate" in step:
                out = _do_validate(step["validate"], ctx, work)
                if verbose and out:
                    print(f"   [{label}] validate -> {out[:80]}")
            if verbose:
                print(_c("32", f"   ✓ {label}"))

        want_exit = int(spec.get("expect_exit", 0))
        rc = sess.wait(timeout=max(5, timeout - (time.time() - started)))
        if rc is None:
            raise TestError("magic did not exit within the test timeout")
        if rc != want_exit:
            raise TestError(f"magic exit {rc} != expected {want_exit} (see {logpath})")
        print(_c("32", f"   PASS  ({time.time()-started:.1f}s)"))
        return True
    except TestError as e:
        print(_c("31", f"   FAIL  {e}"))
        print(f"         log: {logpath}")
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
    verbose = "-v" in argv[3:]
    tests = find_tests(target)
    if not tests:
        sys.exit(f"magictest: no tests found at {target}")
    if action == "list":
        for t in tests:
            print(t)
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
