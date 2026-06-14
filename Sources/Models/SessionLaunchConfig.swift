import Foundation

/// The permission posture a session is launched with. CCorn's taxonomy maps
/// onto the Claude Code CLI's `--permission-mode` choices plus the two bypass
/// flags (verified on Claude Code 2.1.173):
///
///  - `standard`/`plan`/`acceptEdits`/`auto` → `--permission-mode <raw>`
///  - `allowBypass` → `--allow-dangerously-skip-permissions` (arms bypass as an
///    in-session option the user can cycle into via Shift+Tab; does NOT start in
///    it — the start-safe path that also sidesteps the root refusal below)
///  - `bypass` → `--dangerously-skip-permissions` (active from launch; refuses
///    to run as root/sudo)
///
/// `auto` is the safe-but-autonomous default: a classifier auto-approves routine
/// work (edits, reads, safe commands) but blocks dangerous escalations (mass
/// deletes, force-push, prod deploys). It is launch-only and, like every flag
/// here, does NOT persist across `--resume` — a restart must re-apply it.
///
/// rawValue strings are the persistence keys (stable across builds); the
/// non-bypass cases' rawValues double as the CLI `--permission-mode` argument,
/// so they must match the CLI's spelling exactly.
enum CCPermissionMode: String, Codable, CaseIterable {
    case standard      // claude's implicit default — no flag emitted
    case plan
    case acceptEdits
    case auto
    case allowBypass
    case bypass

    /// Picker label.
    var displayName: String {
        switch self {
        case .standard:    return "Default"
        case .plan:        return "Plan"
        case .acceptEdits: return "Accept Edits"
        case .auto:        return "Auto"
        case .allowBypass: return "Allow Bypass"
        case .bypass:      return "Bypass"
        }
    }

    /// One-line description for the picker / tooltip.
    var summary: String {
        switch self {
        case .standard:    return "Prompts for every tool use."
        case .plan:        return "Read-only exploration; writes are blocked."
        case .acceptEdits: return "Auto-approves file edits; still prompts for commands."
        case .auto:        return "Autonomous, but blocks dangerous escalations."
        case .allowBypass: return "Starts safe; lets you switch to full bypass in-session (Shift+Tab)."
        case .bypass:      return "Skips all permission checks. Cannot run as root."
        }
    }

    /// The two cases that arm or activate bypass — the ones the root guard and
    /// the bypass marker care about.
    var involvesBypass: Bool {
        self == .allowBypass || self == .bypass
    }

    /// Modes the UI should offer. Under root/sudo the bypass modes are dropped:
    /// `--dangerously-skip-permissions` refuses to run as root, and an armed
    /// bypass (`allowBypass`) cannot escalate there either, so neither can reach
    /// active bypass — offering them would only produce a launch that fails.
    static func selectable(isRoot: Bool) -> [CCPermissionMode] {
        isRoot ? allCases.filter { !$0.involvesBypass } : allCases
    }
}

/// Process-environment facts the launch UI needs.
enum LaunchEnvironment {
    /// True when CCorn itself is running as root (uid 0) — almost never the case
    /// for a GUI app, but if it is, bypass cannot work (the CLI refuses it).
    static var isRoot: Bool { getuid() == 0 }
}

/// Typed launch configuration carried by a session: the flags CCorn passes to
/// `claude` when it starts, resumes, or restarts the session. Persisted on the
/// `SessionRecord` so a restart relaunches with the same flags (they do not
/// persist on the CLI side), and held as a global default in `CCornSettings`
/// that new sessions inherit.
///
/// `extraArgs` is a tokenized array, NOT a free string: each token is
/// shell-quoted independently by the engine before it is typed into the pane
/// shell, so the escape hatch never re-opens the injection door `shellQuote`
/// closes. `--max-budget-usd` is deliberately absent: it only works with
/// `--print`, so it is a no-op in CCorn's interactive `--rc` sessions.
struct SessionLaunchConfig: Codable, Equatable {
    var permissionMode: CCPermissionMode
    /// Model alias (`opus`/`sonnet`/`fable`) or full id; nil/empty = account default.
    var model: String?
    /// `--add-dir` entries — additional directories the session may touch.
    var additionalDirectories: [String]
    /// Advanced escape hatch: extra argv tokens, already split (one flag or
    /// value per element). Passed through verbatim after the known flags.
    var extraArgs: [String]

    init(permissionMode: CCPermissionMode = .auto,
         model: String? = nil,
         additionalDirectories: [String] = [],
         extraArgs: [String] = []) {
        self.permissionMode = permissionMode
        self.model = model
        self.additionalDirectories = additionalDirectories
        self.extraArgs = extraArgs
    }

    /// The default new sessions inherit: safe-but-autonomous (`auto`), nothing else.
    static let safeDefault = SessionLaunchConfig(permissionMode: .auto)

    /// Field-by-field defaults (the CCornSettings/SessionRecord rule): a config
    /// written by an older build — or one missing a field — decodes cleanly
    /// instead of failing the whole parent record/settings decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permissionMode = try c.decodeIfPresent(CCPermissionMode.self, forKey: .permissionMode) ?? .auto
        model = try c.decodeIfPresent(String.self, forKey: .model)
        additionalDirectories = try c.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
    }

    /// The ordered argv tokens this config contributes after `claude` (and after
    /// `--rc`/`--resume`). RAW tokens — the engine shell-quotes each one before
    /// typing it into the pane shell.
    ///
    /// The two hard CLI rules are enforced *by construction* here:
    ///  1. `--dangerously-skip-permissions` is emitted ONLY by the `.bypass`
    ///     arm, which emits no `--permission-mode` — they can never co-occur (the
    ///     dangerous flag overrides the mode, and mixing is invalid).
    ///  2. `.standard` emits nothing (claude's implicit default), so a "default"
    ///     session carries no permission flag at all.
    func claudeFlagTokens() -> [String] {
        var tokens: [String] = []
        switch permissionMode {
        case .standard:
            break
        case .plan, .acceptEdits, .auto:
            tokens += ["--permission-mode", permissionMode.rawValue]
        case .allowBypass:
            tokens += ["--allow-dangerously-skip-permissions"]
        case .bypass:
            tokens += ["--dangerously-skip-permissions"]
        }
        if let model, !model.isEmpty {
            tokens += ["--model", model]
        }
        for dir in additionalDirectories where !dir.isEmpty {
            tokens += ["--add-dir", dir]
        }
        tokens += extraArgs.filter { !$0.isEmpty }
        return tokens
    }
}
