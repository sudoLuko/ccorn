# Shared helpers for the hermetic app e2e scripts (sourced, not executed).
#
# Callers set: SOCKET (tmux -L name), SESSION (tmux session name), E2E (run
# dir), then call e2e_setup + launch_app. Everything (tmux server, support
# dir, debug channel) lives under the run's own namespace; nothing touches
# the user's default tmux server or a normally-running CCorn.

TMUX() { command tmux -L "$SOCKET" "$@"; }

FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
log()  { echo "[$(basename "$0" .sh)] $*"; }

e2e_setup() {
    CHANNEL="$E2E/chan"
    SUPPORT="$E2E/support"
    SHOTS="$E2E/shots"
    APP_BIN=build/Build/Products/Debug/CCorn.app/Contents/MacOS/CCorn
    mkdir -p "$CHANNEL" "$SUPPORT" "$SHOTS"
    [[ -x "$APP_BIN" ]] || { echo "FATAL: no debug build at $APP_BIN"; exit 1; }
}

# --- debug-channel client -------------------------------------------------
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

row_state()  { cmd dump | jq -r --arg p "$1" '.[] | select(.path == $p) | .state'; }
row_notice() { cmd dump | jq -r --arg p "$1" '.[] | select(.path == $p) | .authNotice'; }
row_window() { cmd dump | jq -r --arg p "$1" '.[] | select(.path == $p) | .windowId'; }

wait_row_state() { # <path> <state> <timeout-seconds>
    local deadline=$((SECONDS + $3))
    while ((SECONDS < deadline)); do
        [[ "$(row_state "$1")" == "$2" ]] && return 0
        sleep 1
    done
    return 1
}

assert_row_state() { # <path> <state> <timeout-seconds> <label>
    if wait_row_state "$1" "$2" "$3"; then
        pass "$4 (state: $2)"
    else
        fail "$4, expected $2, got '$(row_state "$1")'"
    fi
}

# --- pane driving (simulating the user in Terminal) ------------------------
pane_text() { TMUX capture-pane -t "$1" -p; }

wait_pane() { # <window> <string> <timeout-seconds>
    local deadline=$((SECONDS + $3))
    while ((SECONDS < deadline)); do
        pane_text "$1" | grep -qiF -- "$2" && return 0
        sleep 0.5
    done
    return 1
}

# Real compositor pixels (the channel's cacheDisplay shoot renders materials blank).
shot() { # <target> <file>
    local wid
    wid=$(cmd windowid "$1" | awk '{print $2}')
    [[ -n "$wid" ]] && screencapture -o -l "$wid" "$SHOTS/$2" 2>/dev/null || true
}

# --- app lifecycle ----------------------------------------------------------
launch_app() {
    log "launching hermetic app instance"
    # A real user launches CCorn from Finder, where no Claude Code session
    # vars exist. Run from a Claude Code Bash tool, CLAUDE_CODE_CHILD_SESSION
    # leaks app -> tmux -> claude, and a claude marked as a child session
    # SKIPS all local session persistence: no pid registry, no conversation
    # records, no history entry, resume refuses (runtime findings P8). Scrub
    # everything Claude-Code-shaped so the hermetic app matches production.
    local scrub
    scrub=$(env | sed -nE 's/^(CLAUDE[A-Za-z0-9_]*|AI_AGENT)=.*/-u \1/p' | tr '\n' ' ')
    # shellcheck disable=SC2086  # word-splitting of the -u flags is intended
    env $scrub \
    CCORN_DEBUG_UI=cmd \
    CCORN_DEBUG_TMUX_SOCKET=$SOCKET \
    CCORN_DEBUG_TMUX_SESSION=$SESSION \
    CCORN_DEBUG_SUPPORT_DIR="$SUPPORT" \
    CCORN_DEBUG_CHANNEL_DIR="$CHANNEL" \
    "$APP_BIN" > "$E2E/app.log" 2>&1 &
    APP_PID=$!
    trap 'kill "$APP_PID" 2>/dev/null || true; TMUX kill-server 2>/dev/null || true' EXIT

    # The channel deletes any pre-existing cmd file when it starts, so a
    # command written too early is eaten; probe with retries.
    local up=false
    for _ in 1 2 3 4; do
        if cmd dump | grep -q '^\['; then up=true; break; fi
    done
    if $up; then
        pass "app launched; debug channel responding"
    else
        fail "debug channel never responded"
        exit 1
    fi
}

finish() {
    echo
    if ((FAILS > 0)); then
        echo "[$(basename "$0" .sh)] $FAILS assertion(s) FAILED; logs: $E2E/app.log, shots: $SHOTS"
        exit 1
    fi
    echo "[$(basename "$0" .sh)] all assertions passed; shots: $SHOTS"
}
