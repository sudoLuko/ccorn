<div align="center">

<img src="docs/images/ccorn-icon.png" width="88" alt="CCorn, OpenMoji ear-of-corn app icon" />

# CCorn

**Spin up a Claude Code session per task. Close any of them. Get back to all of them.** Right in the macOS menu bar.

[![license MIT](https://img.shields.io/badge/license-MIT-71717A?style=flat-square)](LICENSE)
&nbsp;![macOS 13+](https://img.shields.io/badge/macOS-13%2B-71717A?style=flat-square&logo=apple&logoColor=white)
&nbsp;[![latest release](https://img.shields.io/github/v/release/sudoLuko/ccorn?style=flat-square&color=16a34a&label=release&cacheSeconds=3600)](https://github.com/sudoLuko/ccorn/releases)

</div>

Once you can close a Claude Code session and trust you'll get it back, you stop hoarding context in a few long-lived sessions and start spinning up an agent per task. CCorn makes that safe: every session is a durable tmux window you can close, reopen, and resume without losing the conversation, one `tmux attach` away. And when a dozen are running, the menu-bar popover triages the fleet so the one stuck on a permission prompt floats to the top instead of going unnoticed.

CCorn is a native macOS menu-bar app that starts, watches, and controls [Claude Code](https://claude.com/claude-code) sessions running in tmux, built for developers who keep many sessions going in parallel.

It is a process manager, not a chat interface. The model, your prompts, and the conversation all stay in Claude Code. You keep working in your terminal, at claude.ai/code, or on your phone, and CCorn keeps the fleet running.

## See it in action

<div align="center">

<img src="docs/images/demo.gif" width="300" alt="CCorn menu-bar popover: a session goes from working to needs-input to ended and back to calm, the popover header reflecting the most urgent state">

*The menu-bar popover, live. A session moves from working (blue) to needs-input (amber) to ended (amber) and back to calm; the popover header always carries the single most urgent mark across every session.*

</div>

## What it does

- **Close it and come back.** Each session is its own tmux window inside a single `ccorn` tmux session, so you can close CCorn, restart your Mac, or just walk away and still resume right where you left off. Sessions survive restarts, and your real terminal is always one `tmux attach` away. Open any session in Terminal in one click; CCorn raises the window if it is already up.
- **Discovery and takeover.** Finds Claude Code sessions already running on your Mac and adopts them under management, resuming the same conversation without losing work.
- **Worst-first triage.** Click the menu-bar corn and the popover sorts every session by urgency: sign-in, no-remote, waiting, and ended sessions rise to the top, while the calm ones fold behind a single "all clear" line. The header shows one aggregate mark for the whole fleet.
- **One mark per row.** Every session shows exactly one status mark, a colored dot or a single warning triangle, so you read state by glancing at color, never by parsing text.
- **Set and forget.** CCorn launches and supervises; you drive. Keep working in your terminal, at claude.ai/code, or from your phone over Remote Control. CCorn never touches the conversation, and it does not set the model (you pick that in Claude Code with `/model`).
- **Native macOS restraint.** A menu-bar app with no Dock icon by default, no chat window, and no color anywhere except the status marks. Notifications ping you when a session needs input, needs sign-in, or ends.

<div align="center">

<img src="docs/images/main-window-demo.gif" width="760" alt="CCorn main window: sessions flipping between working, needs-input, signed-in, and restarted as a new one slides in and an old one is cleared">

*The main window. Sessions flip between working, needs-input, and healthy in real time as a new one slides in and an old one is cleared, all in one list with rename, group, archive, remove, stop, restart, and import.*

</div>

## Status colors

Status marks are the only color in CCorn. Every row shows exactly one mark, a colored dot for routine states or a single warning triangle for the broken trio (sign-in, no-remote, ended). That is the whole product: glance at the colors, know the state.

| Swatch | State | Mark | Label | What it means |
|:------:|-------|:----:|-------|---------------|
| ![green](https://placehold.co/15x15/16a34a/16a34a.png) | **Running** | ● | | Alive, remote control active, healthy |
| ![blue](https://placehold.co/15x15/2563eb/2563eb.png) | **Working** | ● | | Claude is executing mid-task |
| ![amber](https://placehold.co/15x15/f59e0b/f59e0b.png) | **Waiting** | ◉ | Needs input | Claude is waiting for input or approval |
| ![slate](https://placehold.co/15x15/64748b/64748b.png) | **Stale** | ● | | Idle past your threshold |
| ![amber](https://placehold.co/15x15/f59e0b/f59e0b.png) | **Sign in** | ▲ | Sign in | Login prompt is showing; sign-in needed |
| ![amber](https://placehold.co/15x15/f59e0b/f59e0b.png) | **No remote** | ▲ | No remote | Alive, but remote control is not active past the grace period |
| ![amber](https://placehold.co/15x15/f59e0b/f59e0b.png) | **Ended** | ▲ | Ended | Claude exited; restart it to resume |
| ![grey](https://placehold.co/15x15/a1a1aa/a1a1aa.png) | **Stopped** | ○ | | You stopped it; not running |
| ![grey](https://placehold.co/15x15/71717a/71717a.png) | **Unmanaged** | ○ | | Discovered on your machine, not yet imported |

On a live row the working dot breathes a gentle brightness pulse and the waiting dot emits a slow expanding halo, so activity reads from motion as well as color. The popover header carries the single most urgent mark across everything CCorn manages, so the popover alone tells you whether anything needs you. The menu-bar corn itself is a monochrome glyph that follows the menu bar's appearance. Exact light and dark hex for every token lives in [docs/CCORN_SPEC.md](docs/CCORN_SPEC.md), section 3.

## Requirements

- macOS 13 or later
- [tmux](https://github.com/tmux/tmux) (`brew install tmux`)
- A recent version of the [Claude Code CLI](https://claude.com/claude-code); older versions may not be recognized correctly, because state detection tracks the current CLI's wording (2.1.110+ for mobile push via Remote Control)

## Install

Download the latest build from [Releases](https://github.com/sudoLuko/ccorn/releases), unzip, drag **CCorn.app** to Applications, and open it. Release builds are signed and notarized; if macOS still warns that it cannot verify the developer, right-click the app and choose Open.

On first launch, CCorn walks you through picking the directories it should watch for sessions.

The first time you use **Open in Terminal**, or let the onboarding helper install prerequisites with Homebrew, macOS asks for permission to let CCorn automate Terminal. Both actions simply no-op if you deny it; you can grant it later under System Settings › Privacy & Security › Automation.

## Build from source

```sh
brew install xcodegen
git clone https://github.com/sudoLuko/ccorn.git
cd ccorn
xcodegen generate
xcodebuild -project CCorn.xcodeproj -scheme CCorn -configuration Release build
```

The `.xcodeproj` is generated, so edit `project.yml`, not the project file. A full Xcode install is required (Command Line Tools alone will not build the app bundle). Run the tests with `xcodebuild test -project CCorn.xcodeproj -scheme CCorn -destination 'platform=macOS'`.

## Usage

- **New Session.** Pick a folder; CCorn opens a tmux window there and starts a session with a title you choose (leave it blank to use Claude's own title). Set the permission mode (Default, Plan, Accept Edits, Auto, Allow Bypass, or Bypass; Auto is the default) and whether to enable Remote Control, and under Advanced add extra directories (`--add-dir`) or extra `claude` arguments. The defaults come from Settings. CCorn does not set the model; pick that inside Claude Code with `/model`.
- **Import and take over.** Adopt sessions you started yourself; CCorn resumes them under management, preserving the conversation.
- **Open in Terminal or Browser.** Jump into the live tmux pane, or deep-link to the session at claude.ai/code (falling back to the session list until the remote-control link is ready).
- **Groups.** Organize sessions into user-defined collections in the sidebar.
- **Archive vs Remove.** Archive hides a session reversibly; Unarchive brings it back. Remove from CCorn untracks it for good and stops discovery from re-surfacing it. Neither touches the conversation on disk, so `claude --resume` still works either way.
- **Settings.** Watch directories, new-session defaults (permission mode and remote control), stale threshold, click behavior, launch options, and the full status legend.

## Known limitations

- macOS only, and tmux is required. Sessions live in a tmux session named `ccorn`.
- No chat UI by design. CCorn manages processes; conversations happen elsewhere.
- State detection reads the Claude Code TUI's pane text (polled every 3 seconds), so a CLI update can shift wording before CCorn catches up. The preflight suite in `scripts/preflight/` exists to catch exactly that before releases.
- The App Sandbox is off by design. CCorn spawns `tmux` and `claude`, watches arbitrary directories with FSEvents, and sends AppleEvents to Terminal, none of which a sandboxed app may do.
- "Open in Browser" deep-links to the session via its remote-control bridge id (`claude.ai/code/session_…`); until that id surfaces (remote control still activating, or a local session that has none), it falls back to the claude.ai/code session list.
- Voice input does not work inside managed sessions.
- Copy-mode drag-select auto-scroll is sluggish inside managed sessions.
- Up-arrow prompt history is shared by every session in the same folder. Claude Code keys its input history (`~/.claude/history.jsonl`) by working directory, not by session, so recalling earlier prompts can surface ones typed in another session that ran in the same directory. This is Claude Code's behavior, not cross-session leakage; give a session its own working directory (a git worktree, say) if you want its history isolated.
- CCorn tracks Claude Code's current on-disk layout under `~/.claude`. If a future Claude Code release renames or restructures that, discovery, titles, or deep links could break until CCorn catches up.

## Privacy

CCorn runs entirely on your Mac. It reads session metadata from `~/.claude/`, stores its own state in `~/Library/Application Support/CCorn/`, makes no network requests, and only opens links in your browser.

## More

- [Full build spec](docs/CCORN_SPEC.md): architecture, design language, every screen and flow.

## License

[MIT](LICENSE) covers CCorn's source code.

The app icon is the [ear-of-corn glyph `1F33D`](https://openmoji.org/library/emoji-1F33D/) from [OpenMoji](https://openmoji.org), licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Per ShareAlike, the icon artwork (this adaptation) is itself CC BY-SA 4.0; this applies to the image only and does not affect the MIT-licensed code. Details in [design-assets/app-icon/ICON_CREDITS.md](design-assets/app-icon/ICON_CREDITS.md).
