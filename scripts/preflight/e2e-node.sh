#!/bin/bash
# Node-wrapped claude verification: RUNTIME_FINDINGS' standing caveat is that
# every process-identity fact was verified only against the NATIVE install
# (version-named Mach-O at ~/.local/share/claude/versions/<v>). This test
# installs @anthropic-ai/claude-code via npm into a throwaway prefix and runs
# the full session lifecycle against the node shim: spawn -> Running (proves
# ProcessControl.findClaude matches the node process shape within the spawn
# grace), SIGKILL -> Dead (PID tracking), restart -> Running.
#
# The hermetic app instance spawns windows whose shell is controlled via a
# throwaway ZDOTDIR (injected through tmux session env): PATH contains the
# npm shim and node, NOT ~/.local/bin — so `claude` can only resolve to the
# node-wrapped install. The user's shell config and native install are never
# touched.
set -euo pipefail
cd "$(dirname "$0")/../.."

SOCKET=ccorn-node
SESSION=ccornNode
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-node/run-$STAMP
PREFIX=/tmp/ccorn-node/npm-prefix     # cached across runs; ~1min install once
ZDOT="$E2E/zdot"
PROJ="$E2E/proj"

source scripts/preflight/e2e-lib.sh
e2e_setup
mkdir -p "$ZDOT" "$PROJ"

# --- install the npm package (cached) -------------------------------------------
# Non-global --prefix install: the shim lands in node_modules/.bin.
NPM_BIN="$PREFIX/node_modules/.bin"
if [[ ! -x "$NPM_BIN/claude" ]]; then
    log "installing @anthropic-ai/claude-code into $PREFIX"
    npm install --prefix "$PREFIX" --no-fund --no-audit @anthropic-ai/claude-code \
        > "$E2E/npm-install.log" 2>&1
fi
[[ -x "$NPM_BIN/claude" ]] || { echo "FATAL: npm install produced no .bin/claude"; exit 1; }
# As of 2.1.172 the npm package ships a NATIVE binary (RUNTIME_FINDINGS P6);
# older releases shipped a node cli.js shim. Record what this run exercised.
log "npm bin type: $(file -b "$(readlink -f "$NPM_BIN/claude")" | head -c 80)"

# --- controlled shell for spawned windows ----------------------------------------
# ZDOTDIR redirects ALL zsh dotfiles, so the user's profile (which prepends
# ~/.local/bin, the native claude) never runs in these windows. PATH gets
# exactly: npm shim, node, system dirs.
NODE_BIN=$(dirname "$(command -v node)")
cat > "$ZDOT/.zshenv" <<EOF
export PATH="$NPM_BIN:$NODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
EOF

TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
TMUX set-environment -t "$SESSION" ZDOTDIR "$ZDOT"

launch_app
cmd onboard "$PROJ" > /dev/null

# --- spawn against the node shim --------------------------------------------------
log "starting a session that can only resolve the npm claude"
cmd new "$PROJ" > /dev/null
WIN=$(row_window "$PROJ")
if wait_pane "$WIN" "trust this folder" 30; then
    TMUX send-keys -t "$WIN" Enter
fi
assert_row_state "$PROJ" running 60 "node-wrapped session reaches Running"

# Past the 10s spawn grace, Running can only mean findClaude positively
# matched the node process shape (otherwise the row would have gone Dead).
sleep 11
assert_row_state "$PROJ" running 10 "still Running past the spawn grace (matcher held)"

# Record the actual process shape we matched — the evidence RUNTIME_FINDINGS
# needs for the node-wrapped caveat.
CLAUDE_PID=$(cmd pids | tr ' ' '\n' | awk -F= -v w="$WIN" '$1 == w {print $2}')
if [[ -n "$CLAUDE_PID" && "$CLAUDE_PID" != "-" ]]; then
    SHAPE=$(ps -p "$CLAUDE_PID" -o comm= -o args= | head -1)
    pass "matched pid $CLAUDE_PID: $SHAPE"
    NPM_VERSION=$(pane_text "$WIN" | grep -oE 'Claude Code v[0-9.]+' | head -1 || true)
    log "npm-shipped version: ${NPM_VERSION:-unknown}"
else
    fail "no claude pid tracked for the node-wrapped session"
fi

# --- kill / restart on the node shape ----------------------------------------------
log "SIGKILL the node claude; window survives"
kill -9 "$CLAUDE_PID" 2>/dev/null || true
assert_row_state "$PROJ" dead 20 "SIGKILLed node claude detected by PID"

log "restart (resume) on the node shim"
cmd restart "$PROJ" > /dev/null
assert_row_state "$PROJ" running 60 "restarted session recovers on node claude"

finish
