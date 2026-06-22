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
cmd onboard "$PROJ_A" "$PROJ_B" > /dev/null   # complete onboarding so flows are live

# The section-8 alert is an NSAlert that sheets onto a visible "CCorn" window
# and falls back to a blocking runModal otherwise (Alerts.sheetOrModal). Show
# the main window first so the alert is always the countable sheet, never a
# runModal that would stall the debug channel.
cmd show main > /dev/null
sleep 1

# Why this test forces detection passes instead of trusting the poll:
# the 2.1.181 onboarding reaches the login picker fast (theme picker ~2s after
# spawn, then a single Enter -> "Select login method" ~1s later, well inside the
# 30s grace). The classifier flags that frame needsAuth on first sight (the
# preflight contract test pins it). The flake is NOT detection or onboarding: in
# the headless e2e app no window ever counts as on-screen, so the state poll
# parks at its 30s idle cadence, and the login pane is first re-observed on a
# tick that lands right on the session's own 30s activation grace boundary. The
# modal gate (`!rcGraceExpired`) is then decided by sub-second poll-vs-grace
# alignment: A (wants the modal) and B (wants none) were testing that same knife
# edge from opposite sides, so each failed about as often as it passed. The fix
# is to observe the transition at a CONTROLLED time relative to the grace via an
# explicit `force_refresh` (same engine refresh the poll runs), not to wait on a
# tick whose phase is unknowable.

# --- scenario A: login screen INSIDE the grace -> one-shot modal ---------------
log "scenario A: session reaches the login screen well inside the 30s grace"
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

# Observe the running->needsAuth transition NOW, while the session is still
# deep inside its 30s grace (login rendered ~6-8s after spawn): the modal must
# fire. force_refresh runs the real engine refresh + rebuildRows, which is where
# presentAuthAlertIfNeeded fires the one-shot alert.
force_refresh "$PROJ_A" "auth-A"
assert_row_state "$PROJ_A" needsAuth 10 "A: row flipped within grace"

NOTICE=$(row_notice "$PROJ_A")
if [[ -n "$NOTICE" && "$NOTICE" != "null" ]]; then
    pass "A: authNotice carries the CLI's line: \"$NOTICE\""
else
    fail "A: authNotice is empty"
fi

sleep 2   # the alert presents a turn after the rows publish
shot main auth-modal.png
DISMISSED=$(cmd dismisssheet)
if [[ "$DISMISSED" == "dismissed 1" ]]; then
    pass "A: one-shot auth modal was presented (and dismissed)"
else
    fail "A: expected exactly one sheet, got '$DISMISSED'"
fi

# --- scenario B: login screen AFTER grace expiry -> notification, NO modal -----
# The grace is measured from session start, so hold B on the theme picker (a
# benign "running" frame) until the 30s grace has unambiguously expired, THEN
# advance to login. Because the FIRST time B's pane shows login is past the
# grace, no observation of it can fire the modal. Forcing the refresh after the
# advance gives the verdict immediately, without depending on a slow poll tick.
log "scenario B: session drifts to login AFTER the 30s grace (no modal)"
cmd new "$PROJ_B" > /dev/null
WIN=$(row_window "$PROJ_B")
wait_pane "$WIN" "Choose the text style" 25 || log "WARN: no theme picker in B"
log "B: holding on the theme picker through the 30s activation grace"
sleep 35   # > 30s grace; B's pane shows only the (running) theme picker until now
TMUX send-keys -t "$WIN" Enter
if wait_pane "$WIN" "Select login method" 20; then
    pass "B: login screen rendered after grace expiry"
else
    fail "B: login screen never rendered"
fi
force_refresh "$PROJ_B" "auth-B"
assert_row_state "$PROJ_B" needsAuth 10 "B: row flipped after grace"
sleep 2
DISMISSED=$(cmd dismisssheet)
if [[ "$DISMISSED" == "dismissed 0" ]]; then
    pass "B: no modal for a drift-into-auth session (notification path)"
else
    fail "B: expected no sheet, got '$DISMISSED'"
fi

# Evidence shot of the rows themselves (the needsAuth row treatment).
shot main rows.png
finish
