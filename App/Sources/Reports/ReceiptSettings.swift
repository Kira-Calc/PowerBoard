import AppKit
import ElectricityCore
import ElectricityReceipt
import SwiftUI

/// How "Print receipt" prints (appendix R2.3).
enum ReceiptPrintMethod: String, CaseIterable, Identifiable {
    /// Any printer set up in System Settings, through the print panel.
    case system
    /// A network thermal printer that speaks ESC/POS, without a driver.
    case network
    /// Printing turned off.
    case none

    var id: String { rawValue }
}

/// Receipt preferences and the per-day serial number.
@MainActor
enum ReceiptSettings {
    static let paperKey = "receipt.paper"
    static let printMethodKey = "receipt.printMethod"
    static let paperEffectKey = "receipt.paperEffect"
    static let showsQRCodeKey = "receipt.showQRCode"
    static let customerKey = "receipt.customer"
    private static let serialDayKey = "receipt.serial.day"
    private static let serialCountKey = "receipt.serial.count"

    static var defaultPaper: ReceiptPaper {
        UserDefaults.standard.string(forKey: paperKey).flatMap(ReceiptPaper.init) ?? .mm80
    }

    static var printMethod: ReceiptPrintMethod {
        UserDefaults.standard.string(forKey: printMethodKey).flatMap(ReceiptPrintMethod.init) ?? .system
    }

    /// The number the next receipt of the day gets: 1 for the first one made on a day, then 2, 3 and so on.
    /// Looking does not use it up; `useSerial` does, once the receipt is copied, saved or printed.
    static func nextSerial(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let defaults = UserDefaults.standard
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        return defaults.double(forKey: serialDayKey) == day ? defaults.integer(forKey: serialCountKey) + 1 : 1
    }

    /// Records that a receipt with this number went out, so the next one gets the following number.
    static func useSerial(_ number: Int, now: Date = Date(), calendar: Calendar = .current) {
        let defaults = UserDefaults.standard
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        let used = defaults.double(forKey: serialDayKey) == day ? defaults.integer(forKey: serialCountKey) : 0
        defaults.set(day, forKey: serialDayKey)
        defaults.set(max(used, number), forKey: serialCountKey)
    }

    /// The app's `ReceiptLogo` image when the asset catalog has one, otherwise the placeholder (appendix R5.2).
    static var logo: ReceiptLogo {
        if let image = NSImage(named: "ReceiptLogo")?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .image(image)
        }
        return .placeholder(symbol: Icons.receiptLogo.badge)
    }

    /// The language receipts are made in: the app's (appendix R10).
    static var language: CLILanguageCode { ReportStrings.app.language }

    /// `PowerBoard-receipt-2026-10-14-daily.png` (appendix R2.4).
    static func fileName(_ report: Report) -> String {
        let name = AppIdentity.displayName.replacingOccurrences(of: " ", with: "-")
        var day = Date.ISO8601FormatStyle().year().month().day()
        day.timeZone = .current
        let kind = switch report.period {
        case .day: "daily"
        case .week: "weekly"
        case .month: "monthly"
        case .year: "yearly"
        }
        return "\(name)-receipt-\(report.interval.start.formatted(day))-\(kind).png"
    }
}

/// System printing of a receipt (appendix R7.1): the 1-bit bitmap at one dot per pixel, on a page as wide as the
/// paper and as tall as the receipt, no margins, no scaling, no centring.
@MainActor
enum ReceiptSystemPrint {
    static func run(_ bitmap: MonochromeBitmap, paper: ReceiptPaper, window: NSWindow?) {
        guard let image = bitmap.cgImage() else { return }
        let pointsPerMillimetre = 72 / 25.4
        let paperWidth = paper.paperMillimetres * pointsPerMillimetre
        let printableWidth = paper.printableMillimetres * pointsPerMillimetre
        let height = (printableWidth * Double(bitmap.height) / Double(bitmap.width)).rounded(.up)
        let view = ReceiptPrintView(frame: NSRect(x: 0, y: 0, width: paperWidth, height: height), image: image,
                                    imageRect: NSRect(x: (paperWidth - printableWidth) / 2, y: 0, width: printableWidth, height: height))

        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = NSSize(width: paperWidth, height: height)
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.scalingFactor = 1

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

/// Draws the receipt bitmap without smoothing, so every dot stays a dot.
private final class ReceiptPrintView: NSView {
    private let image: CGImage
    private let imageRect: NSRect

    init(frame: NSRect, image: CGImage, imageRect: NSRect) {
        self.image = image
        self.imageRect = imageRect
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.interpolationQuality = .none
        context.draw(image, in: imageRect)
    }
}
