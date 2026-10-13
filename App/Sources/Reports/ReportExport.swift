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

    /// Which report parts this format can hold.
    var contentFormat: ReportSections.Format {
        switch self {
        case .pngPortrait, .pngLandscape, .pdf: .image
        case .csv: .csv
        case .json: .json
        case .markdown: .markdown
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
    /// The name shown after the report title on PNG and PDF exports, set in the export dialog. Empty means none.
    static let authorKey = "export.author"

    static var savedAuthor: String? {
        UserDefaults.standard.string(forKey: authorKey).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    static func data(_ format: ExportFormat, report: Report, store: UsageStore, strings: ReportStrings, hideProjects: Bool,
                     sections: ReportSections = .all, author: String? = savedAuthor) throws -> Data {
        let sections = sections.intersection(ReportSections.available(in: format.contentFormat))
        let options = ExportOptions(language: strings.language, hideProjects: hideProjects, sections: sections)
        let canvas = ReportCanvas(report: report, strings: strings, sections: sections, hideProjects: hideProjects, author: author)
        switch format {
        case .pngPortrait:
            return try png(canvas)
        case .pngLandscape:
            var canvas = canvas
            canvas.style = .landscape
            return try png(canvas)
        case .pdf:
            return try pdf(canvas.pdfPages(), size: ReportCanvas.pageSize)
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

    /// Renders the page at 2x: 1190 pixels wide in portrait, 1684 in landscape, as tall as the chosen parts need.
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

/// The exported report on a white page: brand header, the chosen parts, and the footer every export carries.
/// Portrait PNG stacks the parts in one image as tall as they need; PDF puts the same parts on A4 pages,
/// moving a part to the next page when it does not fit; landscape PNG arranges them in columns.
struct ReportCanvas: View {
    enum Style { case portrait, landscape }

    /// The optional parts in page order. The summary always comes first.
    enum Part: Hashable { case summary, trends, mix, tool, model, project, method }

    let report: Report
    let strings: ReportStrings
    let sections: ReportSections
    let hideProjects: Bool
    var author: String?
    var style = Style.portrait

    /// A4 in points.
    static let pageSize = CGSize(width: 595, height: 842)
    static let landscapeWidth: CGFloat = 842
    static let margin: CGFloat = 28
    static let spacing: CGFloat = 12

    var width: CGFloat { style == .landscape ? Self.landscapeWidth : Self.pageSize.width }

    var body: some View {
        ReportSheet(report: report, strings: strings, author: author, width: width) {
            if report.isEmpty {
                Text(verbatim: strings(.noUsage)).foregroundStyle(.secondary)
            } else if style == .landscape {
                landscapeBody
            } else {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(parts, id: \.self) { part($0) }
                }
            }
        }
    }

    var parts: [Part] {
        guard !report.isEmpty else { return [] }
        var parts: [Part] = [.summary]
        if sections.contains(.trends) { parts.append(.trends) }
        if hasMix { parts.append(.mix) }
        if sections.contains(.byTool), !report.bySource.isEmpty { parts.append(.tool) }
        if sections.contains(.byModel), !report.byModel.isEmpty { parts.append(.model) }
        if sections.contains(.byProject), !report.byProject.isEmpty { parts.append(.project) }
        if sections.contains(.method) { parts.append(.method) }
        return parts
    }

    private var hasMix: Bool { sections.contains(.energyMix) && (report.energyMix != nil || report.hasGridLevels) }

    // MARK: Portrait and PDF

    @ViewBuilder
    func part(_ part: Part) -> some View {
        switch part {
        case .summary: summary
        case .trends: charts(height: 90)
        case .mix: mixRow
        case .tool: table(.tool, maxRows: 8)
        case .model: table(.model, maxRows: 10)
        case .project: table(.project, maxRows: 12)
        case .method: box(strings(.method)) { methodLines }
        }
    }

    /// Energy mix with the grid levels beside it; either one alone takes the full width.
    @ViewBuilder
    private var mixRow: some View {
        if let mix = report.energyMix, report.hasGridLevels {
            HStack(alignment: .top, spacing: 14) {
                box(strings(.energyMix), fillHeight: true) { ReportEnergyMixView(mix: mix, strings: strings, donut: 84, legendColumns: 2) }
                box(strings(.byGridLevel), fillHeight: true) { ReportGridLevelView(report: report, strings: strings) }
                    .frame(width: 190)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if let mix = report.energyMix {
            box(strings(.energyMix)) { ReportEnergyMixView(mix: mix, strings: strings, donut: 84, legendColumns: 3) }
        } else {
            box(strings(.byGridLevel)) { ReportGridLevelView(report: report, strings: strings) }
        }
    }

    // MARK: Landscape

    /// Summary on the left with the charts (or the energy mix) on the right; the tables share one row below,
    /// and the method notes close the page as small print.
    private var landscapeBody: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if sections.contains(.trends) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        summary
                        if hasMix { landscapeMix(legendColumns: 1) }
                    }
                    .frame(width: 340)
                    charts(height: 150)
                }
            } else if hasMix {
                HStack(alignment: .top, spacing: 18) {
                    summary.frame(width: 340, alignment: .leading)
                    VStack(alignment: .leading, spacing: Self.spacing) { landscapeMix(legendColumns: 2) }
                }
            } else {
                summary
            }
            let tables = parts.filter { [.tool, .model, .project].contains($0) }
            if !tables.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(tables, id: \.self) { kind in
                        landscapeTable(kind, columns: tables.count == 1 ? .full : tables.count == 2 ? .noBar : .compact)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if sections.contains(.method) {
                methodLines.foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func landscapeMix(legendColumns: Int) -> some View {
        if let mix = report.energyMix {
            box(strings(.energyMix)) { ReportEnergyMixView(mix: mix, strings: strings, donut: 84, legendColumns: legendColumns) }
        }
        if report.hasGridLevels {
            box(strings(.byGridLevel)) { ReportGridLevelView(report: report, strings: strings) }
        }
    }

    private func landscapeTable(_ part: Part, columns: ReportBreakdownTable.Columns) -> some View {
        box(title(part), fillHeight: true) {
            ReportBreakdownTable(kind: kind(part), items: items(part), strings: strings, maxRows: 6, hideProjects: hideProjects, columns: columns)
        }
        .font(.caption)
    }

    // MARK: Shared parts

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
            ReportUsageChart(report: report, strings: strings, metric: metric, cumulative: cumulative, compactAxis: style == .landscape)
                .font(.caption2)
                .frame(height: height)
        }
    }

    private func table(_ part: Part, maxRows: Int) -> some View {
        box(title(part)) {
            ReportBreakdownTable(kind: kind(part), items: items(part), strings: strings, maxRows: maxRows, hideProjects: hideProjects)
        }
    }

    private func title(_ part: Part) -> String {
        switch part {
        case .model: strings(.byModel)
        case .project: strings(.byProject)
        default: strings(.byTool)
        }
    }

    private func kind(_ part: Part) -> ReportBreakdownTable.Kind {
        switch part {
        case .model: .model
        case .project: .project
        default: .tool
        }
    }

    private func items(_ part: Part) -> [ReportBreakdownItem] {
        switch part {
        case .model: report.byModel
        case .project: report.byProject
        default: report.bySource
        }
    }

    private var methodLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.gridIntensities, id: \.self) { Text(verbatim: strings(.gridBasis(String(format: "%.0f", $0)))) }
            ForEach(report.factorVersions, id: \.self) { Text(verbatim: strings(.factorVersion($0))) }
        }
        .font(.caption)
    }

    private func box(_ title: String, fillHeight: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: PDF pages

    /// Splits the parts over A4 pages. A part never breaks across pages; one that does not fit starts the next page.
    @MainActor
    func pdfPages() -> [AnyView] {
        let contentWidth = Self.pageSize.width - 2 * Self.margin
        let chrome = ReportSheet(report: report, strings: strings, author: author, width: Self.pageSize.width) { EmptyView() }
        // Header, divider and footer, plus the gaps around the content and the spacer above the footer.
        let available = Self.pageSize.height - Self.measure(chrome, width: Self.pageSize.width) - 2 * Self.spacing - 4
        var pages: [[Part]] = []
        var used: CGFloat = 0
        for part in parts {
            let height = Self.measure(self.part(part), width: contentWidth)
            if let last = pages.indices.last, !pages[last].isEmpty, used + Self.spacing + height <= available {
                pages[last].append(part)
                used += Self.spacing + height
            } else {
                pages.append([part])
                used = height
            }
        }
        if pages.isEmpty { pages = [[]] }
        return pages.enumerated().map { index, parts in
            AnyView(ReportSheet(report: report, strings: strings, author: index == 0 ? author : nil,
                                width: Self.pageSize.width, height: Self.pageSize.height) {
                if report.isEmpty {
                    Text(verbatim: strings(.noUsage)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        ForEach(parts, id: \.self) { self.part($0) }
                    }
                }
            })
        }
    }

    /// Height of a view at a fixed width, with the page's font and light appearance.
    @MainActor
    private static func measure(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view
            .font(.callout)
            .environment(\.colorScheme, .light)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        return host.fittingSize.height
    }
}

/// One exported page: brand header, content, and the footer. With a height it is a fixed page
/// (the footer sits at the bottom); without one it is as tall as its content.
struct ReportSheet<Content: View>: View {
    let report: Report
    let strings: ReportStrings
    var author: String?
    let width: CGFloat
    var height: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ReportCanvas.spacing) {
            ReportBrandHeader(report: report, strings: strings, iconSize: 34, author: author)
            Divider()
            content
            if height != nil { Spacer(minLength: 0) }
            ReportFooter(strings: strings)
        }
        .font(.callout)
        .padding(ReportCanvas.margin)
        .frame(width: width, height: height, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: height == nil)
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
    @AppStorage("export.sections") private var sections = ReportSections.all
    @AppStorage(ReportExport.authorKey) private var author = ""
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
                ExportContentPicker(format: format, sections: $sections, hideProjects: $hideProjects)
                TextField("export.author", text: $author, prompt: Text("export.author.prompt"))
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
        .frame(width: 440)
    }

    private func save() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReportExport.fileName(format, report: report)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ReportExport.data(format, report: report, store: store, strings: language.strings,
                                             hideProjects: hideProjects, sections: sections)
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            errorText = String(format: String(localized: "export.error"), error.localizedDescription)
        }
    }
}

/// Checkboxes for the optional report parts that the chosen format can hold, and the project name option.
struct ExportContentPicker: View {
    let format: ExportFormat
    @Binding var sections: ReportSections
    @Binding var hideProjects: Bool

    private static let options: [(ReportSections, LocalizedStringKey)] = [
        (.trends, "export.include.trends"),
        (.energyMix, "export.include.energyMix"),
        (.byTool, "export.include.byTool"),
        (.byModel, "export.include.byModel"),
        (.byProject, "export.include.byProject"),
        (.method, "export.include.method"),
    ]

    var body: some View {
        let available = ReportSections.available(in: format.contentFormat)
        let shown = Self.options.filter { available.contains($0.0) }
        LabeledContent("export.include") {
            VStack(alignment: .leading, spacing: 6) {
                let rows = stride(from: 0, to: shown.count, by: 2).map { Array(shown[$0..<min($0 + 2, shown.count)]) }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row], id: \.0.rawValue) { option in
                                Toggle(option.1, isOn: binding(option.0)).toggleStyle(.checkbox).fixedSize()
                            }
                        }
                    }
                }
                Toggle("export.hideProjects", isOn: $hideProjects)
                    .toggleStyle(.checkbox)
                    .disabled(!sections.contains(.byProject))
                Text(format.contentFormat == .csv ? "export.include.noteCSV" : "export.include.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(_ section: ReportSections) -> Binding<Bool> {
        Binding(get: { sections.contains(section) },
                set: { on in if on { sections.insert(section) } else { sections.remove(section) } })
    }
}
