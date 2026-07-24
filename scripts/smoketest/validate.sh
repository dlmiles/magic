#!/usr/bin/env bash
#
# validate.sh -- check the outcome of a smoke run (see run.sh).  Kept separate
# so the checks are readable and reusable, and because -dnull magic does not
# fail its exit status on a bad command: the real signal is (a) the smoke
# script reaching its success sentinel, (b) the absence of failure markers in
# the log, and (c) for the workflow, the generated artifacts existing and
# looking like what they claim to be.
#
# Usage:  validate.sh <startup|workflow> <workdir> <logfile> <launcher-rc>
set -euo pipefail

mode="${1:?mode}"; workdir="${2:?workdir}"; log="${3:?logfile}"; rc="${4:-0}"

fails=0
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }
ok()   { echo "  ok:   $*"; }

# 1. The launcher must have exited cleanly.  A Tcl [exit N] from the prelude's
#    abort path shows up here as a non-zero status.
if [ "$rc" -ne 0 ]; then
    fail "launcher exited with status $rc"
else
    ok "launcher exit status 0"
fi

# 2. No failure markers in the log.  These are the signatures of a genuinely
#    broken run; benign chatter ("Contact size value ignored", the RLIMIT
#    "Tcl_Version<9" warning, "not handled by extraction") must NOT match, so
#    the patterns are specific fatal markers, not broad substrings like "Tcl_".
bad_re='SMOKE-FAIL|invalid command name|No such file or directory|can'\''t read|[Ss]egmentation fault|core dumped|child killed|Aborted|Tcl_Panic'
if grep -Eiq "$bad_re" "$log"; then
    fail "failure marker(s) in log:"
    grep -Ein "$bad_re" "$log" | sed 's/^/        /' >&2
else
    ok "no failure markers in log"
fi

# 3. The smoke script reached its success sentinel (proves it ran end to end
#    rather than dying silently partway through).
case "$mode" in
    startup)  sentinel='SMOKE-STARTUP-OK'  ;;
    workflow) sentinel='SMOKE-WORKFLOW-OK' ;;
    *) echo "validate: unknown mode '$mode'" >&2; exit 2 ;;
esac
if grep -q "$sentinel" "$log"; then
    ok "reached sentinel $sentinel"
else
    fail "did not reach sentinel $sentinel"
fi

# 4. Workflow mode: the generated artifacts must exist, be non-empty, and carry
#    a recognisable signature for their format.
if [ "$mode" = "workflow" ]; then
    # Derive the cell name from SMOKE_CELL if exported, else default to min.
    cell="$(basename "${SMOKE_CELL:-min}")"
    d="$workdir"

    check_file() {   # check_file <path> <human-name>
        if [ ! -f "$1" ]; then fail "$2 missing ($1)"; return 1; fi
        if [ ! -s "$1" ]; then fail "$2 is empty ($1)"; return 1; fi
        ok "$2 present ($(wc -c < "$1") bytes)"
    }
    check_grep() {   # check_grep <path> <regex> <what>
        if grep -Eq "$2" "$1"; then ok "$3"; else fail "$3 (pattern /$2/ not found in $1)"; fi
    }

    if check_file "$d/$cell.ext"   ".ext";   then check_grep "$d/$cell.ext"   '^(node|cap|fet|device|timestamp)' "  .ext content"; fi
    if check_file "$d/$cell.spice" ".spice"; then check_grep "$d/$cell.spice" 'SPICE'                             "  .spice header"; fi
    if check_file "$d/$cell.gds"   ".gds";   then
        # GDSII begins with an HEADER record: length 0x0006, record type 0x00,
        # data type 0x02.  Match the type/datatype byte pair at offset 2.
        if od -An -tx1 -N4 "$d/$cell.gds" | grep -Eq '00 06 00 02'; then
            ok "  .gds GDSII header"
        else
            fail "  .gds does not start with a GDSII HEADER record"
        fi
    fi
    if check_file "$d/$cell.cif"   ".cif";   then check_grep "$d/$cell.cif"   '(DS|9 |C[0-9]|End)'                "  .cif content"; fi

    # The DRC pass must have reported a total (value itself is layout-dependent).
    check_grep "$log" 'Total DRC errors found:' "  drc reported a total"
fi

echo "smoketest[$mode]: $fails failure(s)"
[ "$fails" -eq 0 ]
