import SwiftUI

@main
struct ClaudeStatsApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: container.viewModel, container: container)
                .frame(width: 380)
                .frame(maxHeight: 480)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(container.viewModel.isActive ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(formatTokens(container.viewModel.todayTokens))
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
            }
            .task { container.startBackgroundWork() }
        }
        .menuBarExtraStyle(.window)

        Window("ClaudeStats Settings", id: "settings") {
            SettingsView(container: container)
        }
        .windowResizability(.contentSize)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
