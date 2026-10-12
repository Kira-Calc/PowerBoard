import ElectricityCore
import SwiftUI

/// The app uses four accent colors only: green, yellow, orange and red. Green is reserved for
/// "cleaner" grid levels. Numbers use the primary text color; accents appear on icons, bars and charts.
enum Palette {
    static let clean = Color.green
    static let tokens = Color.yellow
    static let energy = Color.orange
    static let carbon = Color.red
    /// This Mac's own measured energy.
    static let local = Color.gray
    static let neutral = Color.gray

    static func source(_ source: UsageSource) -> Color {
        switch source {
        case .claudeCode: .orange
        case .codex: .yellow
        case .antigravity: .red
        }
    }
}

/// Text that rolls and blurs between values when it changes. Plain cross-fade when Reduce Motion is on.
struct RollingText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.35), value: text)
    }
}

/// Unit labels with proper chemical notation.
enum Units {
    /// "CO₂e" with a subscript 2.
    static let co2e = "CO\u{2082}e"
    static let gramsPerKWh = "gCO\u{2082}e/kWh"
}
