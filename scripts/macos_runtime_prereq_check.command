#!/usr/bin/env bash
#
# macos_runtime_prereq_check.command -- confirm the runtime prerequisites that
# this Magic.app was BUILT against are installed on this Mac.
#
# Magic.app bundles magic + its private Tcl/Tk, but still links these EXTERNAL
# libraries at run time (they are NOT inside the bundle):
#   * XQuartz  -- the X11 server + libX11/libGL/... that `-d X11`/`-d OGL` need
#   * cairo    -- Homebrew cairo, for `-d XR` (Cairo) rendering
#
# For each it prints OK (installed and >= the version this build used),
# OUTDATED (installed but older -> shows the `brew upgrade` line), or MISSING
# (-> shows the install line).  The report is printed to the Terminal; when run
# there it waits for a keypress before the window closes, and when run without a
# terminal (e.g. from the app launcher) it shows the same summary in a pop-up.
#
# RUN IT ANY TIME:
#   Double-click macos_runtime_prereq_check.command in Finder (opens Terminal),
#   or from Terminal:
#     bash "/Applications/Magic.app/Contents/Resources/macos_runtime_prereq_check.command"
#   (add --no-gui to print once and exit, no keypress wait / pop-up.)
#
# The @...@ tokens below are filled in at package time with the exact versions
# this build linked; if you see literal @CAIRO_WANT@ etc. it was run from the
# source tree, and the version check falls back to "any installed version".

BUILD_LABEL="@BUILD_LABEL@"     # e.g. "macOS 26 arm64"
CAIRO_WANT="@CAIRO_WANT@"       # cairo version this build linked
XQUARTZ_WANT="@XQUARTZ_WANT@"   # XQuartz version this build used

case "$BUILD_LABEL"  in *@*) BUILD_LABEL="(source tree)";; esac
case "$CAIRO_WANT"   in *@*) CAIRO_WANT="";; esac
case "$XQUARTZ_WANT" in *@*) XQUARTZ_WANT="";; esac

GUI=1; [ "${1:-}" = "--no-gui" ] && GUI=0

report=""
add() { report="${report}$1
"; printf '%s\n' "$1"; }

# $1 < $2 ?  (semantic version compare via sort -V)
vlt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

check_formula() {   # name  want
    local name="$1" want="$2" have
    have="$(brew list --versions "$name" 2>/dev/null | awk '{print $NF}')"
    if [ -z "$have" ]; then
        add "MISSING  $name    ->  brew install $name"
    elif [ -n "$want" ] && vlt "$have" "$want"; then
        add "OUTDATED $name  ($have; build used $want)  ->  brew upgrade $name"
    else
        add "OK       $name  ($have${want:+; build used $want})"
    fi
}

check_xquartz() {   # want
    local want="$1" have
    have="$(defaults read /Applications/Utilities/XQuartz.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
    [ -z "$have" ] && have="$(brew list --cask --versions xquartz 2>/dev/null | awk '{print $NF}')"
    if [ -z "$have" ]; then
        add "MISSING  XQuartz  ->  brew install --cask xquartz   (or https://www.xquartz.org)"
    elif [ -n "$want" ] && vlt "$have" "$want"; then
        add "OUTDATED XQuartz  ($have; build used $want)  ->  brew upgrade --cask xquartz"
    else
        add "OK       XQuartz  ($have${want:+; build used $want})"
    fi
}

check_brew() {      # never assume brew exists; report it + where to get it
    if command -v brew >/dev/null 2>&1; then
        add "OK       Homebrew  ($(brew --version 2>/dev/null | sed -n '1s/^Homebrew //p'))"
        return 0
    fi
    add "MISSING  Homebrew  -- required to install cairo (and XQuartz via cask)"
    add "         obtain it from  https://brew.sh  --  one-line install:"
    add "         /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    return 1
}

printf '=== Magic runtime prerequisites (this build: %s) ===\n' "$BUILD_LABEL"
check_brew || true
# XQuartz is read from the installed app, so it is checked with or without brew
# (and can be installed from https://www.xquartz.org independently of brew).
check_xquartz "$XQUARTZ_WANT"
if command -v brew >/dev/null 2>&1; then
    check_formula cairo "$CAIRO_WANT"
else
    add "MISSING  cairo    ->  install Homebrew (above), then:  brew install cairo"
fi

# Overall status + pop-up
if printf '%s' "$report" | grep -q '^MISSING\|^OUTDATED'; then
    status="Action needed -- see the commands below."
else
    status="All runtime prerequisites are present."
fi
printf '\n%s\n' "$status"

if [ "$GUI" = 1 ]; then
    if [ -t 1 ]; then
        # Interactive terminal (double-clicked .command, or run in Terminal):
        # the report above is on screen -- wait for a keypress so the window
        # does not vanish before it has been read.
        printf '\nPress any key to close this window... '
        read -n 1 -s -r _ 2>/dev/null || read -r _ 2>/dev/null || true
        printf '\n'
    elif command -v osascript >/dev/null 2>&1; then
        # No controlling terminal (e.g. launched from Magic.app) -- present the
        # same summary + commands in a native pop-up instead.
        dlg="$(printf 'Magic runtime prerequisites\n(this build: %s)\n\n%s\n%s' \
               "$BUILD_LABEL" "$report" "$status" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')"
        osascript -e "display dialog \"$dlg\" buttons {\"OK\"} with title \"Magic\"" >/dev/null 2>&1 || true
    fi
fi

# Exit status for callers (the app launcher): 0 = all prerequisites OK; 1 =
# something MISSING or OUTDATED, so the launcher keeps prompting on next launch.
printf '%s' "$report" | grep -q '^MISSING\|^OUTDATED' && exit 1
exit 0

# --- HOW TO RE-RUN THIS CHECK LATER ------------------------------------------
# Double-click macos_runtime_prereq_check.command in Finder, or from Terminal:
#   bash "/Applications/Magic.app/Contents/Resources/macos_runtime_prereq_check.command"
# (append --no-gui to print once and exit).  Copy any brew command
# shown above to install/upgrade a missing or outdated prerequisite.
