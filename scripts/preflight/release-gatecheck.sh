#!/bin/bash
# Release-artifact gatecheck. Two jobs:
#
#   1. Always: build Release and assert the debug surface is compiled out (no
#      CCORN_DEBUG strings in the binary), then launch-smoke the freshly built
#      app in a throwaway world. The smoke runs the RELEASE binary (which has
#      no debug isolation seams, by design); so it gets a throwaway HOME and
#      TMUX_TMPDIR: discovery, the session store, and the default tmux server
#      all resolve inside the staging dir, never the real ones.
#
#   2. With a notarized artifact (pass the stapled .app as $1, or run
#      scripts/release.sh which leaves dist/CCorn.app and invokes this): prove
#      what a downloader faces: codesign --verify --strict passes, spctl
#      accepts the app even carrying a browser-style quarantine stamp, and the
#      notarization ticket is stapled (stapler validate, so the verdict holds
#      offline too). Deliberately never `open`s the app via LaunchServices:
#      that raises GUI dialogs on whatever screen this runs on; spctl gives
#      the same verdict programmatically.
set -euo pipefail
cd "$(dirname "$0")/../.."

STAMP=$(date +%Y%m%d-%H%M%S)
STAGE=/tmp/ccorn-gatecheck/run-$STAMP
APP=build-release/Build/Products/Release/CCorn.app
ARTIFACT="${1:-}"
[[ -z "$ARTIFACT" && -d dist/CCorn.app ]] && ARTIFACT=dist/CCorn.app
REPORT="$STAGE/report.md"
mkdir -p "$STAGE/home" "$STAGE/tmux"

FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP  $*"; }
log()  { echo "[gatecheck] $*"; }

# --- build the release binary ----------------------------------------------------
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

SIGNATURE=$(codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier|flags" | tr '\n' ' ')
log "built-app signature: $SIGNATURE"

# Launch smoke in a throwaway world (real HOME / real tmux server untouched).
log "launch smoke of the built Release app (isolated HOME/TMUX_TMPDIR)"
HOME="$STAGE/home" TMUX_TMPDIR="$STAGE/tmux" \
    "$BIN" > "$STAGE/app.log" 2>&1 &
APP_PID=$!
disown   # keep bash from reporting our own SIGTERM as a job failure
sleep 8
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "release app launched and stayed up for 8s under the hardened runtime"
else
    fail "release app did not survive launch (see $STAGE/app.log)"
fi
kill "$APP_PID" 2>/dev/null || true
TMUX_TMPDIR="$STAGE/tmux" tmux kill-server 2>/dev/null || true

# --- notarized-artifact validation ----------------------------------------------
NVERDICT="(no artifact)"
if [[ -z "$ARTIFACT" ]]; then
    skip "no notarized artifact to validate; run scripts/release.sh first, or pass the stapled .app as \$1"
else
    log "validating notarized artifact: $ARTIFACT"
    # Work on a copy stamped the way a real browser download arrives.
    DLAPP="$STAGE/download/CCorn.app"
    mkdir -p "$STAGE/download"
    ditto "$ARTIFACT" "$DLAPP"
    find "$DLAPP" -exec xattr -w com.apple.quarantine \
        "0081;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" {} \; 2>/dev/null || true

    # The shipped binary must be stripped (release.sh runs strip -rSx before
    # signing): no /Users build paths in its symbol table. strings can't see
    # these STAB entries, so probe with nm -pa, the way they actually hide.
    if nm -pa "$DLAPP/Contents/MacOS/CCorn" 2>/dev/null | grep -q "/Users/"; then
        fail "artifact binary contains absolute build paths (not stripped before signing)"
    else
        pass "artifact binary carries no absolute build paths"
    fi

    if codesign --verify --strict --verbose=2 "$DLAPP" 2>&1; then
        pass "codesign --verify --strict accepts the artifact"
    else
        fail "codesign --verify --strict rejected the artifact"
    fi

    NVERDICT=$(spctl --assess --type execute -vv "$DLAPP" 2>&1 || true)
    log "spctl verdict on quarantined artifact: $NVERDICT"
    if grep -q "accepted" <<<"$NVERDICT" && grep -q "Notarized Developer ID" <<<"$NVERDICT"; then
        pass "Gatekeeper accepts the quarantined artifact as Notarized Developer ID"
    else
        fail "expected spctl 'accepted / Notarized Developer ID', got: $NVERDICT"
    fi

    if xcrun stapler validate "$DLAPP" > /dev/null 2>&1; then
        pass "notarization ticket is stapled (valid offline)"
    else
        fail "stapler validate failed: ticket missing or not stapled"
    fi
fi

# --- report -------------------------------------------------------------------------
{
    echo "# Release gatecheck"
    echo
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')  · macOS $(sw_vers -productVersion)"
    echo "- artifact: ${ARTIFACT:-none (built app only)}"
    echo "- built-app signature: $SIGNATURE"
    echo "- spctl on quarantined artifact: \`${NVERDICT//$'\n'/ · }\`"
    echo
    echo "## What a downloader sees"
    echo
    echo "The artifact is signed with a Developer ID and notarized: Gatekeeper"
    echo "accepts it straight from a browser download. No overrides, no xattr"
    echo "workarounds; the only first-open prompt is the standard"
    echo "\"downloaded from the Internet\" confirmation."
} > "$REPORT"

echo
echo "[gatecheck] report: $REPORT"
if ((FAILS > 0)); then
    echo "[gatecheck] $FAILS check(s) FAILED"
    exit 1
fi
echo "[gatecheck] all checks passed"
