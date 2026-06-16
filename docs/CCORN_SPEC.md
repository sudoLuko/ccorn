# CCorn: Full Build Specification

> Version 1.3, Reconciled with the shipped design (one mark per row, attention words, adaptive attention amber, triage popover, hidden title-bar text); 1.2 reconciled runtime findings (Claude Code 2.1.169)  
> Status: Matches the built app  
> Repo: `ccorn`

-----

## 1. Overview & Philosophy

CCorn is a native macOS menu bar app that manages Claude Code sessions running in tmux on your local machine. It is a **process manager**, not a chat interface.

The core philosophy is **set and forget**. Sessions run silently in the background. You never need to look at a terminal. You interact with sessions exclusively through claude.ai/code or the Claude mobile app via remote control. CCorn keeps everything alive, organized, and accessible.

**The problem it solves:** Developers running 10+ concurrent Claude Code sessions end up with 10+ open terminal windows they never look at. CCorn replaces all of those with a single menu bar icon. Sessions live in tmux, remote control is always enabled, and you interact from anywhere.

**What CCorn is not:**

- Not a chat interface
- Not a replacement for claude.ai/code
- Not a cloud tool; everything stays local
- Not a complex project manager

**Tagline:** All your kernels, one cob.

-----

## 2. Tech Stack & Architecture

### Core

- **Language:** Swift
- **UI Framework:** SwiftUI
- **Target:** macOS only, minimum macOS 13 (Ventura)
- **Process backbone:** tmux, every Claude Code session is a tmux window inside a single tmux session named `ccorn`
- **Menu bar:** `NSStatusItem` + `NSPopover` for the popover
- **Settings window:** SwiftUI `Settings` scene
- **File watching:** FSEvents, watches user-specified directories in real time

### Process Execution Environment

Everything in CCorn depends on spawning `tmux`, `claude`, `ps`, `pgrep`, `lsof`, `osascript`, and `brew`. Two macOS facts must be handled up front or the app does nothing on first launch:

- **PATH.** A GUI app launched from Finder/Xcode does not inherit the user's shell PATH; it gets roughly `/usr/bin:/bin:/usr/sbin:/sbin`. `tmux`, `claude`, and `brew` live in `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel), which are not on that PATH, so `which tmux`/`which claude`/`which brew` and every spawned command fail with "command not found" even when installed. Resolve this once: run external commands through a login shell (`/bin/zsh -lc "<command>"`) so the user's PATH is sourced, or resolve absolute binary paths, or build a PATH including both Homebrew prefixes. Pick one and use it for every `Process` invocation; all `which ...` checks below assume this resolved PATH.
- **App Sandbox must be OFF.** With the sandbox on, `Process`/`exec` is blocked entirely, FSEvents on arbitrary user directories is restricted, and Apple Events to Terminal are blocked. The Xcode target must not add the App Sandbox capability. (Code signing/notarization stay out of scope per Section 11, but set a stable bundle identifier and use ad-hoc signing so notifications, login-item registration, and Terminal automation behave; an app with no stable identity triggers repeated TCC prompts or silent failures.)

### Session Discovery

- User specifies watch directories in settings (e.g. `~/dev/`). These scope which projects CCorn shows; they are a filter, not the discovery source.
- **Primary discovery source is `~/.claude/projects/`.** Enumerate every subdirectory there; each corresponds to a project with Claude Code history. For each, read the `cwd` field from the first transcript line that carries one (the very first line is a `{leafUuid, sessionId, type}` metadata record with no `cwd`; `system` and `user` records carry it). Use that for the project's real absolute path (see Encoded Path Format; do not decode the folder name). Ignore non-transcript entries like a sibling `memory/` directory. Transcripts are created lazily (only after a session's first turn), so a brand-new external session may not surface here until then; sessions CCorn starts are tracked via their tmux window and PID regardless.
- Keep only projects whose `cwd` is inside a watch directory. Do not rely on a project-local `.claude/` folder existing: that folder is optional and absent for any project with no project-level settings or commands, so crawling watch directories for `.claude/` folders would miss most real sessions.
- Cross-reference with running processes for live state (see PID Tracking and Process Identification). A project with a `~/.claude/projects/` entry but no running process is Stopped or Dead; a running process whose cwd is a watch directory is surfaced even if its entry is new.
- Deduplication by absolute path: the same project under two watch directories shows once.
- FSEvents watches both the watch directories and `~/.claude/projects/`, so new sessions surface without a manual rescan. The reliable new-session signal is a new subdirectory or `*.jsonl` under `~/.claude/projects/`, not a `.claude/` folder appearing in a project.

### Encoded Path Format

Claude Code encodes a project's absolute path into the directory name under `~/.claude/projects/` by replacing every non-alphanumeric character with a single `-` (this includes `/`, `.`, and `_`) and prepending a leading `-`. Example:

- `/Users/you/dev/mella` becomes `-Users-you-dev-mella`
- `/Users/you/dev/my.app` becomes `-Users-you-dev-my-app`

This encoding is lossy and cannot be reversed by string substitution (verified on 2.1.169: `/`, `.`, `_`, and existing `-` all collapse to a single `-`, so `ccorn.probe_2`, `ccorn-probe-2`, and `ccorn_probe_2` share one directory name). Do not decode the directory name back into a path. Treat the encoded name as an opaque lookup key and resolve the real project path by reading the `cwd` field from the first transcript line that has one (not line 1, which is a metadata record without `cwd`). Two matching caveats: the encoding is built from the **symlink-resolved** path (`/tmp/x` encodes via `/private/tmp/x`) and the JSONL `cwd` stores that resolved true path, so canonicalize watch-directory paths (resolve symlinks) before comparing them to `cwd`. Match by comparing resolved absolute paths, never by decoding the folder name.

### Remote Control

- Global "enable for all sessions" is **not** something CCorn should write directly. The only documented controls are the `/config` toggle "Enable Remote Control for all sessions" and Desktop Settings, Claude Code, "Enable remote control by default"; there is no documented `~/.claude.json` key (`remoteControlAtStartup` was an unverified guess) and the toggle has a known reset bug. CCorn cannot reliably script `/config`, so do not attempt the global enable. It is unnecessary regardless: CCorn passes `--rc` on every session it starts, which is fully under its control, so the global setting only affects sessions a user starts outside CCorn.
- For all sessions CCorn starts or resumes: use `claude --rc` or `claude --resume <uuid> --rc`. Remote control is enabled from session start via the flag; no separate step. Use the interactive `--rc` flag with one window per session, not `claude remote-control` (server mode), which multiplexes many sessions in a single process and conflicts with the one-window-per-session model.
- **A per-session URL exists, and CCorn can build it** (Remote Control ≥ 2.1.162; the older "no URL on 2.1.169" finding is superseded). Claude Code prints `https://claude.ai/code/session_<id>` for an RC-active session, and that `session_…` segment equals the **`bridgeSessionId` recorded in the process session registry** (`~/.claude/sessions/<pid>.json`); verified against real printed URLs on 2026-06-14 (5/7 printed URLs matched a registry handle exactly; the misses were stale registry files). CCorn reads that handle in `StateDetector` and carries it to the row, so "Open in Browser" can deep-link straight to the session. **Caveat, two different `bridgeSessionId`s:** the *registry* value is a `session_…` id and IS the URL segment; the *transcript* `bridge-session` record (`{type: "bridge-session", sessionId, bridgeSessionId, lastSequenceNum}`) carries a `cse_…` id in a different namespace that is **not** URL-valid; use it only as the boolean RC signal, never to build the deep link. The title remains the handle for the portal fallback, so still set a clear one (`claude --rc "<title>"`).
- "Open in Browser" deep-links to `https://claude.ai/code/<bridgeSessionId>` (the registry `session_…` handle) when it is known, and falls back to `https://claude.ai/code` (the session list) otherwise; the handle is a positive-only signal (the registry file can lag a live bridge), so the fallback is normal, not an error.
- Remote-control-active detection (for the Running state): the literal string `Remote Control active` is printed right-aligned in the TUI footer from session start and is stable across frames (verified on 2.1.169), so `tmux capture-pane` matching on it is the primary signal. A version-independent secondary signal that does not depend on pane scraping: a `bridge-session` record exists in the session's JSONL transcript. Treat remote control as active if either holds; show the grey warning indicator only when neither does.
- Remote-control loss: short drops (sleep, brief network loss) reconnect automatically when the machine is back online, so take no action. A sustained ~10-minute outage is different: the session times out and the `claude` process **exits**. Do not send `/rc` to a timed-out session (nothing is there to receive it). Detection marks it Dead (PID gone); recovery is the normal Restart flow (`claude --resume <uuid> --rc`). The `/rc` slash command is only for turning remote control on for a still-alive session.

### Session Resume

- Resume by session ID: `claude --resume <uuid> --rc`, run in the project directory via tmux.
- Session ID: the JSONL filename *is* the session UUID, so `basename <file> .jsonl` yields it directly; the `sessionId` field inside each line is an equivalent source.
- Transcripts are flat `*.jsonl` directly in the project directory (verified on 2.1.169; not nested under `sessions/`). A directory can hold several, one per session, alongside a `memory/` subdir (ignore it). The transcript is created **lazily**, only after the session's first real turn, so a freshly started session may not have a file yet. Choose the session to resume by most-recently-modified transcript.
- The directory is set when the window is created (`tmux new-window -c <path>`), so a separate `cd` is not needed: `tmux send-keys -t <window-id> "claude --resume <uuid> --rc" Enter`. If a window was somehow created without `-c`, prefix `cd <path> && ` instead, never both.

### PID Tracking Per Session

CCorn tracks the live PID of the `claude` process for each managed session. Without it, dead detection and kill operations have no reliable target. PIDs are runtime-only and must be re-derived on every app launch (see Launch Reconciliation).

**How to capture the PID after starting a session:**

1. After sending `claude --rc` (or `claude --resume <uuid> --rc`) via `tmux send-keys`, wait ~1 second, then poll (do not assume readiness at exactly 1s; node-based installs can take longer to spawn).
1. Get the shell PID of the pane: `tmux list-panes -t <window-id> -F "#{pane_pid}"`.
1. Find the `claude` child of that shell by argv (see Process Identification). Do not assume the OS-level process name is `claude`; on a native install it is the version string (e.g. `2.1.169`).
1. Store the PID on the session record.
1. If no `claude` child appears within 5 seconds, treat it as a failed start and show an error.

**Using the PID:**

- Liveness/dead detection: `kill -0 <pid>` fails when the process is gone.
- Stop and import-kill both use the canonical termination routine (see Terminating a Session).

**tmux session and windows:**

- Single tmux session named `ccorn`; each Claude Code session is one window.
- On app launch: `tmux has-session -t ccorn` first; only create if absent: `tmux new-session -d -s ccorn`.
- New window (capture its ID): `tmux new-window -t ccorn -n <sanitized-name> -c <project-directory> -P -F "#{window_id}"`. Target this window by the returned `@N` ID for all later commands, not by name (see Window Naming and Identity).
- New session command: `tmux send-keys -t <window-id> "claude --rc" Enter`.
- Resume command: `tmux send-keys -t <window-id> "claude --resume <uuid> --rc" Enter`.
- Capture for state detection: `tmux capture-pane -t <window-id> -p` (the visible frame; see Session States for why scrollback is unreliable here).
- "Open in Terminal": attach each terminal through its own grouped "view" session via `osascript`, not the shared `ccorn` session directly (see Window Naming and Identity).

### Process Identification

Several operations need to find and match the `claude` process. Confirm the binary's actual shape on the build machine before trusting any pattern. On a native install (verified on 2.1.169) the executable is **version-named** (`~/.local/share/claude/versions/<version>`, symlinked from `~/.local/bin/claude`), which makes the process identity diverge by API: argv[0] basename is `claude`, but `proc_name()` / `proc_pidinfo` / kernel `p_comm` / `ps -o ucomm` return the version string (e.g. `2.1.169`). A Node-wrapped install instead shows process name `node` and `node .../cli.js --rc` in argv.

- Find the `claude` child of a known shell PID: list children with `pgrep -P <shell_pid>` (or `proc_listchildpids`) and select the Claude Code process **by argv, not by process name**. Read args via `KERN_PROCARGS2` (sysctl) and match argv[0] basename == `claude` or args containing `--rc`; alternatively match the exec-path basename via `proc_pidpath`. **Do not match on `proc_name()` / `p_comm` / `ps -o ucomm`** (on a native install these return the version string like `2.1.169`, not `claude`), and **never** use a global `pgrep claude` (the probe machine had ~15 unrelated `claude` processes running). For a Node install, match `cli.js` in argv. This argv/exec-path rule is tolerant of both shapes.
- Scan all running sessions with `ps -axww` (the `ww` prevents truncation of long Node command lines) and match on the resolved binary. Do not match on the bare command-line substring `claude` plus flags: it misses sessions started as plain `claude` with no flags (exactly the unmanaged ones the import flow targets). A naive line grep also matches its own process; if you grep, use a bracket pattern like `grep "[c]laude"`.
- Map a PID to its working directory (to match an unmanaged process to a project): `ps` does not expose cwd; use `lsof -p <pid> -d cwd` or `proc_pidinfo` via libproc.

### Window Naming and Identity

The tmux window name is a display/attach label, not a reliable key. Folder names can contain spaces and dots, and tmux target syntax is `session:window.pane`, so a project named `mella.studio` yields target `ccorn:mella.studio`, which tmux parses as window `mella`, pane `studio`; a space breaks the target entirely. Therefore:

- Sanitize window names: replace spaces, dots, colons, and other tmux-significant characters with `-` before creating the window; append `-2`, `-3` on collision.
- Target programmatic commands (`send-keys`, `capture-pane`, `kill-window`, `rename-window`) by the stable window ID (`@N`) captured at creation. The `ccorn:<name>` forms shown elsewhere in this doc are illustrative and are only safe while names are unique and unchanged, so resolve them to the window ID (or an `@ccorn_id` tag) first. Optionally tag the window: `tmux set-option -w -t <window-id> @ccorn_id <session-uuid>` (the `-w` scopes it to the window) and resolve windows by it. This is what makes Launch Reconciliation and Rename robust.
- For "Open in Terminal," do NOT attach the terminal directly to the shared `ccorn` session (`tmux attach -t ccorn`). The current window and the active pane are session-level state shared by every attached client, so a second terminal mirrors the first: selecting a window (or CCorn creating a new one) switches all attached terminals, keystrokes route to the single shared pane, and clients are clamped to the smallest one's size. Instead attach each terminal through its own throwaway grouped session that shares `ccorn`'s window list but holds an independent current window and active pane: `tmux new-session -t ccorn -s <view> ';' set-option -t <view> destroy-unattached on ';' select-window -t '<view>:<window-id>'`. Name views `ccorn-view-<window-id>` (unique-suffixed on collision). `destroy-unattached` reaps a view when its terminal closes and MUST be set with the client attached (set on a detached session, tmux destroys it immediately); the launch reconcile sweep kills any unattached `ccorn-view-*` a crashed terminal left behind. Chain the commands with a single-quoted `';'` (the shell hands tmux a literal `;` separator) so no backslash needs escaping inside the `osascript` `do script` string, and select the window by `@N` id, never the name, so spaces or quotes can't break the target.

Two names exist and must not be confused: the **tmux window name** (display/attach only) and the **Claude session title** set by `/rename` (which syncs to claude.ai and mobile). On rename in CCorn, send `/rename <new>` to update the Claude title *and* run `tmux rename-window` so they stay in sync. CCorn displays the Claude title and targets by window ID. To set the title when CCorn starts a session, pass it as the name argument (`claude --rc "<title>"`) rather than a follow-up `/rename`; reserve `/rename` for retitling a session that is already running.

### Launch Reconciliation

tmux sessions outlive CCorn, so on every launch CCorn rebuilds its view from what already exists rather than assuming start-time state:

- If the `ccorn` session exists, enumerate its windows by ID. For each, re-derive the live PID from the pane (see Process Identification); previous-run PIDs are meaningless.
- Re-detect each session's state from pane capture (the `Remote Control active` string) and/or the JSONL `bridge-session` record. The per-session URL is not persisted; it is re-derived each launch from the registry `bridgeSessionId`, so "Open in Browser" deep-links once remote control re-activates and falls back to the session list until then.
- Re-join existing windows to persisted records (see Session Record) by `@ccorn_id`/window ID, not by name.

### Session Record (Data Model)

One persisted record per known session. Identity key: the Claude session UUID (JSONL filename / `sessionId`). Fields:

- Project absolute path (resolved via `cwd`), display title (Claude session title), tmux window ID and `@ccorn_id` tag.
- Live-only (never trusted across relaunch): current PID, current state, last-pane-hash and last-hash-change timestamp. (No session URL is stored; remote-control liveness comes from the `Remote Control active` string or the JSONL `bridge-session` record.)
- Persisted (survive relaunch): archived flag, session UUID, last-known path and title.

Persist as JSON under `~/Library/Application Support/CCorn/`. Archived state in particular must survive relaunch; PID, URL, and state are re-derived on launch.

### Terminating a Session

One canonical routine, referenced by Stop, Archive, and Import:

1. If managed (has a tmux window): `tmux kill-window` by window ID. This sends SIGHUP to the pane's processes and usually ends `claude`.
1. If the tracked PID is still alive (`kill -0` succeeds): `SIGTERM`, wait 5s, then `SIGKILL` if still alive.
1. If unmanaged (no tmux window): skip step 1 and apply step 2 to the unmanaged process PID directly.

### Key Dependencies

- tmux, required, detected on launch via `which tmux`, install prompt if missing
- Claude Code CLI: detected on launch via `which claude` (on the resolved PATH; see Process Execution Environment). If not found: alert "Claude Code is not installed. Visit docs.anthropic.com/claude-code to install it." with a link. Also run `claude --version` and require v2.1.51+ (the Remote Control minimum; mobile push needs v2.1.110+); below that, warn that remote-control features will not work.
- Homebrew, used only for tmux install prompt. If `which brew` returns nothing: alert “Homebrew is required to install tmux. Visit brew.sh to install Homebrew first, then relaunch CCorn.”

-----

## 3. Design Language

### Philosophy

Native macOS utility. Invisible when done right. The app gets out of the way. Status dots are the only color; everything else is zinc neutral. No gradients, no shadows, no decorative elements.

### Color Palette: B1 Zinc Neutral

System-following (light/dark adapts automatically) except the menu bar popover which is fixed dark.

**Light mode:**

```
Background:     #FAFAFA
Surface/hover:  #F4F4F5
Border:         #E4E4E7
Muted text:     #A1A1AA
Secondary text: #71717A
Primary text:   #09090B
Primary action: #09090B bg / #FAFAFA text
```

**Dark mode (zinc inverted, SwiftUI handles automatically):**

```
Background:     #09090B
Surface/hover:  #18181B
Border:         #27272A
Muted text:     #52525B
Secondary text: #A1A1AA
Primary text:   #FAFAFA
Primary action: #FAFAFA bg / #09090B text
```

**Menu bar popover, fixed dark regardless of system:**

```
Background:     #09090B
Row hover:      #18181B
Dividers:       #27272A
Primary text:   #FAFAFA
Secondary text: #71717A
```

**Status mark colors, the only color in the app.** Tokens listed below with
a light / dark pair adapt to appearance; single-value tokens are identical in
both. Contrast floors: the attention amber doubles as word TEXT, so its light
face must clear WCAG AA 4.5:1 on the light background (the original #D97706
sits near 3:1 and fails); the dots, rings, and triangles are graphical UI
components, so each face must clear 3:1 on the backgrounds it renders over:

```
Green:           #16A34A light / #22C55E dark   : running, healthy, remote control active;
                                                  same hue lifted a step on dark (and the
                                                  fixed-dark popover) so the dot doesn't
                                                  recede next to the bright dark-face amber;
                                                  green-500 is dark-face only (~2.3:1 on
                                                  white fails the 3:1 component floor)

Blue:            #2563EB light / #3B82F6 dark   : Claude actively working mid-task; same hue
                                                  lifted a step on dark (and the fixed-dark
                                                  popover) so working reads active and
                                                  separates from the muted stale slate

Attention amber: #A34A0B light / #F59E0B dark   : waiting dot + halo, recoverable warning
                                                  triangles (sign-in, no-remote), and every
                                                  amber attention word

Slate:           #64748b                        : stale, idle past threshold (recessive on
                                                  purpose; the original #EA580C orange read
                                                  like Crashed at 7px)

Red:             #dc2626                        : crashed (triangle + word), rename error

Stopped outline: #8A8A8F light / #A1A1AA dark   : hollow dot ring (dark face also the fixed-dark
                                                  popover); the light face is fixed because the
                                                  original tertiaryLabel resolved near #BDBDBD,
                                                  ~1.6:1 on white, and the ring all but vanished;
                                                  #8A8A8F is ~3.4:1 and still lighter than the
                                                  unmanaged #71717A, so stopped stays the quieter
                                                  hollow dot

Unmanaged:       #71717a                        : hollow dot ring, same in both appearances
```

### Typography

SF Pro Text throughout. SF Mono for directory paths only. Two weights only: regular (400) and medium (500). Never bold (700).

Use SwiftUI semantic text styles, which respect Dynamic Type automatically. The point sizes annotated in the table below are nominal: on macOS the rendered sizes differ from iOS (e.g. `.subheadline` is ~11pt, `.caption`/`.caption2` ~10pt). Use the named style, not a hardcoded `.system(size:)`, so Dynamic Type still applies, and pick the style whose macOS size matches the intended hierarchy rather than forcing the listed pt. Use semantic SwiftUI colors wherever possible so dark mode is handled automatically. Never hardcode hex values for text colors in the main window; only use hardcoded hex in the menu bar popover which is fixed dark.

```
Column headers:     .caption2   11pt  regular   Color.secondary  uppercase via .textCase(.uppercase)
Timestamps:         .caption    12pt  regular   Color.secondary
Directory paths:    .caption    12pt  monospaced Color.secondary  (SF Mono via .monospaced())
Attention words:    .caption    12pt  regular   matches the mark color (attention amber / red)
Session names:      .subheadline 13pt medium    Color.primary
Sidebar nav items:  .subheadline 13pt regular   Color.primary    (medium when active)
Section labels:     .caption    12pt  regular   Color.secondary  uppercase via .textCase(.uppercase)
Settings headers:   .subheadline 13pt medium    Color.primary
Button labels:      .subheadline 13pt medium    For dark bg buttons: Color.white text on Color.primary bg. SwiftUI does not auto-invert button text; specify explicitly.
```

**Popover only, hardcoded hex acceptable since popover is always dark:**

```
Primary text:   #FAFAFA
Secondary text: #71717A
```

### Spacing

- 8px grid: all spacing is a multiple of 4 or 8
- Content padding: 16px left/right on main list rows
- Sidebar padding: 12px left/right
- Sidebar nav item height: native SwiftUI `.listStyle(.sidebar)`, do not hardcode
- Main list row height: 36px
- Column header height: 28px
- Menu bar popover width: 280px
- Menu bar popover padding: 12px
- Menu bar popover row height: 32px
- Button corner radius: 6px
- Borders: 0.5px only, never 1px
- No shadows anywhere
- No gradients anywhere

### Reference Screenshots

- Plane left sidebar (section labels, nav items, indented sub-items, no borders)
- Vercel deployments list (name dominant, status dot only on left, metadata right, timestamp far right, dot only, no text label next to dot)
- Docker Desktop popover (dark background, status at top, actions below, tight spacing)
- Craft modal (centered card, icon top, title, subtitle, action button full width)
- Linear empty state (centered illustration, title, subtitle, two action buttons)
- ElevenLabs settings (single screen, no tabs, form sections with toggles, clean native feel)

### CCorn Icon

**Menu bar icon:**
Monochrome corn cob silhouette. SF Symbol style stroke weight. Follows system appearance automatically: rendered as a template image so macOS handles color (dark in light mode, light in dark mode). Shape: simple elongated oval body tapering slightly toward the tip, with a minimal two-leaf husk suggestion at the base. No kernels, no texture, no detail. Must read clearly at 16×16px.

**App icon:**
Same corn cob silhouette on a rounded-square canvas (standard macOS app icon shape). Zinc neutral treatment: `#09090B` cob on `#FAFAFA` background in light mode. Slightly more form than the menu bar icon, gentle taper, minimal husk. No gradients, no shadows. Delivered at all required macOS sizes: 16, 32, 64, 128, 256, 512, 1024px.

**Implementation note:** Create the icon as an SVG first, then export at all required sizes into `Assets.xcassets/AppIcon.appiconset/`. If the icon cannot be created programmatically, place a placeholder corn cob emoji (`🌽`) as a temporary menu bar icon and note it as a manual design task.

-----

## 4. Session States

Eight detected states (the original seven plus Needs-auth, section 8), shown
as nine *presentations*: an alive session whose remote control is not active
past the 30s activation grace presents as No-remote regardless of its
underlying activity. Every row shows exactly ONE status mark: a 7px dot for
the routine states, or the single warning symbol `exclamationmark.triangle.fill`
(slightly larger than the dot, in the same fixed-width slot) for the broken
trio, never a dot and a symbol together, never any other status glyph. The
four presentations that need the user also show a short colored word after
the title; the routine states keep their word in the mark's tooltip.

|Presentation|Mark                |Color                                    |Word         |Meaning                                        |
|------------|--------------------|-----------------------------------------|-------------|-----------------------------------------------|
|Running     |Filled circle       |Green `#16a34a`                          |-            |Session alive, remote control active, healthy  |
|Working     |Filled circle       |Blue `#2563eb`                           |-            |Claude actively executing mid-task             |
|Waiting     |Filled circle + halo|Attention amber `#A34A0B` light / `#F59E0B` dark|"Needs input"|Claude waiting for user input or approval|
|Stale       |Filled circle       |Slate `#64748b`                          |-            |Idle past user-defined threshold               |
|Sign in     |Warning triangle    |Attention amber (same token)             |"Sign in"    |Login prompt showing; sign-in is the root cause|
|No remote   |Warning triangle    |Attention amber (same token)             |"No remote"  |Alive, remote control not active past the grace|
|Crashed     |Warning triangle    |Red `#dc2626`                            |"Crashed"    |Process crashed or died unexpectedly (Dead)    |
|Stopped     |Empty circle        |Stopped outline (tertiaryLabel light / `#A1A1AA` dark+popover)|-|Manually stopped by user, not running|
|Unmanaged   |Outline circle      |`#71717A` ring                           |-            |Discovered but not yet imported into CCorn     |

**Dot size:** 7px diameter (hollow rings 1px; a 0.5px ring is invisible at 7px)  
**Dot position:** Left of session name in a fixed-width slot, 8px gap between mark and name

**State detection: implementation:**

Poll each session every 3 seconds with `tmux capture-pane -t <window-id> -p` (the `@N` window ID captured at creation, not the name; see Window Naming and Identity). Capture the visible frame only: Claude Code is a full-screen TUI on the terminal's alternate screen, which keeps no per-app scrollback, so `-S -<n>` would read stale pre-launch output rather than the current view. The visible frame is the current TUI render, which is exactly what these patterns match against (add `-J` to rejoin wrapped lines if needed). Parse the output for these patterns:

- **Working (blue):** Output contains tool invocation strings like `Bash(`, `Read(`, `Write(`, `Edit(`, `Task(`, or contains spinner characters `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`. Rely on pane output patterns; do not use CPU usage from `ps` as it reports lifetime averages, not real-time activity.
- **Waiting (amber):** Output ends with Claude’s prompt indicator, typically a `>` or `?` prompt with no spinner, or contains phrases like “Would you like”, “Do you want”, “Please confirm”, “Allow”, or Claude Code’s permission prompt patterns. Process is running but no Working pattern matched.
- **Running (green):** Process is alive and remote control is active (see Remote Control in Section 2 for the detection signal and its fallback), but no Working or Waiting pattern matched. This is the default healthy idle state.
- **Stale (slate):** Running state but pane output hash unchanged for longer than the user-defined threshold. Implementation: store a SHA256 hash of captured pane output each poll cycle. Compare to previous hash; if identical for longer than threshold → stale. Track last-hash-change timestamp per session.
- **Dead (red):** The session's tracked PID is gone (`kill -0 <pid>` fails). Confirm against the process list (see Process Identification), matching by PID rather than a grep on the command line.
- **Stopped (empty circle):** User-initiated stop, set by CCorn, not detected from process state.
- **Unmanaged (outline):** discovered via `~/.claude/projects/` (a project whose `cwd` resolves into a watch directory), or a live `claude` process running in such a directory, with no window in the `ccorn` session matching this project path. Not detected from a `.claude/` folder (see Session Discovery).

**Note:** The literal footer string is `Remote Control active` (verified on 2.1.169). If a future Claude Code version changes the wording, the `bridge-session` JSONL record (see Remote control linkage) is the version-independent fallback.

**Remote control linkage and the per-session URL:**
Detect that remote control is active via the `Remote Control active` footer string (see the Running state above) or the `bridge-session` record in the session's JSONL. The per-session URL `https://claude.ai/code/session_<id>` (RC ≥ 2.1.162) is not scraped from the pane; its `session_…` id equals the `bridgeSessionId` in the process registry (`~/.claude/sessions/<pid>.json`), which CCorn already reads. "Open in Browser" deep-links to `https://claude.ai/code/<bridgeSessionId>` when the handle is known, falling back to `https://claude.ai/code` (the session list, located by title) otherwise. Do not use the transcript `bridge-session` record's `bridgeSessionId` (a `cse_…`, different namespace) for the URL.

**Warning presentation (one mark per row, no overlay):**
There is no separate warning indicator next to the dot. A session that is
broken for the user, sign-in required, remote control not active past the
30s grace, or crashed, REPLACES its dot with the single warning symbol
`exclamationmark.triangle.fill`: attention amber for the recoverable pair
(sign-in, no-remote), red for crashed. The short word after the title names
the specific problem, and the mark's tooltip carries the full reason
(including the underlying activity a No-remote session was in). Waiting is
routine, not broken: it keeps its amber dot plus the "Needs input" word.

**Bypass detection (no on-row marker for now):**
Bypass is still tracked at runtime; the detector's pane footer signal
(`bypass permissions on`) flags a session running with permissions bypassed,
including one escalated mid-session (Shift+Tab) or an adopted session, plus any
session CCorn started with a Bypass launch config, and the row model carries
the resulting `isBypass` flag. No on-row marker is currently rendered for it:
earlier treatments (a monochrome `shield.slash`, then `bolt.fill`, after the
name) read either as an alert or as "fast," so any visible marker is deferred
until a treatment fits the one-status-mark-per-row and status-marks-own-the-
only-color rules. See 5.5 (New Session Defaults) and 6.3 (New Session).

-----

## 5. Screen Inventory

### 5.1 Main App Window

The primary interface. Opens from “Open CCorn” in the popover or by right-clicking the menu bar icon.

**Activation policy:**
CCorn uses `NSApplicationActivationPolicyAccessory` (in Swift, `.accessory`) by default: no Dock icon, no Cmd+Tab. When any regular window opens (main window, Settings, or onboarding), switch to `NSApplicationActivationPolicyRegular` (`.regular`) so the window can take focus and appear in Cmd+Tab. Switch back to `.accessory` only when no regular windows remain open, not unconditionally on main-window close (otherwise an open Settings or onboarding window is left under a deactivated app). Do NOT use `LSUIElement = YES`: that prevents the dynamic switching needed for proper window focus.

**Window:**

- `NavigationSplitView`, two panels
- Minimum size: 720 × 480px, resizable
- Standard macOS title bar with traffic lights, title TEXT hidden
  (`window.titleVisibility = .hidden`); app identity lives in the branded
  sidebar header and the popover header, not duplicated in the title bar
- `window.title` stays set to `"CCorn"` for programmatic lookup (the debug
  channel finds the window by title; activation policy keys off `.titled`)
- No toolbar

**Left Sidebar: 200px fixed:**

Top section:

- No sidebar brand lockup or wordmark: app identity is the OpenMoji corn
  glyph (`CornMark`) at the trailing edge of the title bar (a titlebar
  accessory, not a toolbar item; a toolbar would add AppKit's "Icon and
  Text / Icon Only" right-click menu; see 5.1 header), so the sidebar opens
  directly on the New Session button
- `+ New Session`, text button with SF Symbol `plus` icon left, `.subheadline` medium `Color.primary`

Nav section (`.listStyle(.sidebar)`):

- Section label: “SESSIONS”, `.caption` `Color.secondary` uppercase via `.textCase(.uppercase)`
- Nav item: “All Sessions”, `.subheadline` regular `Color.primary`, medium when active, system sidebar selection highlight on active
- Sub-item indented: “Archived”, `.caption` regular `Color.secondary`

Bottom pinned:

- Settings gear icon, SF Symbol `gear`, 16px, `Color.secondary`

No borders between sidebar items. Hierarchy through indentation and weight only.

**Main Panel:**

Column header row (28px, `Color(.controlBackgroundColor)` background, 0.5px bottom border `Color(.separatorColor)`):

- NAME, STATUS, DIRECTORY, LAST ACTIVE, (actions column, no header)
- `.caption2` `Color.secondary` uppercase via `.textCase(.uppercase)`, 16px left padding

Session rows (36px each):

- 16px left padding
- Status dot (7px filled circle or outline), left. Dot only, no text label next to it.
- 8px gap
- Session name, `.subheadline` medium `Color.primary`
- Directory path, `.caption` monospaced `Color.secondary`, truncated with ellipsis
- Last active timestamp, `.caption` `Color.secondary`, far right, before actions
- `...` button, appears on hover only, far right, SF Symbol `ellipsis` at 14px

**Row click behavior in main window:** Single click selects the row (highlight only). Double-click opens the session using the **click action** chosen in Settings (5.5), Terminal (default) or browser, routing through the same handoff as the popover row click (flow 6.4). The double-click itself is not gated on remote control: in Terminal mode it attaches to the tmux window regardless; a stopped session (no live window) is restarted first and the fresh window opened in Terminal (the Restart preconditions apply, so a missing project dir or transcript surfaces the same dialog); an archived or unmanaged row with no window falls back to the browser. The explicit, remote-control-gated "Open in Browser" and "Open in Terminal" items remain in the context menu for forcing either destination. Right-click or the `...` button opens the context menu. (Composing single-click select, double-click open, right-click menu, and hover-to-reveal `...` on a SwiftUI `List` row inside `NavigationSplitView` is finicky; budget for gesture composition or light AppKit interop.)

Row states:

- Default: system background color (`Color(.windowBackgroundColor)`)
- Hover: system secondary background (`Color(.controlBackgroundColor)`)
- Selected: system selection highlight (`Color.accentColor.opacity(0.15)`)
- 0.5px row dividers using `Color(.separatorColor)`

Sorted by last active, most recent first.

-----

### 5.2 Menu Bar Popover

Triggered by clicking the CCorn icon in the macOS menu bar. Fixed dark zinc regardless of system appearance.

**Container:**

- Width: 280px
- `NSPopover` anchored below menu bar icon
- Background: `#09090B`
- 12px padding all sides
- Dismisses on click outside

**Header (32px):**

- Corn glyph (`CornMark`, 18pt) far left, no wordmark; the popover is summoned from the menu-bar corn, so “CCorn” text would be redundant
- Aggregate status mark far right: reflects the worst presentation across all sessions, severity order crashed > sign-in > no-remote > waiting > stale > working > running (waiting outranks stale because a waiting session is blocked on the user). A broken-tier worst renders the exclamation symbol colored by severity (amber recoverable, red terminal); otherwise the worst state's dot. If every session is stopped or unmanaged (no active-state color), show the empty/outline dot.
- 0.5px divider below, `#27272A`

**Session list, triage layout:**

The popover is a triage surface, not a mirror of the dashboard: it answers
"does anything need me" first and summarizes the rest. The split is
popover-local; the main window keeps its full recency-ordered list.

- Attention section, top: sessions whose presentation needs the user:
  Waiting (Needs input), Sign in, No remote, Crashed, as individual rows,
  sorted worst-first by the aggregate severity ladder (crashed > sign-in >
  no-remote > waiting), recency as tiebreak
- Calm section, below: running/working/stale/stopped sessions are NOT listed
  individually by default; they collapse behind one disclosure row showing a
  count ("5 quiet", chevron left), which expands on click to the full
  recency-ordered calm list. Collapsed by default on every popover open.
- All-clear: with no attention sessions, the disclosure row doubles as the
  all-clear line: "All clear" (`.subheadline` medium `#FAFAFA`) + "N quiet"
  (`.caption` `#71717A`), and the header aggregate shows its calm dot
- Row anatomy unchanged: 32px rows, 8px left/right padding, status mark in
  the fixed slot left, 8px gap, session name `.subheadline` medium `#FAFAFA`,
  attention word after the name, last active `.caption` `#71717A` far right
- Click anywhere on a session row → opens the session using the **click action** chosen in Settings (5.5): Terminal (default) attaches to its tmux window; a stopped session is restarted first and the fresh window opened in Terminal; browser opens claude.ai/code. Same handoff as the main-window double-click (flow 6.4).
- Hover: `#18181B` background (rows and the disclosure row)
- Size budget: width stays 280; the list region caps at 8 rows × 32px before
  scrolling. Attention rows + the collapsed disclosure fit unscrolled in the
  common case; expanding the calm list is what scrolls.
- 0.5px dividers `#27272A`

**Footer (36px):**

- 0.5px divider above, `#27272A`
- `+ New Session`, left, `.caption` medium `#A1A1AA`
- `Open CCorn`, right, `.caption` medium `#A1A1AA`

-----

### 5.3 Onboarding Screen

First launch only. Never shown again after completion.

**Container:**

- Centered card on the system window background (`Color(.windowBackgroundColor)`), so onboarding follows light/dark like the rest of the main UI
- Card: 480px wide, auto height, `Color(.controlBackgroundColor)` surface, 0.5px border `Color(.separatorColor)`, 12px corner radius, 32px padding. Do not hardcode light hex here; it would render as a glaring white card in dark mode
- Not a sheet: standalone centered window, not resizable. The app is `.accessory` at first launch, so switch to `.regular` before showing this window so it can take focus (see Activation policy)
- Title-bar TEXT hidden (`titleVisibility = .hidden`), same treatment as the main window: the card body shows the corn glyph and the app name, so the title would duplicate it. The title STRING stays `"Welcome to CCorn"` for programmatic lookup (the debug channel finds the window by it)

**Layout top to bottom:**

- CCorn logo/icon, 48px centered, 8px margin bottom
- “CCorn”, `.title2` medium `Color.primary` centered
- “Where do you keep your projects?”, `.subheadline` regular `Color.secondary` centered
- 24px gap
- Directory list area, grows as user adds directories
  - Each row: SF Symbol `folder` `Color.secondary` left, monospaced path `.subheadline` `Color.primary`, `×` remove button far right `Color.secondary`
  - `Color(.separatorColor)` borders between rows
  - Empty state of list: dashed border area with `+ Add Directory` centered
- `+ Add Directory` text button below list, `.subheadline` medium `Color.primary`
- 8px gap
- Caption: “CCorn will scan these folders for Claude Code sessions”, `.caption` `Color.secondary` centered
- 24px gap
- “Start Scanning”, full width button, `Color.primary` bg, `Color.white` text, 36px tall, 6px radius
  - Disabled/muted until at least one directory added
- “Add more directories later in Settings”, `.caption` `Color.secondary` centered, below button

**Behavior:**

- `+ Add Directory` opens native `NSOpenPanel` folder picker
- Selected path appends as new row in list
- Duplicate directory silently ignored
- Onboarding is required; there is no dismiss or skip option. The app is not usable without at least one watch directory. The window cannot be closed until “Start Scanning” is clicked with at least one directory added.
- Start Scanning → scans, transitions to main window + first run import sheet if sessions found

-----

### 5.4 First Run Import Sheet

Appears immediately after onboarding scan if unmanaged sessions are found. Slides down from main window title bar as a native macOS sheet.

**Sheet container:** 480px wide, auto height, standard macOS sheet chrome

#### State 1: Discovery

Header:

- “Found [X] active sessions”, `.title3` medium `Color.primary`
- “Import them into CCorn to manage them here”, `.subheadline` regular `Color.secondary`
- `Color(.separatorColor)` divider below

Session list, each row 36px:

- Checkbox left, checked by default
- Status dot, green if idle, blue if actively working (matches main state model: green = healthy, blue = working)
- Session name, `.subheadline` medium `Color.primary`
- Directory path, `.caption` monospaced `Color.secondary`
- “Working” or “Idle” pill badge far right, `.caption` medium, blue fill for Working, green fill for Idle, 4px corner radius

Footer:

- “Skip for Now”, text button left, `.subheadline` `Color.secondary`
- “Import Selected ([X])”, filled button right, `Color.primary` bg, `Color.white` text

#### State 2: Importing Progress

List is locked; no interaction. Each row shows import state:

- Waiting: muted opacity, grey dot
- Currently importing: `ProgressView` spinner replacing dot, row `Color(.controlBackgroundColor)` background (semantic, so it adapts to dark mode)
- Done: SF Symbol `checkmark` green replacing dot, row dims to 60% opacity
- Failed: SF Symbol `xmark` red replacing dot, full opacity

Progress text below list (centered):

- “Importing [X] of [Y]…”, `.caption` `Color.secondary`

Footer:

- “Importing…”, disabled muted button, no cancel

#### State 3: Active Session Warning

Appears as an alert over the sheet when CCorn hits an actively-working session:

- Title: “Claude is mid-task in [session name]”
- Message: “Importing now may interrupt active work.”
- “Wait for Idle”, default button, polls every 10 seconds, auto-continues when session goes quiet
- “Import Anyway”, proceeds immediately

#### State 4: Complete

- Title: “All done”, `.title3` medium `Color.primary`
- Subtitle: “[X] sessions are now managed by CCorn”, `.subheadline` `Color.secondary`
- All rows show SF Symbol `checkmark` green
- “Close”, full width button
- Sheet dismisses, main window shows all sessions with correct status dots

-----

### 5.5 Settings Screen

Opens from the gear icon in the sidebar (open the `Settings` scene programmatically; a menu-bar-only `.accessory` app may not present a standard app menu, so do not rely on a system menu item). Native macOS `Settings` scene, renders as a preferences window automatically.

**Window:** ~480px wide, auto height (grows as directories are added), standard macOS preferences chrome with the title-bar TEXT hidden (`titleVisibility = .hidden`, matching the main and onboarding windows; the scene-set title string, containing "Settings", stays for programmatic lookup)

**Single screen, three sections using SwiftUI `Form` + `Section`:**

Section 1, “Watch Directories”:

- Directory list, same row treatment as onboarding (SF Symbol `folder`, monospaced path, × remove)
- `+ Add Directory` button below, opens `NSOpenPanel`
- Removing a directory: confirmation alert: “Remove [path]? This will hide [X] sessions from the list. Sessions will continue running in the background.” Cancel / Remove
- Caption below list: “CCorn scans these folders for Claude Code sessions”, `.caption` `Color.secondary`

Section 2, “Behavior”:

- Launch at login, `Toggle`
- Auto-restart sessions on launch, `Toggle`
- Scroll wheel scrolls in sessions, `Toggle`, default **on**. Drives tmux `set-option -t ccorn mouse on|off` scoped to CCorn's own `ccorn` session and its Open-in-Terminal view sessions, never the tmux global (`-g`), so a user's own `set -g mouse` for their other tmux work is untouched. On: the scroll wheel scrolls the pane. Off: native terminal text selection is simpler, but the wheel acts as arrow keys in the full-screen TUI. Applied at session setup (`TmuxController.ensureSession`) and live on toggle (`SessionEngine.applyMouseMode`)
  - With mouse on, releasing a drag-selection is rebound away from tmux's default `MouseDragEnd1Pane → copy-pipe-and-cancel` to `copy-pipe-no-clear pbcopy` (`TmuxController.installCopyModeSelectBindings`, both the `copy-mode` and `copy-mode-vi` tables). Two fixes: (1) **no jump**: the default's `-and-cancel` exits copy-mode, which snaps the pane back to the live bottom on every release; `no-clear` keeps copy-mode, so the scroll position holds and the user returns to live with `q`/Escape. (2) **clipboard actually works**: CCorn attaches through Terminal.app, which ignores the OSC 52 clipboard escape tmux's default `set-clipboard` path uses, so a stock copy went nowhere; piping to `pbcopy` writes the macOS pasteboard directly. Key tables are server-global (no per-session table), so the binding is guarded with `if-shell -F '#{m:ccorn*,#{session_name}}'` to fire only inside CCorn's `ccorn`/`ccorn-view-*` sessions and fall through to the tmux default everywhere else, the same restraint the session-scoped `mouse` option shows. (Native ⌥-drag selection in Terminal.app still bypasses tmux entirely.)
- Clicking a session opens, `Picker`: Terminal (default) / Browser. Governs both the popover single-click and the main-window double-click (flow 6.4)
- Stale session threshold, `Picker` with options: 1 hour, 2 hours, 4 hours, 8 hours, 24 hours

Section 3, “New Session Defaults”:

- The launch flags new sessions inherit; the New Session sheet (6.3) seeds its per-session override from these (inherit → override). Discrete controls only (the Behavior-section `Picker` idiom), so a keystroke never churns settings + rediscovery; per-session free text (custom model id, additional directories, extra args) lives in the sheet, not here.
- Permission mode, `Picker`: Default / Plan / Accept Edits / Auto / Allow Bypass / Bypass. Default is **Auto** (safe-but-autonomous: auto-approves routine work, blocks dangerous escalations). Maps to the CLI `--permission-mode` choices, except Bypass → `--dangerously-skip-permissions` and Allow Bypass → `--allow-dangerously-skip-permissions` (never combined with `--permission-mode`). The two bypass modes are dropped from the picker when CCorn runs as root (the CLI refuses bypass under root/sudo).
- Model, `Picker`: Account default / Opus / Sonnet / Fable
- Caption: a one-line summary of the selected permission mode, `.caption` `Color.secondary`

Section 4, “About”:

- Version number, `.caption` `Color.secondary` (read from Bundle)
- “View on GitHub”, `.caption` tappable link `Color.accentColor`, opens `https://github.com/sudoLuko/ccorn` in browser

No tabs. No second sidebar.

-----

### 5.6 Empty State

Shown in main panel when watch directories have been scanned but no Claude Code sessions found.

**Layout, centered vertically and horizontally in content area:**

- Corn cob outline illustration, ~48px, `Color.secondary` stroke, no fill. Should be a simple, clean line drawing with personality. This is the one place CCorn’s identity shows.
- “No sessions found”, `.title3` medium `Color.primary`
- “Add a watch directory or start a new Claude Code session”, `.subheadline` regular `Color.secondary`, max 320px wide, centered, wraps naturally
- 16px gap
- Two buttons side by side:
  - “New Session”, filled `Color.primary` bg, `Color.white` text
  - “Add Directory”, outline style, `Color(.separatorColor)` border, `Color.primary` text

-----

### 5.7 Context Menu

Native `NSMenu`; no custom styling. Appears on `...` button click or right-click on any session row. Renders instantly, follows system appearance automatically.

**For a running/working/waiting session:**

```
Open in Browser
Open in Terminal
───────────────
Rename
───────────────
Stop Session        ← recoverable; session stays as Stopped
Archive
───────────────
Copy Session ID
```

**For a dead/stopped session:**

```
Restart Session
───────────────
Rename
───────────────
Archive
───────────────
Copy Session ID
```

**For an archived session:**

```
Unarchive
───────────────
Copy Session ID
```

**For an unmanaged session:**

```
Open in Terminal
Import Session
───────────────
Copy Session ID
```

Both items adopt the session (take over the external `claude` → resume under CCorn, flow 6.10); “Open in Terminal” also attaches the fresh managed window. The take-over confirmation applies to either path.

Stop Session requires a confirmation alert:

- Title: “Stop [session name]?”
- Message: “The session will stop but stay in your list. You can restart it anytime.”
- Buttons: Stop (default, Return confirms, mirroring Start Session's default button; not destructive-red, since Stop is recoverable), Cancel (Escape backs out). Escape and Cancel stay the safety valve against an accidental stop of a live session.

-----

### 5.8 Rename: Inline Interaction

Triggered by “Rename” in context menu.

- Session name text in the row transforms to an editable `TextField` in place
- Same font, size, position, just editable with subtle `Color(.separatorColor)` border
- Text pre-selected so user can type immediately
- Enter → confirms, sends `/rename <new-name>` followed by a separate `Enter` key via `tmux send-keys`, then watches pane output for 3 seconds for an error response. If no error detected → row returns to normal with new name. If error detected (e.g. duplicate name) → show inline error.
- Escape → cancels, original name restored, nothing sent
- Empty name + Enter → cancels, original name restored
- Duplicate name error → inline `.caption` red text below row: “That name is already taken”, field stays editable

No modal. No sheet. Pure inline edit, same as renaming a file in Finder.

-----

### 5.9 Archived Sessions View

Triggered by clicking “Archived” in the sidebar.

Identical layout to main session list, same column headers, same row structure. Differences:

- Session name text: `Color.secondary`, visually muted
- Status dot: always empty circle; archived sessions are stopped, not running. Archiving a session kills it first, then archives it.
- `...` context menu: “Unarchive” and “Copy Session ID” only

Empty state for archived view:

- Same corn cob outline illustration as main empty state
- “No archived sessions”, no action buttons needed

**Unarchive flow:**

- Session moves back to All Sessions
- Appears as stopped state (empty circle dot)
- User can restart from `...` menu if desired

-----

### 5.10 Notifications

Local macOS notifications (`UNUserNotificationCenter`) for state changes worth surfacing while the user is not looking at the app. Request permission on first launch after onboarding.

- Fire when a session transitions to **Waiting** (Claude needs input/approval) or **Dead** (crashed or timed out). Coalesce rapid transitions; never notify on every poll.
- Do not fire for Working/Running/Stale transitions (too noisy).
- Tapping a notification opens that session in the browser (same as "Open in Browser").
- Separate from Claude Code's own mobile push (which fires on the phone when remote control is active, v2.1.110+); these are local desktop alerts about session state.

-----

### 5.11 Groups (user-defined collections)

The Apple Books collections pattern: a group is a user-named collection of
sessions, one level, no nesting, no new screens.

**Model and storage, the split matters:**

- Group DEFINITIONS (id, name; order = array position) persist in
  `CCornSettings.groups` (settings.json), using the settings file's
  field-by-field-defaulting decode so files written by older builds never
  reset.
- MEMBERSHIP is a field on the session record (`SessionRecord.groupIDs`),
  merged by uuid exactly like the archived flag (nil leaves it untouched;
  the record is created if absent). It therefore inherits the record store's
  prune and retention lifecycle: when a record dies, its memberships die
  with it; deleting a group sweeps its id off every record.
- Membership keys on the session UUID, never `SessionRow.id`; the row id
  differs across managed (`@N` window id), stopped (`record:` prefix), and
  unmanaged rows, and changes when a session stops.
- Bound-uuid gate: a brand-new session has an empty uuid until its first
  transcript binds, so the Groups control is disabled until uuid is
  non-empty (same gating family as Restart on a missing path).

**Scope:** record-backed rows only: running, working, waiting, needsAuth,
stale, dead, stopped, archived. Unmanaged/discovered rows get no Groups
control: they have no record, their uuid is borrowed and can shift, and
creating a record would reclassify them out of Discovered. A discovered
session joins a group after the user imports it.

**Sidebar:**

- GROUPS section below SESSIONS, header `.caption` `Color.secondary`
  uppercase, one row per group in stored order, member count `.caption`
  `Color.secondary` trailing
- `+ New Group` creates a group with a placeholder name and opens the
  inline editor on it (the 5.8 rename pattern: plain TextField, pre-selected
  text, Enter commits, Escape cancels, cancel on a just-created placeholder
  removes it). The editing row is not selection-tagged, so the editor never
  fights List selection.
- Right-click on a group row: Rename / Delete Group (native menu).
  Deleting asks to confirm, removes the definition, and clears the id from
  every record's membership; sessions are NEVER deleted or archived by it.

**Per-session menu (5.7 additions, record-backed variants only):**

- "Groups" submenu: one item per group with its state `.on` when the session
  is a member; toggling assigns/unassigns; the one control does both and
  shows membership inline. "New Group…" at the bottom creates a group,
  assigns the session, and opens the sidebar's inline editor.
- While a group view is active, a direct "Remove from [Group name]" item
  surfaces near the top of the menu.

**Filtering:**

- Selecting a group in the sidebar (`SidebarNav.group(id)`) lists managed,
  non-archived rows whose record carries the group id, in the shared recency
  order. Archived members keep their membership but surface only in the
  Archived view.
- Empty group: "No sessions in this group" with a hint to add via a
  session's `⋯` menu.

**Out of scope (this pass):** drag-and-drop assignment onto sidebar groups;
the menu submenu fully covers assignment; drag needs gesture-interplay
verification with the list's existing tap/right-click stack.

-----

## 6. User Flows

### 6.1 First Launch

1. App launches: menu bar icon appears immediately
1. Activation policy set to `NSApplicationActivationPolicyAccessory`
1. tmux checked first; if missing, show install alert. App halts here until resolved.
1. `claude` binary checked; if missing, show install alert. App halts here until resolved.
1. Dependencies confirmed: onboarding card appears centered on screen
1. User adds one or more watch directories via `NSOpenPanel`
1. Clicks “Start Scanning”: button disabled until at least one directory added
1. App scans directories, cross-references with running processes
1. If unmanaged sessions found → first run import sheet appears (see 6.2)
1. If no sessions found → main window opens, empty state shown
1. Onboarding never shown again

### 6.2 First Run Session Import

1. Import sheet slides down from main window title bar
1. All discovered unmanaged sessions listed with checkboxes, all checked by default
1. Each row shows idle/active badge
1. User reviews, unchecks any they don’t want to import
1. Clicks “Import Selected ([X])”
1. CCorn processes sequentially, one at a time:
   a. For idle sessions: sends `SIGTERM` to existing terminal process PID, waits 5 seconds, `SIGKILL` if still running. Creates new tmux window, runs `claude --resume <uuid> --rc`, confirms remote control is active (the `Remote Control active` footer string or a `bridge-session` JSONL record; liveness is signal-based, not URL-based).
   b. For active sessions: pauses, shows warning alert: user chooses “Wait for Idle” (polls every 10s) or “Import Anyway” (proceeds immediately with same kill flow)
1. Progress shown per row: waiting → importing spinner → green checkmark
1. On completion: “All done” state, user clicks Close
1. Main window shows all sessions with correct status dots
1. User can close all original terminal windows

### 6.3 New Session

1. User clicks `+ New Session` in sidebar or popover
1. Native `NSOpenPanel` folder picker opens
1. User selects a directory
1. If directory already tracked → alert: “This directory already has an active session”
1. The **New Session sheet** opens on the main window (from the popover, the main window is brought up first to host it), seeded from the Settings default launch config (5.5). It collects: the session name (blank → Claude’s AI title); the **permission mode** as a visible `Picker` (the one knob people vary per session); and, behind a collapsed **Advanced** disclosure, the model, additional directories (`--add-dir`, via `NSOpenPanel`), and extra arguments (a free-text field split on spaces into argv tokens). Bypass modes are absent from the picker when CCorn runs as root. Cancel aborts; Start Session proceeds.
1. CCorn creates a new tmux window (sanitize the folder name, capture the window ID): `tmux new-window -t ccorn -n <sanitized-folder> -c <directory> -P -F "#{window_id}"`, appending `-2`/`-3` on name conflict. Target this window by its `@N` ID afterward (see Window Naming and Identity)
1. Runs `claude --rc "<title>" <launch-config flags>` in that window, every flag token shell-quoted (the command is typed into and evaluated by the pane shell). The launch config is persisted on the session record, because the CLI does NOT keep these flags across `--resume`: a restart re-applies the stored config, or the session silently drops to its default posture. Bypass (`--dangerously-skip-permissions`) is launch-time only (there is no mid-session toggle from CCorn) and is re-applied on every restart; it is never emitted alongside `--permission-mode`. If a Bypass launch is refused (e.g. under root/sudo, where `claude` exits immediately), the failed-start alert leads with the CLI’s own refusal line rather than the generic “no process appeared”.
1. Captures the session's PID for liveness and kill (see PID Tracking)
1. Confirms remote control is active by detecting the `Remote Control active` footer string in the captured pane, or a `bridge-session` record in the session's JSONL
1. Session appears in list immediately with green dot
1. If remote control does not become active within the 30s grace (no `Remote Control active` string and no `bridge-session` record) → the row presents No-remote: amber warning triangle plus the "No remote" word (see Section 4)

### 6.4 Open Session (row click)

1. User clicks a session row in the popover (single click) or double-clicks a row in the main window
1. The handoff follows the **click action** in Settings (5.5):
   - Terminal (default) → attach to the session’s tmux window (6.5). A stopped session has no window, so it is restarted first (resume, flow 6.7, including the missing-dir/missing-transcript dialogs) and the fresh window opened in Terminal. An unmanaged (discovered) row has no window either, so it is imported (adopted) first (flow 6.10, including the take-over confirm and the wait-for-idle guard) and the fresh managed window opened in Terminal. An archived row with no window falls back to the browser
   - Browser → open the session in the default browser: the per-session deep link `https://claude.ai/code/<bridgeSessionId>` when the registry handle is known, else `https://claude.ai/code` (the session list, selected by the title CCorn set)
1. The explicit context-menu items override the preference: “Open in Terminal” always attaches (6.5); “Open in Browser” deep-links to the session (falling back to the list), and is greyed out (tooltip “Remote control is not active on this session”) when remote control is not active on the session

### 6.5 Open Session in Terminal

1. User activates the session (row click/double-click) or clicks “Open in Terminal” in the `...` menu
1. **One terminal per session.** If a terminal is already open for this session (a live `ccorn-view-<window-id>` client exists) CCorn raises and focuses that Terminal window instead of opening another. The window is found by matching tmux’s `client_tty` to Terminal’s `tty of tab` (they are byte-for-byte identical). The raise must resolve the window id and address `window id <id>`, using `set index … to 1` to reorder it to the front; setting `frontmost`/`index` on a `repeat`-loop window reference silently no-ops when other Terminal windows are open. If the user has since closed the terminal there is no client (`destroy-unattached` reaped the view), so CCorn opens a fresh one. A restart/import attaches to a new window id with no view yet, so it always opens fresh.
1. Otherwise App opens Terminal via osascript, attaching through a per-terminal grouped **view** session (its own current window + active pane) rather than the shared `ccorn` session directly, so multiple open terminals don’t mirror each other’s window switching or share keystrokes (Window Naming and Identity has the exact command and rationale)
1. New terminal window opens, showing that session’s tmux window
1. User interacts directly in terminal: switching windows or typing affects only this terminal
1. User closes terminal window: the view session is reaped (`destroy-unattached`), the underlying session stays alive in tmux, and CCorn continues tracking

### 6.6 Stop Session

Stop is recoverable, not destructive: it ends the running process but keeps the
session in the list as Stopped, restartable via flow 6.7. The UI verb is "Stop"
because the outcome is a parked session; the engine still performs a literal
kill (SIGTERM → SIGKILL) as the mechanism.

1. User clicks “Stop Session” in `...` menu
1. Confirmation alert appears: “Stop [name]? The session will stop but stay in your list. You can restart it anytime.” Stop (default, Return confirms) / Cancel (Escape backs out)
1. User confirms
1. CCorn persists a Stopped record (UUID, path, title) so the row survives as Stopped and can be restarted
1. CCorn kills the tmux window by ID: `tmux kill-window -t <window-id>` (see Terminating a Session for the full SIGTERM/SIGKILL fallback)
1. If the underlying `claude` process is still running after window kill: send `SIGTERM` to the PID first, wait 5 seconds, then `SIGKILL` if still running
1. Row updates to stopped state (empty circle)

### 6.7 Restart Dead Session

1. User clicks “Restart Session” in `...` menu on a dead session
1. CCorn gets session ID from `~/.claude/projects/<encoded-path>/*.jsonl`: read most recent file, find `sessionId` field
1. If session ID not found → alert: “Couldn’t find session data. Start a new session in this directory instead?”
1. If directory no longer exists → alert: “The project directory no longer exists.”
1. If a tmux window for this project still exists (a crashed session often leaves its window and shell), reuse it (respawn in place) or kill it first; only create a new window if none exists, to avoid an orphaned dead window plus a `-2` duplicate. Otherwise: `tmux new-window -t ccorn -n <sanitized-name> -c <directory> -P -F "#{window_id}"` (store the returned window ID; see Window Naming and Identity)
1. Runs `claude --resume <uuid> --rc`: resumes session with remote control enabled
1. Confirms remote control is active (footer string or `bridge-session` record; liveness is signal-based, not URL-based)
1. Row updates to green dot

### 6.8 Rename Session

1. User clicks “Rename” in `...` menu
1. Session name in row becomes inline editable text field
1. Text pre-selected
1. User types new name
1. Enter → sends `/rename <new-name>` followed by a separate `Enter` key via `tmux send-keys`, watches pane output for 3 seconds for error response. If no error → row returns to normal with new name. If duplicate name error detected → show inline red error below row, field stays editable.
1. Escape → cancels, no changes
1. Empty + Enter → cancels, no changes
1. On duplicate name error from Claude Code → inline red error below row

### 6.9 Archive Session

1. User clicks “Archive” in `...` menu
1. If session is stopped or dead → archives immediately, no confirmation
1. If session is running → show confirmation alert: “This session is still running. Archive and stop it?” Cancel / Archive. Comparable in weight to the Stop confirmation; archive implies done, but worth one prompt since it stops a live session.
1. User confirms (or session already stopped) → CCorn kills the tmux window (SIGTERM → 5s → SIGKILL on PID)
1. Session record moved to archived state
1. Row disappears from All Sessions
1. Appears in Archived view with empty circle dot and muted text
1. To unarchive: click “Unarchive” in `...` menu → moves back to All Sessions as stopped state

### 6.10 Import Single Unmanaged Session

1. User triggers adopt on an unmanaged row: “Import Session” or “Open in Terminal” in the `...` menu, or a row click in Terminal click-action mode (flow 6.4). All three land here; “Open in Terminal” and the row click also attach the fresh window at the end
1. Alert: “CCorn will take over this session. Your existing terminal window will stop working. Continue?” Cancel / Import
1. User confirms
1. Wait-for-idle guard (shared with the first-run sheet, flow 6.2): if the session is mid-task (a live external `claude` plus transcript writes in the last two minutes), warn: “Claude is mid-task … Wait for Idle / Import Anyway”. “Wait for Idle” polls every 10s and proceeds once it goes quiet, so the SIGTERM → resume doesn’t cut off an in-flight turn; “Import Anyway” proceeds immediately. An already-idle session skips this step. Rapid re-triggers on the same session are ignored while one adopt is in flight
1. CCorn reads session ID from `~/.claude/projects/` JSONL files: most recent entry for that project path
1. Find the PID of the unmanaged `claude` process for this directory. `ps` does not expose a process's working directory, so match by cwd using `lsof -p <pid> -d cwd` (or libproc) against each candidate `claude` process; do not match the directory from `ps` output alone (see Process Identification)
1. Sends `SIGTERM` to existing process PID, waits 5 seconds, sends `SIGKILL` if still running
1. Creates new tmux window: `tmux new-window -t ccorn -n <folder-name> -c <directory>`
1. Runs `claude --resume <uuid> --rc`: resumes with remote control enabled
1. Confirms remote control is active (footer string or `bridge-session` record; liveness is signal-based, not URL-based)
1. Row updates: unmanaged badge removed, dot fills to correct state
1. If triggered via “Open in Terminal” or a row click, the fresh managed window opens in Terminal (flow 6.5)
1. User closes old terminal window

### 6.11 Auto-Restart on Launch

- If “Auto-restart sessions on launch” toggle is enabled in settings
- On app launch: finds all sessions in stopped or dead state
- Sequentially restarts each: reads session ID from JSONL, runs `claude --resume <uuid> --rc` in correct directory
- Confirms remote control becomes active for each (footer string or `bridge-session` record)
- Shows progress: dot animates from empty circle to green as each restarts

-----

## 7. Key Technical Decisions

### Why tmux as backbone

- Sessions survive terminal window closure
- Multiple sessions in one place: one `ccorn` tmux session, many windows
- `tmux send-keys` enables programmatic interaction (sending `/rename`, monitoring for output patterns, re-enabling remote control on running sessions, etc.)
- `tmux attach` gives user raw terminal access when needed
- Well-understood, stable, widely installed on Mac via Homebrew

### Why watch directories scope discovery

- Watch directories let the user control which projects CCorn surfaces, instead of showing every project that has ever had a session.
- More intuitive: the user decides what the app sees.
- Honest caveat: discovery still depends on Claude Code internal structure (`~/.claude/projects/`, the JSONL `cwd`/`sessionId` fields, the path-encoding scheme, `~/.claude.json`). If Anthropic changes these, resume, restart, import, and discovery can break. Watch directories reduce coupling for *filtering*, not for the underlying reads.

### Why sequential import not parallel

- Prevents race conditions on `~/.claude/projects/` file reads
- Prevents tmux window naming conflicts
- Prevents remote control registration collisions
- User can see clear progress per session

### Remote control strategy

- All new sessions CCorn starts use the `claude --rc` flag directly; all resumed/imported sessions use `claude --resume <uuid> --rc`. This is the reliable path and is fully under CCorn's control.
- A per-session URL exists (RC ≥ 2.1.162: `claude.ai/code/session_<id>`), and its `session_…` id is the registry `bridgeSessionId`, so "Open in Browser" deep-links to it and falls back to `https://claude.ai/code` (find by title) only when the handle hasn't surfaced. Remote-control liveness is the `Remote Control active` footer string or the JSONL `bridge-session` record. (Do not use the transcript record's `cse_…` id for the URL.)
- A global "enable for all sessions" toggle exists but has a known reset bug, and the underlying config key is undocumented. Do not depend on it; rely on per-session `--rc`, which CCorn controls.
- Remote control has a ~10-minute network timeout after which the process exits. CCorn does not re-enable a timed-out session; it detects the process death and offers Restart (see Remote Control in Section 2).

### Session naming

- Uses Claude Code’s native `/rename` command (added in v2.0.64)
- Name is consistent across CCorn, claude.ai/code, and Claude mobile app
- No local nickname system; single source of truth
- The title is the handle a remote user needs to find the session in the claude.ai/code list, the fallback whenever the per-session deep link isn't available (see Remote Control in Section 2). Set it at session start with `claude --rc "<title>"` rather than relying on a follow-up `/rename`.

### FSEvents for directory watching

- Watches the user-specified directories and `~/.claude/projects/` in real time.
- A new `~/.claude/projects/` subdirectory or `*.jsonl` whose `cwd` is inside a watch directory: the session surfaces in the list. A `.claude/` folder appearing inside a project is not a session signal and is ignored.
- A removed `~/.claude/projects/` entry: the session is no longer discoverable and drops from the list. This is not Dead; deleting history does not kill a running process, and process death is detected separately by PID (see Session States).
- No polling needed for discovery; it is event-driven. State detection still polls pane output (see Session States).

### tmux not installed

- Detected on first launch via `which tmux`
- If missing: one-time alert “CCorn requires tmux. Install it with Homebrew?”
- “Install” button runs `brew install tmux` in a visible terminal
- App waits for installation before proceeding

-----

## 8. Edge Cases & Error Handling

|Scenario                                       |Behavior                                                                                                                                                                                                    |
|-----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|tmux not installed                             |One-time alert with Install via Homebrew button                                                                                                                                                             |
|Homebrew not installed                         |Alert: “Visit brew.sh to install Homebrew first, then relaunch CCorn”                                                                                                                                       |
|`claude` binary not in PATH                    |Alert: “Claude Code is not installed” with link to installation docs                                                                                                                                        |
|Watch directory doesn’t exist                  |Skip silently on scan, remove from settings list                                                                                                                                                            |
|Session directory deleted or moved             |Show error on restart: “Project directory not found”                                                                                                                                                        |
|Remote control fails to activate within 30s    |Row presents No-remote: the amber warning triangle replaces the dot, "No remote" word after the title (Section 4)                                                                                           |
|Remote control activation fails with auth error|Alert: “Remote Control is available on Pro, Max, Team, and Enterprise plans (Team/Enterprise need an admin to enable it); API keys and inference-only tokens are not supported.”                                                                                                              |
|Remote control lost: sustained ~10min outage    |Process has exited (the timeout kills the process). Detection marks it Dead via PID; recover with Restart (`claude --resume <uuid> --rc`). Do not send `/rc` to a timed-out session, nothing is there to receive it. Short drops reconnect on their own (see Remote Control in Section 2).|
|User not authenticated with Claude Code CLI    |Detect by checking pane output for login prompts after starting session. Show alert: “Authenticate Claude Code first: run `claude` then `/login` (or `claude auth login`), and unset ANTHROPIC_API_KEY. Surface the CLI's own error text rather than a hard-coded string.”                                                |
|Kill command fails (SIGTERM)                   |Force SIGKILL after 5 second timeout; applies to session kill, archive kill, and import kill                                                                                                               |
|Session ID not found in JSONL files            |Alert: “Couldn’t find session data. Start a new session?”                                                                                                                                                   |
|Duplicate watch directory                      |Silently ignored                                                                                                                                                                                            |
|Same project in two watch directories          |Deduplication by absolute path; shows once                                                                                                                                                                 |
|New `.claude` folder in watched directory      |Auto-surfaces in session list via FSEvents                                                                                                                                                                  |
|Rename to duplicate name                       |Inline red error below row, field stays editable                                                                                                                                                            |
|Import of actively-working session             |Pause import, show warning: Wait for Idle or Import Anyway                                                                                                                                                  |
|User adds directory with no sessions           |Empty state shown, no error                                                                                                                                                                                 |
|App quit with sessions running                 |Sessions continue running in tmux; that’s the point                                                                                                                                                        |
|Machine reboots                                |tmux and sessions die. tmux-resurrect not included in v1; note for future                                                                                                                                  |
|Remote control not active on session           |No-remote presentation (amber triangle + word); Open in Browser greyed out                                                                                                                                  |
|Active session during first run import         |Pause on that session, show warning alert                                                                                                                                                                   |
|`ccorn` tmux session already exists on launch  |Detected via `tmux has-session -t ccorn`; attach to existing, do not recreate                                                                                                                              |
|~/.claude.json doesn’t exist                   |No action needed. CCorn does not write a global remote-control key (none is documented); it uses `--rc` per session.                                                                                                                                                           |
|~/.claude.json exists with other content       |Read existing JSON, merge key, write back; never overwrite entire file                                                                                                                                     |
|tmux window name conflict                      |Append `-2`, `-3` etc. to window name until unique                                                                                                                                                          |
|Per-session URL not yet available               |Expected while remote control is still activating: the registry `bridgeSessionId` is a positive-only signal, so "Open in Browser" falls back to the session list (claude.ai/code, found by title) until the handle surfaces, then deep-links. Liveness uses the `Remote Control active` string or the `bridge-session` JSONL record                                                                                                                          |
|Ultraplan started in a session                 |Starting an ultraplan session disconnects that session's remote control (both use the claude.ai/code surface). Surfaces as an RC drop; do not treat as an error.|
|Remote-only picker commands run locally        |`/mcp`, `/plugin`, `/resume` open interactive pickers and work only from the local terminal, not browser/mobile. Not CCorn's concern, but relevant if scripting against a session.|
|Session idle-archived while process alive      |Separate from the network timeout: after ~10-15 min idle even on a stable network, the remote session can be archived server-side while the local `claude` process keeps running. PID-based detection correctly keeps it out of Dead (shows Running/Stale); note that "Open in Browser" may land on an archived session until a new message reactivates it.|

-----

## 9. CLAUDE.md

> This file goes in the root of the ccorn repo. Keep it under 200 lines.

```markdown
# CCorn: Claude Code Session Manager

## What this is
Native macOS menu bar app. Swift/SwiftUI. Manages Claude Code sessions in tmux.
Process manager only; no chat interface.

## Stack
- Swift + SwiftUI, macOS 13+ target
- tmux as process backbone (single session named `ccorn`, one window per CC session)
- NSStatusItem + NSPopover for menu bar
- FSEvents for directory watching
- NSOpenPanel for folder picking

## Key files to understand first
- `CCORN_SPEC.md`: full spec, read this before writing any code

## Architecture rules
- Spawned commands need a resolved PATH (GUI apps do not inherit the shell PATH): run via a login shell or absolute paths. App Sandbox must be OFF or exec/FSEvents/AppleEvents are blocked (see CCORN_SPEC.md Process Execution Environment)
- Every Claude Code session runs in a tmux window inside the `ccorn` tmux session; for programmatic commands (send-keys, capture-pane, kill-window, rename-window) target the captured window ID (`@N`)/`@ccorn_id` tag, resolving any name to its ID first
- Primary session discovery is `~/.claude/projects/` (resolve real paths via the JSONL `cwd`); do NOT rely on a project-local `.claude/` folder existing
- Never hardcode session IDs: read from ~/.claude/projects/ (the JSONL filename is the session UUID)
- Always enable remote control via the `--rc` flag on sessions CCorn starts or restarts
- Use `tmux send-keys` for all programmatic interaction; send the key as a separate `Enter` argument, never an embedded `\n`
- Use FSEvents not polling for directory watching
- On launch, reconcile with existing tmux windows (re-derive PIDs and state; prior-run runtime values are meaningless)

## Design rules
- Zinc neutral color palette; see CCORN_SPEC.md section 3 for exact hex values
- Use SwiftUI semantic colors (Color.primary, Color.secondary, Color(.separatorColor), Color(.windowBackgroundColor)) for ALL main window UI; never hardcode hex in the main window
- Hardcoded hex only in the menu bar popover (always dark, semantic colors would be wrong there)
- SF Pro Text only, SF Mono for directory paths via .monospaced()
- Two font weights only: regular (400) and medium (500)
- 0.5px borders only; never 1px
- No shadows, no gradients, no decorative elements
- Status dots are the only color in the app
- Menu bar popover is fixed dark (#09090B) regardless of system appearance
- Main window follows system appearance automatically via semantic colors

## Activation policy
- Default: NSApplicationActivationPolicyAccessory (no Dock, no Cmd+Tab)
- When main window opens: switch to NSApplicationActivationPolicyRegular
- When main window closes: switch back to NSApplicationActivationPolicyAccessory
- Do NOT use LSUIElement = YES; prevents dynamic policy switching

## SwiftUI notes
- Use .listStyle(.sidebar) for sidebar; do not hardcode row heights
- Use Settings scene for preferences window; do not build a custom window
- Use NSMenu for context menus; not custom SwiftUI menus
- Use native NSOpenPanel for folder picking
- Do not put NavigationStack inside Settings scene; it breaks

## tmux commands
- Check session exists: `tmux has-session -t ccorn` (exit 0 = exists, only create if not)
- New session: `tmux new-session -d -s ccorn`
- New window: `tmux new-window -t ccorn -n <name> -c <directory>`
- New Claude session: `tmux send-keys -t <window-id> "claude --rc" Enter`
- Resume session: `tmux send-keys -t <window-id> "claude --resume <uuid> --rc" Enter`
- Capture output (visible frame; alt-screen TUI has no scrollback, so no `-S`): `tmux capture-pane -t <window-id> -p`
- Kill window: `tmux kill-window -t <window-id>`
- List windows: `tmux list-windows -t ccorn` (check for name conflicts)
- Attach (Open in Terminal): `osascript` runs `tmux attach -t ccorn` then selects the target window by `<window-id>` (escape any window name used)

## Remote control
- Do NOT write a global remote-control key to ~/.claude.json (no documented key exists; the control is the `/config` toggle / Desktop setting). Rely on the `--rc` flag per session, which CCorn controls.
- New sessions: use `claude --rc` flag; do NOT use separate `/rc` send-keys
- Resumed/imported sessions: use `claude --resume <uuid> --rc`
- Detect RC-active via the `Remote Control active` footer string (capture-pane) or a `bridge-session` record in the session JSONL
- "Open in Browser" deep-links to `https://claude.ai/code/<bridgeSessionId>` (the registry `session_…` handle, RC ≥ 2.1.162), falling back to `https://claude.ai/code` (find by title, set via `claude --rc "<title>"`) until the handle surfaces
- Process kill: SIGTERM first, wait 5s, SIGKILL if still running

## Build order (recommended)
1. Menu bar icon + basic popover shell
2. tmux session management (create, list, kill); check has-session before creating
3. Watch directory scanning + FSEvents
4. Session discovery and status detection (pane capture polling every 3s)
5. Main app window: sidebar + list view
6. New session flow (claude --rc "<title>", RC-active detection)
7. Import/resume session flow (SIGTERM/SIGKILL, claude --resume --rc)
8. Remote-control-active detection (footer string / bridge-session record; signal-based, not URL-based)
9. Context menu actions
10. Rename inline interaction
11. Settings screen (with remove directory warning)
12. Onboarding screen
13. First run import sheet: all four states
14. Empty states
15. Notifications (local, on Waiting/Dead) + menu bar status indicator
16. Polish: animations, error states, edge cases
```

-----

## 10. Build Order

Build in this order for early testability. Each phase should be runnable and testable before moving to the next.

**Phase 1: Shell (day 1)**

- Menu bar icon appears immediately on launch
- Activation policy: `NSApplicationActivationPolicyAccessory` by default
- Basic popover opens and closes
- “Open CCorn” opens a blank main window, switches to `NSApplicationActivationPolicyRegular`, switches back on close
- tmux session `ccorn` created on launch if not exists (check `has-session` first)
- tmux not installed → alert + Homebrew install prompt
- `claude` binary not in PATH → alert with link to installation docs

**Phase 2: Discovery (day 1-2)**

- Hardcode a watch directory that exists on the build machine (e.g. `~/dev/` or wherever Claude Code projects live during development) as a placeholder for phases 2-4. This is replaced by the real onboarding flow in Phase 5. If `~/dev/` doesn’t exist, use any directory containing a `.claude` folder.
- Scans for `.claude` folders in hardcoded directory
- Cross-references with the running-process list (see Process Identification) to mark live sessions
- PID discovery for each session via the shell pane PID (see Process Identification)
- Sessions appear in main window list with correct state dots
- FSEvents watching; new sessions auto-appear

**Phase 3: Core actions (day 2-3)**

- New session flow: folder picker → tmux window → `claude --rc "<title>"` → RC-active detection
- Kill session: confirmation → SIGTERM → SIGKILL fallback → dot updates
- Restart session: resume by ID → `claude --resume <uuid> --rc` → RC-active detection → dot updates
- Open in Terminal: osascript tmux attach
- Open in Browser: deep-links to `claude.ai/code/<bridgeSessionId>` (registry `session_…` handle), falling back to claude.ai/code (find by title) until the handle surfaces

**Phase 4: Import flow (day 3-4)**

- Unmanaged session detection
- Single session import from context menu
- First run import sheet: all four states
- Active session warning alert

**Phase 5: Polish (day 4-5)**

- Real onboarding screen (replaces hardcoded directory from Phase 2)
- Remote-control-active detection (per-session `--rc`; there is no global auto-enable)
- Rename inline interaction
- Archive/unarchive
- Settings screen
- Empty states
- Menu bar status indicator. The icon is a monochrome template image (macOS controls its color), so it cannot also carry a colored status dot without breaking template rendering. Choose one: keep the icon pure template and show the aggregate status dot only in the popover header (default), or render a custom non-template status image. There is no Dock badge: the app is `.accessory` with no Dock icon.
- Stale session detection (SHA256 hash comparison)
- All error states and edge cases

-----

## 11. What’s Out of Scope for v1

- App Store distribution (not viable for CCorn anyway: App Store apps must run sandboxed, and CCorn requires the App Sandbox off)
- Code signing and notarization for distribution. v1 ships **ad-hoc signed** ("Sign to Run Locally"), which runs only on the build machine; a downloaded ad-hoc app is Gatekeeper-blocked on other Macs. For online distribution later, the path is a **Developer ID Application** certificate plus **notarization** (`xcrun notarytool submit`, then `xcrun stapler staple`), shipped as a zip or dmg so it opens cleanly on download. The release build differs from the dev build only by enabling **Hardened Runtime** (required for notarization) and adding the `com.apple.security.automation.apple-events` entitlement for Terminal automation. This is a release step done after the app works, fully scriptable from the CLI.
- Multiple user accounts
- Team/Enterprise features
- Windows or Linux support
- In-app chat interface
- Session search or filtering
- tmux-resurrect integration (power loss recovery)
- Pricing or licensing
- Analytics or telemetry

-----

*Last updated: June 2026*  
*This document is the source of truth. When in doubt, refer here.*