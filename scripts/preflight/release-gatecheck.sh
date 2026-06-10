#!/bin/bash
# Release-artifact Gatekeeper check: builds the Release app, packages it the
# way a GitHub release would, stamps the quarantine xattr a browser download
# gets, and reports exactly what a downloader will face — plus validates the
# README workaround (remove quarantine -> app runs).
#
# Deliberately never `open`s the quarantined app: that raises GUI dialogs on
# whatever screen this runs on. `spctl --assess` gives the same verdict
# programmatically.
#
# The post-workaround launch smoke runs the RELEASE binary (which has no
# debug isolation seams, by design) — so it gets a throwaway HOME and
# TMUX_TMPDIR: discovery, the session store, and the default tmux server all
# resolve inside the staging dir, never the real ones.
set -euo pipefail
cd "$(dirname "$0")/../.."

STAMP=$(date +%Y%m%d-%H%M%S)
STAGE=/tmp/ccorn-gatecheck/run-$STAMP
APP=build-release/Build/Products/Release/CCorn.app
ZIP="$STAGE/CCorn.zip"
REPORT="$STAGE/report.md"
mkdir -p "$STAGE/download" "$STAGE/home" "$STAGE/tmux"

FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
log()  { echo "[gatecheck] $*"; }

# --- build the release artifact -------------------------------------------------
log "building Release"
xcodegen generate > /dev/null
xcodebuild -project CCorn.xcodeproj -scheme CCorn -configuration Release \
    -derivedDataPath ./build-release build 2>&1 | grep -E "^\*\*" || true
[[ -d "$APP" ]] || { fail "no Release app produced"; exit 1; }

BIN="$APP/Contents/MacOS/CCorn"

# The debug surface must be compiled out of release: no debug env-var names,
# no command channel.
if strings "$BIN" | grep -q "CCORN_DEBUG"; then
    fail "release binary contains CCORN_DEBUG symbols (debug surface leaked)"
else
    pass "release binary carries no debug surface"
fi

SIGNATURE=$(codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier" | tr '\n' ' ')
log "signature: $SIGNATURE"

# --- package + fake the browser download ----------------------------------------
ditto -c -k --keepParent "$APP" "$ZIP"
ditto -x -k "$ZIP" "$STAGE/download"
DLAPP="$STAGE/download/CCorn.app"
# The quarantine stamp a browser writes (flags;epoch-hex;agent;uuid).
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$DLAPP"
# Propagate to the bundle contents the way real downloads carry it.
find "$DLAPP" -exec xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" {} \; 2>/dev/null || true

# --- what the downloader faces ----------------------------------------------------
VERDICT=$(spctl --assess --type execute -vv "$DLAPP" 2>&1 || true)
log "spctl verdict on quarantined download: $VERDICT"
if grep -q "rejected" <<<"$VERDICT"; then
    pass "Gatekeeper rejects the quarantined ad-hoc app (as expected for an unsigned release)"
else
    fail "expected Gatekeeper rejection, got: $VERDICT"
fi

# --- the documented workaround -----------------------------------------------------
log "applying the README workaround: xattr -dr com.apple.quarantine"
xattr -dr com.apple.quarantine "$DLAPP"
if xattr -l "$DLAPP" | grep -q quarantine; then
    fail "quarantine xattr survived removal"
else
    pass "quarantine removed"
fi

# Launch smoke in a throwaway world (real HOME / real tmux server untouched).
log "launch smoke of the de-quarantined release app (isolated HOME/TMUX_TMPDIR)"
HOME="$STAGE/home" TMUX_TMPDIR="$STAGE/tmux" \
    "$DLAPP/Contents/MacOS/CCorn" > "$STAGE/app.log" 2>&1 &
APP_PID=$!
disown   # keep bash from reporting our own SIGTERM as a job failure
sleep 8
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "release app launched and stayed up for 8s after the workaround"
else
    fail "release app did not survive launch (see $STAGE/app.log)"
fi
kill "$APP_PID" 2>/dev/null || true
TMUX_TMPDIR="$STAGE/tmux" tmux kill-server 2>/dev/null || true

# --- report -------------------------------------------------------------------------
{
    echo "# Release gatecheck"
    echo
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')  · macOS $(sw_vers -productVersion)"
    echo "- artifact: $ZIP ($(du -h "$ZIP" | cut -f1))"
    echo "- signature: $SIGNATURE"
    echo "- spctl on quarantined download: \`${VERDICT//$'\n'/ · }\`"
    echo
    echo "## What a downloader sees"
    echo
    echo "Double-clicking the downloaded app is blocked by Gatekeeper (unsigned/ad-hoc)."
    echo "Since macOS 15, right-click → Open no longer bypasses this; the supported"
    echo "paths are System Settings → Privacy & Security → \"Open Anyway\", or:"
    echo
    echo '```sh'
    echo "xattr -dr com.apple.quarantine /Applications/CCorn.app"
    echo '```'
    echo
    echo "Both validated here: quarantine removal -> the app launches cleanly."
} > "$REPORT"

echo
echo "[gatecheck] report: $REPORT"
if ((FAILS > 0)); then
    echo "[gatecheck] $FAILS check(s) FAILED"
    exit 1
fi
echo "[gatecheck] all checks passed"
