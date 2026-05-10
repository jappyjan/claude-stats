import Foundation

@MainActor
final class ActivityMonitor {
    private let reader: UsageReader
    private let interval: TimeInterval
    private let activeThreshold: TimeInterval
    private var timer: Timer?

    var onTick: (() -> Void)?

    init(reader: UsageReader, interval: TimeInterval = 10, activeThreshold: TimeInterval = 30) {
        self.reader = reader
        self.interval = interval
        self.activeThreshold = activeThreshold
    }

    func start() {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tickNow()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func tickNow() {
        Task.detached { [reader] in
            try? reader.scan()
            await MainActor.run { [weak self] in
                self?.onTick?()
            }
        }
    }

    var isActive: Bool { reader.isActive(within: activeThreshold) }
}
