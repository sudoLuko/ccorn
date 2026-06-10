# Preflight contract test

Answers one question before a release: **does the installed Claude Code CLI
still render the pane text CCorn's state detection is built on?** Every
detection contract (docs/RUNTIME_FINDINGS.md C/T/G series) is pinned to
specific CLI renders; this harness re-verifies them against whatever `claude`
is installed right now.

## Run it

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
   not pinned; a miss is information for docs/RUNTIME_FINDINGS.md, not a
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
shift in docs/RUNTIME_FINDINGS.md), and promote the frame into
`Tests/CCornEngineTests/Fixtures/panes/` so the unit suite pins it too.
