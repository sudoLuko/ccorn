#!/bin/bash
# Captures live Claude Code TUI frames for the preflight contract test
# (scripts/preflight/run.sh classifies and asserts them).
#
# Safety: everything runs on an ISOLATED tmux server (-L ccorn-preflight).
# The user's default tmux server — and CCorn's `ccorn` session on it — are
# never touched. kill-server below applies only to this socket.
#
# Side effects on the machine (intentional, documented):
#   - real claude sessions run in scratch dirs under /tmp/ccorn-preflight/run-*;
#     their transcripts land in ~/.claude/projects/ and the dirs are recorded
#     as trusted in ~/.claude.json (same footprint as the M1 fixture probe)
#   - one short prompt is sent to capture Working frames (one real turn)
#   - the fresh-config scenario writes a throwaway CLAUDE_CONFIG_DIR under the
#     run dir; it never touches ~/.claude
set -euo pipefail

SOCKET=ccorn-preflight
TMUX() { command tmux -L "$SOCKET" "$@"; }

RUN_DIR=${PREFLIGHT_RUN_DIR:-/tmp/ccorn-preflight}
OUT="$RUN_DIR/frames"
# Unique scratch project per run so the first-run trust prompt is reproducible
# (trust is recorded per-path in ~/.claude.json and never re-fires).
STAMP=$(date +%Y%m%d-%H%M%S)
PROJ="$RUN_DIR/run-$STAMP/project"
PROJ2="$RUN_DIR/run-$STAMP/badkey"
FRESH_CONFIG="$RUN_DIR/run-$STAMP/fresh-config"
CLAUDE_BIN=${CLAUDE_BIN:-$(command -v claude || echo claude)}

mkdir -p "$OUT/burst" "$PROJ" "$PROJ2" "$FRESH_CONFIG"
rm -f "$OUT"/*.txt "$OUT"/burst/*.txt

log() { echo "[capture] $*"; }

cap() { TMUX capture-pane -t "$WIN" -p; }

snap() { cap > "$OUT/$1.txt"; log "captured $1"; }

# Type a line into the TUI: literal text first, Enter as its own key
# (CLAUDE.md: never an embedded backslash-n).
type_line() {
    TMUX send-keys -t "$WIN" -l -- "$1"
    TMUX send-keys -t "$WIN" Enter
}

# Poll until the pane contains the fixed string (case-insensitive).
# Returns 1 on timeout — callers decide whether that's fatal.
wait_for() { # <string> <timeout-seconds>
    local needle=$1 deadline=$((SECONDS + ${2:-30}))
    while ((SECONDS < deadline)); do
        if cap | grep -qiF -- "$needle"; then return 0; fi
        sleep 0.5
    done
    return 1
}

wait_for_any() { # <timeout-seconds> <string>...
    local deadline=$((SECONDS + $1)); shift
    local pane needle
    while ((SECONDS < deadline)); do
        pane=$(cap)
        for needle in "$@"; do
            if grep -qiF -- "$needle" <<<"$pane"; then return 0; fi
        done
        sleep 0.5
    done
    return 1
}

wait_gone() { # <string> <timeout-seconds>
    local needle=$1 deadline=$((SECONDS + ${2:-60}))
    while ((SECONDS < deadline)); do
        if ! cap | grep -qiF -- "$needle"; then return 0; fi
        sleep 0.5
    done
    return 1
}

# Wait until the pane stops changing: N consecutive identical captures,
# 0.7s apart. A working session keeps re-rendering (spinner/elapsed-seconds),
# so stability is a good idle proxy on top of the marker checks.
wait_stable() { # <consecutive> <timeout-seconds>
    local need=${1:-3} deadline=$((SECONDS + ${2:-30}))
    local prev="" cur same=0
    while ((SECONDS < deadline)); do
        cur=$(cap)
        if [[ "$cur" == "$prev" && -n "$cur" ]]; then
            ((same += 1))
            ((same >= need)) && return 0
        else
            same=0
        fi
        prev="$cur"
        sleep 0.7
    done
    return 1
}

# --- isolated server up -------------------------------------------------------
TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s preflight -x 220 -y 50
log "isolated tmux server up (socket: $SOCKET)"

# --- scenario 1: fresh start -> trust prompt -> idle --------------------------
WIN=$(TMUX new-window -t preflight -n probe -c "$PROJ" -P -F '#{window_id}')
type_line "$CLAUDE_BIN --rc \"CCorn Preflight Probe\""

# Trust wording changed across CLI versions: 2.1.170 asked "Do you trust the
# files in this folder?" (RUNTIME_FINDINGS G1); 2.1.172 renders "Quick safety
# check: … ❯ 1. Yes, I trust this folder". Match either.
if wait_for_any 25 "Do you trust" "trust this folder"; then
    snap trust-prompt
    TMUX send-keys -t "$WIN" Enter   # accept the default (Yes, I trust)
else
    log "WARN: trust prompt never appeared (dir already trusted?)"
fi

# Idle markers: the --rc footer (C2) or the shortcuts hint.
wait_for_any 40 "Remote Control active" "? for shortcuts" \
    || log "WARN: no idle marker after start"
wait_stable 3 30 || true
snap idle-fresh

# --- scenario 2: one real turn -> burst-capture Working -----------------------
type_line "Reply with exactly: ok"
for i in $(seq -w 1 40); do
    cap > "$OUT/burst/burst-$i.txt"
    sleep 0.3
done
wait_gone "esc to interrupt" 90 || log "WARN: live-activity marker still present"
wait_stable 3 30 || true
snap idle-finished

# --- scenario 3: /login screen (account stays signed in; Esc backs out) -------
type_line "/login"
wait_for "login" 15 || log "WARN: nothing login-like after /login"
wait_stable 2 10 || true
snap login-screen
TMUX send-keys -t "$WIN" Escape
sleep 1
TMUX send-keys -t "$WIN" Escape   # belt and braces: some pickers need two
wait_stable 2 15 || true

# --- scenario 4: clean exit (T2: pane keeps stale markers + resume hint) ------
type_line "/exit"
wait_for "claude --resume" 20 || log "WARN: no resume hint after /exit"
snap exited
TMUX kill-window -t "$WIN"

# Record the probe session's transcript path: run.sh asserts remote control
# engaged via footer OR bridge-session record (the engine ORs the same two
# signals). The project dir encodes per RUNTIME_FINDINGS C5.
ENCODED=$(sed 's/[^A-Za-z0-9]/-/g' <<<"/private${PROJ}")
ls -t ~/.claude/projects/"$ENCODED"/*.jsonl 2>/dev/null | head -1 \
    > "$OUT/probe-transcript.path" || true

# --- scenario 5: invalid ANTHROPIC_API_KEY ------------------------------------
# Verified on 2.1.172: with OAuth signed in, a custom env key does NOT error
# at launch — after the trust prompt the CLI asks "Detected a custom API key
# in your environment … Do you want to use this API key?" with No as the
# default. Selecting 1 (Yes) deliberately is what exposes the invalid-key
# path; the hypothesis under test (task: validate auth phrases) is that it
# surfaces an auth-phrase line such as "Invalid API key · Please run /login".
# Unique key per run: the CLI remembers approved/rejected key hashes, so a
# reused key skips the picker on every run after the first.
WIN=$(TMUX new-window -t preflight -n badkey -c "$PROJ2" \
      -e ANTHROPIC_API_KEY="sk-ant-api03-PREFLIGHT-INVALID-$STAMP" \
      -P -F '#{window_id}')
type_line "$CLAUDE_BIN --rc \"CCorn Preflight BadKey\""
if wait_for_any 25 "Do you trust" "trust this folder"; then
    TMUX send-keys -t "$WIN" Enter
fi
if wait_for "use this API key" 20; then
    wait_stable 2 10 || true
    snap api-key-picker
    TMUX send-keys -t "$WIN" -l -- "1"   # select Yes (No is the default)
    TMUX send-keys -t "$WIN" Enter
else
    log "WARN: API-key picker never appeared"
fi
wait_stable 3 40 || true
snap invalid-api-key-1
# Verified on 2.1.172: with the invalid key selected the session still starts
# normally (only a "auth may not work as expected" warning line) — the failure
# is deferred to the first API call. Send one message to capture the actual
# error render; this is the frame the authPhrases hypothesis lives or dies on.
type_line "Reply with exactly: ok"
wait_gone "esc to interrupt" 60 || true
wait_stable 3 30 || true
snap invalid-api-key-error
TMUX kill-window -t "$WIN"

# --- scenario 6: fresh CLAUDE_CONFIG_DIR (real signed-out first run) ----------
# A clean config dir should land on first-run setup and/or the real login
# screen without de-authing the machine (~/.claude is untouched). The CLI may
# show a theme/onboarding step first; Enter advances it once.
WIN=$(TMUX new-window -t preflight -n freshcfg -c "$PROJ" \
      -e CLAUDE_CONFIG_DIR="$FRESH_CONFIG" \
      -P -F '#{window_id}')
type_line "$CLAUDE_BIN"
wait_stable 3 40 || true
snap fresh-config-1
TMUX send-keys -t "$WIN" Enter
wait_stable 3 30 || true
snap fresh-config-2
TMUX kill-window -t "$WIN"

# --- teardown (our socket only) ------------------------------------------------
TMUX kill-server 2>/dev/null || true
log "done; frames in $OUT"
