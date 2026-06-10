import AppKit
import UserNotifications

/// Local notifications for session-state changes worth surfacing while the
/// user is not looking at the app (docs/CCORN_SPEC.md 5.10): fire ONLY on
/// transitions into Waiting or Dead, detected as edges by the caller — never
/// on every poll — plus a per-session cooldown here so a flapping session
/// can't spam. Tapping a notification opens the session in the browser (same
/// as "Open in Browser": claude.ai/code, found by title — no per-session URL
/// exists).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Minimum spacing between two notifications for the same session+state.
    private let cooldown: TimeInterval = 120
    /// "uuid|state" -> last fired.
    private var lastFired: [String: Date] = [:]

    #if DEBUG
    /// Verification hook: which session|state notifications have fired.
    var firedKeys: [String] { Array(lastFired.keys).sorted() }
    #endif

    /// Requested on first launch after onboarding (and idempotently on every
    /// launch thereafter — the system only prompts once).
    func requestPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a notification for a session that just transitioned. The caller
    /// guarantees this is an edge (previous state differed); this layer adds
    /// the cooldown and the content.
    func notify(sessionKey: String, title: String, state: SessionState, now: Date = Date()) {
        guard state == .waiting || state == .dead || state == .needsAuth else { return }
        // An entry past the cooldown behaves exactly like a missing one, so
        // expired entries are dropped here — keyed by window id (monotonic),
        // the map would otherwise grow for the lifetime of the app.
        lastFired = lastFired.filter { now.timeIntervalSince($0.value) < cooldown }
        let key = "\(sessionKey)|\(state.rawValue)"
        if let last = lastFired[key], now.timeIntervalSince(last) < cooldown { return }
        lastFired[key] = now

        let content = UNMutableNotificationContent()
        switch state {
        case .waiting:
            content.title = "\(title) is waiting"
            content.body = "Claude needs your input or approval."
        case .needsAuth:
            content.title = "\(title) needs sign-in"
            content.body = "Claude Code is not authenticated. Open the session in Terminal and run /login."
        case .dead:
            content.title = "\(title) died"
            content.body = "The session's process is gone. Restart it from CCorn."
        default:
            return
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: key,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Tap → open the session in the browser (flow: same as "Open in Browser").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if let url = URL(string: "https://claude.ai/code") {
                NSWorkspace.shared.open(url)
            }
            completionHandler()
        }
    }

    /// Show banners even when CCorn is technically frontmost (it's a menu-bar
    /// app; "frontmost" rarely means the user is looking at it).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
