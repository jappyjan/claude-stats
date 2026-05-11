import Foundation
import Sparkle

@MainActor
final class UpdaterController {
    let updater: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        self.updater = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecks: Bool {
        get { updater.updater.automaticallyChecksForUpdates }
        set { updater.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }
}
