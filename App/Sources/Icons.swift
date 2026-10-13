import SwiftUI

/// An SF Symbol with a regular form for inline use and a form for colored badges.
struct Icon: Hashable {
    let regular: String
    let badge: String

    init(_ regular: String, badge: String? = nil) {
        self.regular = regular
        self.badge = badge ?? regular
    }
}

/// All icons used by the app. Reference icons only through these constants.
enum Icons {
    static let lightning = Icon("bolt", badge: "bolt.fill")
    /// Tokens: pieces of text the model reads and writes.
    static let coins = Icon("text.word.spacing")
    static let cloud = Icon("carbon.dioxide.cloud", badge: "carbon.dioxide.cloud.fill")
    static let gearSix = Icon("gearshape", badge: "gearshape.fill")
    static let terminalWindow = Icon("terminal", badge: "terminal.fill")
    static let power = Icon("power")
    static let info = Icon("info.circle", badge: "info")
    static let gauge = Icon("gauge.with.dots.needle.67percent")
    static let calendarBlank = Icon("calendar")
    static let table = Icon("tablecells", badge: "tablecells.fill")
    static let leaf = Icon("leaf", badge: "leaf.fill")
    static let pieChart = Icon("chart.pie", badge: "chart.pie.fill")
    static let folderOpen = Icon("folder", badge: "folder.fill")
    static let integrations = Icon("puzzlepiece.extension", badge: "puzzlepiece.extension.fill")
    static let checkmarkSeal = Icon("checkmark.circle.fill")
    static let monitor = Icon("menubar.rectangle")
    static let function = Icon("function")
    static let bell = Icon("bell", badge: "bell.fill")
    static let bookOpen = Icon("book", badge: "book.fill")
    static let export = Icon("square.and.arrow.up")
    static let arrowsClockwise = Icon("arrow.clockwise")
    static let plus = Icon("plus")
    static let trash = Icon("trash")
    static let close = Icon("xmark")
    static let mail = Icon("envelope")
    static let warning = Icon("exclamationmark.triangle.fill")
    static let checkmark = Icon("checkmark.circle.fill")
    static let circle = Icon("circle")
    static let previous = Icon("chevron.left")
    static let next = Icon("chevron.right")
}

/// An SF Symbol at a fixed point size, in its regular form.
struct SymbolIcon: View {
    let icon: Icon
    var size: CGFloat = 15

    init(_ icon: Icon, size: CGFloat = 15) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(systemName: icon.regular)
            .font(.system(size: size * 0.9, weight: .regular))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A white symbol on a rounded square of a system color, as in System Settings (SPEC 11.1).
struct IconBadge: View {
    static let defaultSize: CGFloat = 22

    let icon: Icon
    let color: Color
    var size: CGFloat = IconBadge.defaultSize

    init(_ icon: Icon, color: Color, size: CGFloat = IconBadge.defaultSize) {
        self.icon = icon
        self.color = color
        self.size = size
    }

    var body: some View {
        Image(systemName: icon.badge)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}
