# Shared helpers, prepended to every smoke script by run.sh.
#
# Why this exists: in -dnull batch mode magic reports command failures on
# stderr but leaves the process exit status at 0 (a bad command prints
# "invalid command name ..." and keeps going).  So a smoke test cannot rely on
# the exit code alone -- it must assert its own way through and abort the
# instant something is wrong.  Tcl's [exit N] *does* propagate to the process
# status, so the helpers below exit non-zero on the first failure, and the
# companion validate.sh independently re-checks the artifacts afterwards.

# require LABEL BODY -- run BODY; abort (exit 1) if it raises a Tcl error.
proc require {label body} {
    if {[catch {uplevel 1 $body} err]} {
        puts stderr "SMOKE-FAIL $label : $err"
        exit 1
    }
    puts "SMOKE-STEP $label ok"
}

# expect_true LABEL EXPR -- EXPR (an [expr] condition) must evaluate true.
proc expect_true {label cond} {
    if {[catch {uplevel 1 [list expr $cond]} v] || !$v} {
        puts stderr "SMOKE-FAIL $label : expected true, got '$v' from: $cond"
        exit 1
    }
    puts "SMOKE-STEP $label ok"
}

# have_cmd NAME -- 1 if command NAME is registered in the interpreter.
proc have_cmd {name} { expr {[llength [info commands $name]] > 0} }

# env_or LABEL VAR -- fetch a required environment variable or abort.
proc env_or {var} {
    global env
    if {![info exists env($var)]} {
        puts stderr "SMOKE-FAIL env : \$$var is not set"
        exit 1
    }
    return $env($var)
}
