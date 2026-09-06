import SwiftUI

/// The status-bar popover: one glance, no scrolling.
struct MenuBarView: View {
    @Environment(AppMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(Theme.gridline)

            VStack(spacing: 0) {
                ForEach(monitor.apps) { app in
                    row(for: app)
                }
                if !monitor.dependencies.isEmpty {
                    Divider().overlay(Theme.gridline).padding(.vertical, 4)
                    ForEach(monitor.dependencies) { app in
                        row(for: app)
                    }
                }
            }
            .padding(.vertical, 4)

            Divider().overlay(Theme.gridline)

            footer
        }
        .frame(width: 280)
        .background(Theme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.count(monitor.visitsThisWeek))
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.inkPrimary)
            Text("visits this week · \(Format.count(monitor.totalVisits)) all time")
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func row(for app: MonitoredApp) -> some View {
        let state = monitor.health[app.slug] ?? .unknown
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(app.isDependency ? Theme.dependencySwatch : Theme.color(for: app.slug))
                .frame(width: 8, height: 8)

            Text(app.name)
                .font(.system(size: 12))
                .foregroundStyle(app.isDependency ? Theme.inkSecondary : Theme.inkPrimary)

            Spacer(minLength: 6)

            // Dependencies have no visitors of their own, so the column stays
            // blank rather than showing a misleading zero.
            if !app.isDependency {
                Text(Format.count(monitor.visitsThisWeek(for: app.slug)))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }

            StatusBadge(state: state)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            menuButton("Open dashboard", "macwindow") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton(
                monitor.isRefreshingStats ? "Refreshing…" : "Refresh now",
                "arrow.clockwise"
            ) {
                Task { await monitor.refreshAll() }
            }
            menuButton("Settings…", "gearshape") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton("Quit observor", "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func menuButton(
        _ title: String,
        _ icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.inkSecondary)
    }
}

/// The status-bar icon itself. Shape changes with state, not just colour, so it
/// reads at 16pt in a monochrome menu bar.
struct MenuBarLabel: View {
    @Environment(AppMonitor.self) private var monitor

    var body: some View {
        Image(systemName: monitor.anyDown ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
    }
}
