#!/bin/bash
# e2e-name-collision.sh — regression guard for the new-session failure that
# hits when a managed window's name equals the tmux session name.
#
# CCorn names each window after its project basename and creates windows with
# `tmux new-window -t <session>`. A bare `-t <session>` is a target-WINDOW: once
# a managed window is named the same as the session (a project whose basename ==
# the session name — e.g. CCorn run on its own "ccorn" repo), tmux resolves the
# bare name to THAT window and tries to reuse its index, so EVERY subsequent new
# session fails with "create window failed: index N in use". The fix targets the
# session unambiguously (`-t <session>:`). This test reproduces the collision
# and asserts a second session still starts.
#
# Hermetic, real signed-in account — same isolation as the other e2e scripts.
set -euo pipefail
cd "$(dirname "$0")/../.."

SOCKET=ccorn-collide
SESSION=ccollide                 # the collision: a project below is named this
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-collide/run-$STAMP
PROJ_COLLIDE="$E2E/$SESSION"      # basename == session name -> window named "ccollide"
PROJ_OTHER="$E2E/other"
APP_BIN=build/Build/Products/Debug/CCorn.app/Contents/MacOS/CCorn

source scripts/preflight/e2e-lib.sh

mkdir -p "$E2E"
if [[ ! -x "$APP_BIN" ]]; then
    log "no debug build at $APP_BIN — building Debug…"
    [[ -d CCorn.xcodeproj ]] || xcodegen generate
    if ! xcodebuild -project CCorn.xcodeproj -scheme CCorn -configuration Debug \
        -derivedDataPath build build > "$E2E/build.log" 2>&1; then
        tail -20 "$E2E/build.log"; echo "FATAL: build failed"; exit 1
    fi
fi

e2e_setup
mkdir -p "$PROJ_COLLIDE" "$PROJ_OTHER"
TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
launch_app
cmd onboard "$PROJ_COLLIDE" > /dev/null

# 1) Start the colliding session: its window gets named "ccollide" (== session).
r1=$(cmd new "$PROJ_COLLIDE") || true
if [[ $r1 == "new started("* ]]; then
    pass "colliding session started (window now named '$SESSION')"
else
    fail "colliding session did not start: $r1"
fi
log "windows after collide: $(TMUX list-windows -t "$SESSION" -F '#{window_index}:#{window_name}' | paste -sd' ' -)"

# 2) The regression: a SECOND new session. Pre-fix this fails with
#    "could not create tmux window"; post-fix it must start.
r2=$(cmd new "$PROJ_OTHER") || true
if [[ $r2 == "new started("* ]]; then
    pass "second session started despite the name collision (fix works)"
else
    fail "second session BLOCKED by name collision: $r2"
fi

finish
