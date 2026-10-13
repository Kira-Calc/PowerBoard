import AppKit
import Foundation
import Testing
@testable import ElectricityCore
@testable import ElectricityReceipt

@Suite struct ReceiptEquivalentTests {
    private let items = try! EquivalentCatalog.bundled().items

    @Test(arguments: [0.5, 17.0, 230.0, 5_000.0, 400_000.0])
    func microwaveIsAlwaysFirst(energyWh: Double) {
        let matches = ReceiptEquivalents.select(energyWh: energyWh, items: items)
        #expect(matches.first?.item.id == "microwave_minute")
        #expect(matches.count <= 3)
        #expect(Set(matches.map(\.item.id)).count == matches.count)
    }

    @Test func otherTwoPreferAnApplianceAndAFood() {
        let matches = ReceiptEquivalents.select(energyWh: 500, items: items)
        #expect(matches.count == 3)
        #expect(matches.dropFirst().contains { $0.item.kind == .appliance })
        #expect(matches.dropFirst().contains { $0.item.kind == .food })
    }

    @Test func withoutAnchorFallsBackToTheUsualRule() {
        let plain = items.map { item -> EquivalentItem in
            var item = item
            item.receiptAnchor = false
            return item
        }
        let matches = ReceiptEquivalents.select(energyWh: 500, items: plain)
        #expect(matches == EquivalentSelector.select(energyWh: 500, items: plain, limit: 3))
    }

    @Test func bundledCatalogHasOneAnchorAndLabelsInBothLanguages() {
        #expect(items.filter(\.receiptAnchor).map(\.id) == ["microwave_minute"])
        for item in items {
            for language in ["zh", "en"] {
                let label = item.receiptLabel?[language]
                #expect(label?.components(separatedBy: "%@").count == 2, "\(item.id) \(language)")
            }
        }
    }

    @Test func labelsSplitIntoTextAndNumber() {
        let microwave = items.first { $0.id == "microwave_minute" }!
        let zh = ReceiptModel.equivalent(EquivalentMatch(item: microwave, count: 1.4), language: .zh)
        #expect(zh.label == "微波炉转了")
        #expect(zh.value == "1.4 次")
        let en = ReceiptModel.equivalent(EquivalentMatch(item: microwave, count: 1.4), language: .en)
        #expect(en.label == "Microwave runs:")
        #expect(en.value == "1.4")
    }

    @Test func amountBoundaries() {
        let cases: [(Double, String, String)] = [
            (0, "< 0.1", "< 0.1"),
            (0.0999, "< 0.1", "< 0.1"),
            (0.1, "0.1", "0.1"),
            (1.44, "1.4", "1.4"),
            (9.94, "9.9", "9.9"),
            (9.96, "10", "10"),
            (10, "10", "10"),
            (236.4, "236", "236"),
            (9_999, "9,999", "9,999"),
            (9_999.6, "1.0 万", "10k"),
            (10_000, "1.0 万", "10k"),
            (12_000, "1.2 万", "12k"),
        ]
        for (value, zh, en) in cases {
            #expect(ReceiptText.amount(value, language: .zh) == zh, "\(value)")
            #expect(ReceiptText.amount(value, language: .en) == en, "\(value)")
        }
    }
}

@Suite struct ReceiptModelTests {
    @Test func emptyDayStillMakesAReceipt() {
        let model = ReceiptFixtures.model(ReceiptFixtures.report(period: .day, lines: []), language: .zh)
        #expect(model.groups == [])
        #expect(model.others == nil)
        #expect(model.equivalents == [])
        #expect(model.emptyNote == "今天暂无用量记录")
        #expect(model.totalEnergy == "0.00 Wh")
        #expect(model.tokenMix?.shares == [0, 0, 0, 0])
        let english = ReceiptFixtures.model(ReceiptFixtures.report(period: .week, lines: []), language: .en)
        #expect(english.emptyNote == "No usage recorded in this period")
    }

    @Test func eightRowsFitAndANinthIsFolded() {
        let eight = ReceiptFixtures.model(ReceiptFixtures.report(period: .day, lines: ReceiptFixtures.lines(count: 8)), language: .zh)
        #expect(eight.groups?.flatMap(\.rows).count == 8)
        #expect(eight.others == nil)

        let nine = ReceiptFixtures.model(ReceiptFixtures.report(period: .day, lines: ReceiptFixtures.lines(count: 9)), language: .zh)
        #expect(nine.groups?.flatMap(\.rows).count == 8)
        #expect(nine.others?.name == "其他 1 项")
        // The folded row is the one with the least energy.
        #expect(nine.groups?.flatMap(\.rows).contains { $0.name == "model-8" } == false)
        let english = ReceiptFixtures.model(ReceiptFixtures.report(period: .day, lines: ReceiptFixtures.lines(count: 11)), language: .en)
        #expect(english.others?.name == "3 others")
    }

    @Test func rowsAreGroupedUnderTools() {
        let model = ReceiptFixtures.model(ReceiptFixtures.report(period: .day), language: .zh)
        #expect(model.groups?.map(\.tool) == ["Claude Code", "Codex"])
        #expect(model.groups?.first?.rows.map(\.name) == ["opus-test", "haiku-test"])
        #expect(model.groups?.first?.rows.first?.energyWh == "19")
    }

    @Test func longNamesAreCutWithAnEllipsis() {
        let name = "claude-opus-test-20990101-extended-preview"
        let cut = ReceiptText.truncate(name, columns: 23)
        #expect(cut.hasSuffix("…"))
        #expect(ReceiptText.columns(cut) <= 23)
        #expect(ReceiptText.truncate("模型名称很长很长很长很长", columns: 9) == "模型名称…")
        #expect(ReceiptText.truncate("short", columns: 23) == "short")
        #expect(ReceiptText.columns("电量 Wh") == 7)
    }

    @Test func documentInformation() {
        let model = ReceiptFixtures.model(ReceiptFixtures.report(period: .day), language: .zh, customer: "  一个很长很长很长很长很长很长的昵称名字  ")
        #expect(model.serial == "2026-1014-0003")
        #expect(model.kind == "日报")
        #expect(model.period == "2026-10-14 00:00–23:59")
        #expect(model.printed == "2026-10-14 23:58")
        #expect(model.cashier == "\(AppIdentity.cliName) \(AppIdentity.version)")
        #expect(model.customer?.count == ReceiptModel.maxCustomerLength)
        #expect(ReceiptFixtures.model(ReceiptFixtures.report(period: .day), language: .zh, customer: "   ").customer == nil)
        let week = ReceiptFixtures.model(ReceiptFixtures.report(period: .week), language: .en)
        #expect(week.period == "2026-10-12 – 10-18")
        #expect(week.bars?.values.count == 7)
    }

    @Test func yearListsMonthsAndTotalOnly() {
        let model = ReceiptFixtures.model(ReceiptFixtures.report(period: .year), language: .zh)
        #expect(model.groups == nil)
        #expect(model.equivalents == nil)
        #expect(model.tokenMix == nil)
        #expect(model.bars?.values.count == 12)
        #expect(model.bars?.firstLabel == "1月")
    }

    @Test func projectNamesNeverAppear() {
        let report = ReceiptFixtures.report(period: .day, projects: ["/Users/tester/Code/secret-project", "/tmp/hidden-thing"])
        for language in CLILanguageCode.allCases {
            let text = Self.allText(ReceiptFixtures.model(report, language: language))
            #expect(!text.contains("secret-project"))
            #expect(!text.contains("hidden-thing"))
            #expect(!text.contains("/Users/"))
        }
    }

    /// Every string the model holds, found by reflection, so a new field cannot slip past the check.
    static func allText(_ value: Any) -> String {
        if let string = value as? String { return string }
        return Mirror(reflecting: value).children.map { allText($0.value) }.joined(separator: "\n")
    }
}

@MainActor
@Suite struct ReceiptRenderingTests {
    @Test func pngIsTwiceTheDotWidth() throws {
        let model = ReceiptFixtures.model(ReceiptFixtures.report(period: .day), language: .zh)
        let plain = try ReceiptRenderer.png(model: model, paper: .mm80, logo: ReceiptFixtures.logo, paperEffect: false)
        #expect(NSBitmapImageRep(data: plain)?.pixelsWide == 1152)
        let paper = try ReceiptRenderer.png(model: model, paper: .mm80, logo: ReceiptFixtures.logo, paperEffect: true)
        #expect(NSBitmapImageRep(data: paper)?.pixelsWide == (576 + 2 * 32 + 2 * 40) * 2)
        let narrow = try ReceiptRenderer.png(model: model, paper: .mm58, logo: ReceiptFixtures.logo, paperEffect: false)
        #expect(NSBitmapImageRep(data: narrow)?.pixelsWide == 768)
    }

    @Test func printBitmapIsPureBlackAndWhite() throws {
        let model = ReceiptFixtures.model(ReceiptFixtures.report(period: .week), language: .zh)
        let bitmap = try #require(ReceiptRenderer.printBitmap(model: model, paper: .mm80, logo: ReceiptFixtures.logo))
        #expect(bitmap.width == 576)
        #expect(bitmap.bits.contains { $0 != 0 })
        let image = try #require(bitmap.cgImage())
        let values = Set(Self.grayPixels(image))
        #expect(values.isSubset(of: [0, 255]))
    }

    @Test func thresholdIs128() throws {
        // One row: 0, 127, 128, 255.
        let pixels: [UInt8] = [0, 127, 128, 255]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 4,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bitmap = try #require(MonochromeBitmap(image))
        #expect((0..<4).map { bitmap.isBlack(x: $0, y: 0) } == [true, true, false, false])
    }

    @Test func tokenBarSegmentsFillTheLine() {
        #expect(ReceiptTokenBar.segmentColumns([0.1, 0.05, 0.15, 0.7], columns: 46).reduce(0, +) == 46)
        #expect(ReceiptTokenBar.segmentColumns([1, 1, 1], columns: 46).reduce(0, +) == 46)
        #expect(ReceiptTokenBar.segmentColumns([0, 0, 0, 0], columns: 46) == [0, 0, 0, 0])
        // Tiny shares still get a column; the sum stays exact.
        let tiny = ReceiptTokenBar.segmentColumns([0.0002, 0.003, 0.009, 0.9878], columns: 46)
        #expect(tiny == [1, 1, 1, 43])
    }

    /// A Chinese model name must not move the number columns: the right part of the detail is the same pixels.
    @Test(arguments: [ReceiptPaper.mm80, .mm58], [CLILanguageCode.zh, .en])
    func numbersLineUpWithChineseNames(paper: ReceiptPaper, language: CLILanguageCode) throws {
        func image(firstName: String) throws -> CGImage {
            var lines = ReceiptFixtures.standardLines
            lines[0].model = firstName
            let model = ReceiptFixtures.model(ReceiptFixtures.report(period: .day, lines: lines), language: language)
            return try #require(ReceiptRenderer.image(model: model, paper: paper, logo: ReceiptFixtures.logo, paperEffect: false, scale: 1))
        }
        let latin = try image(firstName: "opus-test")
        let chinese = try image(firstName: "中文模型")
        #expect(latin.height == chinese.height)
        let nameColumns = ReceiptLayout(paper: paper, language: language).detail.name
        let x = Int(ReceiptLayout.points(nameColumns))
        let crop = CGRect(x: x, y: 0, width: latin.width - x, height: latin.height)
        let left = try #require(latin.cropping(to: crop))
        let right = try #require(chinese.cropping(to: crop))
        #expect(Self.grayPixels(left) == Self.grayPixels(right))
    }

    static func grayPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}
