import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppMonitor.self) private var monitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                statusSection
                trafficSection
                weeklySection
                errorsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.plane)
        .toolbar {
            ToolbarItem(placement: .status) {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            ToolbarItem {
                Button {
                    Task { await monitor.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshingStats)
            }
            ToolbarItem {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("observor")
    }

    private var statusLine: String {
        var parts: [String] = []
        if let last = monitor.lastHealthCheck {
            parts.append("checked \(Format.relative(last))")
        }
        if let last = monitor.lastStatsRefresh {
            parts.append("visits \(Format.relative(last))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Status

    private var statusSection: some View {
        SectionBox(
            title: "Status",
            subtitle: "Probed from this Mac every \(monitor.healthIntervalSeconds)s. History covers only the time observor was running."
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                spacing: 12
            ) {
                // Dependencies sit alongside the apps deliberately. The blog is
                // a static SPA whose posts load from Supabase in the browser,
                // so Netlify answers 200 whether or not the database is
                // serving — a green blog card alone would be misleading.
                ForEach(monitor.targets) { app in
                    StatusCard(app: app)
                }
            }
        }
    }

    // MARK: - Traffic

    private var trafficSection: some View {
        SectionBox(title: "Traffic", subtitle: trafficSubtitle) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    StatTile(
                        label: "Total visits",
                        value: Format.count(monitor.totalVisits),
                        caption: "distinct sessions, all time"
                    )
                    StatTile(
                        label: "Total pageviews",
                        value: Format.count(monitor.totalPageviews),
                        caption: "individual page loads"
                    )
                    StatTile(
                        label: "This week",
                        value: Format.count(monitor.visitsThisWeek),
                        caption: "visits since Monday"
                    )
                }

                if monitor.isConfigured {
                    perAppTable
                } else {
                    EmptyHint(
                        icon: "key",
                        message: "Add your Supabase URL and service key in Settings to see visit counts. Uptime works without them."
                    )
                }
            }
        }
    }

    private var trafficSubtitle: String {
        if let error = monitor.statsError { return error }
        return "A visit is one browser session; a pageview is one page load within it."
    }

    /// The table is not decoration. The validator flags the aqua series as
    /// sub-3:1 on the light surface, and a readable table of the same numbers
    /// is the required relief.
    private var perAppTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                Text("Visits").frame(width: 80, alignment: .trailing)
                Text("Pageviews").frame(width: 90, alignment: .trailing)
                Text("This week").frame(width: 80, alignment: .trailing)
                Text("Last visit").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.inkMuted)
            .padding(.bottom, 8)

            ForEach(monitor.apps) { app in
                let totals = monitor.totals(for: app.slug)
                Divider().overlay(Theme.gridline)
                HStack {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.color(for: app.slug))
                            .frame(width: 9, height: 9)
                        Text(app.name)
                            .foregroundStyle(Theme.inkPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(Format.count(totals?.visits ?? 0))
                        .frame(width: 80, alignment: .trailing)
                    Text(Format.count(totals?.pageviews ?? 0))
                        .frame(width: 90, alignment: .trailing)
                    Text(Format.count(monitor.visitsThisWeek(for: app.slug)))
                        .frame(width: 80, alignment: .trailing)
                    Text(Format.relative(totals?.lastSeen))
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 7)
            }
        }
        .card()
    }

    // MARK: - Weekly chart

    private var weeklySection: some View {
        SectionBox(title: "Visits per week", subtitle: "Last 12 weeks, ISO weeks starting Monday") {
            VStack(alignment: .leading, spacing: 12) {
                if monitor.weekly.isEmpty {
                    EmptyHint(
                        icon: "chart.bar",
                        message: monitor.isConfigured
                            ? "No visits recorded yet. The beacon writes the first row on the next real page load."
                            : "Connect Supabase in Settings to chart weekly visits."
                    )
                } else {
                    ChartLegend(entries: legendEntries)
                    weeklyChart
                        .frame(height: 240)
                        .card()
                }
            }
        }
    }

    private var legendEntries: [(name: String, color: Color)] {
        monitor.apps.map { ($0.name, Theme.color(for: $0.slug)) }
    }

    private var nameBySlug: [String: String] {
        Dictionary(uniqueKeysWithValues: monitor.apps.map { ($0.slug, $0.name) })
    }

    private var weeklyChart: some View {
        let names = monitor.apps.map(\.name)
        let colors = monitor.apps.map { Theme.color(for: $0.slug) }
        let lookup = nameBySlug

        return Chart(monitor.weekly) { row in
            // A fixed width narrower than the per-series slot leaves the
            // surface gap between adjacent bars; no borders are drawn to
            // separate them.
            BarMark(
                x: .value("Week", row.week, unit: .weekOfYear),
                y: .value("Visits", row.visits),
                width: .fixed(10)
            )
            .position(by: .value("App", lookup[row.appSlug] ?? row.appSlug))
            .foregroundStyle(by: .value("App", lookup[row.appSlug] ?? row.appSlug))
            .cornerRadius(4)
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.gridline)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { value in
                AxisTick().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Format.weekLabel(date))
                            .font(.caption2)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    // MARK: - Errors

    private var errorsSection: some View {
        SectionBox(
            title: "Client errors",
            subtitle: "Uncaught JavaScript errors reported by visitors' browsers, grouped by message"
        ) {
            if monitor.groupedErrors.isEmpty {
                EmptyHint(
                    icon: "checkmark.seal",
                    message: monitor.isConfigured
                        ? "No client errors reported."
                        : "Connect Supabase in Settings to see reported errors."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(monitor.groupedErrors.prefix(25).enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider().overlay(Theme.gridline) }
                        ErrorRow(group: group, appName: nameBySlug[group.appSlug] ?? group.appSlug)
                    }
                }
                .card()
            }
        }
    }
}

// MARK: - Status card

private struct StatusCard: View {
    @Environment(AppMonitor.self) private var monitor
    let app: MonitoredApp

    private var state: HealthState { monitor.health[app.slug] ?? .unknown }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(app.isDependency ? Theme.dependencySwatch : Theme.color(for: app.slug))
                        .frame(width: 9, height: 9)
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.inkPrimary)
                    if app.isDependency {
                        Text("dependency")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(Theme.inkMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Theme.gridline.opacity(0.6))
                            )
                    }
                }
                Spacer()
                StatusBadge(state: state)
            }

            HStack(spacing: 14) {
                metric("Latency", latencyText)
                metric("24h uptime", uptimeText)
            }

            UptimeStrip(samples: monitor.samples(for: app.slug, since: Date().addingTimeInterval(-86400)))

            if case let .down(reason) = state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.statusCritical)
                    .lineLimit(2)
            } else if let url = app.siteURL {
                Link(url.host() ?? app.url, destination: url)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .card()
    }

    private var latencyText: String {
        if case let .up(millis) = state { return "\(millis) ms" }
        return "—"
    }

    private var uptimeText: String {
        guard let fraction = monitor.uptimeFraction(for: app.slug) else { return "not measured" }
        return Format.percent(fraction)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.inkMuted)
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

// MARK: - Error row

private struct ErrorRow: View {
    let group: GroupedError
    let appName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.color(for: group.appSlug))
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.inkPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(appName)
                    if let path = group.sample.path {
                        Text("·")
                        Text(path)
                    }
                    Text("·")
                    Text(Format.relative(group.lastSeen))
                }
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
            }

            Spacer(minLength: 8)

            Text("\(group.occurrences)×")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.vertical, 9)
    }
}
