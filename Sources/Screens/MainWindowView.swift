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
            SessionListView(model: model, nav: model.sidebarNav)
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $model.importFlow) { flow in
            ImportSheetView(flow: flow)
        }
    }
}

/// Value-bearing so a user group can be the selected view; stays Hashable
/// for the sidebar's List(selection:) binding.
enum SidebarNav: Hashable {
    case allSessions
    case archived
    case group(String)
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

                // User groups (docs/CCORN_SPEC.md 5.11): ordered as stored.
                Section {
                    ForEach(model.groups) { group in
                        if model.editingGroupId == group.id {
                            // The editing row is deliberately NOT tagged:
                            // List selection cannot land on (or fight) the
                            // TextField while a name is being typed.
                            GroupNameField(model: model, group: group)
                        } else {
                            groupRow(group)
                        }
                    }
                    Button {
                        model.beginNewGroup()
                    } label: {
                        Label {
                            Text("New Group")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Groups")
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

    /// One group row: name, member count, rename/delete context menu.
    /// SwiftUI `.contextMenu` here (not the RowRightClickCatcher overlay):
    /// it bridges to a native menu, and the catcher does not compose with
    /// List's row selection — the NSMenu rule's intent (no custom-styled
    /// menus) is preserved.
    private func groupRow(_ group: SessionGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name)
                .font(.subheadline.weight(nav == .group(group.id) ? .medium : .regular))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(model.groupRows(id: group.id).count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .tag(SidebarNav.group(group.id))
        .contextMenu {
            Button("Rename") { model.beginGroupRename(group.id) }
            Button("Delete Group…") { model.deleteGroup(group.id) }
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

/// Inline group-name editor (the session-rename pattern, 5.8): same font and
/// position as the group row, subtle border, pre-selected text. Enter
/// commits; Escape cancels (removing a just-created placeholder).
private struct GroupNameField: View {
    @ObservedObject var model: AppModel
    let group: SessionGroup

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .foregroundColor(.primary)
            .focused($focused)
            .onSubmit { model.commitGroupName(group.id, to: draft) }
            .onExitCommand { model.cancelGroupEdit() }
            .padding(.horizontal, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
            )
            .onAppear {
                draft = group.name
                focused = true
                // Pre-select so the user can type immediately (Finder-style).
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
    }
}
