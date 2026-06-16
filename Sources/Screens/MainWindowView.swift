import SwiftUI

/// Main app window (docs/CCORN_SPEC.md section 5.1): NavigationSplitView with a
/// 200px fixed sidebar and the session list (All Sessions or Archived).
/// Semantic colors only; the window follows system appearance. Also hosts the
/// first-run import sheet (5.4).
struct MainWindowView: View {
    @ObservedObject var model: AppModel

    /// Explicit visibility binding: every collapse/expand path routes through
    /// the model (persisted, and restorable from the titlebar toggle). An
    /// unbound NavigationSplitView owns this state itself, and with no toolbar
    /// or menu command a collapse had no recovery affordance at all.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = ($0 != .detailOnly) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(model: model, nav: $model.sidebarNav)
                .navigationSplitViewColumnWidth(200)
        } detail: {
            SessionListView(model: model, nav: model.sidebarNav)
        }
        // App identity lives in the branded sidebar header; the bound
        // NavigationSplitView otherwise surfaces the window title ("CCorn") in
        // the titlebar, duplicating it. AppKit's titleVisibility = .hidden no
        // longer wins against SwiftUI's titlebar, so remove the title item
        // here. window.title stays "CCorn" for the debug/window lookup.
        .hiddenWindowTitle()
        // App identity: the corn glyph lives in the title bar as a trailing
        // titlebar accessory (see MainWindowController.show). It is deliberately
        // not an NSToolbar item; a toolbar would add AppKit's "Icon and Text /
        // Icon Only" right-click menu, and a plain accessory has no such chrome.
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $model.importFlow) { flow in
            ImportSheetView(flow: flow)
        }
        .sheet(item: $model.newSessionFlow) { flow in
            NewSessionSheetView(flow: flow)
        }
        // The closed window keeps this tree alive (isReleasedWhenClosed =
        // false): the row marks gate their repeatForever motion on the
        // window's actual visibility (close, miniaturize, full occlusion).
        .environment(\.rowMotionEnabled, model.mainWindowOnScreen)
        // Click-away ends an inline rename / group edit (the field commits on
        // the resulting focus loss). The sheets above are separate windows and
        // carry their own resigner.
        .endsEditingOnOutsideClick()
    }
}

private extension View {
    /// Hide the titlebar's title text without clearing `window.title`.
    /// `.toolbar(removing: .title)` is macOS 15+; below that the AppKit
    /// `titleVisibility = .hidden` in MainWindowController is the fallback.
    @ViewBuilder
    func hiddenWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
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

/// Left sidebar: branded header (the lockup is where app identity lives;
/// the title bar hides its text), New Session button, SESSIONS nav (All
/// Sessions + indented Archived), pinned settings gear. Below the header,
/// no borders between items; hierarchy through indentation and weight only.
private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var nav: SidebarNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand mark moved to the centered title-bar glyph; the sidebar now
            // opens straight on New Session.
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
            .padding(.top, 12)
            .padding(.bottom, 4)

            List(selection: Binding(get: { nav as SidebarNav? },
                                    set: { nav = $0 ?? .allSessions })) {
                Section {
                    Text("All Sessions")
                        .font(.subheadline)
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
            // Keep the list's own translucent sidebar material hidden so the
            // column's opaque fill (applied to the VStack below) shows through and
            // the labels paint crisp rather than vibrancy-blended. The opaque
            // surface now lives on the enclosing column, not on the List alone, so
            // the header above and the footer below share the same shade.
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            settingsButton
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        // One opaque surface for the whole sidebar column. The fill lives on the
        // container (header + List + footer), not just the List: applied to the
        // List alone, the "New Session" header above and the settings-gear footer
        // below still rendered against the default translucent sidebar material,
        // a lighter band at each end. Expanding to fill the column edge to edge
        // first means the fill also covers any translucency at the column's edges,
        // so the sidebar reads as one solid surface, top to bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    /// One group row: name, member count, rename/delete context menu.
    /// SwiftUI `.contextMenu` here (not the RowRightClickCatcher overlay):
    /// it bridges to a native menu, and the catcher does not compose with
    /// List's row selection; the NSMenu rule's intent (no custom-styled
    /// menus) is preserved.
    private func groupRow(_ group: SessionGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name)
                .font(.subheadline)
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
            // Outside click resigns first responder (the window-root resigner);
            // commit the typed name on focus loss, the same as Return. Guarded
            // so Escape (cancelGroupEdit clears the id first) and Enter's own
            // commit don't re-fire it.
            .onChange(of: focused) { focused in
                guard !focused, model.editingGroupId == group.id else { return }
                model.commitGroupName(group.id, to: draft)
            }
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
