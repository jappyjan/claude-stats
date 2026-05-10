import XCTest
@testable import ClaudeStats

final class ProjectNameTests: XCTestCase {
    func testStandardOrgRepoPath() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/code/attraccess/Attraccess"),
            "Attraccess"
        )
    }

    func testJappyjanRepoPath() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/code/jappyjan/claude-stats"),
            "claude-stats"
        )
    }

    func testWorktreeCollapsesToParentRepo() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/code/attraccess/Attraccess/.claude/worktrees/naughty-tharp"),
            "Attraccess"
        )
    }

    func testNoProjectPath() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/-no-project"),
            "no-project"
        )
    }

    func testUnknownPathFallsBackToLastComponent() {
        XCTAssertEqual(
            ProjectName.display(for: "/tmp/scratch/foo"),
            "foo"
        )
    }

    func testCanonicalKeyCollapsesWorktrees() {
        let a = ProjectName.canonicalKey(for: "/Users/jappy/code/attraccess/Attraccess")
        let b = ProjectName.canonicalKey(for: "/Users/jappy/code/attraccess/Attraccess/.claude/worktrees/naughty-tharp")
        XCTAssertEqual(a, b)
    }
}
