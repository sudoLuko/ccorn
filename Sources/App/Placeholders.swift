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
