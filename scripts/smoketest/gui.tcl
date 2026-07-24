# Smoke test -- Step C: X11 GUI startup on a headless display.
#
# Driven through run_magic.sh with "-d X11 -noconsole" against a headless
# Xvfb+openbox (see x11-start.sh).  "-d X11" selects the X11 graphics device;
# "-noconsole" stops the Tk console from swallowing stdin so we can script it
# like a batch run.  This proves the real GUI binary (magicexec) connects to the
# X display, brings up its graphics, loads a technology and a layout (drawing
# into the X11 window), then exits cleanly.  Prints "SMOKE-GUI-OK ..." on
# success.  Window-level *interaction* (xdotool/wmctrl driving) is a later step;
# xdotool/wmctrl are installed already so that work has its tools ready.

# magicexec is a wish replacement, so Tk is initialized under -d X11.
expect_true "tk-present" {[llength [info commands wm]] > 0}

set tech [env_or SMOKE_TECH]
require    "tech-load" { tech load $tech }
expect_true "tech-name" {[string equal [tech name] $tech]}

# Loading a cell under -d X11 opens/refreshes the layout window on the server.
require "load-cell" { load [env_or SMOKE_CELL] }
# Flush any pending X drawing before teardown (best-effort; not all builds
# expose a Tk-style [update] in this mode).
catch { update }

puts "SMOKE-GUI-OK tech=[tech name]"
quit -noprompt
