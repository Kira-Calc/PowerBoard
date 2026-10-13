import Charts
import ElectricityCore
import SwiftUI

/// Day, week, month and year reports with export (SPEC 9.2).
struct ReportsPage: View {
    let context: DashboardContext

    @AppStorage("reports.period") private var period: ReportPeriod = .week
    /// False: calendar day, week, month or year. True: the last 24 hours, 7 days, 30 days or 12 months.
    @AppStorage("reports.rolling") private var rolling = false
    @State private var anchor = Date()
    @State private var report: Report?
    @State private var showExport = false
    @State private var showYear = false

    private let strings = ReportStrings.app

    var body: some View {
        PageContainer {
            controls
            if let report {
                if report.isEmpty {
                    Card {
                        Text(verbatim: strings(.noUsage)).foregroundStyle(.secondary)
                    }
                } else {
                    content(report)
                }
            }
            AutoExportCard(settings: context.autoExport)
        }
        .task(id: [AnyHashable(period), AnyHashable(anchor), AnyHashable(rolling), AnyHashable(context.model.dataVersion)]) {
            await load()
        }
        .sheet(isPresented: $showExport) {
            if let report { ExportSheet(report: report, store: context.model.store) }
        }
        .sheet(isPresented: $showYear) {
            YearSummaryView(context: context, date: anchor)
        }
    }

    private var interval: DateInterval { period.interval(containing: anchor) }

    private var isCurrent: Bool { rolling || interval.contains(Date()) }

    /// Builds the report off the main thread, with the generation mix for its interval.
    private func load() async {
        guard let store = context.model.store else { return }
        let (period, anchor, rolling) = (period, anchor, rolling)
        let now = Date()
        let mixes = await context.model.energyMixes(for: ReportBuilder.interval(period: period, rolling: rolling, containing: anchor, now: now))
        let result = await Task.detached {
            try? ReportBuilder.build(store: store, period: period, containing: anchor, rolling: rolling, energyMixes: mixes, now: now)
        }.value
        if let result { withAnimation(.smooth(duration: 0.3)) { report = result } }
    }

    /// Two rows, so the period fits in a narrow window: what to show and export, then which period.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $period) {
                    Text("reports.period.day").tag(ReportPeriod.day)
                    Text("reports.period.week").tag(ReportPeriod.week)
                    Text("reports.period.month").tag(ReportPeriod.month)
                    Text("reports.period.year").tag(ReportPeriod.year)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $rolling) {
                    Text("reports.mode.calendar").tag(false)
                    Text("reports.mode.rolling").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(Text("reports.mode.help"))
                Spacer(minLength: 0)
                Button {
                    showExport = true
                } label: {
                    Label { Text("reports.export") } icon: { SymbolIcon(Icons.export, size: 14) }
                }
                .disabled(report == nil)
            }
            HStack(spacing: 8) {
                if rolling {
                    Text(verbatim: report.map { strings.periodLabel($0) } ?? "")
                        .font(.headline)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Button { shift(-1) } label: { SymbolIcon(Icons.previous, size: 13) }
                        .buttonStyle(.borderless)
                        .help(Text("reports.previous"))
                        .accessibilityLabel(Text("reports.previous"))
                    Text(verbatim: strings.periodLabel(period, interval))
                        .font(.headline)
                        .monospacedDigit()
                        .lineLimit(1)
                    Button { shift(1) } label: { SymbolIcon(Icons.next, size: 13) }
                        .buttonStyle(.borderless)
                        .disabled(isCurrent)
                        .help(Text("reports.next"))
                        .accessibilityLabel(Text("reports.next"))
                    if !isCurrent {
                        Button("reports.current") { anchor = Date() }
                    }
                }
                Spacer(minLength: 0)
                if period == .year && !rolling {
                    Button("reports.yearSummary") { showYear = true }
                }
            }
        }
    }

    private func shift(_ offset: Int) {
        anchor = period.shifted(interval, by: offset).start
    }

    @ViewBuilder
    private func content(_ report: Report) -> some View {
        Card {
            CardHeader(icon: Icons.lightning, color: Palette.energy, title: "reports.energy", serverTag: true)
                .environment(\.locale, strings.locale)
            ReportSummaryView(report: report, strings: strings)
            ReportTokenLine(report: report, strings: strings)
            if let peak = report.peak {
                Text(verbatim: "\(strings(.peak))\(strings.language == .zh ? "：" : ": ")\(ReportExporter.peakLabel(peak, period: report.period, strings: strings, calendar: .current))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        Card {
            CardHeader(icon: Icons.calendarBlank, color: Palette.energy, title: "reports.trend")
            // Two charts per row when there is room, one per row in a narrow window.
            VStack(spacing: 16) {
                ResponsiveRow(minItemWidth: 260, spacing: 20) {
                    chart(strings(.energyChart), report, .energy, cumulative: false)
                    chart(strings(.energyCumulative), report, .energy, cumulative: true)
                }
                ResponsiveRow(minItemWidth: 260, spacing: 20) {
                    chart(strings(.tokenChart), report, .tokens, cumulative: false)
                    chart(strings(.tokenCumulative), report, .tokens, cumulative: true)
                }
            }
        }
        ResponsiveRow(minItemWidth: 250) {
            Card(fillHeight: true) {
                CardHeader(icon: Icons.pieChart, color: Palette.clean, title: "reports.energyMix")
                if let mix = report.energyMix {
                    ReportEnergyMixView(mix: mix, strings: strings, donut: 130)
                } else {
                    Text("grid.loading").foregroundStyle(.secondary)
                }
            }
            if report.hasGridLevels {
                Card(fillHeight: true) {
                    CardHeader(icon: Icons.leaf, color: Palette.clean, title: "reports.byGridLevel")
                    ReportGridLevelView(report: report, strings: strings)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        Card {
            CardHeader(icon: Icons.terminalWindow, color: Palette.neutral, title: "reports.byTool")
            ReportBreakdownTable(kind: .tool, items: report.bySource, strings: strings)
        }
        Card {
            CardHeader(icon: Icons.function, color: Palette.neutral, title: "reports.byModel")
            ReportBreakdownTable(kind: .model, items: report.byModel, strings: strings)
        }
        Card {
            CardHeader(icon: Icons.folderOpen, color: Palette.neutral, title: "reports.byProject")
            ReportBreakdownTable(kind: .project, items: report.byProject, strings: strings, maxRows: 12)
        }
    }
}

extension ReportsPage {
    fileprivate func chart(_ title: String, _ report: Report, _ metric: ReportUsageChart.Metric, cumulative: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            ReportUsageChart(report: report, strings: strings, metric: metric, cumulative: cumulative)
                .font(.caption)
                .frame(height: 160)
        }
    }
}

/// Year in review as a series of cards (SPEC 9.2).
struct YearSummaryView: View {
    let context: DashboardContext
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var summary: YearSummary?
    @State private var page = 0
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(String(format: String(localized: "year.title"), String(summary?.year ?? Calendar.current.component(.year, from: date))))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("year.close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ZStack {
                if let summary {
                    card(summary)
                        .id(page)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Button { withAnimation(.smooth) { page = max(0, page - 1) } } label: { SymbolIcon(Icons.previous, size: 14) }
                    .disabled(page == 0)
                    .accessibilityLabel(Text("reports.previous"))
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle().fill(index == page ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                    }
                }
                Spacer()
                Button { withAnimation(.smooth) { page = min(pageCount - 1, page + 1) } } label: { SymbolIcon(Icons.next, size: 14) }
                    .disabled(page == pageCount - 1)
                    .accessibilityLabel(Text("reports.next"))
            }
            .buttonStyle(.borderless)
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .task {
            guard let store = context.model.store else { return }
            let date = self.date
            summary = await Task.detached { try? ReportBuilder.yearSummary(store: store, containing: date) }.value
        }
    }

    @ViewBuilder
    private func card(_ summary: YearSummary) -> some View {
        let settings = context.settings
        VStack(alignment: .leading, spacing: 14) {
            switch page {
            case 0:
                label("year.total")
                big(settings.formatEnergy(summary.totals.energyWh.mid).text)
                if let match = EquivalentSelector.select(energyWh: summary.totals.energyWh.mid,
                                                         items: settings.enabledEquivalents(from: context.model.equivalents), limit: 1).first {
                    Text(String(format: String(localized: "year.equivalent"), EquivalentText.amount(match), EquivalentText.name(match.item)))
                        .font(.title3)
                }
                Text(String(format: String(localized: "year.carbonTokens"),
                            "\(ValueFormatting.carbon(grams: summary.totals.co2GramsMid).text) \(Units.co2e)",
                            ValueFormatting.tokens(summary.totals.tokens.total)))
                    .foregroundStyle(.secondary)
                if let start = summary.dataStart {
                    Text(String(format: String(localized: "year.partial"), start.formatted(date: .long, time: .omitted), summary.daysCovered))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case 1:
                label("year.topDay")
                if let day = summary.topDay {
                    big(day.day.formatted(date: .long, time: .omitted))
                    Text(String(format: String(localized: "year.topDay.detail"),
                                settings.formatEnergy(day.energyWhMid).text, ValueFormatting.tokens(day.tokens)))
                        .font(.title3)
                }
            case 2:
                label("year.topModel")
                if let model = summary.topModel {
                    big(model.key)
                    Text(String(format: String(localized: "year.topModel.detail"),
                                ValueFormatting.tokens(model.tokens.total), settings.formatEnergy(model.energyWh.mid).text))
                        .font(.title3)
                }
            case 3:
                label("year.longestSession")
                if let session = summary.longestSession {
                    big(Duration.seconds(session.duration).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
                    Text(String(format: String(localized: "year.longestSession.detail"),
                                Formatting.projectName(session.projectPath), SourceText.name(session.source),
                                session.start.formatted(date: .abbreviated, time: .shortened), settings.formatEnergy(session.energyWhMid).text))
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                label("year.months")
                Chart(summary.months) { month in
                    BarMark(x: .value("Month", month.start, unit: .month), y: .value("Wh", month.serverWh))
                        .foregroundStyle(Palette.energy.gradient)
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel { if let wh = value.as(Double.self) { Text(settings.formatEnergy(wh).text) } }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.headline).foregroundStyle(.secondary)
    }

    private func big(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 44, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.5)
    }
}
