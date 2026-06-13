#!/bin/bash
# e2e-name-collision.sh — regression guard for the new-session failure that hits
# when a managed window is named the same as the tmux session (a project whose
# basename == the session name, e.g. CCorn run on its own "ccorn" repo).
#
# Two defenses, both pinned here:
#   1. Naming — uniqueWindowName never names a window identically to the session,
#      so the hazard is avoided at creation. Checked by opening a project whose
#      basename == the session and asserting its window was renamed (e.g.
#      "ccollide-2"), with the displayed session unaffected.
#   2. Targeting — windows are created with `tmux new-window -t <session>:`
#      (not bare `-t <session>`), so even a window named exactly like the session
#      cannot capture the target. Checked by FORCING that hazard (rename a window
#      to the session name) and asserting a further new session still starts;
#      bare targeting would fail "create window failed: index N in use".
#
# Hermetic, real signed-in account — same isolation as the other e2e scripts.
set -euo pipefail
cd "$(dirname "$0")/../.."

SOCKET=ccorn-collide
SESSION=ccollide                 # a project below is named this on purpose
STAMP=$(date +%Y%m%d-%H%M%S)
E2E=/tmp/ccorn-collide/run-$STAMP
PROJ_NAMED="$E2E/$SESSION"        # basename == session name
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

# windowId out of a `new started(windowId: "@N", pid: …)` reply.
win_of() { sed -n 's/.*windowId: "\(@[0-9][0-9]*\)".*/\1/p' <<< "$1"; }

e2e_setup
mkdir -p "$PROJ_NAMED" "$PROJ_OTHER"
TMUX kill-server 2>/dev/null || true
TMUX new-session -d -s "$SESSION" -x 220 -y 50
launch_app
cmd onboard "$PROJ_NAMED" > /dev/null

# --- Defense 1 (naming): a same-named project must not yield a same-named window
r1=$(cmd new "$PROJ_NAMED") || true
if [[ $r1 == "new started("* ]]; then pass "same-named project session started"; else fail "same-named project did not start: $r1"; fi
w1=$(win_of "$r1")
n1=$(TMUX display-message -p -t "$w1" '#{window_name}' 2>/dev/null || echo '?')
if [[ -n "$w1" && "$n1" != "$SESSION" ]]; then
    pass "window born as '$n1', not the session name '$SESSION' (naming guard)"
else
    fail "window named identically to the session ('$n1') — uniqueWindowName guard missing"
fi

# --- Defense 2 (targeting): force the hazard, then a new session must still start
TMUX rename-window -t "$w1" "$SESSION"
log "injected hazard: window $w1 renamed to '$SESSION'"
r2=$(cmd new "$PROJ_OTHER") || true
if [[ $r2 == "new started("* ]]; then
    pass "new session starts despite a window named exactly '$SESSION' (colon target)"
else
    fail "new session BLOCKED by the name collision: $r2"
fi

finish
