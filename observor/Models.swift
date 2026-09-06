import Foundation
import SwiftData

// MARK: - Rows read from Supabase

/// One monitored target. Mirrors a row of the `observor_apps` table, so adding
/// a fourth app is an INSERT rather than a release of this app.
struct MonitoredApp: Codable, Identifiable, Hashable, Sendable {
    let slug: String
    let name: String
    let url: String
    /// Path to probe for uptime, query string included. `nil` probes the root.
    let healthPath: String?
    let active: Bool
    /// `"app"` or `"dependency"`. Decoded as a string so an unrecognised value
    /// from a future schema degrades to "treat it as an app" rather than
    /// failing the whole registry read.
    let kind: String?
    /// Whether the probe must carry the Supabase key.
    let requiresKey: Bool?

    var id: String { slug }

    /// Infrastructure the apps sit on. Monitored for uptime, but absent from
    /// the visit charts — it has no visitors of its own.
    var isDependency: Bool { kind == "dependency" }

    var needsKey: Bool { requiresKey == true }

    /// The URL the health checker actually hits.
    ///
    /// Built by string concatenation rather than `URLComponents.path`, because
    /// a health path may carry a query (`?select=slug&limit=1`) and assigning
    /// it to `.path` would silently drop it.
    var probeURL: URL? {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        let path = healthPath ?? "/"
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path))
    }

    /// The URL "Open site" uses — always the site root, never the health path.
    var siteURL: URL? { URL(string: url) }
}

/// A row of the `observor_visit_totals` view.
///
/// `visits` counts distinct sessions and `pageviews` counts rows; the gap
/// between them is how many pages a typical visitor reads.
struct VisitTotals: Codable, Identifiable, Sendable {
    let appSlug: String
    let appName: String
    let visits: Int
    let pageviews: Int
    let firstSeen: Date?
    let lastSeen: Date?

    var id: String { appSlug }
}

/// A row of the `observor_visits_weekly` view. `week` is the Monday that starts
/// the ISO week, as produced by `date_trunc('week', ...)`.
struct WeeklyVisits: Codable, Identifiable, Sendable {
    let appSlug: String
    let week: Date
    let visits: Int
    let pageviews: Int

    var id: String { "\(appSlug)@\(week.timeIntervalSince1970)" }
}

/// A row of `observor_errors` — one uncaught JS error from a visitor's browser.
struct ClientError: Codable, Identifiable, Sendable {
    let id: String
    let appSlug: String
    let path: String?
    let message: String
    let source: String?
    let line: Int?
    let stack: String?
    let occurredAt: Date
}

/// Client errors collapsed by message, since one bad deploy produces the same
/// error from many sessions and the count is the interesting part.
struct GroupedError: Identifiable, Sendable {
    let id: String
    let appSlug: String
    let message: String
    let occurrences: Int
    let lastSeen: Date
    let sample: ClientError
}

// MARK: - Locally stored uptime history

/// One health probe result.
///
/// Stored locally in SwiftData rather than in Supabase because observor is the
/// only thing that produces it. The consequence, which the UI must be honest
/// about: history only exists for periods when this app was actually running.
@Model
final class HealthSample {
    var appSlug: String = ""
    var checkedAt: Date = Date()
    var isUp: Bool = false
    var statusCode: Int = 0
    var latencyMillis: Int = 0
    var failureReason: String?

    init(
        appSlug: String,
        checkedAt: Date,
        isUp: Bool,
        statusCode: Int,
        latencyMillis: Int,
        failureReason: String?
    ) {
        self.appSlug = appSlug
        self.checkedAt = checkedAt
        self.isUp = isUp
        self.statusCode = statusCode
        self.latencyMillis = latencyMillis
        self.failureReason = failureReason
    }
}

/// The live result of the most recent probe, held in memory.
struct HealthResult: Sendable, Equatable {
    let appSlug: String
    let checkedAt: Date
    let isUp: Bool
    let statusCode: Int
    let latencyMillis: Int
    let failureReason: String?
}

/// What the UI shows for an app right now.
enum HealthState: Sendable, Equatable {
    /// No probe has completed yet this launch.
    case unknown
    case up(latencyMillis: Int)
    case down(reason: String)

    var isUp: Bool {
        if case .up = self { return true }
        return false
    }
}
