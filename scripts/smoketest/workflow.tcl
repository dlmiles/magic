# Smoke test -- Step B: extraction / export workflow.
#
# Reproduces, natively and headless, the same pipeline the WASM CI runs against
# npm/examples/min.mag (see npm/examples/{extract,gds,cif,drc}.js):
#
#     tech load -> load -> extract -> ext2spice -> gds -> cif -> drc
#
# so a regression in extraction, netlisting or stream output shows up on native
# Linux/aarch64 too, not only in the WASM job.  Paths come from the environment
# (run.sh sets them) so the driver owns where inputs and outputs live.  The
# generated files are checked separately by validate.sh; here we just drive the
# commands and abort on any Tcl-level failure.  Prints "SMOKE-WORKFLOW-OK ...".

set tech [env_or SMOKE_TECH]
set cell [env_or SMOKE_CELL]        ;# absolute path to the layout, without .mag
set out  [env_or SMOKE_OUT]         ;# directory to receive generated artifacts
set name [file tail $cell]

require "tech-load"    { tech load $tech }
# A failed "tech load" is not a Tcl error -- magic just keeps the previous tech
# -- so assert the requested one is actually active before trusting the output.
expect_true "tech-name" {[string equal [tech name] $tech]}
require "load-cell"    { load $cell }

# Extraction (capacitance + resistance), matching extract.tcl.
require "extract-path" { extract path $out }
require "extract-res"  { extract do resistance }
require "extract-all"  { extract all }
require "select-top"   { select top cell }
require "extresist"    { extresist all }

# SPICE netlist, matching extract.tcl's ext2spice settings.
require "spice-format" { ext2spice format ngspice }
require "spice-eres"   { ext2spice extresist on }
require "spice-cthr"   { ext2spice cthresh 0 }
require "ext2spice"    { ext2spice $out/$name }

# Stream / intermediate-form exports.  gds write does not append ".gds", so we
# pass it explicitly; cif write appends ".cif" itself.
require "gds-write"    { gds write $out/$name.gds }
require "cif-write"    { cif write $out/$name }

# Design-rule check.  drc count total prints "Total DRC errors found: N" (its
# return value is empty), so validate.sh reads the count from the log.
require "drc-catchup"  { drc catchup }
require "drc-count"    { drc count total }

puts "SMOKE-WORKFLOW-OK cell=$name out=$out"

# Quit explicitly so the same script exits cleanly under the GUI (-d X11) too,
# not just under -dnull (where EOF would end it) -- otherwise magic idles in its
# event loop until the -timeout watchdog fires.
quit -noprompt
