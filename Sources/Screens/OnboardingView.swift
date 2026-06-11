import SwiftUI

/// Onboarding card (docs/CCORN_SPEC.md 5.3, flow 6.1). First launch only,
/// required — no skip: the window has no close button and "Start Scanning"
/// stays disabled until at least one directory is added. Semantic colors so
/// the card follows light/dark like the rest of the main UI.
struct OnboardingView: View {
    /// Called with the chosen directories when "Start Scanning" is clicked.
    let onComplete: ([String]) -> Void

    @State private var directories: [String] = []

    var body: some View {
        // Auto height (5.3): the card grows as directories are added and the
        // hosting window follows; only the width is fixed.
        ZStack {
            Color(.windowBackgroundColor)
            card
                .padding(.vertical, 30)
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        #if DEBUG
        // Scripted stand-in for the NSOpenPanel (DebugCommandChannel
        // `onboarddir`), so the Start Scanning disabled->enabled gate can be
        // exercised end to end. Duplicates ignored, same as addDirectory().
        .onReceive(NotificationCenter.default.publisher(for: Self.debugAddDirectory)) { note in
            if let dir = note.object as? String, !directories.contains(dir) {
                directories.append(dir)
            }
        }
        #endif
    }

    #if DEBUG
    static let debugAddDirectory = Notification.Name("ccorn.debug.onboarding.add-directory")
    #endif

    private var card: some View {
        VStack(spacing: 0) {
            // The in-app brand mark is the corn emoji (review item 3); vector
            // assets are reserved for the app icon and menu-bar glyph.
            Text("🌽")
                .font(.system(size: 44))
                .frame(height: 48)
                .padding(.bottom, 8)
                .accessibilityHidden(true)

            Text("CCorn")
                .font(.title2.weight(.medium))
                .foregroundColor(.primary)

            Text("Where do you keep your projects?")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 24)

            directoryList
                .padding(.bottom, 8)

            if !directories.isEmpty {
                Button {
                    addDirectory()
                } label: {
                    Text("+ Add Directory")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }

            Text("CCorn will scan these folders for Claude Code sessions")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 24)

            // Real primary button (review item 2): solid accent fill with
            // knockout text when actionable, a legible intentional disabled
            // state until a directory is added.
            FilledButton(title: "Start Scanning",
                         disabled: directories.isEmpty,
                         fullWidth: true,
                         height: 36) {
                onComplete(directories)
            }
            .padding(.bottom, 8)

            Text("Add more directories later in Settings")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .frame(width: 480)
        .background(Color(.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Directory rows, or the dashed empty area with a centered add button.
    @ViewBuilder
    private var directoryList: some View {
        if directories.isEmpty {
            Button {
                addDirectory()
            } label: {
                Text("+ Add Directory")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separatorColor),
                                          style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(directories.enumerated()), id: \.element) { index, dir in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(.separatorColor))
                            .frame(height: 0.5)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text((dir as NSString).abbreviatingWithTildeInPath)
                            .font(.subheadline.monospaced())
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button {
                            directories.removeAll { $0 == dir }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(dir)")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
            )
        }
    }

    /// NSOpenPanel; duplicates are silently ignored (5.3).
    private func addDirectory() {
        guard let dir = Alerts.pickFolder(prompt: "Add Directory") else { return }
        guard !directories.contains(dir) else { return }
        directories.append(dir)
    }
}
