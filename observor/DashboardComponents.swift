import SwiftUI

// MARK: - Section scaffolding

/// A titled block. Every section on the dashboard uses one so the vertical
/// rhythm stays even.
struct SectionBox<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.inkPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            content
        }
    }
}

/// Card chrome: a hairline ring on the chart surface. No shadows, no fills
/// competing with the data.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.hairline.opacity(0.5), lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

// MARK: - Stat tile

/// When the story is one number, the number is the chart.
struct StatTile: View {
    let label: String
    let value: String
    var caption: String?
    var accent: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.inkMuted)

            Text(value)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(accent ?? Theme.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Status

/// Icon + word + color, never color alone — the status palette is sub-3:1 in
/// places and colorblind readers get nothing from hue here.
struct StatusBadge: View {
    let state: HealthState

    private var icon: String {
        switch state {
        case .up: "checkmark.circle.fill"
        case .down: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var label: String {
        switch state {
        case .up: "Up"
        case .down: "Down"
        case .unknown: "Checking"
        }
    }

    private var tint: Color {
        switch state {
        case .up: Theme.statusGood
        case .down: Theme.statusCritical
        case .unknown: Theme.inkMuted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
    }
}

/// 24 hours of probe results as one bucket per half hour.
///
/// Gaps are grey and mean "not measured", which is a genuinely different claim
/// from "down". observor only sees what happens while it is running, and the
/// strip must not imply otherwise.
struct UptimeStrip: View {
    let samples: [HealthSample]
    var hours: Int = 24
    var bucketMinutes: Int = 30

    private enum Bucket { case up, down, missing }

    private var buckets: [Bucket] {
        let count = hours * 60 / bucketMinutes
        let now = Date()
        let span = Double(bucketMinutes) * 60
        let start = now.addingTimeInterval(-Double(hours) * 3600)

        var result = [Bucket](repeating: .missing, count: count)
        for sample in samples {
            let offset = sample.checkedAt.timeIntervalSince(start)
            guard offset >= 0 else { continue }
            let index = min(count - 1, Int(offset / span))
            // Any failure in the window colours the bucket: a monitor should
            // surface the outage, not average it away.
            if !sample.isUp {
                result[index] = .down
            } else if result[index] == .missing {
                result[index] = .up
            }
        }
        return result
    }

    private func color(_ bucket: Bucket) -> Color {
        switch bucket {
        case .up: Theme.statusGood
        case .down: Theme.statusCritical
        case .missing: Theme.gridline
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let items = buckets
            let gap: CGFloat = 1.5
            let width = max(
                1,
                (geometry.size.width - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
            )
            HStack(spacing: gap) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, bucket in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(bucket))
                        .frame(width: width)
                }
            }
        }
        .frame(height: 16)
        .accessibilityLabel("Uptime over the last \(hours) hours")
    }
}

// MARK: - Legend

/// Always present for two or more series, so identity is never colour-alone.
struct ChartLegend: View {
    let entries: [(name: String, color: Color)]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(entries, id: \.name) { entry in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.color)
                        .frame(width: 9, height: 9)
                    Text(entry.name)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }
}

// MARK: - Empty state

struct EmptyHint: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.inkMuted)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
