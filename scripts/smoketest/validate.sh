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
    gui)      sentinel='SMOKE-GUI-OK'      ;;
    *) echo "validate: unknown mode '$mode'" >&2; exit 2 ;;
esac
if grep -q "$sentinel" "$log"; then
    ok "reached sentinel $sentinel"
else
    fail "did not reach sentinel $sentinel"
fi

# 3b. Under X11 (gui mode, or startup/workflow with SMOKE_DEVICE=x11): magic must
#     have really talked to the X server, not failed to open the display nor
#     fallen back to the null graphics device.
if [ "${SMOKE_DEVICE:-dnull}" = "x11" ]; then
    x_bad='could ?n.?t connect to display|can.?t open display|cannot open display|unable to open display|Using NULL graphics|no graphics device'
    if grep -Eiq "$x_bad" "$log"; then
        fail "X11 display/graphics failure in log:"
        grep -Ein "$x_bad" "$log" | sed 's/^/        /' >&2
    else
        ok "connected to the X11 display (no display/graphics failure)"
    fi
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
    # Loose functional sanity: a real output has more than a couple of lines.
    # We are not matching exact counts (they shift with paths/timestamps/tech) --
    # just confirming the file has substantive content, and logging the count.
    check_minlines() {   # check_minlines <path> <min> <what>
        local n; n=$(grep -c '' "$1" 2>/dev/null || echo 0)
        if [ "$n" -ge "$2" ]; then ok "$3 ($n lines)"; else fail "$3: only $n lines (< $2) in $1"; fi
    }
    # Per-artifact line for cross-run / cross-platform comparison: size, line
    # count, and a stable CRC32 in hex (POSIX cksum -- same algorithm on Linux
    # and macOS).  With a second arg of 1 it also dumps the first + last 64 bytes
    # in hex (used only on failure, where any stray CR/LF 0d/0a shows directly).
    dump_file() {   # dump_file <path> <name> [with_hex 0|1]
        local f="$1" name="$2" hx="${3:-0}" sz lines crc
        if [ ! -f "$f" ]; then echo "  DUMP $name: (missing $f)"; return; fi
        sz=$(wc -c < "$f" | tr -d ' ')
        lines=$(wc -l < "$f" | tr -d ' ')
        crc=$(cksum < "$f" | awk '{printf "%08X", $1}')
        echo "  DUMP $name: ${sz} bytes, ${lines} lines, CRC32=${crc}"
        if [ "$hx" = "1" ]; then
            echo "    head[64]: $(od -An -tx1 -N64 "$f" | tr '\n' ' ' | tr -s ' ')"
            echo "    tail[64]: $(tail -c 64 "$f" | od -An -tx1 | tr '\n' ' ' | tr -s ' ')"
        fi
    }

    if check_file "$d/$cell.ext"   ".ext";   then
        check_grep     "$d/$cell.ext" '^(node|cap|fet|device|timestamp)' "  .ext content"
        check_minlines "$d/$cell.ext" 5                                  "  .ext line count"
    fi
    if check_file "$d/$cell.spice" ".spice"; then
        check_grep     "$d/$cell.spice" 'SPICE'                          "  .spice header"
        check_minlines "$d/$cell.spice" 4                                "  .spice line count"
    fi
    if check_file "$d/$cell.gds"   ".gds";   then
        # GDSII begins with a HEADER record: length 0x0006, record type 0x00,
        # data type 0x02.  Normalize od's output to bare hex first -- GNU and BSD
        # (macOS) od space/group -tx1 differently, so grepping "00 06 00 02"
        # verbatim fails on macOS even when the bytes are correct.
        hdr=$(od -An -tx1 -N4 "$d/$cell.gds" 2>/dev/null | tr -dc '0-9a-fA-F')
        if [ "$hdr" = "00060002" ]; then
            ok "  .gds GDSII header"
        else
            fail "  .gds header is '$hdr', not 00060002 (GDSII HEADER record)"
        fi
    fi
    if check_file "$d/$cell.cif"   ".cif";   then
        check_grep     "$d/$cell.cif" '(DS|9 |C[0-9]|End)'               "  .cif content"
        check_minlines "$d/$cell.cif" 8                                  "  .cif line count"
    fi

    # The DRC pass must have reported a total (value itself is layout-dependent).
    check_grep "$log" 'Total DRC errors found:' "  drc reported a total"

    # One line per artifact (size / lines / CRC32) so a change between CI runs is
    # visible; add the first+last 64 bytes in hex only when something failed.
    _hex=0; [ "$fails" -gt 0 ] && _hex=1
    for a in ext spice gds cif; do dump_file "$d/$cell.$a" ".$a" "$_hex"; done
fi

echo "smoketest[$mode]: $fails failure(s)"
[ "$fails" -eq 0 ]
