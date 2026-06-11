#!/bin/bash
# tmux chaos suite: things users and crashes do to CCorn's tmux world behind
# its back. Runs against a hermetic app instance on its OWN tmux server
# (CCORN_DEBUG_TMUX_SOCKET) — the kill-server scenario below is only safe
# because of that isolation; it must never run against the default server.
#
# Scenarios:
#   A  junk typed into a healthy session's pane  -> settles back to Running
#   B  claude SIGKILLed, window+shell survive    -> Dead (T2: pane still looks
#      alive — PID liveness must decide, never pane content)
#   C  kill-window behind CCorn's back           -> Dead
#   D  restart of the killed session             -> back to Running
#   E  tmux kill-server mid-run                  -> app survives, all rows
#      Dead, channel responsive
#   F  new session after the server died         -> server auto-respawns,
#      session comes up Running
#
# Sessions use the real signed-in account (idle sessions cost nothing); each
# scratch dir hits the first-run trust prompt, which the script accepts the
# way a user would.
set -euo pipefail
cd "$(dirname "$0")/../.."

SOCKET=ccorn-chaos
SESSION=ccornChaos
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-chaos/run-$STAMP
PROJ_1="$E2E/proj-1"
PROJ_2="$E2E/proj-2"
PROJ_3="$E2E/proj-3"

source scripts/preflight/e2e-lib.sh
e2e_setup
mkdir -p "$PROJ_1" "$PROJ_2" "$PROJ_3"

TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
launch_app
cmd onboard "$PROJ_1" > /dev/null

# Start a session and walk it to healthy idle: accept the trust prompt the
# way a user would, then wait for the engine to report Running.
start_session() { # <dir>
    cmd new "$1" > /dev/null
    local win
    win=$(row_window "$1")
    if wait_pane "$win" "trust this folder" 25; then
        TMUX send-keys -t "$win" Enter
    fi
    wait_row_state "$1" running 40
}

log "starting two healthy sessions"
if start_session "$PROJ_1"; then pass "session 1 healthy (running)"; else fail "session 1 never reached running"; fi
if start_session "$PROJ_2"; then pass "session 2 healthy (running)"; else fail "session 2 never reached running"; fi

# --- A: junk typed into the pane ------------------------------------------------
log "A: typing junk into session 1's pane"
WIN1=$(row_window "$PROJ_1")
TMUX send-keys -t "$WIN1" -l -- "stray keystrokes from a user poking around"
sleep 4   # pane changed -> may read Working for a tick
assert_row_state "$PROJ_1" running 30 "A: junk-typed session settles back"
TMUX send-keys -t "$WIN1" C-u   # clear the input line for later scenarios

# --- B: claude killed, window survives (T2 in the real app) ---------------------
log "B: SIGKILL the claude process; window and shell stay up"
# `pids` prints "pids @1=123 @2=456"; "-" means no pid tracked.
CLAUDE_PID=$(cmd pids | tr ' ' '\n' | awk -F= -v w="$WIN1" '$1 == w {print $2}')
if [[ -n "$CLAUDE_PID" && "$CLAUDE_PID" != "-" ]]; then
    kill -9 "$CLAUDE_PID"
    assert_row_state "$PROJ_1" dead 20 "B: SIGKILLed claude detected by PID despite live-looking pane"
else
    fail "B: could not resolve claude pid for $WIN1"
fi

# --- C: kill-window behind CCorn's back -----------------------------------------
log "C: kill-window on session 2 behind CCorn's back"
WIN2=$(row_window "$PROJ_2")
TMUX kill-window -t "$WIN2"
assert_row_state "$PROJ_2" dead 20 "C: externally killed window detected"

# --- D: restart the dead session -------------------------------------------------
log "D: restart session 1 via the app flow"
cmd restart "$PROJ_1" > /dev/null
# The replacement window resumes in the same (now trusted) directory.
assert_row_state "$PROJ_1" running 40 "D: restarted session recovers"

# --- E: kill-server mid-run ------------------------------------------------------
log "E: tmux kill-server on the app's server (isolated socket)"
TMUX kill-server
assert_row_state "$PROJ_1" dead 20 "E: session 1 reported dead after server death"
if cmd dump | grep -q '^\['; then
    pass "E: app alive and channel responsive after kill-server"
else
    fail "E: channel dead after kill-server"
fi

# --- F: new session after the server died ----------------------------------------
log "F: new session after server death (server must respawn)"
cmd new "$PROJ_3" > /dev/null
WIN3=$(row_window "$PROJ_3")
if [[ -n "$WIN3" ]]; then
    if wait_pane "$WIN3" "trust this folder" 25; then
        TMUX send-keys -t "$WIN3" Enter
    fi
    assert_row_state "$PROJ_3" running 40 "F: post-kill-server session comes up"
else
    fail "F: no window created for the new session"
fi

shot main rows-after-chaos.png
finish
