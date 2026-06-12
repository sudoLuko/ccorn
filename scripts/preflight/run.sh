#!/bin/bash
# Preflight contract test: does the installed Claude Code CLI still render the
# pane text CCorn's state detection is built on?
#
# Pipeline: build the classifier from the PRODUCTION StateDetector sources ->
# self-test it against the committed pane fixtures -> capture live frames from
# the installed CLI (capture-frames.sh, isolated tmux socket) -> classify ->
# assert -> write a markdown report.
#
# Usage:
#   scripts/preflight/run.sh                 full run (build + fixtures + live)
#   scripts/preflight/run.sh --fixtures-only skip live capture (no sessions run)
#   scripts/preflight/run.sh --classify-only re-assert existing frames
#
# Exit code: 0 all hard assertions pass; 1 otherwise. Soft assertions report
# FINDING, never fail the run — they are hypotheses about unverified CLI
# behavior, and a miss is information.
set -euo pipefail
cd "$(dirname "$0")/../.."

RUN_DIR=${PREFLIGHT_RUN_DIR:-/tmp/ccorn-preflight}
OUT="$RUN_DIR/frames"
BIN="$RUN_DIR/bin/pane-classify"
RESULTS="$RUN_DIR/results.tsv"
REPORT="$RUN_DIR/report.md"
mkdir -p "$RUN_DIR/bin"

MODE=${1:-full}

# --- build: compile the classifier from production sources --------------------
# The file list is the minimal dependency closure of StateDetector. No phrase
# or rule is duplicated anywhere in scripts/preflight.
build() {
    echo "[build] compiling pane-classify from production StateDetector"
    swiftc -O -swift-version 5 \
        scripts/preflight/pane-classify.swift \
        Sources/Engine/StateDetector.swift \
        Sources/Engine/SessionDiscovery.swift \
        Sources/Engine/ProcessControl.swift \
        Sources/Engine/TmuxController.swift \
        Sources/Engine/CommandRunner.swift \
        Sources/Engine/TranscriptMetaCache.swift \
        Sources/Models/SessionState.swift \
        Sources/Models/Discovery.swift \
        -o "$BIN"
}

# --- result helpers ------------------------------------------------------------
# results.tsv columns (from pane-classify):
#   1 state  2 live_activity  3 waiting  4 rc_marker  5 claude_evidence
#   6 auth_notice  7 rc_plan_notice  8 file
col() { # <frame-path> <column-number>
    awk -F'\t' -v f="$1" -v c="$2" '$8 == f { print $c }' "$RESULTS"
}

HARD_FAILS=0
LINES=()

note() { LINES+=("$1"); echo "$1"; }

pass() { note "PASS  $1"; }
fail() { note "FAIL  $1"; HARD_FAILS=$((HARD_FAILS + 1)); }
finding() { note "FINDING  $1"; }

# Hard: this contract was verified on 2.1.169/170; a miss is a regression.
assert_state() { # <frame> <expected-state>
    local frame="$OUT/$1.txt" expected=$2 actual
    [[ -f "$frame" ]] || { fail "$1: frame was not captured"; return; }
    actual=$(col "$frame" 1)
    if [[ "$actual" == "$expected" ]]; then
        pass "$1 classifies as $expected"
    else
        fail "$1: expected $expected, got ${actual:-<missing>}"
    fi
}

# Hard variant of the any-of check: at least one of the frames must classify
# as expected (used where the scenario is verified but lands on one of two
# frames depending on flow pacing).
assert_state_any() { # <expected-state> <frame>...
    local expected=$1; shift
    local name frame states=""
    for name in "$@"; do
        frame="$OUT/$name.txt"
        [[ -f "$frame" ]] || continue
        states+="$name=$(col "$frame" 1) "
        if [[ "$(col "$frame" 1)" == "$expected" ]]; then
            pass "$name classifies as $expected"
            return
        fi
    done
    fail "none of [$*] classified as $expected (got: ${states:-nothing captured})"
}

# Soft: hypothesis about never-verified CLI output; reports, never fails.
expect_state_any() { # <expected-state> <frame>...
    local expected=$1; shift
    local name frame states=""
    for name in "$@"; do
        frame="$OUT/$name.txt"
        [[ -f "$frame" ]] || continue
        states+="$name=$(col "$frame" 1) "
        if [[ "$(col "$frame" 1)" == "$expected" ]]; then
            pass "$name classifies as $expected (hypothesis confirmed)"
            return
        fi
    done
    finding "none of [$*] classified as $expected (got: ${states:-nothing captured})"
}

assert_flag() { # <frame> <column> <expected> <label>
    local frame="$OUT/$1.txt" actual
    [[ -f "$frame" ]] || { fail "$1: frame was not captured"; return; }
    actual=$(col "$frame" "$2")
    if [[ "$actual" == "$3" ]]; then
        pass "$1: $4"
    else
        fail "$1: $4 — expected $3, got ${actual:-<missing>}"
    fi
}

assert_grep() { # <frame> <fixed-string> <label>
    local frame="$OUT/$1.txt"
    [[ -f "$frame" ]] || { fail "$1: frame was not captured"; return; }
    if grep -qiF -- "$2" "$frame"; then
        pass "$1: $3"
    else
        fail "$1: $3 — '$2' not found in pane"
    fi
}

# --- fixtures self-test --------------------------------------------------------
# The committed fixtures are known-good captures; their filenames encode the
# expected classification. This catches a broken classifier build before any
# live session is spent, and re-verifies the detector against history.
fixtures_selftest() {
    echo "[fixtures] classifying committed pane fixtures"
    local fx_results="$RUN_DIR/fixtures.tsv"
    "$BIN" Tests/CCornEngineTests/Fixtures/panes/*.txt > "$fx_results"
    local failures=0
    check_fx() { # <fixture-basename> <expected-state>
        local actual
        actual=$(awk -F'\t' -v f="$1" -v c=1 '$8 ~ f { print $c }' "$fx_results")
        if [[ "$actual" == "$2" ]]; then
            echo "  ok  $1 -> $2"
        else
            echo "  BAD $1 -> ${actual:-<missing>} (expected $2)"
            failures=$((failures + 1))
        fi
    }
    check_fx idle-finished.txt running
    check_fx idle-finished-2170.txt running
    check_fx running-idle.txt running
    check_fx waiting-permission.txt waiting
    check_fx working-midtask.txt working
    check_fx needs-auth-login.txt needsAuth
    check_fx needs-auth-fresh-login-2172.txt needsAuth
    check_fx needs-auth-invalid-key-2172.txt needsAuth
    check_fx waiting-trust-2172.txt waiting
    # dead-exited reads running from pane text alone — T2: Dead is decided by
    # PID liveness, never pane content. The pane-only result is pinned here so
    # a change in that behavior is noticed, not silently absorbed.
    check_fx dead-exited.txt running
    if ((failures > 0)); then
        echo "[fixtures] $failures fixture(s) misclassified — aborting before live capture"
        exit 1
    fi
}

# --- main ----------------------------------------------------------------------
build
fixtures_selftest
if [[ "$MODE" == "--fixtures-only" ]]; then
    echo "[done] fixtures self-test passed (no live capture requested)"
    exit 0
fi

if [[ "$MODE" != "--classify-only" ]]; then
    bash scripts/preflight/capture-frames.sh
fi

echo "[classify] classifying captured frames"
"$BIN" "$OUT"/*.txt "$OUT"/burst/*.txt > "$RESULTS"

echo
echo "=== contract assertions ==="

# Verified contracts (runtime findings C2/T1/T2/T5, fixture probe) — hard.
assert_state idle-fresh running
assert_state idle-finished running
assert_state login-screen needsAuth
assert_grep  exited "claude --resume" "resume hint after clean exit (T2)"
assert_flag  exited 5 true "exited pane still shows claude evidence (reconciliation)"

# Remote control engaged: the engine ORs two signals — the footer literal
# (C2; stopped rendering in 2.1.172) and a bridge-session transcript record
# (C1). Hard-require that at least one is live, via the production checks.
RC_FOOTER=$(col "$OUT/idle-finished.txt" 4)
TRANSCRIPT=$(cat "$OUT/probe-transcript.path" 2>/dev/null || true)
RC_BRIDGE=false
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
    RC_BRIDGE=$("$BIN" --bridge "$TRANSCRIPT")
fi
if [[ "$RC_FOOTER" == "true" || "$RC_BRIDGE" == "true" ]]; then
    pass "remote control engaged on --rc session (footer=$RC_FOOTER bridge-session=$RC_BRIDGE)"
    if [[ "$RC_FOOTER" != "true" ]]; then
        finding "C2 footer literal did not render; bridge-session is the only live RC signal on this CLI"
    fi
else
    fail "remote control: neither footer (C2) nor bridge-session record (C1) found"
fi

# Working: at least one burst frame must catch live activity (T1/T5).
WORKING_FRAMES=$(awk -F'\t' '$1 == "working" && $8 ~ /burst/' "$RESULTS" | wc -l | tr -d ' ')
if ((WORKING_FRAMES > 0)); then
    pass "burst: $WORKING_FRAMES frame(s) classified working during the live turn"
else
    fail "burst: no frame classified working during a real turn"
fi

# Trust prompt fires only on a never-trusted dir; when captured it must read
# Waiting (G1; wording changed by 2.1.172 — see capture-frames.sh). Hard if
# present, noted if the capture was skipped.
if [[ -f "$OUT/trust-prompt.txt" ]]; then
    assert_state trust-prompt waiting
else
    finding "trust-prompt not captured this run (scratch dir already trusted?)"
fi

# Custom-env-key picker (verified 2.1.172): blocked on the user -> Waiting.
if [[ -f "$OUT/api-key-picker.txt" ]]; then
    assert_state api-key-picker waiting
else
    finding "api-key-picker not captured this run"
fi

# Signed-out first run (fresh CLAUDE_CONFIG_DIR) must land on the login screen
# in one of the two captured frames — verified live on 2.1.172.
assert_state_any needsAuth fresh-config-1 fresh-config-2

# Hypothesis (never verified): an invalid key surfaces an auth-phrase error —
# at launch, or in the error rendered by the first real send. Soft — see task:
# validate auth phrases. A FINDING here means the authPhrases list needs work,
# not that the build broke.
expect_state_any needsAuth invalid-api-key-1 invalid-api-key-error

# --- report --------------------------------------------------------------------
{
    echo "# CCorn preflight contract report"
    echo
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- claude: $(command -v claude || echo '<not found>') ($(claude --version 2>/dev/null || echo 'version unknown'))"
    echo "- tmux: $(tmux -V)"
    echo "- hard failures: $HARD_FAILS"
    echo
    echo "## Assertions"
    echo
    printf '%s\n' "${LINES[@]/#/- }"
    echo
    echo "## Raw classifications"
    echo
    echo '```'
    column -t -s$'\t' "$RESULTS"
    echo '```'
} > "$REPORT"

echo
echo "[report] $REPORT"
if ((HARD_FAILS > 0)); then
    echo "[done] $HARD_FAILS hard assertion(s) FAILED"
    exit 1
fi
echo "[done] all hard assertions passed"
