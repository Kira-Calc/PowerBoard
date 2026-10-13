import Foundation

/// Character-grid helpers for the receipt (appendix R3.1): a Latin letter or digit takes one column,
/// a Chinese character two.
public enum ReceiptText {
    /// Columns a string takes on the receipt grid.
    public static func columns(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + columns($1) }
    }

    static func columns(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            2
        case 0x0300...0x036F, 0x200B...0x200F:
            0
        default:
            1
        }
    }

    /// Cuts `text` to at most `width` columns, ending in an ellipsis when it was cut.
    public static func truncate(_ text: String, columns width: Int) -> String {
        guard columns(text) > width else { return text }
        guard width > 1 else { return width == 1 ? "…" : "" }
        var result = ""
        var used = 0
        for character in text {
            let size = columns(String(character))
            if used + size > width - 1 { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }

    /// Numbers in the "equivalent to" section (appendix R6.3): "< 0.1", one decimal up to 10, whole numbers up to
    /// 9,999, then "1.2 万" in Chinese or "12k" in English. Separators follow the language.
    public static func amount(_ value: Double, language: CLILanguageCode) -> String {
        let locale = Locale(identifier: language == .zh ? "zh-Hans" : "en")
        switch value {
        case ..<0.1:
            return "< " + 0.1.formatted(.number.locale(locale).precision(.fractionLength(1)))
        case ..<10:
            // Values just under 10 round to "10.0"; show them as the whole number the next range would.
            let rounded = (value * 10).rounded() / 10
            if rounded >= 10 { return 10.formatted(.number.locale(locale)) }
            return value.formatted(.number.locale(locale).precision(.fractionLength(1)))
        case ..<10_000:
            let rounded = value.rounded()
            if rounded >= 10_000 { return amount(10_000, language: language) }
            return rounded.formatted(.number.locale(locale).precision(.fractionLength(0)))
        default:
            if language == .zh {
                return (value / 10_000).formatted(.number.locale(locale).precision(.fractionLength(1))) + " 万"
            }
            return (value / 1000).formatted(.number.locale(locale).precision(.fractionLength(0))) + "k"
        }
    }
}
