import Foundation
import Observation
import SwiftData

/// Root application state: what is being monitored, whether it is up, and how
/// much traffic it is getting.
///
/// Modelled on `ios-ggyst/AppSession.swift` — one `@Observable` object that owns
/// the clients, the loading flags and the refresh loops, injected into the view
/// tree via `.environment`.
@Observable
@MainActor
final class AppMonitor {

    // MARK: - Configuration

    private(set) var credentials: ObservorCredentials?
    var isConfigured: Bool { credentials?.isComplete == true }

    /// Seconds between uptime probes. Persisted, because a monitor you have to
    /// re-tune on every launch is a monitor you stop using.
    var healthIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(healthIntervalSeconds, forKey: Self.healthIntervalKey)
            restartHealthLoop()
        }
    }

    /// Seconds between Supabase reads. Visit counts move slowly; five minutes
    /// is plenty and keeps the request count negligible.
    var statsIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(statsIntervalSeconds, forKey: Self.statsIntervalKey)
            restartStatsLoop()
        }
    }

    // MARK: - Monitored targets

    /// Everything in the registry, apps and dependencies alike.
    private(set) var targets: [MonitoredApp] = MonitoredApp.fallbacks

    /// Traffic-generating apps. These are the ones with visit counts, series
    /// colors and chart bars.
    var apps: [MonitoredApp] { targets.filter { !$0.isDependency } }

    /// Infrastructure the apps sit on. Uptime only.
    var dependencies: [MonitoredApp] { targets.filter(\.isDependency) }

    /// What actually gets probed. A dependency that needs a key is skipped
    /// until one is configured, so it shows as "not measured" rather than
    /// flashing red on a fresh install.
    private var probeTargets: [MonitoredApp] {
        targets.filter { !$0.needsKey || credentials?.isComplete == true }
    }

    // MARK: - Health

    private(set) var health: [String: HealthState] = [:]
    private(set) var lastProbe: [String: HealthResult] = [:]
    private(set) var lastHealthCheck: Date?

    // MARK: - Visits

    private(set) var totals: [VisitTotals] = []
    private(set) var weekly: [WeeklyVisits] = []
    private(set) var clientErrors: [ClientError] = []
    private(set) var lastStatsRefresh: Date?
    private(set) var isRefreshingStats = false
    private(set) var statsError: String?

    // MARK: - Derived

    var totalVisits: Int { totals.reduce(0) { $0 + $1.visits } }
    var totalPageviews: Int { totals.reduce(0) { $0 + $1.pageviews } }

    /// Visits recorded in the current ISO week, all apps combined.
    var visitsThisWeek: Int {
        let start = Self.startOfCurrentWeek()
        return weekly.filter { Calendar.iso8601UTC.isDate($0.week, inSameDayAs: start) }
            .reduce(0) { $0 + $1.visits }
    }

    func visitsThisWeek(for slug: String) -> Int {
        let start = Self.startOfCurrentWeek()
        return weekly.first {
            $0.appSlug == slug && Calendar.iso8601UTC.isDate($0.week, inSameDayAs: start)
        }?.visits ?? 0
    }

    func totals(for slug: String) -> VisitTotals? {
        totals.first { $0.appSlug == slug }
    }

    var anyDown: Bool {
        targets.contains { if case .down = health[$0.slug] { return true } else { return false } }
    }

    /// Errors collapsed by message so one bad deploy is a single row with a
    /// count, not two hundred rows.
    var groupedErrors: [GroupedError] {
        let groups = Dictionary(grouping: clientErrors) { "\($0.appSlug)|\($0.message)" }
        return groups.compactMap { key, rows -> GroupedError? in
            guard let newest = rows.max(by: { $0.occurredAt < $1.occurredAt }) else { return nil }
            return GroupedError(
                id: key,
                appSlug: newest.appSlug,
                message: newest.message,
                occurrences: rows.count,
                lastSeen: newest.occurredAt,
                sample: newest
            )
        }
        .sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Collaborators

    private let keychain = KeychainSecretStore()
    private let healthChecker = HealthChecker()
    private var modelContext: ModelContext?

    private var healthTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var hasStarted = false

    private static let healthIntervalKey = "observor.healthIntervalSeconds"
    private static let statsIntervalKey = "observor.statsIntervalSeconds"

    // MARK: - Lifecycle

    init() {
        let defaults = UserDefaults.standard
        let storedHealth = defaults.integer(forKey: Self.healthIntervalKey)
        let storedStats = defaults.integer(forKey: Self.statsIntervalKey)
        healthIntervalSeconds = storedHealth > 0 ? storedHealth : 60
        statsIntervalSeconds = storedStats > 0 ? storedStats : 300

        credentials = try? keychain.load()
    }

    /// Called from whichever scene appears first, once the SwiftData
    /// container exists. Both the window and the menu bar extra call it, so it
    /// has to be idempotent — restarting the loops on every window open would
    /// reset the probe cadence.
    func start(modelContext: ModelContext) {
        guard !hasStarted else { return }
        hasStarted = true
        self.modelContext = modelContext
        restartHealthLoop()
        restartStatsLoop()
    }

    // MARK: - Credentials

    func saveCredentials(_ new: ObservorCredentials) throws {
        try keychain.save(new)
        credentials = new
        statsError = nil
        restartStatsLoop()
    }

    func clearCredentials() throws {
        try keychain.clear()
        credentials = nil
        totals = []
        weekly = []
        clientErrors = []
        targets = MonitoredApp.fallbacks
    }

    /// Round-trips the given credentials without saving them, so Settings can
    /// tell a bad key from a bad URL before committing either.
    func verify(_ candidate: ObservorCredentials) async throws {
        try await SupabaseClient(credentials: candidate).verify()
    }

    // MARK: - Refresh loops

    private func restartHealthLoop() {
        healthTask?.cancel()
        let interval = healthIntervalSeconds
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshHealth()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func restartStatsLoop() {
        statsTask?.cancel()
        let interval = statsIntervalSeconds
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStats()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refreshAll() async {
        await refreshStats()
        await refreshHealth()
    }

    // MARK: - Health

    func refreshHealth() async {
        let toProbe = probeTargets
        guard !toProbe.isEmpty else { return }

        let results = await healthChecker.checkAll(toProbe, credentials: credentials)
        lastHealthCheck = Date()

        for result in results {
            lastProbe[result.appSlug] = result
            health[result.appSlug] = result.isUp
                ? .up(latencyMillis: result.latencyMillis)
                : .down(reason: result.failureReason ?? "Unreachable")
            persist(result)
        }
    }

    private func persist(_ result: HealthResult) {
        guard let modelContext else { return }
        modelContext.insert(
            HealthSample(
                appSlug: result.appSlug,
                checkedAt: result.checkedAt,
                isUp: result.isUp,
                statusCode: result.statusCode,
                latencyMillis: result.latencyMillis,
                failureReason: result.failureReason
            )
        )
        try? modelContext.save()
    }

    /// Probes recorded for `slug` since `since`, oldest first.
    func samples(for slug: String, since: Date) -> [HealthSample] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<HealthSample>(
            predicate: #Predicate { $0.appSlug == slug && $0.checkedAt >= since },
            sortBy: [SortDescriptor(\.checkedAt, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Share of probes in the last 24 hours that succeeded.
    ///
    /// Returns `nil` when nothing was recorded — which is a different statement
    /// from 0%, and the UI says so. observor only observes while it is running.
    func uptimeFraction(for slug: String, hours: Int = 24) -> Double? {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        let window = samples(for: slug, since: since)
        guard !window.isEmpty else { return nil }
        let up = window.count { $0.isUp }
        return Double(up) / Double(window.count)
    }

    /// Deletes probe history older than `days` so the local store stays small.
    func pruneHistory(olderThan days: Int = 30) {
        guard let modelContext else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let descriptor = FetchDescriptor<HealthSample>(
            predicate: #Predicate { $0.checkedAt < cutoff }
        )
        guard let stale = try? modelContext.fetch(descriptor), !stale.isEmpty else { return }
        for sample in stale { modelContext.delete(sample) }
        try? modelContext.save()
    }

    // MARK: - Visits

    func refreshStats() async {
        guard let credentials, credentials.isComplete else {
            statsError = nil
            return
        }

        isRefreshingStats = true
        defer { isRefreshingStats = false }

        let client = SupabaseClient(credentials: credentials)
        do {
            async let remoteApps = client.apps()
            async let remoteTotals = client.visitTotals()
            async let remoteWeekly = client.weeklyVisits()
            async let remoteErrors = client.recentErrors()

            let loaded = try await remoteApps
            if !loaded.isEmpty { targets = loaded }
            totals = try await remoteTotals
            weekly = try await remoteWeekly
            clientErrors = try await remoteErrors

            lastStatsRefresh = Date()
            statsError = nil
        } catch {
            statsError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Helpers

    private static func startOfCurrentWeek() -> Date {
        let calendar = Calendar.iso8601UTC
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return calendar.date(from: components) ?? Date()
    }
}

extension Calendar {
    /// Postgres `date_trunc('week', ...)` yields ISO weeks starting Monday, in
    /// UTC. Bucket comparisons here have to use the same calendar or the
    /// current week silently fails to match.
    static let iso8601UTC: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

extension MonitoredApp {
    /// Used before Supabase credentials are entered, and if the registry read
    /// fails. Uptime monitoring needs no server, so the app should be useful on
    /// first launch rather than showing an empty screen. Keep in sync with the
    /// seed rows in `observor-schema.sql`.
    static let fallbacks: [MonitoredApp] = [
        MonitoredApp(
            slug: "ggyst",
            name: "ggyst",
            url: "https://www.ggyst.com",
            healthPath: "/api/health",
            active: true,
            kind: "app",
            requiresKey: false
        ),
        MonitoredApp(
            slug: "weblog",
            name: "Portfolio",
            url: "https://chadingramcx.com",
            healthPath: nil,
            active: true,
            kind: "app",
            requiresKey: false
        ),
        MonitoredApp(
            slug: "blog",
            name: "Yappin'",
            url: "https://yappinblog.netlify.app",
            healthPath: nil,
            active: true,
            kind: "app",
            requiresKey: false
        ),
        MonitoredApp(
            slug: "supabase",
            name: "Supabase",
            url: "https://kcydfdpnvykrtbmandca.supabase.co",
            healthPath: "/rest/v1/observor_apps?select=slug&limit=1",
            active: true,
            kind: "dependency",
            requiresKey: true
        )
    ]
}
