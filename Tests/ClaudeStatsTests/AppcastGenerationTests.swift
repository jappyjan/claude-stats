import XCTest

final class AppcastGenerationTests: XCTestCase {
    func test_makeAppcast_matchesGolden() throws {
        let bundle = Bundle.module
        guard
            let fixtureURL = bundle.url(forResource: "releases-sample", withExtension: "json", subdirectory: "Fixtures"),
            let goldenURL = bundle.url(forResource: "appcast-expected", withExtension: "xml", subdirectory: "Fixtures")
        else {
            XCTFail("fixtures not found in test bundle")
            return
        }

        let fixture = try Data(contentsOf: fixtureURL)
        let expected = try String(contentsOf: goldenURL, encoding: .utf8)
        let scriptURL = try Self.projectRoot()
            .appendingPathComponent("scripts/make-appcast.sh")

        let stdin = Pipe()
        let stdout = Pipe()
        let process = Process()
        process.executableURL = scriptURL
        process.standardInput = stdin
        process.standardOutput = stdout
        var env = ProcessInfo.processInfo.environment
        env["SPARKLE_SIGNATURE"] = "TEST_SIGNATURE_BASE64"
        env["SPARKLE_LENGTH"] = "3000000"
        process.environment = env

        try process.run()
        stdin.fileHandleForWriting.write(fixture)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "script exited non-zero")
        let actual = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(
            actual.trimmingCharacters(in: .whitespacesAndNewlines),
            expected.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Walk up from this source file until we find a directory containing Package.swift.
    private static func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        struct ProjectRootNotFound: Error {}
        throw ProjectRootNotFound()
    }
}
