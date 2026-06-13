#!/bin/bash
# spawn-in-terminal.sh — watch CCorn spawn real Claude Code sessions into
# VISIBLE Terminal.app windows via the actual product path: startNewSession ->
# openInTerminal -> osascript `tmux attach`. Unlike e2e-churn.sh (headless
# channel ops), this opens real Terminal windows you can watch and type into —
# including answering each "trust this folder" prompt the way you normally would.
#
# Hermetic like the other e2e scripts: own tmux server (CCORN_DEBUG_TMUX_SOCKET),
# session, support dir, and channel. The visible attach lands on that isolated
# server, not your real `ccorn`, because the app's attach command now honors the
# debug socket+session (AppModel.attachTerminal). Real signed-in account.
#
# Usage:
#   scripts/preflight/spawn-in-terminal.sh [count]      # default 3; holds until Ctrl-C
#   HOLD_SECONDS=8 scripts/preflight/spawn-in-terminal.sh 2   # auto-teardown after 8s
#
# On exit (Ctrl-C or HOLD_SECONDS elapsed) the e2e-lib EXIT trap quits the
# hermetic app and kills its tmux server, so the spawned Terminal windows detach.
set -euo pipefail
cd "$(dirname "$0")/../.."

COUNT=${1:-3}
HOLD_SECONDS=${HOLD_SECONDS:-0}        # 0 = hold open until Ctrl-C
SOCKET=ccorn-spawn
SESSION=ccornSpawn
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-spawn/run-$STAMP
APP_BIN=build/Build/Products/Debug/CCorn.app/Contents/MacOS/CCorn

source scripts/preflight/e2e-lib.sh

mkdir -p "$E2E"
if [[ ! -x "$APP_BIN" ]]; then
    log "no debug build at $APP_BIN — building Debug…"
    [[ -d CCorn.xcodeproj ]] || xcodegen generate
    if ! xcodebuild -project CCorn.xcodeproj -scheme CCorn -configuration Debug \
        -derivedDataPath build build > "$E2E/build.log" 2>&1; then
        tail -20 "$E2E/build.log"
        echo "FATAL: Debug build failed (full log: $E2E/build.log)"
        exit 1
    fi
fi

e2e_setup
TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
launch_app

onboarded=false
for ((i = 1; i <= COUNT; i++)); do
    proj="$E2E/proj-$i"
    mkdir -p "$proj"
    # One onboard clears the app's onboarding gate; later `new`s manage their
    # dirs regardless of whether they are watch dirs.
    if ! $onboarded; then cmd onboard "$proj" > /dev/null; onboarded=true; fi

    log "spawning session $i in $proj"
    new_reply=$(cmd new "$proj") || true
    if [[ $new_reply != "new started("* ]]; then
        fail "session $i did not start: $new_reply"
        continue
    fi
    pass "session $i started ($new_reply)"

    # The real "Open in Terminal" path: a Terminal window pops up attached to the
    # window we just created on the isolated server.
    term_reply=$(cmd terminal "$proj") || true
    if [[ $term_reply == terminal* ]]; then
        pass "session $i attached in Terminal ($term_reply)"
    else
        fail "session $i: Open in Terminal -> $term_reply"
    fi
    sleep 2   # let the window settle / be seen before the next pops
done

echo
log "$COUNT session(s) attached to the hermetic '$SESSION' session (socket: $SOCKET)."
log "Answer any 'trust this folder' prompt in each Terminal as you would normally."
if (( HOLD_SECONDS > 0 )); then
    log "holding $HOLD_SECONDS s, then tearing down…"
    sleep "$HOLD_SECONDS"
    finish
else
    log "Press Ctrl-C here to close the sessions and quit the hermetic app."
    while true; do sleep 1; done
fi
