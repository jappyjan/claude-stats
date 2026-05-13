import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoUpdate: Bool
    @AppStorage("useUsageAPI") private var useAPI: Bool = false
    @AppStorage("planOverride") private var planOverrideRaw: String = "auto"
    @State private var apiAlertMessage: String?
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _autoUpdate = State(initialValue: container.updater.automaticallyChecks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 14, weight: .semibold))

            GroupBox("Limits") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Plan", selection: $planOverrideRaw) {
                        Text("Auto (\(autoLabel()))").tag("auto")
                        Text("Pro").tag(PlanTier.pro.rawValue)
                        Text("Max 5x").tag(PlanTier.max_5x.rawValue)
                        Text("Max 20x").tag(PlanTier.max_20x.rawValue)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: planOverrideRaw) { _, _ in
                        Task { await container.viewModel.refresh() }
                    }

                    Toggle("Use Anthropic API for real numbers", isOn: $useAPI)
                        .onChange(of: useAPI) { _, newValue in
                            if newValue {
                                Task {
                                    await container.viewModel.refresh()
                                    if let err = container.viewModel.limits.apiError {
                                        await MainActor.run {
                                            apiAlertMessage = err
                                            useAPI = false
                                        }
                                    }
                                }
                            }
                        }
                    if useAPI {
                        let count = (container.viewModel.limits.calibrationSamples
                                      .values.reduce(0, +))
                        Text("Calibrated from \(count) sample\(count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Calibration uses tokens from this Mac only. If you also use Claude Code on other machines, limit estimates may read low.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin.toggle()
                    }
                }

            Toggle("Automatically check for updates", isOn: $autoUpdate)
                .onChange(of: autoUpdate) { _, on in
                    container.updater.automaticallyChecks = on
                }

            Button("Check for updates now") {
                container.updater.checkForUpdates()
            }

            Button("Rebuild index (relaunch required)") {
                Task {
                    await container.rebuildIndex()
                    NSApp.terminate(nil)
                }
            }

            Button("Open data folder") {
                let url = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("claude-stats")
                NSWorkspace.shared.open(url)
            }

            Spacer()

            HStack {
                Spacer()
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360, height: 420)
        .alert("Couldn't read from Keychain", isPresented: .constant(apiAlertMessage != nil)) {
            Button("OK") { apiAlertMessage = nil }
        } message: {
            Text(apiAlertMessage ?? "")
        }
    }

    private func autoLabel() -> String {
        let detected = container.detectedPlanLabel
        return detected.isEmpty ? "no plan detected" : "detected: \(detected)"
    }
}
