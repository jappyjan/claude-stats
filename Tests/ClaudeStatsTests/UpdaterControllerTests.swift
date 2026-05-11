import XCTest
@testable import ClaudeStats

@MainActor
final class UpdaterControllerTests: XCTestCase {
    func test_initWithoutStartingUpdater_doesNotCrash() {
        let controller = UpdaterController(startingUpdater: false)
        XCTAssertNotNil(controller.updater)
    }

    func test_automaticallyChecks_setterUpdatesGetter() {
        let controller = UpdaterController(startingUpdater: false)
        let original = controller.automaticallyChecks

        controller.automaticallyChecks = false
        XCTAssertFalse(controller.automaticallyChecks)

        controller.automaticallyChecks = true
        XCTAssertTrue(controller.automaticallyChecks)

        controller.automaticallyChecks = original  // restore
    }
}
