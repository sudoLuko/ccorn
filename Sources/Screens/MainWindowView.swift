import SwiftUI

/// Main app window (docs/CCORN_SPEC.md section 5.1): NavigationSplitView with a
/// 200px fixed sidebar and the session list (All Sessions or Archived).
/// Semantic colors only — the window follows system appearance. Also hosts the
/// first-run import sheet (5.4).
struct MainWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, nav: $model.sidebarNav)
                .navigationSplitViewColumnWidth(200)
        } detail: {
            SessionListView(model: model, archived: model.sidebarNav == .archived)
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $model.importFlow) { flow in
            ImportSheetView(flow: flow)
        }
    }
}

enum SidebarNav: Hashable {
    case allSessions
    case archived
}

/// Left sidebar: branded header (the lockup is where app identity lives —
/// the title bar hides its text), New Session button, SESSIONS nav (All
/// Sessions + indented Archived), pinned settings gear. Below the header,
/// no borders between items — hierarchy through indentation and weight only.
private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var nav: SidebarNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Rectangle()
                .fill(Color(.separatorColor))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Button {
                model.newSession()
            } label: {
                Label {
                    Text("New Session")
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            List(selection: Binding(get: { nav as SidebarNav? },
                                    set: { nav = $0 ?? .allSessions })) {
                Section {
                    Text("All Sessions")
                        .font(.subheadline.weight(nav == .allSessions ? .medium : .regular))
                        .foregroundColor(.primary)
                        .tag(SidebarNav.allSessions)
                    Text("Archived")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 12)
                        .tag(SidebarNav.archived)
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

            settingsButton
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    /// Gear opens the Settings scene. `SettingsLink` is the supported way on
    /// macOS 14+; 13 falls back to the legacy responder-chain selector.
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                gearLabel
            }
            .buttonStyle(.plain)
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                gearLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var gearLabel: some View {
        Image(systemName: "gear")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .contentShape(Rectangle())
            .accessibilityLabel("Settings")
    }
}
