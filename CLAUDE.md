# CCorn: Claude Code Session Manager

## Read first
- `docs/CCORN_SPEC.md`: the full build spec. Read the sections relevant to your task before writing code.
- `docs/RUNTIME_FINDINGS.md`: runtime facts verified on this machine (Claude Code 2.1.169). Where it differs from the spec or from any assumption, it wins.
- `docs/design-references/`: reference screenshots for every screen.

## Current state
All three milestones are built and verified: engine (M1), menu bar + main window (M2), and the full interaction surface (M3 — new session, import, kill/restart/archive, rename, onboarding, settings, archived view, notifications). After adding Swift files, run `xcodegen generate` before `xcodebuild`. Debug builds expose a file-based command channel for scripted verification (`CCORN_DEBUG_UI=cmd`, see Sources/UI/DebugCommandChannel.swift); it is compiled out of release builds.

## What this is
Native macOS menu-bar app. Swift/SwiftUI. Manages Claude Code sessions in tmux. Process manager only, no chat interface.

## Stack
- Swift + SwiftUI, macOS 13+ target
- tmux as the process backbone (single session named `ccorn`, one window per Claude Code session)
- NSStatusItem + NSPopover for the menu bar
- FSEvents for directory watching
- NSOpenPanel for folder picking
- XcodeGen project (`project.yml`); the `.xcodeproj` is generated, not committed

## Architecture rules
- Spawned commands need a resolved PATH (GUI apps do not inherit the shell PATH): run via a login shell or absolute paths. App Sandbox must be OFF or exec/FSEvents/AppleEvents are blocked (see docs/CCORN_SPEC.md, Process Execution Environment).
- Every Claude Code session runs in a tmux window inside the `ccorn` session. For programmatic commands (send-keys, capture-pane, kill-window, rename-window) target the captured window ID (`@N`) or an `@ccorn_id` tag, resolving any name to its ID first.
- Primary session discovery is `~/.claude/projects/` (resolve real paths via the JSONL `cwd`). Do NOT rely on a project-local `.claude/` folder existing.
- Read the `cwd` from the first transcript line that has one; line 1 is a metadata record with no `cwd`. Transcripts are created lazily, only after a session's first turn. Ignore the sibling `memory/` directory.
- Never hardcode session IDs: the JSONL filename is the session UUID.
- Match the `claude` process by argv (argv[0] basename == `claude`, or args contain `--rc`) or exec-path basename, never by `proc_name`/`p_comm` (the native binary is version-named, e.g. `2.1.169`). Match only among children of the shell CCorn spawned; never a global `pgrep claude`.
- Always enable remote control via the `--rc` flag on sessions CCorn starts or restarts, and pass a title: `claude --rc "<title>"`.
- Use `tmux send-keys` for all programmatic interaction; send the key as a separate `Enter` argument, never an embedded backslash-n.
- Use FSEvents, not polling, for directory watching (state detection still polls pane output every 3s).
- On launch, reconcile with existing tmux windows: re-derive PIDs and state, and do not trust prior-run runtime values.

## Design rules
- Zinc neutral palette; exact hex in docs/CCORN_SPEC.md section 3.
- Use SwiftUI semantic colors (Color.primary, Color.secondary, Color(.separatorColor), Color(.windowBackgroundColor)) for ALL main-window UI; never hardcode hex in the main window.
- Hardcoded hex only in the menu-bar popover (it is always dark; semantic colors would be wrong there).
- SF Pro Text only; SF Mono for directory paths via `.monospaced()`.
- Two font weights only: regular (400) and medium (500).
- 0.5px borders only, never 1px. No shadows, gradients, or decorative elements.
- Status dots are the only color in the app.
- The menu-bar popover is fixed dark (#09090B) regardless of system appearance; the main window follows system appearance via semantic colors.

## Activation policy
- Default: `.accessory` (no Dock icon, no Cmd+Tab).
- When a regular window opens (main window, Settings, or onboarding): switch to `.regular`.
- Switch back to `.accessory` only when no regular window remains open.
- Do NOT use LSUIElement = YES; it prevents the dynamic switch.

## SwiftUI notes
- `.listStyle(.sidebar)` for the sidebar; do not hardcode row heights.
- Settings scene for preferences; do not build a custom window, and do not put a NavigationStack inside the Settings scene.
- NSMenu for context menus, not custom SwiftUI menus.
- Native NSOpenPanel for folder picking.

## tmux commands
- Check session: `tmux has-session -t ccorn` (only create if it fails)
- New session: `tmux new-session -d -s ccorn`
- New window (capture the id): `tmux new-window -t ccorn -n <sanitized-name> -c <dir> -P -F "#{window_id}"`
- New Claude session: `tmux send-keys -t <window-id> 'claude --rc "<title>"' Enter`
- Resume: `tmux send-keys -t <window-id> 'claude --resume <uuid> --rc' Enter`
- Capture (visible frame; alt-screen TUI has no scrollback, so no `-S`): `tmux capture-pane -t <window-id> -p`
- Kill window: `tmux kill-window -t <window-id>`
- Terminate routine: kill-window, then if the PID is still alive send SIGTERM, wait 5s, then SIGKILL.

## Remote control
- No session URL exists (verified 2.1.169). Detect remote-control-active via the `Remote Control active` footer string (capture-pane) or a `bridge-session` record in the session JSONL.
- "Open in Browser" opens https://claude.ai/code (the session list); the user finds the session by its title.
- Do NOT write a global remote-control key to `~/.claude.json` (none is documented; the control is the `/config` toggle). Rely on per-session `--rc`.
- Process kill: SIGTERM first, wait 5s, SIGKILL if still running.

## Build milestones
Build sequentially. Each milestone must build, launch, and verify before the next, and gets its own commit. The exact per-milestone prompts are in MILESTONE_PROMPTS.md.
1. Engine (no UI): command runner, tmux orchestration, discovery, encoded-path handling, process identification + PID tracking, state detection, session resume, launch reconciliation, persisted session record.
2. Menu bar + main window: popover, list rows, status dots, aggregate dot, empty state, context menu, Open in Browser/Terminal. Wired to the engine, read-only on real data.
3. Flows + secondary screens: new session, import/resume, kill/archive/restart, rename, onboarding, settings, archived view, notifications, then a polish pass.
