import AppKit
import Foundation

@MainActor
final class AppContainer {
    let store: UsageStore
    let reader: UsageReader
    let monitor: ActivityMonitor
    let pricingFetcher: PricingFetcher
    let viewModel: StatsViewModel
    let updater: UpdaterController
    let catalog: PlanCatalog

    private var midnightTimer: Timer?
    private var pricingTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init() {
        Self.migrateLegacyDefaults()

        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("claude-stats", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let cache = try! FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("claude-stats", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let dbPath = appSupport.appendingPathComponent("usage.db").path
        self.store = try! UsageStore(path: dbPath)

        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        self.reader = UsageReader(rootDir: claudeRoot, store: store)

        let bundled = Bundle.main.url(forResource: "pricing-fallback", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
        self.pricingFetcher = PricingFetcher(
            cacheDir: cache,
            bundledFallback: bundled,
            fetcher: PricingFetcher.defaultFetcher()
        )

        let initialPricing = (try? PricingTable.fromJSON(bundled)) ?? PricingTable(rates: [:])

        let planLimitsBundled = Bundle.main.url(forResource: "plan-limits", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) } ?? Data()
        self.catalog = (try? PlanCatalog(bundledData: planLimitsBundled))
            ?? (try! PlanCatalog(bundledData: Data("""
                {"pro":{"five_hour":{"tokens":25000000},"seven_day":null},"max_5x":{"five_hour":{"tokens":120000000},"seven_day":{"tokens":3500000000}},"max_20x":{"five_hour":{"tokens":480000000},"seven_day":{"tokens":14000000000}}}
                """.utf8)))
        self.viewModel = StatsViewModel(
            store: store,
            pricing: initialPricing,
            calculator: UsageWindowCalculator(store: store),
            catalog: catalog
        )

        let monitor = ActivityMonitor(reader: reader, watchPath: claudeRoot.path)
        self.monitor = monitor
        monitor.onTick = { [weak viewModel, weak monitor] in
            guard let viewModel = viewModel, let monitor = monitor else { return }
            Task { @MainActor in
                viewModel.isActive = monitor.isActive
                await viewModel.refresh()
            }
        }

        self.updater = UpdaterController()
    }

    /// One-shot cleanup of UserDefaults keys that the v2 keychain/auto-detect
    /// path used. Old installs may have `planOverride = "auto"` or a stale
    /// `useUsageAPI` flag; the new picker only understands `none` plus
    /// `PlanTier` raw values.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "planOverride") == "auto" {
            defaults.set("none", forKey: "planOverride")
        }
        defaults.removeObject(forKey: "useUsageAPI")
    }

    func rebuildIndex() async {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("claude-stats")) ?? URL(fileURLWithPath: "/")
        try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("usage.db"))
        try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("usage.db-wal"))
        try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("usage.db-shm"))
        // App relaunch is required for the new DB to be used; the UI prompts the user.
    }

    func startBackgroundWork() {
        monitor.start()
        Task { await refreshPricingNow() }
        scheduleMidnightRollover()
        scheduleDailyPricingRefresh()
        registerWakeNotifications()
    }

    private func refreshPricingNow() async {
        await pricingFetcher.refresh()
        if let table = try? await pricingFetcher.load() {
            await MainActor.run { viewModel.update(pricing: table) }
        }
    }

    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        let now = Date()
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
              let nextMidnight = cal.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow) else {
            return
        }
        let interval = nextMidnight.timeIntervalSince(now)
        midnightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.viewModel.refresh()
                self?.scheduleMidnightRollover()
            }
        }
    }

    private func scheduleDailyPricingRefresh() {
        pricingTimer?.invalidate()
        pricingTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { await self?.refreshPricingNow() }
        }
    }

    private func registerWakeNotifications() {
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.tickNow()
                await self?.refreshPricingNow()
            }
        }
    }
}
