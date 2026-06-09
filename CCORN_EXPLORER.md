# CCorn: Environment & Runtime Explorer

> Purpose: this is the FIRST session before the CCorn build. Its job is to establish a verified build environment, stand up a known-good empty app shell, and pin down the facts the build spec could not verify on its own. It then writes those findings to `RUNTIME_FINDINGS.md`, which the build session consumes.
>
> **Do not implement any CCorn features in this session.** No session list, no state detection, no discovery, no settings. Only the empty shell and the probes below. Building CCorn happens later, against the shell and findings this session produces.

---

## Deliverables (definition of done)

This session is complete when all three exist and are committed:

1. A generated, building, launchable empty app shell (`project.yml` + `Sources/` + a generated `CCorn.xcodeproj`).
2. `RUNTIME_FINDINGS.md` filled in with real, observed values (template in Part D). Anything you cannot observe is recorded as `UNVERIFIED` with the reason, never guessed.
3. The exact, working `xcodebuild` command, recorded in the findings.

If a step cannot be completed (e.g. `claude` is not logged in, so Remote Control cannot be probed), record that clearly and continue with the rest. A partial-but-honest findings doc is the goal, not a fabricated complete one.

---

## Part A: Environment verification

Run each, record the output verbatim in the findings:

```bash
xcode-select -p          # MUST point at Xcode.app, not /Library/Developer/CommandLineTools
xcodebuild -version      # record Xcode version + build
sw_vers                  # macOS version of this build machine
swift --version
which tmux && tmux -V
which claude && claude --version   # MUST be >= 2.1.51 for Remote Control; >= 2.1.110 for mobile push
which xcodegen || brew install xcodegen
xcodegen --version
which jq || echo "jq missing (use python/grep fallbacks in Part C)"
```

Gate: if `xcode-select -p` points at CommandLineTools, stop and switch it (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`) before building. CLT alone will not build a SwiftUI app bundle reliably.

If `claude --version` is below 2.1.51, record it and note that the Remote Control probes in Part C will not be meaningful on this version.

---

## Part B: Generate and verify the empty app shell

The files below are a strong starting point, not gospel. Generate, build, and run them. If anything fails to compile or build (Swift version differences, a signing or scheme issue, an XcodeGen schema change), **fix it, get it building and launching, and record the final working versions** in the findings. The point of this part is to end with a shell that is proven to compile and run as a menu-bar app, plus the exact config that achieved it.

### `project.yml`

```yaml
name: CCorn
options:
  deploymentTarget:
    macOS: "13.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.0"            # match the installed Xcode; bump if needed
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"         # ad-hoc ("Sign to Run Locally"); no team required
    DEVELOPMENT_TEAM: ""
    ENABLE_HARDENED_RUNTIME: NO     # not needed locally; notarization is out of scope
targets:
  CCorn:
    type: application
    platform: macOS
    sources:
      - path: Sources
    # No CODE_SIGN_ENTITLEMENTS and no App Sandbox capability on purpose.
    # App Sandbox OFF is required so the app can spawn tmux/claude/ps/lsof,
    # watch arbitrary directories with FSEvents, and send AppleEvents to Terminal.
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: studio.ccorn.app   # CHANGE to your preferred stable id
    info:
      path: Sources/Info.plist
      properties:
        CFBundleDisplayName: CCorn
        LSMinimumSystemVersion: "13.0"
        # NSAppleEventsUsageDescription is the TCC string shown the first time the
        # app automates Terminal. Keep it even in the shell.
        NSAppleEventsUsageDescription: "CCorn opens your Claude Code sessions in Terminal."
        # Deliberately NO LSUIElement. The app starts as .accessory at runtime
        # (see the build spec's activation-policy decision), which keeps the dynamic
        # .accessory <-> .regular switch working. A brief Dock-icon flash at launch
        # is expected and acceptable.
schemes:
  CCorn:
    build:
      targets:
        CCorn: all
    run:
      config: Debug
```

### `Sources/CCornApp.swift`

```swift
import SwiftUI

@main
struct CCornApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A Settings scene gives SwiftUI a valid Scene to host. The menu bar item
        // and popover are owned by the AppDelegate. No main WindowGroup on purpose:
        // this is a menu-bar app.
        Settings {
            SettingsPlaceholderView()
        }
    }
}
```

### `Sources/AppDelegate.swift`

```swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as an accessory (menu-bar) app. The real app will switch to
        // .regular when it opens a window, then back. See the build spec.
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "circle.grid.2x2",
                                accessibilityDescription: "CCorn")
            image?.isTemplate = true   // template so macOS tints it for light/dark menu bar
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 220)
        popover.contentViewController = NSHostingController(rootView: PopoverPlaceholderView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
```

### `Sources/Placeholders.swift`

```swift
import SwiftUI

struct PopoverPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("CCorn")
                .font(.headline)
            Text("Shell is running. No features yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        Text("Settings placeholder")
            .padding(40)
    }
}
```

### Build and verify

```bash
xcodegen generate
xcodebuild -project CCorn.xcodeproj -scheme CCorn -configuration Debug \
  -derivedDataPath ./build build
open ./build/Build/Products/Debug/CCorn.app
```

Verification:

- The build must succeed. Capture any errors and the fixes you made.
- The app must launch without crashing. Confirm the process is alive: `pgrep -fl CCorn`.
- A menu-bar icon (the four-square symbol) should appear in the status bar, and clicking it should open the small popover. This last check is visual; if you cannot confirm it programmatically, note in the findings that build + launch succeeded and that the icon needs a human glance.
- Note on signing: if `xcodebuild` fails on code signing, first try keeping `CODE_SIGN_IDENTITY: "-"`. As a last resort for the shell only, you may add `CODE_SIGNING_ALLOWED=NO` to the build command, but record that the real app wants ad-hoc signing (identity `-`) so notifications, login-item registration, and Terminal automation work.

Reminder for the build session: XcodeGen re-globs `Sources/` on every run, so after adding new Swift files, run `xcodegen generate` again before building. Adding files needs no manual project edits; adding a capability, framework, SwiftPM dependency, or a new target IS a `project.yml` edit (this is the tradeoff we accepted by using XcodeGen).

---

## Part C: Probe the runtime unknowns

These are the facts the build spec flags as unverified. Each has a fallback in the spec, but real values are better. Record every result verbatim.

**Prerequisite:** Remote Control needs an authenticated claude.ai account. Check with `claude` then `/status` (or just attempt the probe). If not logged in, run `claude` and `/login` (or `claude auth login`, and unset `ANTHROPIC_API_KEY` if set). If you cannot authenticate, mark the Remote Control probes (C1, C2) `UNVERIFIED (not authenticated)` and still do C3-C5.

### Setup: start one real Remote Control session in tmux

```bash
mkdir -p /tmp/ccorn-probe
# Accept workspace trust once if prompted (run `claude` here interactively if needed):
#   (cd /tmp/ccorn-probe && claude)   -> accept trust, then /exit
tmux new-session -d -s ccprobe
tmux new-window -t ccprobe -n probe -c /tmp/ccorn-probe
tmux send-keys -t ccprobe:probe "claude --rc" Enter
sleep 10
tmux capture-pane -t ccprobe:probe -p    # visible frame; this is exactly CCorn's capture model
```

Leave this session running while you do C1-C4, then clean up at the end with `tmux kill-session -t ccprobe`.

### C1: Session URL format

From the captured pane, find the printed session URL. Record it **verbatim** (you can redact the unique id, keep the shape). The build spec assumes `https://claude.ai/code/session_<id>` but does not know the real shape. Report the actual prefix and the id character set so the URL-capture regex can be pinned.

### C2: "Remote control active" indicator text

In the same captured frame, find how the running session signals that Remote Control is active (a line of text, a banner, a status word). Record the exact wording, or note if it is a styled banner with no stable literal string. This is what the Running-state detection keys off (with the captured-URL fallback).

### C3: Is `claude` a native binary or node-wrapped?

While the probe session is running, in a separate shell:

```bash
which claude
readlink -f "$(which claude)"
file "$(readlink -f "$(which claude)")"
ps -axww | grep '[c]laude'      # is the live process 'claude' (native) or 'node .../cli.js'?
pgrep -fl claude
```

Record: native binary vs node wrapper, the exact process name and command line of the running session, and therefore how CCorn should match it (filter `pgrep -P <shell_pid>` children by name `claude`, or match the cli.js path in the argv).

### C4: JSONL transcript layout and session-id check

```bash
ls -la ~/.claude/projects/
# Identify the directory for /tmp/ccorn-probe, then:
ls -laR ~/.claude/projects/<encoded-dir>/
```

Record:
- Whether transcripts are flat `*.jsonl` in that directory, or nested under a `sessions/` subdirectory.
- Whether the JSONL filename equals the session UUID. Confirm:

```bash
f="$(ls -t ~/.claude/projects/<encoded-dir>/*.jsonl 2>/dev/null | head -1)"   # adjust path if nested
basename "$f" .jsonl
head -1 "$f" | jq -r '.sessionId, .cwd'    # or: head -1 "$f" | python3 -c 'import sys,json;d=json.loads(sys.stdin.readline());print(d.get("sessionId"),d.get("cwd"))'
```

Report whether `basename` matches `sessionId`, and the `cwd` value.

### C5: Path-encoding confirmation

Compare the real path `/tmp/ccorn-probe` to its `~/.claude/projects/` directory name. Confirm the rule: every non-alphanumeric char (including `/`, `.`, `_`) becomes a single `-`, with a leading `-`, and it is lossy (not reversible). If you can, also create a probe dir containing a dot or underscore (e.g. `/tmp/ccorn.probe_2`), run `claude` there briefly, and record how it encodes. Reaffirm in the findings: CCorn resolves real paths via the JSONL `cwd`, never by decoding the directory name.

### C6: Config location (low priority, do not write anything)

```bash
ls -la ~/.claude.json ~/.claude/settings.json 2>/dev/null
```

Just record where config lives. **Do not write a global Remote Control key.** The build spec relies on the per-session `--rc` flag, which CCorn controls; the global toggle is `/config` only and is not something CCorn should script.

Cleanup: `tmux kill-session -t ccprobe`.

---

## Part D: Write `RUNTIME_FINDINGS.md`

Create this file at the repo root with the real values. This is the handoff to the build session.

```markdown
# CCorn Runtime Findings

> Produced by the explorer session on <date>. Feeds the CCorn build.

## Environment
- xcode-select path: <...>
- Xcode version: <...>
- macOS: <...>
- Swift: <...>
- tmux: <...>
- claude --version: <...>   (RC requires >= 2.1.51; mobile push >= 2.1.110)
- xcodegen: <...>
- jq present: <yes/no>

## App shell
- Status: <builds and launches / issues>
- Final working build command:
  `xcodebuild -project CCorn.xcodeproj -scheme CCorn -configuration Debug -derivedDataPath ./build build`
- Built app path: ./build/Build/Products/Debug/CCorn.app
- Menu-bar icon confirmed: <yes / needs human glance>
- Changes made to the starter project.yml or sources: <list, or "none">
- Final project.yml: <paste if it changed from the starter>

## Runtime facts
- C1 session URL format (verbatim, id redacted): <...>
- C2 remote-control-active indicator: <exact text, or "styled banner, no stable literal">
- C3 claude process shape: <native 'claude' / node wrapper>; running cmdline: <...>; CCorn match rule: <...>
- C4 JSONL layout: <flat *.jsonl / nested under sessions/>; filename == sessionId: <yes/no>; example cwd: <...>
- C5 path encoding: <real path> -> <encoded dir>; lossy confirmed: <yes/no>; resolve via cwd: confirmed
- C6 config location: <...>  (no global RC key written)

## Anything UNVERIFIED and why
- <...>
```

---

## Guardrails

- Build nothing from the CCorn feature spec in this session. Empty shell only.
- Do not write a global Remote Control key anywhere. Use `--rc` per session (that decision is final).
- Never decode `~/.claude/projects/` directory names into paths; resolve via the JSONL `cwd`.
- If a probe is blocked (auth, version, environment), record `UNVERIFIED` with the reason. Do not invent values.
- Keep `RUNTIME_FINDINGS.md` factual and short. It is an input doc, not a narrative.
