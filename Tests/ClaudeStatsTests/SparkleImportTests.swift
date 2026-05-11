import XCTest
import Sparkle

final class SparkleImportTests: XCTestCase {
    func test_sparkleStandardUpdaterControllerTypeExists() {
        // Compile-time check that Sparkle is wired up correctly.
        // If Sparkle is missing from Package.swift, this file won't build.
        XCTAssertNotNil(SPUStandardUpdaterController.self)
    }
}
