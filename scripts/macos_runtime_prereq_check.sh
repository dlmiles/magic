#!/usr/bin/env bash
#
# macos_runtime_prereq_check.sh -- confirm the runtime prerequisites that this
# Magic.app was BUILT against are installed on this Mac.
#
# Magic.app bundles magic + its private Tcl/Tk, but still links these EXTERNAL
# libraries at run time (they are NOT inside the bundle):
#   * XQuartz  -- the X11 server + libX11/libGL/... that `-d X11`/`-d OGL` need
#   * cairo    -- Homebrew cairo, for `-d XR` (Cairo) rendering
#
# For each it prints OK (installed and >= the version this build used),
# OUTDATED (installed but older -> shows the `brew upgrade` line), or MISSING
# (-> shows the install line), and also shows a native pop-up with the summary.
#
# RUN IT ANY TIME (from Terminal):
#   bash "/Applications/Magic.app/Contents/Resources/macos_runtime_prereq_check.sh"
#   (add --no-gui to skip the pop-up.)
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

printf '=== Magic runtime prerequisites (this build: %s) ===\n' "$BUILD_LABEL"
if command -v brew >/dev/null 2>&1; then
    check_xquartz "$XQUARTZ_WANT"
    check_formula cairo "$CAIRO_WANT"
else
    add "MISSING  Homebrew  ->  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    add "         (Homebrew is needed to install XQuartz + cairo, then re-run this check)"
fi

# Overall status + pop-up
if printf '%s' "$report" | grep -q '^MISSING\|^OUTDATED'; then
    status="Action needed -- see the commands below."
else
    status="All runtime prerequisites are present."
fi
printf '\n%s\n' "$status"

if [ "$GUI" = 1 ] && command -v osascript >/dev/null 2>&1; then
    dlg="$(printf 'Magic runtime prerequisites\n(this build: %s)\n\n%s\n%s' \
           "$BUILD_LABEL" "$report" "$status" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')"
    osascript -e "display dialog \"$dlg\" buttons {\"OK\"} with title \"Magic\"" >/dev/null 2>&1 || true
fi

# --- HOW TO RE-RUN THIS CHECK LATER ------------------------------------------
# From Terminal, at any time:
#   bash "/Applications/Magic.app/Contents/Resources/macos_runtime_prereq_check.sh"
# (append --no-gui to print only, without the pop-up).  Copy any brew command
# shown above to install/upgrade a missing or outdated prerequisite.
