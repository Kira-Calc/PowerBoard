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

    var body: some View {
        let energy = ValueFormatting.energy(report.totals.energyWh)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: strings(.about))
                    .font(.system(size: large ? 26 : 22, weight: .medium))
                    .foregroundStyle(.secondary)
                RollingText(energy.mid.text)
                    .font(.system(size: large ? 48 : 38, weight: .semibold))
            }
            Text(verbatim: "\(strings(.range)) \(energy.low.text) – \(energy.high.text)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: large ? 24 : 28) {
                metric(strings(.carbon), "\(ValueFormatting.carbon(grams: report.totals.co2GramsMid).text) \(Units.co2e)")
                metric(strings(.tokens), ValueFormatting.tokens(report.totals.tokens.total))
                metric(strings(.sessions), "\(report.sessionCount)")
                metric(strings(.comparedWithPrevious), changeText)
            }
            .padding(.top, 4)
        }
    }

    private var changeText: String {
        guard let change = report.energyChange else { return "–" }
        return "\(change >= 0 ? "+" : "")\(String(format: "%.0f", change * 100))%"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            RollingText(value).font(large ? .title2.weight(.semibold) : .title3.weight(.semibold))
        }
    }
}

/// Energy per trend bucket, stacked by tool.
struct ReportTrendChart: View {
    let report: Report
    let strings: ReportStrings

    private struct Point: Identifiable {
        var id: String
        var x: Date
        var wh: Double
        var tool: String
    }

    var body: some View {
        let points = report.trend.flatMap { bucket in
            UsageSource.allCases.compactMap { source -> Point? in
                guard let wh = bucket.serverWhBySource[source], wh > 0 else { return nil }
                return Point(id: "\(source.rawValue)-\(bucket.start.timeIntervalSince1970)", x: bucket.start, wh: wh, tool: strings.sourceName(source))
            }
        }
        let used = UsageSource.allCases.filter { source in report.trend.contains { ($0.serverWhBySource[source] ?? 0) > 0 } }
        Chart(points) { point in
            BarMark(x: .value("Time", point.x, unit: unit), y: .value("Wh", point.wh))
                .foregroundStyle(by: .value("Tool", point.tool))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(domain: used.map(strings.sourceName), range: used.map(Palette.source))
        .chartXScale(domain: (report.trend.first?.start ?? report.interval.start)...(report.trend.last?.end ?? report.interval.end))
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let wh = value.as(Double.self) { Text(ValueFormatting.energy(wh: wh).text).monospacedDigit() }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisValues) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .environment(\.locale, strings.locale)
    }

    private var unit: Calendar.Component {
        switch report.period {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        }
    }

    private var axisValues: AxisMarkValues {
        switch report.period {
        case .day: .stride(by: .hour, count: 3)
        case .week: .stride(by: .day, count: 1)
        case .month: .stride(by: .day, count: 5)
        case .year: .stride(by: .month, count: 1)
        }
    }

    /// Axis labels in the report's language, which may differ from the system language in exports.
    private var axisFormat: Date.FormatStyle {
        let style: Date.FormatStyle = switch report.period {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day()
        case .year: .dateTime.month(.narrow)
        }
        return style.locale(strings.locale)
    }
}

/// A breakdown table: tool, model or project, with energy, carbon and tokens.
struct ReportBreakdownTable: View {
    enum Kind { case tool, model, project }

    let kind: Kind
    let items: [ReportBreakdownItem]
    let strings: ReportStrings
    var maxRows = 8
    var hideProjects = false

    var body: some View {
        let total = max(items.reduce(0) { $0 + $1.energyWh.mid }, 0.000_001)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text(verbatim: header)
                Text(verbatim: "").gridColumnAlignment(.leading)
                Text(verbatim: strings(.energyColumn)).gridColumnAlignment(.trailing)
                Text(verbatim: strings(.carbonColumn)).gridColumnAlignment(.trailing)
                Text(verbatim: strings(.tokensColumn)).gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(Array(items.prefix(maxRows).enumerated()), id: \.offset) { index, item in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(item.source.map(Palette.source) ?? Palette.neutral).frame(width: 7, height: 7)
                        Text(verbatim: name(item, index: index)).lineLimit(1)
                    }
                    Capsule()
                        .fill((item.source.map(Palette.source) ?? Palette.neutral).opacity(0.8))
                        .frame(width: max(2, 80 * item.energyWh.mid / total), height: 5)
                        .frame(width: 80, alignment: .leading)
                    Text(verbatim: ValueFormatting.energy(wh: item.energyWh.mid).text).monospacedDigit()
                    Text(verbatim: ValueFormatting.carbon(grams: item.co2GramsMid).text).monospacedDigit()
                    Text(verbatim: ValueFormatting.tokens(item.tokens.total)).monospacedDigit()
                }
                .font(.callout)
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
