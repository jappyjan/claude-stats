import Foundation

final class UsageReader {
    private let rootDir: URL
    private let store: UsageStore
    private let parser = JSONLParser()

    init(rootDir: URL, store: UsageStore) {
        self.rootDir = rootDir
        self.store = store
    }

    /// One full pass over the directory tree. Inserts only new entries.
    func scan() throws {
        guard FileManager.default.fileExists(atPath: rootDir.path) else { return }
        for url in jsonlFiles() {
            do {
                try processFile(url)
            } catch {
                // Per-file failure: skip and continue. A single bad file shouldn't kill the scan.
            }
        }
    }

    /// True if any tracked JSONL file has been modified within `seconds` of now.
    func isActive(within seconds: TimeInterval) -> Bool {
        let cutoff = Date().addingTimeInterval(-seconds)
        for url in jsonlFiles() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let mtime = values?.contentModificationDate, mtime > cutoff {
                return true
            }
        }
        return false
    }

    private func jsonlFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootDir,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }
        return urls
    }

    private func processFile(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mdate = attrs[.modificationDate] as? Date else { return }
        let mtime = Int64(mdate.timeIntervalSince1970 * 1_000_000_000)

        let prior = try store.fileState(path: url.path)
        if let prior = prior, prior.mtime == mtime {
            return // unchanged
        }

        let startOffset = prior?.lastOffset ?? 0
        let result = try parser.parse(fileURL: url, fromOffset: startOffset)
        try store.insert(result.entries)
        try store.upsertFileState(path: url.path, mtime: mtime, lastOffset: result.endOffset)
    }
}
