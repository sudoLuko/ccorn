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
# its own debug-channel paths; it shares nothing with the user's default
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
FRESH_CONFIG="$E2E/fresh-config"   # signed-out claude config for spawned sessions
PROJ_A="$E2E/proj-a"               # scenario A: needsAuth inside grace -> modal
PROJ_B="$E2E/proj-b"               # scenario B: needsAuth after grace -> no modal

source scripts/preflight/e2e-lib.sh
e2e_setup
mkdir -p "$FRESH_CONFIG" "$PROJ_A" "$PROJ_B"

TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
# Sessions the app spawns must land signed-out: the session environment is
# inherited by every window the app creates on this server.
TMUX set-environment -t "$SESSION" CLAUDE_CONFIG_DIR "$FRESH_CONFIG"

launch_app
cmd onboard "$PROJ_A" > /dev/null   # complete onboarding so flows are live

# --- scenario A: login screen inside the grace window -> modal -----------------
log "scenario A: new session lands on login screen within grace"
cmd new "$PROJ_A" > /dev/null
WIN=$(row_window "$PROJ_A")
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

assert_row_state "$PROJ_A" needsAuth 10 "A: row flipped within poll ticks"

NOTICE=$(row_notice "$PROJ_A")
if [[ -n "$NOTICE" && "$NOTICE" != "null" ]]; then
    pass "A: authNotice carries the CLI's line: \"$NOTICE\""
else
    fail "A: authNotice is empty"
fi

sleep 2   # the alert presents a turn after the rows publish
cmd show main > /dev/null
sleep 1
shot main auth-modal.png
DISMISSED=$(cmd dismisssheet)
if [[ "$DISMISSED" == "dismissed 1" ]]; then
    pass "A: one-shot auth modal was presented (and dismissed)"
else
    fail "A: expected exactly one sheet, got '$DISMISSED'"
fi

# --- scenario B: login screen after grace expiry -> notification, NO modal -----
log "scenario B: session drifts to login after the 30s grace (no modal)"
cmd new "$PROJ_B" > /dev/null
WIN=$(row_window "$PROJ_B")
wait_pane "$WIN" "Choose the text style" 25 || log "WARN: no theme picker in B"
log "B: sitting out the 30s activation grace before driving to the login screen"
sleep 35
TMUX send-keys -t "$WIN" Enter
if wait_pane "$WIN" "Select login method" 20; then
    pass "B: login screen rendered after grace expiry"
else
    fail "B: login screen never rendered"
fi
assert_row_state "$PROJ_B" needsAuth 10 "B: row flipped after grace"
sleep 3
DISMISSED=$(cmd dismisssheet)
if [[ "$DISMISSED" == "dismissed 0" ]]; then
    pass "B: no modal for a drift-into-auth session (notification path)"
else
    fail "B: expected no sheet, got '$DISMISSED'"
fi

# Evidence shot of the rows themselves (the needsAuth row treatment).
shot main rows.png
finish
