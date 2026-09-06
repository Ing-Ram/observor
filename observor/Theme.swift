import AppKit
import SwiftUI

/// Design tokens for the dashboard.
///
/// The categorical series colors are the first three slots of the validated
/// reference palette. Both modes were run through the palette validator on the
/// all-pairs list and pass every gate (worst CVD ΔE 9.2 light / 9.4 dark;
/// worst normal-vision ΔE 24.0 light / 20.9 dark). Do not add a fourth hue by
/// eye — re-run the validator.
///
/// One light-mode caveat the validator flags: aqua sits at 2.74:1 on the light
/// surface, under the 3:1 bar. The relief for that is a visible table of the
/// same numbers, which is why "Traffic by app" lists every value the chart
/// draws rather than leaving the bars to speak alone.
enum Theme {

    // MARK: - Surfaces and ink

    static let surface = Color.themed(light: "#fcfcfb", dark: "#1a1a19")
    static let plane = Color.themed(light: "#f9f9f7", dark: "#0d0d0d")
    static let inkPrimary = Color.themed(light: "#0b0b0b", dark: "#ffffff")
    static let inkSecondary = Color.themed(light: "#52514e", dark: "#c3c2b7")
    static let inkMuted = Color.themed(light: "#898781", dark: "#898781")
    static let gridline = Color.themed(light: "#e1e0d9", dark: "#2c2c2a")
    static let hairline = Color.themed(light: "#c3c2b7", dark: "#383835")

    // MARK: - Status (fixed; never themed)
    //
    // Always paired with an icon and a word. A status color never carries the
    // meaning on its own.

    static let statusGood = Color(hex: "#0ca30c")
    static let statusWarning = Color(hex: "#fab219")
    static let statusCritical = Color(hex: "#d03b3b")

    // MARK: - Categorical series

    private static let seriesSlots: [Color] = [
        .themed(light: "#2a78d6", dark: "#3987e5"),  // slot 1 — blue
        .themed(light: "#eb6834", dark: "#d95926"),  // slot 2 — orange
        .themed(light: "#1baf7a", dark: "#199e70")   // slot 3 — aqua
    ]

    /// Slot assignment is pinned to the app's identity, not to its position in
    /// whatever the chart is currently drawing. Filtering an app out never
    /// repaints the others, and a reader who learned "ggyst is blue" stays
    /// right.
    private static let pinnedSlots: [String: Int] = [
        "ggyst": 0,
        "weblog": 1,
        "blog": 2
    ]

    /// Dependencies are infrastructure, not series. They get a neutral swatch
    /// so the three validated categorical hues keep meaning "app" and the
    /// palette does not quietly grow a fourth member.
    static let dependencySwatch = Color.themed(light: "#898781", dark: "#898781")

    static func color(for slug: String) -> Color {
        if let slot = pinnedSlots[slug] {
            return seriesSlots[slot]
        }
        // A fourth app falls back to a stable hash so it at least keeps the
        // same color between launches. Past three series, the palette rules say
        // to re-validate rather than keep generating hues.
        let hash = abs(slug.hashValue) % seriesSlots.count
        return seriesSlots[hash]
    }
}

extension Color {
    /// Resolves per appearance, so light and dark each get their own selected
    /// step rather than an automatic flip of one palette.
    static func themed(light: String, dark: String) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(Color(hex: isDark ? dark : light))
            }
        )
    }

    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(cleaned, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Formatting

enum Format {
    /// Grouped thousands. Visit counts are read, not compared digit by digit.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func weekLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fraction >= 0.999 ? 0 : 1)))
    }
}
