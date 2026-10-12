import Foundation

/// Unit choice for energy values (SPEC 8.1).
public enum EnergyUnit: String, Sendable, Hashable, CaseIterable, Codable {
    case auto
    case wh
    case kwh
}

/// A formatted number and its unit, kept apart so the UI can style them separately.
public struct FormattedValue: Sendable, Hashable {
    public var number: String
    public var unit: String

    public var text: String { unit.isEmpty ? number : "\(number) \(unit)" }
}

/// Number formatting shared by the app and the CLI. Uses "." as the decimal separator in all languages.
/// Precision follows the size of the value so estimates are not shown more precisely than they are known.
public enum ValueFormatting {
    /// `decimals` nil means automatic.
    public static func energy(wh: Double, unit: EnergyUnit = .auto, decimals: Int? = nil) -> FormattedValue {
        let useKWh = unit == .kwh || (unit == .auto && wh >= 1000)
        if useKWh {
            let kwh = wh / 1000
            return FormattedValue(number: number(kwh, decimals: decimals ?? autoDecimals(kwh, small: 2)), unit: "kWh")
        }
        return FormattedValue(number: number(wh, decimals: decimals ?? (wh < 1 ? 2 : wh < 10 ? 1 : 0)), unit: "Wh")
    }

    /// Formats an estimate. In automatic mode the unit follows the mid value, so all three share one unit.
    public static func energy(_ estimate: Estimate, unit: EnergyUnit = .auto, decimals: Int? = nil) -> (low: FormattedValue, mid: FormattedValue, high: FormattedValue) {
        let resolved: EnergyUnit = unit == .auto ? (estimate.mid >= 1000 ? .kwh : .wh) : unit
        return (
            energy(wh: estimate.low, unit: resolved, decimals: decimals),
            energy(wh: estimate.mid, unit: resolved, decimals: decimals),
            energy(wh: estimate.high, unit: resolved, decimals: decimals)
        )
    }

    public static func carbon(grams: Double) -> FormattedValue {
        if grams >= 1000 {
            let kg = grams / 1000
            return FormattedValue(number: number(kg, decimals: autoDecimals(kg, small: 2)), unit: "kg")
        }
        return FormattedValue(number: number(grams, decimals: grams < 10 ? 1 : 0), unit: "g")
    }

    /// Compact token counts: 950, 12.3K, 4.5M, 1.2B.
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case ..<1000: return String(count)
        case ..<1e6: return compact(value / 1e3) + "K"
        case ..<1e9: return compact(value / 1e6) + "M"
        default: return compact(value / 1e9) + "B"
        }
    }

    static func autoDecimals(_ value: Double, small: Int) -> Int {
        switch abs(value) {
        case ..<10: small
        case ..<100: 1
        default: 0
        }
    }

    static func compact(_ value: Double) -> String {
        number(value, decimals: value < 100 ? 1 : 0)
    }

    static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(max(0, decimals))f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
