import ElectricityCore
import SwiftUI

/// Grid level texts and colors shared by all display layers (SPEC 10.5).
enum GridText {
    static func level(_ level: GridLevel?) -> String {
        switch level {
        case .cleaner: String(localized: "grid.level.cleaner")
        case .typical: String(localized: "grid.level.typical")
        case .lessClean: String(localized: "grid.level.lessClean")
        case nil: String(localized: "grid.level.unknown")
        }
    }

    /// Green for cleaner, neutral for typical, orange for less clean. Red is not used, so it does not read as an error.
    static func color(_ level: GridLevel?) -> Color {
        switch level {
        case .cleaner: Palette.clean
        case .typical: .secondary
        case .lessClean: .orange
        case nil: .gray
        }
    }

    static func provider(_ provider: GridProvider) -> String {
        switch provider {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .google: "Google"
        }
    }

    static func candidateName(_ candidate: GridCandidate) -> String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? candidate.nameZh : candidate.nameEn
    }

    /// "Server grid: cleaner". A hollow dot marks an estimated location; the info button explains it.
    static func summary(_ status: GridStatus) -> String {
        String(format: String(localized: "grid.summary"), level(status.level))
    }
}

/// Filled when the location is known, hollow when it is estimated or unknown (SPEC 10.5).
struct GridDot: View {
    let level: GridLevel?
    let certainty: LocationCertainty
    var size: CGFloat = 8

    var body: some View {
        let color = GridText.color(level)
        Group {
            if certainty == .known && level != nil {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: max(1.5, size / 5))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One line for the popover: dot, level, place and update time.
struct GridLine: View {
    let status: GridStatus

    var body: some View {
        HStack(spacing: 6) {
            GridDot(level: status.level, certainty: status.certainty)
            Text(GridText.summary(status))
            if let updated = status.updatedAt {
                Text(String(format: String(localized: "grid.updated"), Formatting.time(updated)))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
