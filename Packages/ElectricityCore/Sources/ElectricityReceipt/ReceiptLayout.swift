import AppKit
import ElectricityCore
import SwiftUI

/// Paper widths (appendix R3.1). Sizes are in printer dots at 203 dpi, used as points on screen.
public enum ReceiptPaper: String, Sendable, Hashable, CaseIterable, Identifiable {
    case mm80
    case mm58

    public var id: String { rawValue }

    /// Printable width in dots.
    public var dots: Int {
        switch self {
        case .mm80: 576
        case .mm58: 384
        }
    }

    /// Characters per line in the printer's 12 x 24 font.
    public var columns: Int {
        switch self {
        case .mm80: 48
        case .mm58: 32
        }
    }

    /// Paper width in millimetres.
    public var paperMillimetres: Double {
        switch self {
        case .mm80: 80
        case .mm58: 58
        }
    }

    /// Printable width in millimetres.
    public var printableMillimetres: Double {
        switch self {
        case .mm80: 72
        case .mm58: 48
        }
    }

    public var logoSize: CGFloat {
        switch self {
        case .mm80: 96
        case .mm58: 72
        }
    }
}

/// Column widths of each receipt table, per paper width and language (appendix R10). Every row adds up to the
/// paper's column count, and every cell gets a fixed frame, so numbers line up without padding with spaces.
public struct ReceiptLayout: Sendable, Hashable {
    public var paper: ReceiptPaper
    public var language: CLILanguageCode

    public init(paper: ReceiptPaper, language: CLILanguageCode) {
        self.paper = paper
        self.language = language
    }

    /// Width of one character column, in dots.
    public static let columnWidth: CGFloat = 12
    /// Indent of rows under a heading, in columns.
    public static let indent = 2

    public var columns: Int { paper.columns }
    public var width: CGFloat { CGFloat(paper.dots) }

    /// Model name, tokens and energy in the detail.
    public var detail: (name: Int, tokens: Int, energy: Int) {
        switch (paper, language) {
        case (.mm80, .zh): (26, 11, 11)
        case (.mm80, .en): (28, 10, 10)
        case (.mm58, .zh): (14, 9, 9)
        case (.mm58, .en): (16, 8, 8)
        }
    }

    /// Label and value of a document-information row.
    public var info: (label: Int, value: Int) {
        let label = language == .zh ? 8 : 9
        return (label, columns - label)
    }

    /// Space between two token-mix pairs on one line, in columns.
    public static let tokenPairGap = 2

    /// Label and value of a token-mix pair. 80 mm puts two pairs on a line, 58 mm one.
    public var tokenPair: (label: Int, value: Int) {
        switch paper {
        case .mm80: (13, 9)
        case .mm58: (16, columns - 16 - Self.indent)
        }
    }

    public var tokenPairsPerLine: Int { paper == .mm80 ? 2 : 1 }

    public static func points(_ columns: Int) -> CGFloat { CGFloat(columns) * columnWidth }
}

/// Fonts on the receipt grid (appendix R4). The body size is chosen so one SF Mono character is exactly one
/// 12-dot column, which keeps 48 (or 32) characters on a line as on the printer.
public enum ReceiptFont {
    /// SF Mono's advance is a fixed share of its size; measured once.
    static let advancePerPoint: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        let advance = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        return advance > 0 ? advance / 100 : 0.618
    }()

    public static var bodySize: CGFloat { ReceiptLayout.columnWidth / advancePerPoint }
    public static var smallSize: CGFloat { bodySize * 18 / 22 }
    /// Height of one body line, in dots: the printer's 24-dot character height.
    public static let lineHeight: CGFloat = 24

    static func body(_ weight: Font.Weight = .regular) -> Font {
        .system(size: bodySize, weight: weight, design: .monospaced).monospacedDigit()
    }

    static var small: Font { .system(size: smallSize, weight: .regular, design: .monospaced).monospacedDigit() }
}
