import Foundation

enum SupabaseError: Error, LocalizedError {
    case notConfigured
    case wrongKey
    case invalidBaseURL
    case invalidResponse
    case http(status: Int, message: String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add your Supabase URL and service key in Settings."
        case .wrongKey:
            """
            Connected, but the registry came back empty. That is what the anon \
            key sees, because these tables have no public read policy. Use the \
            service_role key instead.
            """
        case .invalidBaseURL:
            "That Supabase URL is not valid."
        case .invalidResponse:
            "Supabase returned an unexpected response."
        case let .http(status, message):
            status == 401 || status == 403
                ? "Supabase rejected the key (\(status)). Check that it is the service_role key, not the anon key."
                : "Supabase returned \(status): \(message)"
        case let .transport(error):
            error.localizedDescription
        }
    }
}

/// Read-only client for the observor tables and views.
///
/// Same shape as `ios-ggyst/APIClient.swift`: a value type over `URLSession`
/// with its own decoder and a typed error enum. It only ever issues GETs — the
/// beacons in the web apps are the sole writers.
struct SupabaseClient {
    let credentials: ObservorCredentials

    private let session: URLSession
    private let decoder: JSONDecoder

    init(credentials: ObservorCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom(Self.decodePostgresDate)
        self.decoder = decoder
    }

    // MARK: - Queries

    /// The app registry. Read with the service key, which bypasses RLS — the
    /// table has no public select policy.
    func apps() async throws -> [MonitoredApp] {
        try await get(
            "observor_apps",
            query: [
                "select": "slug,name,url,health_path,active,kind,requires_key",
                "active": "eq.true",
                "order": "kind.asc,name.asc"
            ]
        )
    }

    /// All-time visits and pageviews per app.
    func visitTotals() async throws -> [VisitTotals] {
        try await get(
            "observor_visit_totals",
            query: ["select": "*", "order": "visits.desc"]
        )
    }

    /// Weekly buckets, newest first, limited to the last `weeks` weeks.
    func weeklyVisits(weeks: Int = 12) async throws -> [WeeklyVisits] {
        let cutoff = Calendar(identifier: .iso8601).date(
            byAdding: .weekOfYear,
            value: -weeks,
            to: Date()
        ) ?? Date.distantPast

        return try await get(
            "observor_visits_weekly",
            query: [
                "select": "*",
                "week": "gte.\(Self.dayFormatter.string(from: cutoff))",
                "order": "week.asc"
            ]
        )
    }

    /// Most recent client-side errors across all apps.
    func recentErrors(limit: Int = 100) async throws -> [ClientError] {
        try await get(
            "observor_errors",
            query: [
                "select": "*",
                "order": "occurred_at.desc",
                "limit": String(limit)
            ]
        )
    }

    /// Cheap round-trip used by Settings to validate credentials before saving.
    ///
    /// An empty result is treated as a failure, not a success. The tables have
    /// no public select policy, so the anon key gets `200 []` rather than a
    /// 401 — without this guard, pasting the wrong key would verify cleanly and
    /// then show an empty dashboard forever.
    func verify() async throws {
        let registry = try await apps()
        guard !registry.isEmpty else { throw SupabaseError.wrongKey }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ table: String, query: [String: String]) async throws -> T {
        guard credentials.isComplete else { throw SupabaseError.notConfigured }
        guard
            let base = credentials.baseURL,
            var components = URLComponents(
                url: base.appendingPathComponent("rest/v1/\(table)"),
                resolvingAgainstBaseURL: false
            )
        else {
            throw SupabaseError.invalidBaseURL
        }

        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw SupabaseError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(credentials.serviceKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(credentials.serviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.http(status: http.statusCode, message: body)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SupabaseError.invalidResponse
        }
    }

    // MARK: - Date decoding

    /// The ISO8601 formatters below are built once and only parse afterwards.
    /// Foundation's date formatters are documented thread-safe for that, which
    /// is what their `nonisolated(unsafe)` is asserting.
    ///
    /// PostgREST hands back two shapes and `ISO8601DateFormatter` accepts
    /// neither universally: `timestamptz` carries 1-6 fractional digits, and a
    /// plain `date` column (the weekly bucket) has no time at all. Try each.
    private nonisolated static func decodePostgresDate(_ decoder: Decoder) throws -> Date {
        let raw = try decoder.singleValueContainer().decode(String.self)

        if let date = fractionalFormatter.date(from: raw) { return date }
        if let date = plainFormatter.date(from: raw) { return date }
        if let date = dayFormatter.date(from: raw) { return date }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognised date format: \(raw)"
            )
        )
    }

    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `date` columns are timezone-free calendar days. Parsed in UTC so a week
    /// bucket does not slide a day when the Mac is west of Greenwich.
    nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
