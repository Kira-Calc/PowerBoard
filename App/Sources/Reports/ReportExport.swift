import AppKit
import ElectricityCore
import SwiftUI

/// Export formats (SPEC 12).
enum ExportFormat: String, CaseIterable, Identifiable {
    case pngPortrait
    case pngLandscape
    case pdf
    case csv
    case json
    case markdown

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .pngPortrait, .pngLandscape: "png"
        case .pdf: "pdf"
        case .csv: "csv"
        case .json: "json"
        case .markdown: "md"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .pngPortrait: "export.format.pngPortrait"
        case .pngLandscape: "export.format.pngLandscape"
        case .pdf: "export.format.pdf"
        case .csv: "export.format.csv"
        case .json: "export.format.json"
        case .markdown: "export.format.markdown"
        }
    }
}

/// Export language: the app's, or a fixed one (SPEC 12).
enum ExportLanguage: String, CaseIterable, Identifiable {
    case app
    case chinese
    case english

    var id: String { rawValue }

    var strings: ReportStrings {
        switch self {
        case .app: .app
        case .chinese: ReportStrings(.zh)
        case .english: ReportStrings(.en)
        }
    }
}

/// Writes a report in any export format.
@MainActor
enum ReportExport {
    static func data(_ format: ExportFormat, report: Report, store: UsageStore, strings: ReportStrings, hideProjects: Bool) throws -> Data {
        let options = ExportOptions(language: strings.language, hideProjects: hideProjects)
        switch format {
        case .pngPortrait:
            return try png(ReportCanvas(report: report, strings: strings, hideProjects: hideProjects))
        case .pngLandscape:
            return try png(ReportCanvas(report: report, strings: strings, hideProjects: hideProjects, landscape: true))
        case .pdf:
            // Page 1 is the same as the portrait image; page 2 has the model and project breakdowns and the method.
            return try pdf([
                AnyView(ReportCanvas(report: report, strings: strings, hideProjects: hideProjects)),
                AnyView(ReportDetailsPage(report: report, strings: strings, hideProjects: hideProjects)),
            ], size: ReportCanvas.portraitSize)
        case .csv:
            return ReportExporter.csv(try store.events(from: report.interval.start, to: report.interval.end), options: options)
        case .json:
            return try ReportExporter.json(report, records: try store.events(from: report.interval.start, to: report.interval.end), options: options)
        case .markdown:
            return Data(ReportExporter.markdown(report, options: options).utf8)
        }
    }

    static func fileName(_ format: ExportFormat, report: Report) -> String {
        let name = AppIdentity.displayName.replacingOccurrences(of: " ", with: "-")
        var day = Date.ISO8601FormatStyle().year().month().day()
        day.timeZone = .current
        let suffix = format == .pngLandscape ? "-wide" : ""
        if report.rolling {
            // "PowerBoard-last-day-2026-10-12-1620": the period ending at the time the report was made.
            var time = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: false)
            time.timeZone = .current
            let end = report.interval.end.formatted(time).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "-")
            return "\(name)-last-\(report.period.rawValue)-\(end.prefix(15))\(suffix).\(format.fileExtension)"
        }
        return "\(name)-\(report.period.rawValue)-\(report.interval.start.formatted(day))\(suffix).\(format.fileExtension)"
    }

    struct RenderError: Error {}

    /// Renders the page at 2x (A4 portrait is 1190 x 1684 pixels), the same layout as the PDF.
    private static func png(_ canvas: ReportCanvas) throws -> Data {
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw RenderError() }
        return data
    }

    /// One A4 page (595 x 842 pt).
    private static func pdf(_ pages: [AnyView], size: CGSize) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw RenderError() }
        for page in pages {
            ImageRenderer(content: page).render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }
}

/// The exported report. PDF and portrait PNG render this same view on an A4 page, so they match;
/// landscape PNG uses the same parts on an A4 landscape page. Every export carries the app icon and name.
struct ReportCanvas: View {
    let report: Report
    let strings: ReportStrings
    let hideProjects: Bool
    var landscape = false

    /// A4 in points.
    static let portraitSize = CGSize(width: 595, height: 842)
    static let landscapeSize = CGSize(width: 842, height: 595)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReportBrandHeader(report: report, strings: strings, iconSize: 34)
            Divider()
            if report.isEmpty {
                Text(verbatim: strings(.noUsage)).foregroundStyle(.secondary)
            } else if landscape {
                landscapeBody
            } else {
                portraitBody
            }
            Spacer(minLength: 0)
            ReportFooter(strings: strings)
        }
        .font(.callout)
        .padding(28)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    var size: CGSize { landscape ? Self.landscapeSize : Self.portraitSize }

    private var portraitBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            charts(height: 84)
            HStack(alignment: .top, spacing: 14) {
                box(strings(.energyMix)) { mixView(donut: 84, columns: 2) }
                if report.hasGridLevels {
                    box(strings(.byGridLevel)) { ReportGridLevelView(report: report, strings: strings) }
                        .frame(width: 190)
                }
            }
            box(strings(.byTool)) { ReportBreakdownTable(kind: .tool, items: report.bySource, strings: strings, maxRows: 3) }
                .font(.caption)
        }
    }

    private var landscapeBody: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                summary
                box(strings(.energyMix)) { mixView(donut: 84, columns: 1) }
            }
            .frame(width: 340)
            charts(height: 150)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReportSummaryView(report: report, strings: strings, compact: true)
            ReportTokenLine(report: report, strings: strings)
        }
    }

    /// Energy and tokens, each as bars and as a cumulative curve.
    private func charts(height: CGFloat) -> some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                chartBox(strings(.energyChart), .energy, cumulative: false, height: height)
                chartBox(strings(.energyCumulative), .energy, cumulative: true, height: height)
            }
            GridRow {
                chartBox(strings(.tokenChart), .tokens, cumulative: false, height: height)
                chartBox(strings(.tokenCumulative), .tokens, cumulative: true, height: height)
            }
        }
    }

    private func chartBox(_ title: String, _ metric: ReportUsageChart.Metric, cumulative: Bool, height: CGFloat) -> some View {
        box(title) {
            ReportUsageChart(report: report, strings: strings, metric: metric, cumulative: cumulative, compactAxis: landscape)
                .font(.caption2)
                .frame(height: height)
        }
    }

    @ViewBuilder
    private func mixView(donut: CGFloat, columns: Int) -> some View {
        if let mix = report.energyMix {
            ReportEnergyMixView(mix: mix, strings: strings, donut: donut, legendColumns: columns)
        } else {
            Text(verbatim: "–").foregroundStyle(.secondary)
        }
    }

    fileprivate func box(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Second PDF page: model and project breakdowns and the calculation notes, with the same header and footer.
struct ReportDetailsPage: View {
    let report: Report
    let strings: ReportStrings
    let hideProjects: Bool

    var body: some View {
        let layout = ReportCanvas(report: report, strings: strings, hideProjects: hideProjects)
        VStack(alignment: .leading, spacing: 12) {
            ReportBrandHeader(report: report, strings: strings, iconSize: 34)
            Divider()
            layout.box(strings(.byModel)) { ReportBreakdownTable(kind: .model, items: report.byModel, strings: strings, maxRows: 10) }
            layout.box(strings(.byProject)) {
                ReportBreakdownTable(kind: .project, items: report.byProject, strings: strings, maxRows: 12, hideProjects: hideProjects)
            }
            layout.box(strings(.method)) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(report.gridIntensities, id: \.self) { Text(verbatim: strings(.gridBasis(String(format: "%.0f", $0)))) }
                    ForEach(report.factorVersions, id: \.self) { Text(verbatim: strings(.factorVersion($0))) }
                    if let mix = report.energyMix {
                        Text(verbatim: strings(mix.basis == .period ? .mixBasisPeriod : .mixBasisRecent))
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
            ReportFooter(strings: strings)
        }
        .font(.callout)
        .padding(28)
        .frame(width: ReportCanvas.portraitSize.width, height: ReportCanvas.portraitSize.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }
}

/// Export dialog: format, language and project names, then a save panel.
struct ExportSheet: View {
    let report: Report
    let store: UsageStore?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.format") private var format: ExportFormat = .pdf
    @AppStorage("export.language") private var language: ExportLanguage = .app
    @AppStorage("export.hideProjects") private var hideProjects = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("export.title").font(.headline)
            Form {
                Picker("export.format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.titleKey).tag($0) }
                }
                Picker("export.language", selection: $language) {
                    Text("export.language.app").tag(ExportLanguage.app)
                    Text(verbatim: "简体中文").tag(ExportLanguage.chinese)
                    Text(verbatim: "English").tag(ExportLanguage.english)
                }
                Toggle("export.hideProjects", isOn: $hideProjects)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("export.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    Text(String(format: String(localized: "export.save"), format.fileExtension.uppercased()))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReportExport.fileName(format, report: report)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ReportExport.data(format, report: report, store: store, strings: language.strings, hideProjects: hideProjects)
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            errorText = String(format: String(localized: "export.error"), error.localizedDescription)
        }
    }
}
