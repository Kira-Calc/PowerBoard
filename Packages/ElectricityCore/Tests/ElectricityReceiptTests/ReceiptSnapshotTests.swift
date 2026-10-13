import AppKit
import Foundation
import Testing
@testable import ElectricityCore
@testable import ElectricityReceipt

/// Layout snapshots (appendix R11): both paper widths, both languages, all four periods, 16 reference images in
/// Snapshots/Receipt. A missing reference is recorded and the test passes; set RECORD_RECEIPT_SNAPSHOTS=1 to
/// record them all again after an intended change. On a mismatch the new image is written next to the
/// reference with a ".failed.png" suffix.
@MainActor
@Suite struct ReceiptSnapshotTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Snapshots/Receipt")
    /// Share of pixels allowed to differ by more than a quarter of the gray range, for font smoothing changes.
    static let tolerance = 0.002

    @Test(arguments: ReceiptPaper.allCases, [CLILanguageCode.zh, .en])
    func snapshot(paper: ReceiptPaper, language: CLILanguageCode) throws {
        for period in ReportPeriod.allCases {
            let model = ReceiptFixtures.model(ReceiptFixtures.report(period: period), language: language, customer: "Tester")
            let image = try #require(ReceiptRenderer.image(model: model, paper: paper, logo: ReceiptFixtures.logo, paperEffect: false, scale: 1))
            try Self.compare(image, name: "\(paper.rawValue)-\(language.rawValue)-\(period.rawValue)")
        }
    }

    static func compare(_ image: CGImage, name: String) throws {
        let url = directory.appendingPathComponent("\(name).png")
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let record = ProcessInfo.processInfo.environment["RECORD_RECEIPT_SNAPSHOTS"] == "1"
        guard !record, let reference = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url)
            return
        }
        let failed = directory.appendingPathComponent("\(name).failed.png")
        guard reference.width == image.width, reference.height == image.height else {
            try png.write(to: failed)
            Issue.record("\(name): size \(image.width)x\(image.height), reference \(reference.width)x\(reference.height)")
            return
        }
        let actual = ReceiptRenderingTests.grayPixels(image)
        let expected = ReceiptRenderingTests.grayPixels(reference)
        let differing = zip(actual, expected).filter { abs(Int($0) - Int($1)) > 64 }.count
        if Double(differing) / Double(actual.count) > tolerance {
            try png.write(to: failed)
            Issue.record("\(name): \(differing) pixels differ")
        } else {
            try? FileManager.default.removeItem(at: failed)
        }
    }
}
