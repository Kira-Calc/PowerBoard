import AppKit
import Charts
import ElectricityCore
import SwiftUI

extension ReportStrings {
    /// Strings in the language the app is shown in.
    static var app: ReportStrings {
        ReportStrings(Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .zh : .en)
    }
}

/// Report building blocks shared by the Reports page and the PNG and PDF exports (SPEC 12).
/// Text comes from `ReportStrings`, so exports can use a language other than the app's.

struct ReportSummaryView: View {
    let report: Report
    let strings: ReportStrings
    var large = false
    /// Smaller type for exported pages.
    var compact = false

    var body: some View {
        let energy = ValueFormatting.energy(report.totals.energyWh)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: strings(.about))
                    .font(.system(size: large ? 26 : compact ? 18 : 22, weight: .medium))
                    .foregroundStyle(.secondary)
                RollingText(energy.mid.text)
                    .font(.system(size: large ? 48 : compact ? 30 : 38, weight: .semibold))
            }
            Text(verbatim: "\(strings(.range)) \(energy.low.text) – \(energy.high.text)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: large ? 24 : compact ? 18 : 28) {
                metric(strings(.carbon), "\(ValueFormatting.carbon(grams: report.totals.co2GramsMid).text) \(Units.co2e)")
                metric(strings(.tokens), ValueFormatting.tokens(report.totals.tokens.total))
                metric(strings(.sessions), "\(report.sessionCount)")
                metric(strings(.comparedWithPrevious), changeText)
            }
            .padding(.top, 4)
        }
    }

    private var changeText: String { strings.change(report.energyChange) }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            RollingText(value).font(large ? .title2.weight(.semibold) : compact ? .headline : .title3.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A breakdown table: tool, model or project, with energy, carbon and tokens.
struct ReportBreakdownTable: View {
    enum Kind { case tool, model, project }
    /// Narrow tables drop the share bar; the narrowest also drop carbon, which follows energy.
    enum Columns { case full, noBar, compact }

    let kind: Kind
    let items: [ReportBreakdownItem]
    let strings: ReportStrings
    var maxRows = 8
    var hideProjects = false
    var columns = Columns.full

    var body: some View {
        let total = max(items.reduce(0) { $0 + $1.energyWh.mid }, 0.000_001)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text(verbatim: header)
                if columns == .full { Text(verbatim: "").gridColumnAlignment(.leading) }
                Text(verbatim: strings(.energyColumn)).gridColumnAlignment(.trailing)
                if columns != .compact { Text(verbatim: strings(.carbonColumn)).gridColumnAlignment(.trailing) }
                Text(verbatim: strings(.tokensColumn)).gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(Array(items.prefix(maxRows).enumerated()), id: \.offset) { index, item in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(item.source.map(Palette.source) ?? Palette.neutral).frame(width: 7, height: 7)
                        Text(verbatim: name(item, index: index)).lineLimit(1).truncationMode(.middle)
                    }
                    if columns == .full {
                        Capsule()
                            .fill((item.source.map(Palette.source) ?? Palette.neutral).opacity(0.8))
                            .frame(width: max(2, 80 * item.energyWh.mid / total), height: 5)
                            .frame(width: 80, alignment: .leading)
                    }
                    Text(verbatim: ValueFormatting.energy(wh: item.energyWh.mid).text).monospacedDigit().fixedSize()
                    if columns != .compact {
                        Text(verbatim: ValueFormatting.carbon(grams: item.co2GramsMid).text).monospacedDigit().fixedSize()
                    }
                    Text(verbatim: ValueFormatting.tokens(item.tokens.total)).monospacedDigit().fixedSize()
                }
                .font(columns == .full ? .callout : .caption)
            }
        }
    }

    private var header: String {
        switch kind {
        case .tool: strings(.tool)
        case .model: strings(.model)
        case .project: strings(.project)
        }
    }

    private func name(_ item: ReportBreakdownItem, index: Int) -> String {
        switch kind {
        case .tool: strings.sourceName(item.source)
        case .model: item.key
        case .project:
            if item.key.isEmpty { strings(.unknownProject) }
            else if hideProjects { "\(strings(.hiddenProject)) \(index + 1)" }
            else { URL(fileURLWithPath: item.key).lastPathComponent }
        }
    }
}

/// "Estimates. Method: ..." line required on PNG and PDF exports (SPEC 12).
struct ReportFooter: View {
    let strings: ReportStrings

    var body: some View {
        Text(verbatim: strings(.footer))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Brand line for exported reports: app icon and name, then the report title and period.
struct ReportBrandHeader: View {
    let report: Report
    let strings: ReportStrings
    var iconSize: CGFloat = 36
    /// Optional name shown after the title, for example "Weekly report · Kira-Calc".
    var author: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: AppIdentity.displayName).font(.headline)
                Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: strings.periodLabel(report))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var subtitle: String {
        guard let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty else { return strings.title(report) }
        return "\(strings.title(report)) · \(author)"
    }
}

/// Token counts by kind, in one line under the summary.
struct ReportTokenLine: View {
    let report: Report
    let strings: ReportStrings

    var body: some View {
        let tokens = report.totals.tokens
        let separator = strings.language == .zh ? "　" : "   "
        Text(verbatim: [
            "\(strings(.input)) \(ValueFormatting.tokens(tokens.inputUncached))",
            "\(strings(.output)) \(ValueFormatting.tokens(tokens.output))",
            "\(strings(.cacheWrite)) \(ValueFormatting.tokens(tokens.cacheWrite))",
            "\(strings(.cacheRead)) \(ValueFormatting.tokens(tokens.cacheRead))",
        ].joined(separator: separator))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// Energy or tokens over the report period: bars per bucket stacked by tool, or a cumulative curve.
struct ReportUsageChart: View {
    enum Metric { case energy, tokens }

    let report: Report
    let strings: ReportStrings
    let metric: Metric
    let cumulative: Bool
    /// Fewer axis labels, for narrow charts on exported pages.
    var compactAxis = false

    private struct Point: Identifiable {
        var id: String
        var x: Date
        var value: Double
        var tool: String
        /// End of the bucket, for bars.
        var end: Date = .distantPast
        /// Bottom of this tool's segment in a stacked bar.
        var base: Double = 0

        var top: Double { base + value }
        /// The bucket narrowed a little on each side, so neighboring bars have a gap.
        var barStart: Date { x.addingTimeInterval(end.timeIntervalSince(x) * 0.12) }
        var barEnd: Date { end.addingTimeInterval(-end.timeIntervalSince(x) * 0.12) }
    }

    private func value(_ bucket: SeriesBucket, _ source: UsageSource) -> Double {
        metric == .energy ? bucket.serverWhBySource[source] ?? 0 : Double(bucket.tokensBySource[source]?.total ?? 0)
    }

    private func total(_ bucket: SeriesBucket) -> Double {
        metric == .energy ? bucket.serverWh : Double(bucket.tokens.total)
    }

    private var sources: [UsageSource] {
        UsageSource.allCases.filter { source in report.trend.contains { value($0, source) > 0 } }
    }

    private var color: Color { metric == .energy ? Palette.energy : Palette.tokens }

    var body: some View {
        if cumulative { axes(cumulativeChart) } else { axes(barChart) }
    }

    private var barChart: some View {
        // Stacked by tool, with each segment's bottom and top computed here, because a bar given its own time span
        // is not stacked by Swift Charts.
        let points = report.trend.flatMap { bucket in
            var base = 0.0
            return sources.compactMap { source -> Point? in
                let v = value(bucket, source)
                guard v > 0 else { return nil }
                defer { base += v }
                return Point(id: "\(source.rawValue)-\(bucket.start.timeIntervalSince1970)", x: bucket.start, value: v,
                             tool: strings.sourceName(source), end: bucket.end, base: base)
            }
        }
        // Each bar spans its own bucket. Binning by calendar unit would draw the short first and last buckets of a
        // rolling period as whole hours or days, past the edges of the chart.
        return Chart(points) { point in
            RectangleMark(xStart: .value("Start", point.barStart), xEnd: .value("End", point.barEnd),
                    yStart: .value("Bottom", point.base), yEnd: .value("Top", point.top))
                .foregroundStyle(by: .value("Tool", point.tool))
                .cornerRadius(1.5)
        }
        .chartForegroundStyleScale(domain: sources.map(strings.sourceName), range: sources.map(Palette.source))
        .chartLegend(sources.count > 1 ? .visible : .hidden)
        .chartLegend(position: .bottom, alignment: .leading)
    }

    private var cumulativeChart: some View {
        // The curve ends when the report was made, so a current period does not show flat future days.
        var running = 0.0
        let points = [Point(id: "start", x: report.interval.start, value: 0, tool: "")] + report.trend
            .filter { $0.start < report.generatedAt }
            .map { bucket in
                running += total(bucket)
                let end = min(bucket.end, report.generatedAt)
                return Point(id: "\(end.timeIntervalSince1970)", x: end, value: running, tool: "")
            }
        return Chart(points) { point in
            // A flat fill: PDF output does not keep the transparency of gradients.
            AreaMark(x: .value("Time", point.x), y: .value("Value", point.value))
                .foregroundStyle(color.opacity(0.15))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.x), y: .value("Value", point.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
        }
    }

    private func axes(_ chart: some View) -> some View {
        chart
            .chartXScale(domain: report.interval.start...report.interval.end)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(verbatim: label(number)).monospacedDigit() }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisValues) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    // A label at the very end of the period would be cut off at the edge.
                    if let date = value.as(Date.self), report.interval.end.timeIntervalSince(date) > report.interval.duration * 0.06,
                       date.timeIntervalSince(report.interval.start) > report.interval.duration * 0.03 {
                        // Centered under its grid line.
                        AxisValueLabel(format: axisFormat, anchor: .top)
                    }
                }
            }
            .environment(\.locale, strings.locale)
    }

    private func label(_ number: Double) -> String {
        if number == 0 { return "0" }
        return metric == .energy ? ValueFormatting.energy(wh: number).text : ValueFormatting.tokens(Int(number))
    }

    private var axisValues: AxisMarkValues {
        switch report.period {
        case .day: .stride(by: .hour, count: compactAxis ? 8 : 6)
        case .week: .stride(by: .day, count: compactAxis ? 2 : 1)
        case .month: .stride(by: .day, count: compactAxis ? 10 : 7)
        case .year: .stride(by: .month, count: compactAxis ? 3 : 2)
        }
    }

    private var axisFormat: Date.FormatStyle {
        let style: Date.FormatStyle = switch report.period {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.month(.defaultDigits).day()
        case .year: .dateTime.month(.abbreviated)
        }
        return style.locale(strings.locale)
    }
}

/// Estimated generation behind the energy: a donut with the fossil-free share in the middle, and a legend.
struct ReportEnergyMixView: View {
    let mix: ReportEnergyMix
    let strings: ReportStrings
    var donut: CGFloat = 110
    /// Legend columns; two keep the block short on exported pages.
    var legendColumns = 1

    private var groups: [FuelGroup] { FuelGroup.allCases.filter { mix.share($0) >= 0.005 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Chart(groups, id: \.self) { group in
                        SectorMark(angle: .value("Wh", mix.whByGroup[group] ?? 0), innerRadius: .ratio(0.64), angularInset: 1)
                            .foregroundStyle(Palette.fuel(group))
                    }
                    .chartLegend(.hidden)
                    VStack(spacing: 0) {
                        Text(verbatim: percent(mix.cleanShare)).font(.title3.weight(.semibold)).monospacedDigit()
                        Text(verbatim: strings(.cleanShare)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: donut, height: donut)
                let rows = stride(from: 0, to: groups.count, by: legendColumns).map { Array(groups[$0..<min($0 + legendColumns, groups.count)]) }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(rows, id: \.self) { row in
                        GridRow {
                            ForEach(row, id: \.self) { group in
                                Circle().fill(Palette.fuel(group)).frame(width: 8, height: 8)
                                Text(verbatim: strings(.fuel(group)))
                                Text(verbatim: percent(mix.share(group))).monospacedDigit().foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                    .padding(.trailing, legendColumns > 1 ? 10 : 0)
                            }
                        }
                    }
                }
                .font(.callout)
            }
            Text(verbatim: strings(mix.basis == .period ? .mixBasisPeriod : .mixBasisRecent))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func percent(_ share: Double) -> String { String(format: "%.0f%%", share * 100) }
}

/// Energy by the grid level saved with each record (WattTime).
struct ReportGridLevelView: View {
    let report: Report
    let strings: ReportStrings

    private let levels: [GridLevel?] = [.cleaner, .typical, .lessClean, nil]

    var body: some View {
        let total = max(report.energyByGridLevel.values.reduce(0, +), 0.000_001)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(levels, id: \.self) { level in
                        let wh = report.energyByGridLevel[level] ?? 0
                        if wh > 0 {
                            Rectangle()
                                .fill(level == nil ? Color.secondary.opacity(0.25) : GridText.color(level))
                                .frame(width: max(2, proxy.size.width * wh / total))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(levels, id: \.self) { level in
                    GridRow {
                        Circle().fill(level == nil ? Color.secondary.opacity(0.4) : GridText.color(level)).frame(width: 8, height: 8)
                        Text(verbatim: level.map { strings(.gridLevel($0)) } ?? strings(.unrecordedLevel))
                        Text(verbatim: ValueFormatting.energy(wh: report.energyByGridLevel[level] ?? 0).text)
                            .monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}
