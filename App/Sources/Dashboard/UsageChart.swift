import Charts
import ElectricityCore
import SwiftUI

/// One chart for energy or tokens, split by agent, as bars per bucket or as a running total,
/// over today (hours), the last 14 days or the last 12 weeks.
struct UsageChartCard: View {
    let context: DashboardContext

    enum Metric: String, CaseIterable { case energy, tokens }
    enum Style: String, CaseIterable { case bars, cumulative }

    @AppStorage("chart.metric") private var metric: Metric = .energy
    @AppStorage("chart.style") private var style: Style = .bars
    @AppStorage("chart.scale") private var scaleRaw: String = ChartScale.hour.rawValue
    /// Comma-separated series IDs to show, or "total" for one combined series.
    @AppStorage("chart.selection") private var selectionRaw: String = Self.totalID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var buckets: [SeriesBucket] = []
    /// 0 to 1: values are drawn scaled by this, so bars grow and lines rise when the view changes.
    @State private var progress: Double = 1
    /// Set when the time scale changes, so the next data load grows from zero.
    @State private var growOnNextLoad = true

    private var scale: ChartScale { ChartScale(rawValue: scaleRaw) ?? .hour }

    static let totalID = "total"
    static let localID = "local"

    /// A chart series: one agent, or this Mac.
    private struct Series: Identifiable, Hashable {
        var id: String
        var name: String
        var color: Color
        var value: (SeriesBucket) -> Double

        static func == (lhs: Series, rhs: Series) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private struct Point: Identifiable {
        var id: String
        var x: Date
        var value: Double
        var series: String
    }

    var body: some View {
        let includeLocal = context.settings.includeLocalEnergy
        Card {
            HStack(alignment: .firstTextBaseline) {
                CardHeader(icon: metric == .energy ? Icons.lightning : Icons.coins,
                           color: metric == .energy ? Palette.energy : Palette.tokens,
                           title: titleKey)
                RollingText(String(format: String(localized: "chart.total"), format(total)))
                    .font(.title3.weight(.semibold))
            }
            HStack(spacing: 12) {
                Picker("", selection: $metric) {
                    Text("chart.metric.energy").tag(Metric.energy)
                    Text("chart.metric.tokens").tag(Metric.tokens)
                }
                Picker("", selection: $style) {
                    Text("chart.style.bars").tag(Style.bars)
                    Text("chart.style.cumulative").tag(Style.cumulative)
                }
                Spacer()
                Picker("", selection: $scaleRaw) {
                    Text("chart.scale.hour").tag(ChartScale.hour.rawValue)
                    Text("chart.scale.day").tag(ChartScale.day.rawValue)
                    Text("chart.scale.week").tag(ChartScale.week.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            seriesToggles

            // Bars and the running total cross-fade; the incoming one grows from zero.
            ZStack {
                if style == .bars {
                    barChart.transition(.opacity)
                } else {
                    cumulativeChart.transition(.opacity)
                }
            }
            .frame(height: 220)
            .animation(.easeInOut(duration: 0.35), value: style)
            .animation(.easeInOut(duration: 0.35), value: metric)
        }
        .onChange(of: style) { grow() }
        .onChange(of: metric) { grow() }
        .onChange(of: selectionRaw) { grow() }
        .onChange(of: scaleRaw) { growOnNextLoad = true }
        .storeQuery(context.model, id: [AnyHashable(scaleRaw), AnyHashable(includeLocal), AnyHashable(context.model.snapshot?.generatedAt)]) {
            [scale, includeLocal] store in
            try store.series(boundaries: scale.boundaries(now: Date()), includeLocal: includeLocal)
        } assign: { result in
            if growOnNextLoad {
                growOnNextLoad = false
                buckets = result
                grow()
            } else {
                // Regular refreshes move the existing marks to their new values.
                withAnimation(.smooth(duration: 0.5)) { buckets = result }
            }
        }
    }

    /// Restarts the growth animation from zero.
    private func grow() {
        guard !reduceMotion else {
            progress = 1
            return
        }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 0 }
        Task { @MainActor in
            // Let the zero state render before animating to full height.
            try? await Task.sleep(for: .milliseconds(20))
            // No overshoot: values never move outside the final range.
            withAnimation(.easeOut(duration: 0.6)) { progress = 1 }
        }
    }

    private var titleKey: LocalizedStringKey {
        switch scale {
        case .hour: "chart.title.hour"
        case .day: "chart.title.day"
        case .week: "chart.title.week"
        }
    }

    // MARK: Series

    /// Every series that can be shown: each agent, then this Mac when included.
    private var availableSeries: [Series] {
        var result: [Series] = UsageSource.allCases.map { source in
            let value: (SeriesBucket) -> Double = metric == .energy
                ? { $0.serverWhBySource[source] ?? 0 }
                : { Double($0.tokensBySource[source]?.total ?? 0) }
            return Series(id: source.rawValue, name: SourceText.name(source), color: Palette.source(source), value: value)
        }
        if metric == .energy, context.settings.includeLocalEnergy {
            result.append(Series(id: Self.localID, name: String(localized: "energy.part.local"), color: Palette.local, value: \.localWh))
        }
        return result
    }

    private var totalSeries: Series {
        let parts = availableSeries
        return Series(id: Self.totalID, name: String(localized: "chart.series.total"),
                      color: metric == .energy ? Palette.energy : Palette.tokens,
                      value: { bucket in parts.reduce(0) { $0 + $1.value(bucket) } })
    }

    private var selectedIDs: Set<String> {
        Set(selectionRaw.split(separator: ",").map(String.init))
    }

    /// The series drawn: the combined total, or the checked agents.
    private var series: [Series] {
        let ids = selectedIDs
        let chosen = availableSeries.filter { ids.contains($0.id) }
        return ids.contains(Self.totalID) || chosen.isEmpty ? [totalSeries] : chosen
    }

    private var showsTotal: Bool { series.first?.id == Self.totalID }

    /// Checking "Total" clears the agents; checking an agent clears "Total". Unchecking everything shows the total.
    private func setSelected(_ id: String, _ on: Bool) {
        var ids = selectedIDs
        if id == Self.totalID {
            ids = on ? [Self.totalID] : []
        } else {
            ids.remove(Self.totalID)
            if on { ids.insert(id) } else { ids.remove(id) }
        }
        let valid = Set(availableSeries.map(\.id))
        ids = ids.filter { $0 == Self.totalID || valid.contains($0) }
        selectionRaw = ids.isEmpty ? Self.totalID : ids.sorted().joined(separator: ",")
    }

    private var seriesToggles: some View {
        HStack(spacing: 16) {
            toggle(totalSeries, isOn: showsTotal)
            ForEach(availableSeries) { item in
                toggle(item, isOn: !showsTotal && selectedIDs.contains(item.id))
            }
            Spacer()
        }
        .font(.callout)
    }

    private func toggle(_ item: Series, isOn: Bool) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { setSelected(item.id, $0) })) {
            HStack(spacing: 5) {
                Circle().fill(item.color).frame(width: 8, height: 8)
                Text(item.name)
            }
        }
        .toggleStyle(.checkbox)
    }

    /// Sum of the series drawn.
    private var total: Double {
        let drawn = series
        return buckets.reduce(0) { sum, bucket in sum + drawn.reduce(0) { $0 + $1.value(bucket) } }
    }

    private var barPoints: [Point] {
        series.flatMap { item in
            buckets.map { bucket in
                Point(id: "\(item.id)-\(bucket.start.timeIntervalSince1970)", x: bucket.start, value: max(0, item.value(bucket) * progress), series: item.name)
            }
        }
    }

    /// Running totals per series at the end of each bucket, up to now. Stacked areas add up to the total.
    private var cumulativePoints: [Point] {
        let now = Date()
        let visible = buckets.filter { $0.start <= now }
        return series.flatMap { item -> [Point] in
            var running = 0.0
            var points: [Point] = []
            if let first = visible.first {
                points.append(Point(id: "\(item.id)-start", x: first.start, value: 0, series: item.name))
            }
            for bucket in visible {
                running += item.value(bucket)
                points.append(Point(id: "\(item.id)-\(bucket.start.timeIntervalSince1970)", x: min(bucket.end, now), value: running * progress, series: item.name))
            }
            return points
        }
    }

    /// Final maximum of the plotted values, so the axis stays fixed while marks grow.
    private var yMax: Double {
        let drawn = series
        let value: Double
        if style == .bars {
            value = drawn.flatMap { item in buckets.map(item.value) }.max() ?? 0
        } else {
            value = drawn.map { item in buckets.reduce(0) { $0 + item.value($1) } }.max() ?? 0
        }
        return max(value * 1.08, metric == .energy ? 1 : 10)
    }

    private var domain: ClosedRange<Date> {
        guard let first = buckets.first?.start, let last = buckets.last?.end, first < last else {
            let now = Date()
            return now...now.addingTimeInterval(1)
        }
        return first...last
    }

    private func format(_ value: Double) -> String {
        metric == .energy ? context.settings.formatEnergy(value).text : ValueFormatting.tokens(Int(value))
    }

    // MARK: Charts

    private var barChart: some View {
        Chart(barPoints) { point in
            // Series are placed side by side within each bucket, not stacked.
            BarMark(x: .value("Time", point.x, unit: barUnit), y: .value("Value", point.value))
                .foregroundStyle(by: .value("Series", point.series))
                .position(by: .value("Series", point.series))
                .cornerRadius(2)
        }
        .modifier(ChartStyling(chart: self))
    }

    /// One line per series with a soft gradient below, a dot at the latest value and a dashed rule at now.
    private var cumulativeChart: some View {
        let points = cumulativePoints
        let drawn = series
        let lastX = points.map(\.x).max()
        return Chart {
            ForEach(drawn) { item in
                let itemPoints = points.filter { $0.series == item.name }
                ForEach(itemPoints) { point in
                    AreaMark(x: .value("Time", point.x), y: .value("Value", point.value), series: .value("Series", item.name), stacking: .unstacked)
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(
                            colors: [item.color.opacity(drawn.count > 1 ? 0.16 : 0.28), item.color.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    LineMark(x: .value("Time", point.x), y: .value("Value", point.value), series: .value("Series", item.name))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(item.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let last = itemPoints.last {
                    PointMark(x: .value("Time", last.x), y: .value("Value", last.value))
                        .symbolSize(40)
                        .foregroundStyle(item.color)
                }
            }
            if let lastX {
                RuleMark(x: .value("Time", lastX))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .modifier(ChartStyling(chart: self))
    }

    /// Axes, scales and legend shared by both charts.
    private struct ChartStyling: ViewModifier {
        let chart: UsageChartCard

        func body(content: Content) -> some View {
            let series = chart.series
            content
                .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
                // The checkboxes above the chart show the colors.
                .chartLegend(.hidden)
                .chartXScale(domain: chart.domain)
                .chartYScale(domain: 0...chart.yMax)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(chart.format(number)).monospacedDigit() }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: chart.xAxisValues) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel(format: chart.xAxisFormat)
                    }
                }
                .accessibilityLabel(Text(chart.titleKey))
        }
    }

    private var barUnit: Calendar.Component {
        switch scale {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        }
    }

    private var xAxisValues: AxisMarkValues {
        switch scale {
        case .hour: .stride(by: .hour, count: 3)
        case .day: .stride(by: .day, count: 2)
        case .week: .stride(by: .weekOfYear, count: 2)
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch scale {
        case .hour: .dateTime.hour()
        case .day, .week: .dateTime.month(.defaultDigits).day()
        }
    }
}
