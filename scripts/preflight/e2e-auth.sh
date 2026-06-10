#!/bin/bash
# End-to-end test of the section-8 auth pipeline in the REAL app:
#
#   real signed-out claude (fresh CLAUDE_CONFIG_DIR) -> StateDetector flags
#   needsAuth from the live pane -> transition edge in AppModel -> the
#   one-shot modal inside the 30s grace -> and the drift path (grace expired)
#   that must NOT show the modal.
#
# Hermetic by construction: the app instance runs on its own tmux SERVER
# (CCORN_DEBUG_TMUX_SOCKET), its own session name, its own support dir, and
# its own debug-channel paths — it shares nothing with the user's default
# tmux server, a normally-running CCorn, or another debug instance.
#
# Prereq: a Debug build at build/Build/Products/Debug/CCorn.app
# (xcodegen generate && xcodebuild -scheme CCorn -configuration Debug
#  -derivedDataPath ./build build)
set -euo pipefail
cd "$(dirname "$0")/../.."

SOCKET=ccorn-e2e
SESSION=ccornE2E
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-e2e/run-$STAMP
CHANNEL="$E2E/chan"
SUPPORT="$E2E/support"
FRESH_CONFIG="$E2E/fresh-config"   # signed-out claude config for spawned sessions
PROJ_A="$E2E/proj-a"               # scenario A: needsAuth inside grace -> modal
PROJ_B="$E2E/proj-b"               # scenario B: needsAuth after grace -> no modal
APP_BIN=build/Build/Products/Debug/CCorn.app/Contents/MacOS/CCorn
SHOTS="$E2E/shots"

mkdir -p "$CHANNEL" "$SUPPORT" "$FRESH_CONFIG" "$PROJ_A" "$PROJ_B" "$SHOTS"
[[ -x "$APP_BIN" ]] || { echo "FATAL: no debug build at $APP_BIN"; exit 1; }

TMUX() { command tmux -L "$SOCKET" "$@"; }
log() { echo "[e2e-auth] $*"; }

FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }

# --- debug-channel client -----------------------------------------------------
# The app polls $CHANNEL/cmd every 0.5s, removes it, writes $CHANNEL/out.
cmd() {
    rm -f "$CHANNEL/out"
    echo "$*" > "$CHANNEL/cmd"
    local deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
        [[ -f "$CHANNEL/out" ]] && { cat "$CHANNEL/out"; return 0; }
        sleep 0.3
    done
    echo "err channel-timeout"
    return 1
}

# State of the row at a path, from the dump JSON.
row_state() { cmd dump | jq -r --arg p "$1" '.[] | select(.path == $p) | .state'; }
row_notice() { cmd dump | jq -r --arg p "$1" '.[] | select(.path == $p) | .authNotice'; }

wait_row_state() { # <path> <state> <timeout>
    local deadline=$((SECONDS + $3))
    while ((SECONDS < deadline)); do
        [[ "$(row_state "$1")" == "$2" ]] && return 0
        sleep 1
    done
    return 1
}

# --- pane driving (simulating the user in Terminal) ---------------------------
pane_of() { # window id of the newest window in our session
    TMUX list-windows -t "$SESSION" -F '#{window_id}' | tail -1
}
pane_text() { TMUX capture-pane -t "$1" -p; }
wait_pane() { # <window> <string> <timeout>
    local deadline=$((SECONDS + $3))
    while ((SECONDS < deadline)); do
        pane_text "$1" | grep -qiF -- "$2" && return 0
        sleep 0.5
    done
    return 1
}

# --- bring up the hermetic world -----------------------------------------------
TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
# Sessions the app spawns must land signed-out: the session environment is
# inherited by every window the app creates on this server.
TMUX set-environment -t "$SESSION" CLAUDE_CONFIG_DIR "$FRESH_CONFIG"

log "launching hermetic app instance"
CCORN_DEBUG_UI=cmd \
CCORN_DEBUG_TMUX_SOCKET=$SOCKET \
CCORN_DEBUG_TMUX_SESSION=$SESSION \
CCORN_DEBUG_SUPPORT_DIR="$SUPPORT" \
CCORN_DEBUG_CHANNEL_DIR="$CHANNEL" \
"$APP_BIN" > "$E2E/app.log" 2>&1 &
APP_PID=$!

cleanup() {
    kill "$APP_PID" 2>/dev/null || true
    TMUX kill-server 2>/dev/null || true
}
trap cleanup EXIT

# Channel up? The channel deletes any pre-existing cmd file when it starts,
# so a command written too early is eaten — probe with retries.
CHANNEL_UP=false
for _ in 1 2 3 4; do
    if cmd dump | grep -q '^\['; then CHANNEL_UP=true; break; fi
done
if $CHANNEL_UP; then
    pass "app launched; debug channel responding"
else
    fail "debug channel never responded"; exit 1
fi
cmd onboard "$PROJ_A" > /dev/null   # complete onboarding so flows are live

# --- scenario A: login screen inside the grace window -> modal -----------------
log "scenario A: new session lands on login screen within grace"
cmd new "$PROJ_A" > /dev/null
WIN=$(pane_of)
if wait_pane "$WIN" "Choose the text style" 25; then
    TMUX send-keys -t "$WIN" Enter       # the user advancing first-run setup
else
    log "WARN: no theme picker; continuing (flow may go straight to login)"
fi
if wait_pane "$WIN" "Select login method" 20; then
    pass "A: real signed-out login screen rendered"
else
    fail "A: login screen never rendered"
fi

# Resolved /tmp paths read /private/tmp back from the engine (T3 normalizes
# toward /tmp) — rows store the /tmp form, which is what $PROJ_A already is.
if wait_row_state "$PROJ_A" needsAuth 10; then
    pass "A: row state flipped to needsAuth within poll ticks"
else
    fail "A: row never reached needsAuth (state: $(row_state "$PROJ_A"))"
fi

NOTICE=$(row_notice "$PROJ_A")
if [[ -n "$NOTICE" && "$NOTICE" != "null" ]]; then
    pass "A: authNotice carries the CLI's line: \"$NOTICE\""
else
    fail "A: authNotice is empty"
fi

sleep 2   # the alert presents a turn after the rows publish
cmd show main > /dev/null
sleep 1
# Real compositor pixels (shoot/cacheDisplay renders materials blank).
WID=$(cmd windowid main | awk '{print $2}')
[[ -n "$WID" ]] && screencapture -o -l "$WID" "$SHOTS/auth-modal.png" 2>/dev/null || true
DISMISSED=$(cmd dismisssheet)
if [[ "$DISMISSED" == "dismissed 1" ]]; then
    pass "A: one-shot auth modal was presented (and dismissed)"
else
    fail "A: expected exactly one sheet, got '$DISMISSED'"
fi

# --- scenario B: login screen after grace expiry -> notification, NO modal -----
log "scenario B: session drifts to login after the 30s grace (no modal)"
cmd new "$PROJ_B" > /dev/null
WIN=$(pane_of)
wait_pane "$WIN" "Choose the text style" 25 || log "WARN: no theme picker in B"
log "B: sitting out the 30s activation grace before driving to the login screen"
sleep 35
TMUX send-keys -t "$WIN" Enter
if wait_pane "$WIN" "Select login method" 20; then
    pass "B: login screen rendered after grace expiry"
else
    fail "B: login screen never rendered"
fi
if wait_row_state "$PROJ_B" needsAuth 10; then
    pass "B: row state flipped to needsAuth"
else
    fail "B: row never reached needsAuth (state: $(row_state "$PROJ_B"))"
fi
sleep 3
DISMISSED=$(cmd dismisssheet)
if [[ "$DISMISSED" == "dismissed 0" ]]; then
    pass "B: no modal for a drift-into-auth session (notification path)"
else
    fail "B: expected no sheet, got '$DISMISSED'"
fi

# Evidence shot of the rows themselves (the needsAuth row treatment).
WID=$(cmd windowid main | awk '{print $2}')
[[ -n "$WID" ]] && screencapture -o -l "$WID" "$SHOTS/rows.png" 2>/dev/null || true

echo
if ((FAILS > 0)); then
    echo "[e2e-auth] $FAILS assertion(s) FAILED — logs: $E2E/app.log, shots: $SHOTS"
    exit 1
fi
echo "[e2e-auth] all assertions passed — shots: $SHOTS"
