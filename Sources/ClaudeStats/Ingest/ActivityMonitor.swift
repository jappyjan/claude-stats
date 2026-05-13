import Foundation

@MainActor
final class ActivityMonitor {
    private let reader: UsageReader
    private let watchPath: String
    private let safetyInterval: TimeInterval
    private let activeThreshold: TimeInterval

    private var watcher: FSEventsWatcher?
    private var fallbackTimer: Timer?
    private var scanInFlight = false

    var onTick: (() -> Void)?

    init(reader: UsageReader,
         watchPath: String,
         safetyInterval: TimeInterval = 60,
         activeThreshold: TimeInterval = 30) {
        self.reader = reader
        self.watchPath = watchPath
        self.safetyInterval = safetyInterval
        self.activeThreshold = activeThreshold
    }

    func start() {
        stop()
        let watcher = FSEventsWatcher(path: watchPath) { [weak self] in
            self?.tickNow()
        }
        if watcher.start() {
            self.watcher = watcher
            scheduleSafetyTimer()
        } else {
            // FSEvents creation failed — fall back to a 10s polling Timer,
            // matching the previous behavior. The 10s cadence already
            // beats the 60s safety net, so we don't schedule both.
            schedulePollingTimer(interval: 10)
        }
        tickNow()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    func tickNow() {
        guard !scanInFlight else { return }
        scanInFlight = true
        Task.detached { [reader] in
            try? reader.scan()
            await MainActor.run { [weak self] in
                self?.scanInFlight = false
                self?.onTick?()
            }
        }
    }

    var isActive: Bool { reader.isActive(within: activeThreshold) }

    private func scheduleSafetyTimer() {
        let t = Timer(timeInterval: safetyInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t
    }

    private func schedulePollingTimer(interval: TimeInterval) {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t
    }
}
