import SwiftUI
import ServiceManagement
import AppKit

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    let container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Revert on failure.
                        launchAtLogin.toggle()
                    }
                }

            Button("Rebuild index (relaunch required)") {
                Task {
                    await container.rebuildIndex()
                    dismiss()
                    NSApp.terminate(nil)
                }
            }

            Button("Open data folder") {
                let url = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("claude-stats")
                NSWorkspace.shared.open(url)
            }

            HStack {
                Spacer()
                Text("v1.0.0").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
