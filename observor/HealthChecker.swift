import Foundation

/// Probes each monitored site directly from this Mac.
///
/// This is the half of observor that needs no server: an outbound GET, a stop
/// watch, and a verdict. Nothing is written anywhere public.
struct HealthChecker {
    private let session: URLSession

    init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // A cached 200 would report an app as up long after it stopped being
        // up, which is the one failure mode a monitor must not have.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    func check(_ app: MonitoredApp, credentials: ObservorCredentials? = nil) async -> HealthResult {
        let start = Date()

        guard let url = app.probeURL else {
            return HealthResult(
                appSlug: app.slug,
                checkedAt: start,
                isUp: false,
                statusCode: 0,
                latencyMillis: 0,
                failureReason: "Malformed URL: \(app.url)"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("observor/1.0 (uptime check)", forHTTPHeaderField: "User-Agent")

        // Authenticated probes (the Supabase dependency) need the key, or every
        // check would come back 401 and report a healthy database as down.
        if app.needsKey, let key = credentials?.serviceKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)

            guard let http = response as? HTTPURLResponse else {
                return HealthResult(
                    appSlug: app.slug,
                    checkedAt: start,
                    isUp: false,
                    statusCode: 0,
                    latencyMillis: latency,
                    failureReason: "Non-HTTP response"
                )
            }

            let verdict = Self.verdict(statusCode: http.statusCode, body: data, app: app)
            return HealthResult(
                appSlug: app.slug,
                checkedAt: start,
                isUp: verdict.isUp,
                statusCode: http.statusCode,
                latencyMillis: latency,
                failureReason: verdict.reason
            )
        } catch {
            return HealthResult(
                appSlug: app.slug,
                checkedAt: start,
                isUp: false,
                statusCode: 0,
                latencyMillis: Int(Date().timeIntervalSince(start) * 1000),
                failureReason: (error as? URLError)?.localizedDescription
                    ?? error.localizedDescription
            )
        }
    }

    func checkAll(
        _ apps: [MonitoredApp],
        credentials: ObservorCredentials? = nil
    ) async -> [HealthResult] {
        await withTaskGroup(of: HealthResult.self) { group in
            for app in apps {
                group.addTask { await check(app, credentials: credentials) }
            }
            var results: [HealthResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// An app with a dedicated health endpoint reports its own readiness in the
    /// body — ggyst's `/api/health` returns 200 `{"status":"ready"}` but 503 if
    /// its database is unreachable. Trust that body over the status code where
    /// it exists; fall back to the status code for plain static sites.
    static func verdict(
        statusCode: Int,
        body: Data,
        app: MonitoredApp
    ) -> (isUp: Bool, reason: String?) {
        // A rejected key is a configuration problem, not an outage, and saying
        // "down" would send you hunting the wrong thing.
        if app.needsKey, statusCode == 401 || statusCode == 403 {
            return (false, "Key rejected (HTTP \(statusCode)) — check Settings")
        }

        if app.healthPath != nil,
           let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let status = payload["status"] as? String {
            let healthy = ["ready", "ok", "healthy", "up"].contains(status.lowercased())
            return (healthy, healthy ? nil : "Reported status: \(status)")
        }

        // A PostgREST read that returns rows proves the database is actually
        // serving, which a static host's 200 does not.
        //
        // The row count matters as much as the status code: RLS is closed on
        // these tables, so a key without service_role privileges gets a
        // perfectly successful `200 []`. Calling that "up" would report a
        // healthy database while observor could see none of it.
        if app.needsKey {
            guard (200..<300).contains(statusCode) else {
                return (false, "HTTP \(statusCode)")
            }
            let rows = (try? JSONSerialization.jsonObject(with: body)) as? [Any]
            guard let rows, !rows.isEmpty else {
                return (false, "Reachable but returned no rows — check the service_role key")
            }
            return (true, nil)
        }

        // 3xx counts as up: a redirect to www or https is a working site.
        let healthy = (200..<400).contains(statusCode)
        return (healthy, healthy ? nil : "HTTP \(statusCode)")
    }
}
