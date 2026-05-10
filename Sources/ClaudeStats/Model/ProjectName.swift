import Foundation

enum ProjectName {
    /// Display name for a project, derived from its cwd.
    static func display(for path: String) -> String {
        let canonical = canonicalKey(for: path)
        if canonical.hasPrefix("/Users/jappy/-") {
            return String(canonical.dropFirst("/Users/jappy/-".count))
        }
        return (canonical as NSString).lastPathComponent
    }

    /// Canonical project key — collapses worktrees to their parent repo path.
    static func canonicalKey(for path: String) -> String {
        // Worktree pattern: <repo>/.claude/worktrees/<name>[/...]
        if let range = path.range(of: "/.claude/worktrees/") {
            return String(path[..<range.lowerBound])
        }
        return path
    }
}
