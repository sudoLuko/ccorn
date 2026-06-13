# Preflight test suite

Pre-release verification that automated agents can run end to end. Findings
are recorded as P-series runtime findings. Run everything before a release:

```sh
scripts/preflight/run.sh                  # CLI pane-contract test (below)
scripts/preflight/e2e-auth.sh             # section-8 auth pipeline in the real app
scripts/preflight/e2e-chaos.sh            # tmux failure modes against the real app
scripts/preflight/e2e-node.sh             # npm-installed claude lifecycle
scripts/preflight/release-gatecheck.sh    # debug surface compiled out + notarized-artifact validation
```

The e2e scripts run a **hermetic debug app instance**: its own tmux server
(`CCORN_DEBUG_TMUX_SOCKET`), session name, support dir, and debug channel
(`CCORN_DEBUG_CHANNEL_DIR`) — they share nothing with the user's default
tmux server or a normally-running CCorn, which is the only reason the chaos
suite may run `kill-server`. They need a Debug build at
`build/Build/Products/Debug/CCorn.app`; gatecheck builds Release itself.

## Window-churn repro (e2e-churn.sh)

Not part of the release gate — a focused diagnostic for the window-creation
failure that only appears after many new/kill cycles in an *existing* ccorn
session ("could not create tmux window"; raw tmux: "index 0 in use"). It churns
one persistent session and asserts every `new` returns `started(...)`; the first
`failed(...)` stops the run, writes a minimal repro (the tmux window table) to
the run dir, and exits non-zero. Builds Debug itself if needed.

```sh
scripts/preflight/e2e-churn.sh            # 50 cycles (default)
scripts/preflight/e2e-churn.sh 200        # push further
CHURN_KEEP_GOING=1 scripts/preflight/e2e-churn.sh 200   # measure failure rate, don't stop
```

Exit 0 = all cycles created+killed cleanly (bug absent/fixed), so it also serves
as a regression guard. Per-op JSON lands in `results.jsonl` under the run dir.

## New-session name collision (e2e-name-collision.sh)

Regression guard for the bug where a managed window named the same as the tmux
session (a project whose basename == the session name, e.g. CCorn run on its own
`ccorn` repo) made `tmux new-window -t <session>` resolve to that window and fail
with "index N in use", blocking every new session. Reproduces the collision and
asserts a second session still starts. Exit 0 = fixed.

```sh
scripts/preflight/e2e-name-collision.sh
```

## Watch real Terminal spawns (spawn-in-terminal.sh)

Interactive (not a gate). Spawns real sessions into VISIBLE Terminal.app windows
via the actual product path (`startNewSession` → `openInTerminal` → osascript
`tmux attach`), so you can watch them come up and answer each "trust this folder"
prompt yourself. Hermetic: the attach lands on the isolated server, not your real
`ccorn` (the app's attach now honors `CCORN_DEBUG_TMUX_SOCKET/_SESSION`).

```sh
scripts/preflight/spawn-in-terminal.sh           # 3 sessions, hold until Ctrl-C
HOLD_SECONDS=8 scripts/preflight/spawn-in-terminal.sh 2   # 2 sessions, auto-teardown
```

Ctrl-C (or HOLD_SECONDS elapsing) quits the hermetic app and kills its server;
the opened Terminal windows then detach (close them when done).

## The contract test (run.sh)

Answers one question: **does the installed Claude Code CLI still render the
pane text CCorn's state detection is built on?** Every detection contract
(runtime findings C/T/G/P series) is pinned to specific CLI renders;
this harness re-verifies them against whatever `claude` is installed right now.

```sh
scripts/preflight/run.sh                  # full: build + fixtures + live capture + assert
scripts/preflight/run.sh --fixtures-only  # no live sessions; classifier vs committed fixtures
scripts/preflight/run.sh --classify-only  # re-assert previously captured frames
```

Exit 0 = all hard assertions pass. Output lands in `/tmp/ccorn-preflight/`
(`report.md`, `results.tsv`, `frames/`). Override with `PREFLIGHT_RUN_DIR`.

## How it works

1. `pane-classify.swift` is compiled by `swiftc` together with the
   **production** `Sources/Engine/StateDetector.swift` and its dependency
   closure. No detection phrase or rule exists anywhere in `scripts/preflight`
   — if the classifier and the app ever disagree, the harness is broken by
   construction, not the app.
2. The classifier first re-classifies the committed pane fixtures
   (`Tests/CCornEngineTests/Fixtures/panes/`); any mismatch aborts before a
   live session is spent.
3. `capture-frames.sh` drives the installed CLI through known states on an
   **isolated tmux server** (`tmux -L ccorn-preflight` — the user's default
   server and CCorn's `ccorn` session are never touched): trust prompt →
   idle → one real turn (burst-captured for Working frames) → `/login` screen
   (Esc backs out; the account is never signed out) → clean exit → an
   invalid-`ANTHROPIC_API_KEY` session driven to its real error render → a
   fresh `CLAUDE_CONFIG_DIR` first run (the genuine signed-out login screen).
4. `run.sh` classifies every frame and asserts. **Hard** assertions are
   contracts verified on a real CLI — a miss is a regression and fails the
   run. **Soft** ones (`FINDING`) are hypotheses about CLI behavior we have
   not pinned; a miss is information, not a
   failure.

## Side effects (intentional, small)

- Real claude sessions run in scratch dirs under `/tmp/ccorn-preflight/run-*`:
  their transcripts land in `~/.claude/projects/`, the dirs are recorded as
  trusted in `~/.claude.json`, and one approved API-key hash is added per run
  (the key is fake; the approval is keyed to its hash). Two short prompts are
  sent per run (one on the account, one that fails on the fake key).
- The fresh-config scenario uses a throwaway `CLAUDE_CONFIG_DIR`; the real
  `~/.claude` is never modified and the account is never signed out.

## When it fails

A hard failure means the CLI changed a render CCorn depends on. Capture the
frame from `/tmp/ccorn-preflight/frames/`, fix the detector (or record the
shift as a new runtime finding), and promote the frame into
`Tests/CCornEngineTests/Fixtures/panes/` so the unit suite pins it too.
