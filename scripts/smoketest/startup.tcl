# Smoke test -- Step A: startup + feature existence.
#
# Confirms the freshly built -dnull magic boots under the Tcl interpreter,
# that the core command surface is actually registered (a missing command
# means a module failed to link/register -- a real regression), and that a
# technology loads.  Reads no layout and writes no files.
#
# Helpers (require / expect_true / have_cmd / env_or) come from _prelude.tcl,
# which run.sh prepends.  Prints "SMOKE-STARTUP-OK ..." on success.

# The Tcl interpreter itself is alive and evaluating.
expect_true "tcl-math" {[expr {6 * 7}] == 42}

# The command surface a working magic must expose.  Kept to commands verified
# to register in the default (Tcl) build; extend deliberately, not speculatively.
set need {
    tech load save flush
    box paint select see snap grid goto label port property
    extract extresist ext2spice ext2sim
    gds cif calma def lef
    drc
}
foreach c $need {
    expect_true "cmd-$c" {[have_cmd $c]}
}

# A technology loads and becomes the active tech.
set tech [env_or SMOKE_TECH]
require    "tech-load" { tech load $tech }
expect_true "tech-name" {[string equal [tech name] $tech]}

puts "SMOKE-STARTUP-OK tech=[tech name] commands=[llength $need]"

# Quit explicitly.  Under -dnull EOF on stdin would exit anyway, but under the
# GUI (-d X11) magic drops into its event loop and would otherwise idle here
# until the -timeout watchdog fires -- so the same script exits cleanly on both.
quit -noprompt
