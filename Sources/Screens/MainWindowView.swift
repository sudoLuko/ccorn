import SwiftUI

/// Main app window (docs/CCORN_SPEC.md section 5.1): NavigationSplitView with a
/// 200px fixed sidebar and the session list. Semantic colors only — the window
/// follows system appearance.
struct MainWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(200)
        } detail: {
            SessionListView(model: model)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// Left sidebar: wordmark, New Session button, SESSIONS nav, pinned settings
/// gear. No borders between items — hierarchy through indentation and weight
/// only. New Session / Archived / Settings are milestone-3 surfaces: present
/// but disabled.
private struct SidebarView: View {
    private enum NavItem: Hashable {
        case allSessions
    }

    @State private var selection: NavItem? = .allSessions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                CornMarkShape()
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1,
                                                              lineCap: .round,
                                                              lineJoin: .round))
                    .frame(width: 16, height: 16)
                Text("CCorn")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Button {} label: {
                Label {
                    Text("New Session")
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.4)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            List(selection: $selection) {
                Section {
                    Text("All Sessions")
                        .font(.subheadline.weight(selection == .allSessions ? .medium : .regular))
                        .foregroundColor(.primary)
                        .tag(NavItem.allSessions)
                    // Archived view ships in milestone 3 — indented, inert.
                    Text("Archived")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 12)
                        .opacity(0.5)
                        .selectionDisabled()
                } header: {
                    Text("Sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            Button {} label: {
                Image(systemName: "gear")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.4)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

/// `.selectionDisabled()` exists only on macOS 14+; on 13 an untagged row is
/// simply not selectable, so this is a no-op shim.
private extension View {
    @ViewBuilder
    func selectionDisabled() -> some View {
        if #available(macOS 14.0, *) {
            self.selectionDisabled(true)
        } else {
            self
        }
    }
}
