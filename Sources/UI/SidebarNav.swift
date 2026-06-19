import Foundation

/// Which view the main-window sidebar has selected. Value-bearing so a
/// user-defined group can be the selected view; stays Hashable for the
/// sidebar's `List(selection:)` binding.
///
/// Lives in its own file (not the SwiftUI view that renders it) so the pure
/// `groupIDsForNewSession` mapping below can ride along into the hostless test
/// target without dragging the screen layer in — the split-out-pure-logic
/// pattern `StatusBarFormat`/`DiscoveryMerge` use.
enum SidebarNav: Hashable {
    case allSessions
    case archived
    case group(String)

    /// The group membership a session started from this view should be seeded
    /// with. A `.group(id)` view contributes `[id]` so the new session joins the
    /// group the user is looking at; `.allSessions`/`.archived` contribute none,
    /// so a launch with no active group stays group-less exactly as before.
    var groupIDsForNewSession: [String] {
        switch self {
        case .group(let id): return [id]
        case .allSessions, .archived: return []
        }
    }
}
