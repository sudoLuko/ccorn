#!/bin/bash
# e2e-churn.sh — focused reproduction of the window-creation failure that only
# appears after many new/kill cycles in an *existing* ccorn session
# ("could not create tmux window"; raw tmux: "index 0 in use"). A freshly
# created session never shows it, so the repro must churn ONE persistent
# session and never kill-server between cycles.
#
# Black-box: it drives the real engine through the debug channel exactly as the
# UI does (startNewSession -> killSession) and asserts every `new` comes back
# `started(...)`. The first `new` that returns `failed(...)` or
# `windowCreatedNoProcess` is the bug — the script stops, writes the tmux window
# table as a minimal repro, and exits non-zero (via finish/FAILS). All N cycles
# clean -> exit 0, so this doubles as a regression guard once the bug is fixed.
#
# Real signed-in account, like the other e2e scripts: an idle new/kill sends no
# prompt and costs nothing. Its own tmux server (CCORN_DEBUG_TMUX_SOCKET),
# support dir, and channel — shares nothing with your running CCorn.
#
# Usage:
#   scripts/preflight/e2e-churn.sh [cycles]              # default 50
#   CHURN_KEEP_GOING=1 scripts/preflight/e2e-churn.sh 200  # don't stop at first fail
set -euo pipefail
cd "$(dirname "$0")/../.."

CYCLES=${1:-50}
SOCKET=ccorn-churn
SESSION=ccornChurn
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-churn/run-$STAMP
PROJ="$E2E/proj"
RESULTS="$E2E/results.jsonl"
APP_BIN=build/Build/Products/Debug/CCorn.app/Contents/MacOS/CCorn

source scripts/preflight/e2e-lib.sh

# A Debug build is required (e2e_setup hard-fails without one); build if absent.
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
mkdir -p "$PROJ"

# One persistent server+session for the whole run: the failure only emerges
# once the session has accumulated churn, so it must never be recreated.
TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
launch_app
cmd onboard "$PROJ" > /dev/null

# results.jsonl: one JSON object per line, every field escaped by jq. No
# hand-built JSON — a stray quote or newline in an engine reply cannot corrupt
# the file (the failure mode of the deleted harness).
record() { # <op> <status> <cycle> <reply>
    jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg op "$1" --arg status "$2" --argjson cycle "$3" --arg reply "$4" \
        '{timestamp:$ts, phase:"churn", cycle:$cycle, op:$op, status:$status, reply:$reply}' \
        >> "$RESULTS"
}

# Minimal repro artifact, written the moment window creation fails.
dump_repro() { # <cycle> <reply>
    {
        echo "=== window creation FAILED at cycle $1 of $CYCLES ==="
        echo "channel reply : $2"
        echo "tmux session  : $SESSION   (socket: $SOCKET)"
        echo "window table  :"
        TMUX list-windows -t "$SESSION" 2>&1 || true
        echo "app log tail  :"
        tail -20 "$E2E/app.log" 2>/dev/null || true
    } | tee "$E2E/repro.txt"
}

log "churning $CYCLES new/kill cycles on one session ($PROJ)"
trusted=false
completed=0
for ((c = 1; c <= CYCLES; c++)); do
    new_reply=$(cmd new "$PROJ") || true

    # The reply is the StartResult's default description:
    #   new started(windowId: "@N", pid: NNN)      -> window created, claude up
    #   new failed("could not create tmux window")  -> THE BUG
    #   new windowCreatedNoProcess(windowId: "@N")  -> window made, claude vanished
    #   err channel-timeout                         -> app hung
    if [[ $new_reply != "new started("* ]]; then
        record new failure "$c" "$new_reply"
        fail "cycle $c: $new_reply"
        dump_repro "$c" "$new_reply"
        [[ "${CHURN_KEEP_GOING:-0}" == 1 ]] || break
        cmd kill "$PROJ" > /dev/null 2>&1 || true   # best-effort cleanup, then continue
        continue
    fi
    record new success "$c" "$new_reply"

    # First cycle only: clear the one-time "trust this folder" prompt the way a
    # user would. Once accepted the dir is trusted in ~/.claude.json and the
    # prompt never returns, so stop checking (a per-cycle wait would burn 3s).
    if ! $trusted; then
        win=$(row_window "$PROJ") || true
        if [[ -n "$win" && "$win" != null ]] && wait_pane "$win" "trust this folder" 3; then
            TMUX send-keys -t "$win" Enter
        fi
        trusted=true
    fi

    kill_reply=$(cmd kill "$PROJ") || true
    if [[ $kill_reply == killed* ]]; then
        record kill success "$c" "$kill_reply"
    else
        record kill failure "$c" "$kill_reply"
        fail "cycle $c: kill -> $kill_reply"
    fi

    completed=$c
    [[ $((c % 10)) -eq 0 ]] && log "  $c/$CYCLES cycles clean"
    sleep 0.3
done

echo
log "completed $completed/$CYCLES clean cycles · $(wc -l < "$RESULTS" | tr -d ' ') ops logged"
log "results: $RESULTS"
[[ -f "$E2E/repro.txt" ]] && log "repro:   $E2E/repro.txt"
finish
