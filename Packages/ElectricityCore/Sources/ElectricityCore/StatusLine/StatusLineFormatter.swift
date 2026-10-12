import Foundation

/// Language of the `powerboard` command output (SPEC 8.3). English by default.
public enum CLILanguageCode: String, Sendable, CaseIterable {
    case en
    case zh
}

public enum StatusLineFormat: String, Sendable, CaseIterable {
    case `default`
    case compact
}

/// Builds the one-line text for the Claude Code status line from the snapshot (SPEC 8.3).
/// Kept separate from how the text is delivered, so other terminals can reuse it.
public enum StatusLineFormatter {
    /// Snapshots older than this are marked as not updated.
    public static let staleAfter: TimeInterval = 300

    public static func render(
        snapshot: Snapshot?,
        sessionID: String?,
        language: CLILanguageCode,
        format: StatusLineFormat,
        color: Bool,
        now: Date = Date()
    ) -> String {
        guard let snapshot else {
            return language == .zh
                ? "\(AppIdentity.cliName)：打开 \(AppIdentity.displayName) 开始统计"
                : "\(AppIdentity.cliName): open the app to start tracking"
        }
        let style = Style(enabled: color)
        let today = ValueFormatting.energy(wh: snapshot.today.energyWh.mid).text
        let carbon = ValueFormatting.carbon(grams: snapshot.today.co2G).text
        let session = sessionID.flatMap { snapshot.sessions[$0] }.map { ValueFormatting.energy(wh: $0.energyWhMid).text }

        let rolling = snapshot.today.window == .last24Hours
        var parts: [String]
        switch (format, language) {
        case (.compact, _):
            parts = [style.value(today), style.value(carbon)]
        case (.default, .en):
            parts = [
                session.map { "\(style.value($0)) session" },
                rolling ? "\(style.value(today)) 24h" : "\(style.value(today)) today",
                "\(style.value(carbon)) CO2e",
            ].compactMap { $0 }
        case (.default, .zh):
            parts = [
                session.map { "本会话 \(style.value($0))" },
                rolling ? "24 小时 \(style.value(today))" : "今日 \(style.value(today))",
                "\(style.value(carbon)) CO2e",
            ].compactMap { $0 }
        }

        if let grid = snapshot.today.grid, let level = grid.level {
            parts.append(gridText(level: level, certainty: grid.locationCertainty, language: language))
        }
        var line = parts.joined(separator: style.separator)
        if snapshot.isStale(now: now, maxAge: staleAfter) {
            line += style.dim(language == .zh ? "（未更新）" : " (stale)")
        }
        return line
    }

    /// "grid: cleaner (est.)" or "电网：较清洁（推测）". Only shown when live grid data is connected (SPEC 10.5).
    static func gridText(level: GridLevel, certainty: LocationCertainty, language: CLILanguageCode) -> String {
        let estimated = certainty != .known
        switch language {
        case .en:
            let name = switch level {
            case .cleaner: "cleaner"
            case .typical: "typical"
            case .lessClean: "less clean"
            }
            return "grid: \(name)" + (estimated ? " (est.)" : "")
        case .zh:
            let name = switch level {
            case .cleaner: "较清洁"
            case .typical: "一般"
            case .lessClean: "较不清洁"
            }
            return "电网：\(name)" + (estimated ? "（推测）" : "")
        }
    }

    /// ANSI styling, or plain text when color is off (`NO_COLOR`, SPEC 8.3).
    struct Style {
        let enabled: Bool

        var separator: String { enabled ? " \u{1B}[2m|\u{1B}[0m " : " | " }

        func value(_ text: String) -> String {
            enabled ? "\u{1B}[1m\(text)\u{1B}[0m" : text
        }

        func dim(_ text: String) -> String {
            enabled ? "\u{1B}[2m\(text)\u{1B}[0m" : text
        }
    }
}
