import Foundation
import CoreServices

/// Minimal wrapper over FSEventStream that fires a callback (debounced)
/// when anything under the watched directory changes.
final class FSEventsWatcher {
    private let path: String
    private let latency: TimeInterval
    private let debounce: TimeInterval
    private let callback: () -> Void

    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?

    init(path: String,
         latency: TimeInterval = 0.2,
         debounce: TimeInterval = 0.2,
         callback: @escaping () -> Void) {
        self.path = path
        self.latency = latency
        self.debounce = debounce
        self.callback = callback
    }

    /// Returns true if the FSEvents stream started successfully.
    @discardableResult
    func start() -> Bool {
        stop()
        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info,
            retain: nil, release: nil, copyDescription: nil
        )
        let paths = [path] as CFArray
        let flags: UInt32 = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleFire()
            },
            &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags
        ) else {
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        if !FSEventStreamStart(s) {
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    func stop() {
        pendingWork?.cancel()
        pendingWork = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func scheduleFire() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.callback()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit { stop() }
}
