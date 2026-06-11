#if DEBUG
import AppKit

/// Debug-build-only staging for the design pass: a curated, deterministic set
/// of seeded rows (every state, realistic titles/paths/ages) and an in-process
/// window screenshot helper. Driven by DebugCommandChannel (`seed`, `shoot`,
/// `appearance`); compiled out of release builds entirely. Seeding goes
/// through AppModel.debugSeed, which stops the live poll first — the real
/// store, tmux session, and discovery are never touched.
enum DebugStage {

    // MARK: - Seed data

    /// Sidebar groups for the seeded set. Definitions only — seeding swaps
    /// AppModel's PUBLISHED list; settings.json is never written.
    static let seedGroups: [SessionGroup] = [
        SessionGroup(id: "seed-group-client", name: "Client work"),
        SessionGroup(id: "seed-group-infra", name: "Infra"),
        // No members: exercises the empty-group state.
        SessionGroup(id: "seed-group-empty", name: "Experiments"),
    ]

    /// A realistic mix covering every presentation: routine dots (working,
    /// waiting, running, stale, stopped), the full broken trio (sign-in,
    /// no-remote — one generic, one with the captured plan notice — and
    /// crashed), a few unmanaged discoveries, and an archived pair. Group
    /// coverage: members of each seed group, one session in BOTH groups, an
    /// archived-and-grouped record, and one brand-new UNBOUND session (empty
    /// uuid — the Groups control must gate disabled on it).
    static func seedRows(now: Date = Date()) -> (all: [SessionRow], archived: [SessionRow]) {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let home = NSHomeDirectory()

        let managed: [SessionRow] = [
            SessionRow(id: "@901", kind: .managed(windowId: "@901"),
                       title: "ccorn polish pass",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000001",
                       path: "\(home)/dev/ccorn",
                       state: .working, remoteControlActive: true,
                       lastActive: ago(15),
                       groupIDs: ["seed-group-client"]),
            SessionRow(id: "@902", kind: .managed(windowId: "@902"),
                       title: "Checkout flow revamp",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000002",
                       path: "\(home)/dev/shop",
                       state: .waiting, remoteControlActive: true,
                       lastActive: ago(4 * 60),
                       groupIDs: ["seed-group-client"]),
            SessionRow(id: "@903", kind: .managed(windowId: "@903"),
                       title: "Auth service refactor",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000003",
                       path: "\(home)/dev/auth-service",
                       state: .needsAuth, remoteControlActive: false,
                       lastActive: ago(60),
                       authNotice: "Invalid API key · Please run /login"),
            SessionRow(id: "@904", kind: .managed(windowId: "@904"),
                       title: "Mella landing page",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000004",
                       path: "\(home)/dev/mella",
                       state: .running, remoteControlActive: true,
                       lastActive: ago(22 * 60)),
            // Presents as No remote (alive + RC inactive past the grace).
            SessionRow(id: "@905", kind: .managed(windowId: "@905"),
                       title: "Release scripts",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000005",
                       path: "\(home)/dev/release-tools",
                       state: .running, remoteControlActive: false,
                       lastActive: ago(35 * 60)),
            // No remote with the captured plan-restriction notice (tooltip),
            // underlying activity Working.
            SessionRow(id: "@908", kind: .managed(windowId: "@908"),
                       title: "Infra terraform",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000009",
                       path: "\(home)/dev/infra",
                       state: .working, remoteControlActive: false,
                       lastActive: ago(8 * 60),
                       rcPlanNotice: "Remote Control is not available on your plan. Upgrade to enable it.",
                       groupIDs: ["seed-group-infra"]),
            SessionRow(id: "@906", kind: .managed(windowId: "@906"),
                       title: "Data pipeline",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000006",
                       path: "\(home)/dev/etl",
                       state: .stale, remoteControlActive: true,
                       lastActive: ago(6 * 3600),
                       // In BOTH groups: multi-membership coverage.
                       groupIDs: ["seed-group-client", "seed-group-infra"]),
            SessionRow(id: "@907", kind: .managed(windowId: "@907"),
                       title: "Docs site rebuild",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000007",
                       path: "\(home)/dev/docs",
                       state: .dead, remoteControlActive: false,
                       lastActive: ago(3 * 3600)),
            // Brand-new session whose transcript hasn't bound yet: NO uuid,
            // so the Groups control must render disabled for it.
            SessionRow(id: "@909", kind: .managed(windowId: "@909"),
                       title: "untitled spike",
                       uuid: "",
                       path: "\(home)/dev/sandbox",
                       state: .working, remoteControlActive: false,
                       rcGraceExpired: false,
                       lastActive: ago(5)),
            SessionRow(id: "record:aaaaaaaa-0000-4000-8000-000000000008",
                       kind: .record,
                       title: "Spike: rate limiter",
                       uuid: "aaaaaaaa-0000-4000-8000-000000000008",
                       path: "\(home)/dev/limiter",
                       state: .stopped, remoteControlActive: false,
                       lastActive: ago(2 * 86_400)),
        ]

        let unmanaged: [SessionRow] = [
            SessionRow(id: "unmanaged:-dev-scratchpad", kind: .unmanaged,
                       title: "scratchpad",
                       uuid: "bbbbbbbb-0000-4000-8000-000000000001",
                       path: "\(home)/dev/scratchpad",
                       state: .unmanaged, remoteControlActive: false,
                       lastActive: ago(5 * 86_400)),
            SessionRow(id: "unmanaged:-dev-old-blog", kind: .unmanaged,
                       title: "old-blog",
                       uuid: "bbbbbbbb-0000-4000-8000-000000000002",
                       path: "\(home)/dev/old-blog",
                       state: .unmanaged, remoteControlActive: false,
                       lastActive: ago(12 * 86_400)),
            SessionRow(id: "unmanaged:-experiments-llm-eval", kind: .unmanaged,
                       title: "llm-eval",
                       uuid: "bbbbbbbb-0000-4000-8000-000000000003",
                       path: "\(home)/experiments/llm-eval",
                       state: .unmanaged, remoteControlActive: false,
                       lastActive: ago(21 * 86_400)),
        ]

        let archived: [SessionRow] = [
            SessionRow(id: "record:cccccccc-0000-4000-8000-000000000001",
                       kind: .record,
                       title: "Bug bash May",
                       uuid: "cccccccc-0000-4000-8000-000000000001",
                       path: "\(home)/dev/shop",
                       state: .stopped, remoteControlActive: false,
                       archived: true,
                       lastActive: ago(18 * 86_400),
                       // Archived AND grouped: membership survives, but the
                       // row surfaces only in the Archived view.
                       groupIDs: ["seed-group-client"]),
            SessionRow(id: "record:cccccccc-0000-4000-8000-000000000002",
                       kind: .record,
                       title: "Onboarding email flow",
                       uuid: "cccccccc-0000-4000-8000-000000000002",
                       path: "\(home)/dev/mailers",
                       state: .stopped, remoteControlActive: false,
                       archived: true,
                       lastActive: ago(40 * 86_400)),
        ]

        // Same sort the real rebuild applies (most recent first) — debugSeed
        // bypasses rebuildRows, so unsorted seeds would render unsorted.
        let all = (managed + unmanaged)
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        return (all, archived)
    }

    /// Working-heavy set: several Working rows at once so the optional
    /// working-dot breath can be judged in motion (review item 1, "Process"),
    /// with one waiting and one running row as contrast.
    static func seedWorkingHeavyRows(now: Date = Date()) -> [SessionRow] {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let home = NSHomeDirectory()
        let working: [(String, String)] = [
            ("ccorn polish pass", "ccorn"),
            ("Checkout flow revamp", "shop"),
            ("Auth service refactor", "auth-service"),
            ("Data pipeline", "etl"),
            ("Docs site rebuild", "docs"),
        ]
        var rows = working.enumerated().map { index, item in
            SessionRow(id: "@95\(index)", kind: .managed(windowId: "@95\(index)"),
                       title: item.0,
                       uuid: "dddddddd-0000-4000-8000-00000000000\(index)",
                       path: "\(home)/dev/\(item.1)",
                       state: .working, remoteControlActive: true,
                       lastActive: ago(TimeInterval(10 + index * 40)))
        }
        rows.append(SessionRow(id: "@958", kind: .managed(windowId: "@958"),
                               title: "Mella landing page",
                               uuid: "dddddddd-0000-4000-8000-000000000008",
                               path: "\(home)/dev/mella",
                               state: .waiting, remoteControlActive: true,
                               lastActive: ago(5 * 60)))
        rows.append(SessionRow(id: "@959", kind: .managed(windowId: "@959"),
                               title: "Release scripts",
                               uuid: "dddddddd-0000-4000-8000-000000000009",
                               path: "\(home)/dev/release-tools",
                               state: .running, remoteControlActive: true,
                               lastActive: ago(12 * 60)))
        return rows
    }

    /// All-clear set: only calm sessions (working/running/stale/stopped), no
    /// attention tier — exercises the popover's all-clear line and its calm
    /// disclosure without attention rows above it.
    static func seedCalmRows(now: Date = Date()) -> [SessionRow] {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let home = NSHomeDirectory()
        var rows: [SessionRow] = [
            SessionRow(id: "@971", kind: .managed(windowId: "@971"),
                       title: "ccorn polish pass",
                       uuid: "eeeeeeee-0000-4000-8000-000000000001",
                       path: "\(home)/dev/ccorn",
                       state: .working, remoteControlActive: true,
                       lastActive: ago(20)),
            SessionRow(id: "@972", kind: .managed(windowId: "@972"),
                       title: "Mella landing page",
                       uuid: "eeeeeeee-0000-4000-8000-000000000002",
                       path: "\(home)/dev/mella",
                       state: .running, remoteControlActive: true,
                       lastActive: ago(9 * 60)),
            SessionRow(id: "@973", kind: .managed(windowId: "@973"),
                       title: "Checkout flow revamp",
                       uuid: "eeeeeeee-0000-4000-8000-000000000003",
                       path: "\(home)/dev/shop",
                       state: .running, remoteControlActive: true,
                       lastActive: ago(25 * 60)),
            SessionRow(id: "@974", kind: .managed(windowId: "@974"),
                       title: "Data pipeline",
                       uuid: "eeeeeeee-0000-4000-8000-000000000004",
                       path: "\(home)/dev/etl",
                       state: .stale, remoteControlActive: true,
                       lastActive: ago(5 * 3600)),
            SessionRow(id: "record:eeeeeeee-0000-4000-8000-000000000005",
                       kind: .record,
                       title: "Spike: rate limiter",
                       uuid: "eeeeeeee-0000-4000-8000-000000000005",
                       path: "\(home)/dev/limiter",
                       state: .stopped, remoteControlActive: false,
                       lastActive: ago(2 * 86_400)),
        ]
        rows.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        return rows
    }

    // MARK: - Window screenshots

    /// Render a window's full frame (title bar included) to a PNG via
    /// `cacheDisplay` — no screen-recording permission needed, and the render
    /// honors the current NSApp.appearance. Targets: main / popover /
    /// settings / onboarding / sheet / key.
    @MainActor
    static func shoot(target: String, path: String) -> String {
        guard let window = window(for: target) else { return "err no-window \(target)" }
        // The themeFrame (contentView's superview) covers the whole window
        // incl. the title bar; borderless windows (popover) fall back to the
        // content view.
        guard let view = window.contentView?.superview ?? window.contentView else {
            return "err no-view"
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "err no-rep"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return "err no-png"
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return "shot \(target) \(Int(view.bounds.width))x\(Int(view.bounds.height)) -> \(path)"
        } catch {
            return "err write \(error.localizedDescription)"
        }
    }

    /// CGWindowID of a target window, for `screencapture -l`.
    @MainActor
    static func windowNumber(for target: String) -> Int? {
        window(for: target).map(\.windowNumber)
    }

    @MainActor
    private static func window(for target: String) -> NSWindow? {
        switch target {
        case "main":
            return NSApp.windows.first { $0.title == "CCorn" }
        case "settings":
            return NSApp.windows.first { $0.title.contains("Settings") && $0.isVisible }
        case "onboarding":
            return NSApp.windows.first { $0.title.contains("Welcome") }
        case "popover":
            return NSApp.windows.first {
                String(describing: type(of: $0)).contains("Popover") && $0.isVisible
            }
        case "sheet":
            return NSApp.windows.compactMap(\.attachedSheet).first
        case "key":
            return NSApp.keyWindow
        default:
            return nil
        }
    }
}
#endif
