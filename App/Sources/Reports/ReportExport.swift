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
            return try png(ShareCardView(report: report, strings: strings, landscape: false), width: 1080, height: 1350)
        case .pngLandscape:
            return try png(ShareCardView(report: report, strings: strings, landscape: true), width: 1600, height: 900)
        case .pdf:
            return try pdf(ReportDocumentView(report: report, strings: strings, hideProjects: hideProjects))
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
        return "\(name)-\(report.period.rawValue)-\(report.interval.start.formatted(day))\(suffix).\(format.fileExtension)"
    }

    struct RenderError: Error {}

    /// Lays the view out at half the pixel size and renders at 2x, so text has normal proportions.
    private static func png(_ view: some View, width: CGFloat, height: CGFloat) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: width / 2, height: height / 2).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw RenderError() }
        return data
    }

    /// One A4 page (595 x 842 pt).
    private static func pdf(_ view: some View) throws -> Data {
        let size = CGSize(width: 595, height: 842)
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw RenderError() }
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// Share card for PNG export: 1080 x 1350 portrait or 1600 x 900 landscape.
struct ShareCardView: View {
    let report: Report
    let strings: ReportStrings
    let landscape: Bool

    var body: some View {
        let header = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconBadge(Icons.lightning, color: Palette.energy, size: 24)
                Text(verbatim: AppIdentity.displayName).font(.headline)
            }
            Text(verbatim: "\(strings(.title(report.period))) \(strings.periodLabel(report.period, report.interval))")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(verbatim: strings(.headline)).font(.title2.weight(.semibold)).padding(.top, 8)
        }
        Group {
            if landscape {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        ReportSummaryView(report: report, strings: strings, large: true)
                        Spacer()
                        ReportFooter(strings: strings)
                    }
                    .frame(width: 330, alignment: .leading)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: strings(.trend)).font(.title3.weight(.semibold))
                        ReportTrendChart(report: report, strings: strings)
                        ReportBreakdownTable(kind: .tool, items: report.bySource, strings: strings, maxRows: 3)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ReportSummaryView(report: report, strings: strings, large: true)
                    Text(verbatim: strings(.trend)).font(.title3.weight(.semibold))
                    ReportTrendChart(report: report, strings: strings).frame(height: 170)
                    ReportBreakdownTable(kind: .tool, items: report.bySource, strings: strings, maxRows: 3)
                    Spacer()
                    ReportFooter(strings: strings)
                }
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }
}

/// Full report on one A4 page for PDF export, with charts and a short method summary.
struct ReportDocumentView: View {
    let report: Report
    let strings: ReportStrings
    let hideProjects: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(AppIdentity.displayName)  \(strings(.title(report.period)))").font(.title3.weight(.semibold))
                Text(verbatim: strings.periodLabel(report.period, report.interval)).foregroundStyle(.secondary)
            }
            if report.isEmpty {
                Text(verbatim: strings(.noUsage))
            } else {
                Text(verbatim: strings(.energy)).font(.caption).foregroundStyle(.secondary)
                ReportSummaryView(report: report, strings: strings)
                section(strings(.trend)) { ReportTrendChart(report: report, strings: strings).frame(height: 140) }
                section(strings(.byTool)) { ReportBreakdownTable(kind: .tool, items: report.bySource, strings: strings, maxRows: 3) }
                section(strings(.byModel)) { ReportBreakdownTable(kind: .model, items: report.byModel, strings: strings, maxRows: 4) }
                section(strings(.byProject)) {
                    ReportBreakdownTable(kind: .project, items: report.byProject, strings: strings, maxRows: 4, hideProjects: hideProjects)
                }
                section(strings(.method)) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.gridIntensities, id: \.self) { Text(verbatim: strings(.gridBasis(String(format: "%.0f", $0)))) }
                        ForEach(report.factorVersions, id: \.self) { Text(verbatim: strings(.factorVersion($0))) }
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
            ReportFooter(strings: strings)
        }
        .font(.callout)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.headline)
            content()
        }
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
