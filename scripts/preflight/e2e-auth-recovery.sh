#!/bin/bash
# End-to-end test of the "recovered auth" case in the REAL app:
#
#   A live, authenticated session emits an auth-error phrase ("Invalid API key")
#   in one turn, then completes a NORMAL successful turn after it. The phrase now
#   sits in scrollback ABOVE later success, with the session idle. Such a session
#   has recovered and must read Running — not needsAuth ("Sign in"), which is the
#   bug when authNotice scans the whole pane instead of recognising the later
#   successful turn that supersedes the stale error.
#
# Drives the hermetic debug app (own tmux server / support dir / debug channel),
# runs two real claude turns on the machine's real auth, reads the row state via
# the debug channel, and captures the resulting pane as a fixture candidate.
#
# Prereq: a Debug build at build/Build/Products/Debug/CCorn.app
# Usage: scripts/preflight/e2e-auth-recovery.sh   (prints the final row state;
#        interpret needsAuth = bug present, running = fixed)
set -euo pipefail
cd "$(dirname "$0")/../.."

SOCKET=ccorn-e2e-recov
SESSION=ccornE2ERecov
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-e2e/recov-$STAMP
PROJ="$E2E/proj"
CAP="$E2E/recovered-pane.txt"

source scripts/preflight/e2e-lib.sh
e2e_setup
mkdir -p "$PROJ"

TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
# NOTE: deliberately do NOT set a fresh CLAUDE_CONFIG_DIR here — this session
# must be REAL-authenticated so its turns actually succeed (that is the whole
# point: a working session with a stale auth phrase in scrollback).

launch_app
cmd onboard "$PROJ" > /dev/null

# Wait until the pane stops showing the live-activity marker for N consecutive
# checks (a turn has finished rendering).
wait_idle() { # <window> <timeout>
    local win=$1 deadline=$((SECONDS + $2)) quiet=0
    while ((SECONDS < deadline)); do
        if pane_text "$win" | grep -qiF "esc to interrupt"; then quiet=0
        else quiet=$((quiet + 1)); ((quiet >= 3)) && return 0; fi
        sleep 1
    done
    return 1
}

drive_turn() { # <window> <prompt>
    TMUX send-keys -t "$1" -l -- "$2"
    TMUX send-keys -t "$1" Enter
    sleep 2
    wait_idle "$1" 90 || log "WARN: turn did not go idle in time"
}

log "creating a real authenticated session"
cmd new "$PROJ" > /dev/null
WIN=$(row_window "$PROJ")
[[ -n "$WIN" && "$WIN" != "null" ]] || { fail "no window for the new session"; finish; }

# Accept the first-run trust prompt for this fresh dir, if it appears.
if wait_pane "$WIN" "trust" 25; then
    TMUX send-keys -t "$WIN" Enter
fi
# Let it settle to an idle, ready prompt.
wait_pane "$WIN" "? for shortcuts" 40 || log "WARN: no idle footer yet"
wait_idle "$WIN" 30 || true

log "turn 1: emit the auth-error phrase"
drive_turn "$WIN" "Output this exact text on its own line and nothing else: Invalid API key"
if pane_text "$WIN" | grep -qiF "Invalid API key"; then
    pass "the auth phrase 'Invalid API key' is now on the pane"
else
    fail "could not get the auth phrase onto the pane (Claude did not emit it)"
fi

log "turn 2: a normal successful turn AFTER the phrase"
drive_turn "$WIN" "Now reply with exactly: all good"

# Capture the resulting recovered pane for use as a fixture.
pane_text "$WIN" > "$CAP"
log "captured recovered pane -> $CAP"

# Give the 3s poll a couple of cycles to classify the settled pane.
sleep 5
STATE=$(row_state "$PROJ")
echo
echo "================ RESULT ================"
echo "  final row state for the recovered session: ${STATE}"
echo "    needsAuth = BUG present (stale phrase wins)"
echo "    running   = FIXED (later success supersedes)"
echo "  captured pane: $CAP"
echo "========================================"
echo

# Record state machine-readably for the caller.
echo "$STATE" > "$E2E/state.txt"
cp "$CAP" /tmp/ccorn-recovered-pane.txt 2>/dev/null || true

finish
