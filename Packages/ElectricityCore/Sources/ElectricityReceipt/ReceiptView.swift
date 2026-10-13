import CoreImage
import CoreImage.CIFilterBuiltins
import ElectricityCore
import SwiftUI

/// The receipt's header logo (appendix R5): the app's `ReceiptLogo` image when it has one, otherwise the
/// placeholder, a rounded frame around a lightning symbol.
public enum ReceiptLogo: Sendable, Hashable {
    case image(CGImage)
    /// SF Symbol name for the placeholder; the app passes its own icon constant.
    case placeholder(symbol: String)
}

/// One receipt, laid out on the thermal-paper grid (appendix R3). Always black on white or on the paper colour,
/// whatever the system appearance (R3.6). The same view feeds the preview, PNG export and printing.
public struct ReceiptView: View {
    let model: ReceiptModel
    let layout: ReceiptLayout
    let logo: ReceiptLogo
    /// Clear when drawn on the paper effect, white otherwise.
    var background: Color

    public init(model: ReceiptModel, paper: ReceiptPaper, logo: ReceiptLogo, background: Color = .white) {
        self.model = model
        layout = ReceiptLayout(paper: paper, language: model.language)
        self.logo = logo
        self.background = background
    }

    private var strings: ReceiptStrings { model.strings }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rule()
            information
            rule()
            if model.groups != nil {
                detail
                rule()
                tokenMix
                rule()
                energySection
                if let bars = model.bars {
                    rule()
                    chart(bars)
                }
                rule()
                equivalentsSection
            } else if let bars = model.bars {
                chart(bars)
            }
            rule("=")
            total
            rule("=")
            footer
        }
        .font(ReceiptFont.body())
        .foregroundStyle(Color.black)
        .padding(.vertical, 24)
        .frame(width: layout.width)
        .background(background)
        .environment(\.colorScheme, .light)
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 6) {
            logoView
                .padding(.bottom, 10)
            Text(verbatim: model.productName).font(ReceiptFont.body(.bold))
            Text(verbatim: strings(.subtitle))
            if let customer = model.customer {
                Text(verbatim: "\(strings(.customer))  \(customer)").padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var logoView: some View {
        let size = layout.paper.logoSize
        switch logo {
        case .image(let image):
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        case .placeholder(let symbol):
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .strokeBorder(Color.black, lineWidth: 4)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .bold))
            }
            .frame(width: size, height: size)
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The period kind goes at the end of the serial line when both fit, otherwise on its own line.
            let kindColumns = ReceiptText.columns(model.kind)
            if ReceiptText.columns(model.serial) + 1 + kindColumns <= layout.info.value {
                HStack(spacing: 0) {
                    cell(strings(.serial), layout.info.label)
                    cell(model.serial, layout.info.value - kindColumns)
                    cell(model.kind, kindColumns, .trailing)
                }
            } else {
                infoRow(.serial, model.serial)
                infoRow(.kind, model.kind)
            }
            infoRow(.period, model.period)
            infoRow(.timeZone, model.timeZone)
            infoRow(.printed, model.printed)
            infoRow(.cashier, model.cashier)
        }
    }

    private var detail: some View {
        let columns = layout.detail
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                cell(strings(.item), columns.name)
                cell(strings(.tokens), columns.tokens, .trailing)
                cell(strings(.energyWh), columns.energy, .trailing)
            }
            rule()
            ForEach(model.groups ?? [], id: \.tool) { group in
                cell(group.tool, layout.columns)
                ForEach(group.rows, id: \.self) { detailRow($0, indented: true) }
            }
            if let others = model.others {
                detailRow(others, indented: false)
            }
            if model.groups?.isEmpty ?? true, model.others == nil {
                detailRow(ReceiptModel.Row(name: "-", tokens: "0", energyWh: "0"), indented: true)
            }
        }
    }

    private func detailRow(_ row: ReceiptModel.Row, indented: Bool) -> some View {
        let columns = layout.detail
        let indent = indented ? ReceiptLayout.indent : 0
        return HStack(spacing: 0) {
            spacer(indent)
            cell(ReceiptText.truncate(row.name, columns: columns.name - indent - 1), columns.name - indent)
            cell(row.tokens, columns.tokens, .trailing)
            cell(row.energyWh, columns.energy, .trailing)
        }
    }

    @ViewBuilder
    private var tokenMix: some View {
        if let mix = model.tokenMix {
            let pairs: [(ReceiptPattern, ReceiptStrings.Key, String)] = [
                (.solid, .input, mix.input), (.hatched, .output, mix.output),
                (.dotted, .cacheWrite, mix.cacheWrite), (.blank, .cacheRead, mix.cacheRead),
            ]
            let perLine = layout.tokenPairsPerLine
            VStack(alignment: .leading, spacing: 0) {
                cell(strings(.tokenMix), layout.columns)
                ForEach(Array(stride(from: 0, to: pairs.count, by: perLine)), id: \.self) { start in
                    HStack(spacing: 0) {
                        spacer(ReceiptLayout.indent)
                        ForEach(pairs[start..<min(start + perLine, pairs.count)], id: \.1) { pair in
                            if pair.1 != pairs[start].1 { spacer(ReceiptLayout.tokenPairGap) }
                            HStack(spacing: 0) {
                                ReceiptPatternSwatch(pattern: pair.0)
                                    .frame(width: ReceiptLayout.columnWidth * 1.5, height: 14)
                                    .frame(width: ReceiptLayout.points(2), alignment: .leading)
                                cell(strings(pair.1), layout.tokenPair.label - 2)
                            }
                            cell(pair.2, layout.tokenPair.value, .trailing)
                        }
                    }
                }
                ReceiptTokenBar(shares: mix.shares, columns: layout.columns - ReceiptLayout.indent)
                    .frame(height: 22)
                    .padding(.leading, ReceiptLayout.points(ReceiptLayout.indent))
                    .padding(.vertical, 6)
                Text(verbatim: strings(.cacheNote))
                    .font(ReceiptFont.small)
                    .padding(.leading, ReceiptLayout.points(ReceiptLayout.indent))
            }
        }
    }

    private var energySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            valueRow(strings(.energySubtotal), model.energySubtotal, indented: false)
            valueRow(strings(.range), model.energyRange, indented: true)
            valueRow(strings(.carbon), model.carbon, indented: false)
            valueRow(strings(.basis), model.basis, indented: true)
            if let cleanliness = model.cleanliness {
                valueRow(strings(.cleanliness), cleanliness, indented: true)
            }
        }
    }

    private func chart(_ bars: ReceiptModel.Bars) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                cell(bars.title, layout.columns - ReceiptText.columns(bars.peakLabel))
                cell(bars.peakLabel, ReceiptText.columns(bars.peakLabel), .trailing)
            }
            ReceiptBarChart(values: bars.values, columns: layout.columns - ReceiptLayout.indent)
                .padding(.leading, ReceiptLayout.points(ReceiptLayout.indent))
            HStack(spacing: 0) {
                spacer(ReceiptLayout.indent)
                cell(bars.firstLabel, (layout.columns - ReceiptLayout.indent) / 2)
                cell(bars.lastLabel, layout.columns - ReceiptLayout.indent - (layout.columns - ReceiptLayout.indent) / 2, .trailing)
            }
            .font(ReceiptFont.small)
        }
    }

    private var equivalentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            cell(strings(.equivalents), layout.columns)
            if let note = model.emptyNote {
                HStack(spacing: 0) {
                    spacer(ReceiptLayout.indent)
                    cell(note, layout.columns - ReceiptLayout.indent)
                }
            }
            ForEach(model.equivalents ?? [], id: \.self) { line in
                valueRow(line.label, line.value, indented: true)
            }
        }
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                cell(strings(.total), layout.columns / 2)
                cell(model.totalEnergy, layout.columns - layout.columns / 2, .trailing)
            }
            .font(ReceiptFont.body(.bold))
            .frame(height: ReceiptFont.lineHeight)
            .scaleEffect(x: 1, y: 2, anchor: .center)
            .frame(height: ReceiptFont.lineHeight * 2)
            HStack(spacing: 0) {
                spacer(layout.columns / 2)
                cell(model.totalCarbon, layout.columns - layout.columns / 2, .trailing)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Group {
                Text(verbatim: strings(.disclaimer))
                if model.showsFoodNote { Text(verbatim: strings(.foodNote)) }
                Text(verbatim: strings(.methodHint))
            }
            .font(ReceiptFont.small)
            .multilineTextAlignment(.center)
            if let payload = model.qrPayload, let qr = ReceiptCodes.qr(payload) {
                printed(qr).padding(.top, 14)
            }
            if let barcode = ReceiptCodes.barcode(model.serial, maxWidth: layout.width - 48) {
                printed(barcode).padding(.top, 10)
            }
            Text(verbatim: model.serial)
            Text(verbatim: strings(.thanks))
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    /// A black-and-white code drawn as black only, so the paper shows through where the code is white.
    private func printed(_ code: CGImage) -> some View {
        Color.black
            .frame(width: CGFloat(code.width), height: CGFloat(code.height))
            .mask(Image(decorative: code, scale: 1).interpolation(.none).colorInvert().luminanceToAlpha())
    }

    // MARK: Grid pieces

    /// A full line of `-` or `=`, drawn with the font as on the printer (R3.4).
    private func rule(_ character: String = "-") -> some View {
        Text(verbatim: String(repeating: character, count: layout.columns))
            .frame(width: layout.width, height: ReceiptFont.lineHeight, alignment: .leading)
            .clipped()
    }

    private func cell(_ text: String, _ columns: Int, _ alignment: Alignment = .leading) -> some View {
        Text(verbatim: text)
            .lineLimit(1)
            .fixedSize()
            .frame(width: ReceiptLayout.points(max(0, columns)), height: ReceiptFont.lineHeight, alignment: alignment)
    }

    private func spacer(_ columns: Int) -> some View {
        Color.clear.frame(width: ReceiptLayout.points(columns), height: ReceiptFont.lineHeight)
    }

    private func infoRow(_ key: ReceiptStrings.Key, _ value: String) -> some View {
        HStack(spacing: 0) {
            cell(strings(key), layout.info.label)
            cell(value, layout.info.value)
        }
    }

    /// A label on the left and a value on the right edge of the line.
    private func valueRow(_ label: String, _ value: String, indented: Bool) -> some View {
        let indent = indented ? ReceiptLayout.indent : 0
        let valueColumns = max(ReceiptText.columns(value), layout.columns / 3)
        return HStack(spacing: 0) {
            spacer(indent)
            cell(ReceiptText.truncate(label, columns: layout.columns - indent - valueColumns - 1), layout.columns - indent - valueColumns)
            cell(value, valueColumns, .trailing)
        }
    }
}

// MARK: - Graphics

/// The four fills that tell the token-mix segments apart (R3.4). No grey: printing turns the receipt into
/// pure black and white.
public enum ReceiptPattern: Sendable, Hashable {
    case solid, hatched, dotted, blank

    func draw(in context: inout GraphicsContext, rect: CGRect) {
        switch self {
        case .solid:
            context.fill(Path(rect), with: .color(.black))
        case .hatched:
            var path = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 6
            }
            context.clip(to: Path(rect))
            context.stroke(path, with: .color(.black), lineWidth: 2)
        case .dotted:
            var y = rect.minY + 2
            while y < rect.maxY - 1 {
                var x = rect.minX + 2
                while x < rect.maxX - 1 {
                    context.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.black))
                    x += 5
                }
                y += 5
            }
        case .blank:
            break
        }
    }
}

struct ReceiptPatternSwatch: View {
    let pattern: ReceiptPattern

    var body: some View {
        Canvas { context, size in
            pattern.draw(in: &context, rect: CGRect(origin: .zero, size: size))
        }
        .overlay(Rectangle().strokeBorder(Color.black, lineWidth: 2))
    }
}

/// Input, output, cache write and cache read as one bar split by share, each segment a whole number of columns.
struct ReceiptTokenBar: View {
    let shares: [Double]
    let columns: Int

    static let patterns: [ReceiptPattern] = [.solid, .hatched, .dotted, .blank]

    /// Columns per segment: rounded down, then the remainder goes to the largest fractions so the sum is exact.
    /// A part that is not zero keeps at least one column, taken from the widest segment, so a small share
    /// (input next to a large cache read) still shows.
    static func segmentColumns(_ shares: [Double], columns: Int) -> [Int] {
        let total = shares.reduce(0, +)
        guard total > 0 else { return shares.map { _ in 0 } }
        let exact = shares.map { $0 / total * Double(columns) }
        var whole = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { exact[$0] - Double(whole[$0]) > exact[$1] - Double(whole[$1]) }
        for index in order.prefix(columns - whole.reduce(0, +)) { whole[index] += 1 }
        for index in whole.indices where shares[index] > 0 && whole[index] == 0 {
            guard let widest = whole.indices.max(by: { whole[$0] < whole[$1] }), whole[widest] > 1 else { break }
            whole[widest] -= 1
            whole[index] = 1
        }
        return whole
    }

    var body: some View {
        let widths = Self.segmentColumns(shares, columns: columns)
        Canvas { context, size in
            var x: CGFloat = 0
            for (index, width) in widths.enumerated() where width > 0 {
                let rect = CGRect(x: x, y: 0, width: ReceiptLayout.points(width), height: size.height)
                var segment = context
                Self.patterns[index].draw(in: &segment, rect: rect)
                if x > 0 {
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.black))
                }
                x += rect.width
            }
        }
        .frame(width: ReceiptLayout.points(columns))
        .overlay(Rectangle().strokeBorder(Color.black, lineWidth: 2))
    }
}

/// Bars of mid energy, each slot a whole number of columns, all black (R3.4).
struct ReceiptBarChart: View {
    let values: [Double]
    let columns: Int
    static let height: CGFloat = 72

    var body: some View {
        let slotColumns = max(1, columns / max(1, values.count))
        let slot = ReceiptLayout.points(slotColumns)
        let gap = max(2, (slot * 0.25).rounded())
        let peak = values.max() ?? 0
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                let share = peak > 0 ? values[index] / peak : 0
                Rectangle()
                    .fill(Color.black)
                    .frame(width: slot - gap, height: max(2, (Self.height * share).rounded()))
                    .frame(width: slot, alignment: .leading)
            }
        }
        .frame(width: ReceiptLayout.points(columns), height: Self.height, alignment: .bottomLeading)
    }
}

/// QR code and barcode images, pure black and white at whole-dot scale.
enum ReceiptCodes {
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// The QR code at about 150 dots.
    static func qr(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        return render(filter.outputImage, target: 150, height: nil)
    }

    /// A Code 128 barcode of the serial, 56 dots tall, at most `maxWidth` wide.
    static func barcode(_ text: String, maxWidth: CGFloat) -> CGImage? {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(text.utf8)
        filter.quietSpace = 0
        filter.barcodeHeight = 1
        return render(filter.outputImage, target: maxWidth, height: 56)
    }

    /// Scales by a whole number so every module is the same number of dots, then draws black on white.
    private static func render(_ image: CIImage?, target: CGFloat, height: CGFloat?) -> CGImage? {
        guard let image, image.extent.width > 0 else { return nil }
        let scale = max(1, (target / image.extent.width).rounded(.down))
        let scaleY = height.map { $0 / image.extent.height } ?? scale
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scaleY))
        return context.createCGImage(scaled, from: scaled.extent.integral, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
