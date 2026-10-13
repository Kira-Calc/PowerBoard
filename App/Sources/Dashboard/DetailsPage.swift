import ElectricityCore
import SwiftUI

/// Sortable, filterable table of usage grouped by session, project or model (SPEC 9.3).
struct DetailsPage: View {
    let context: DashboardContext

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all
        case claudeCode
        case claudeDesktop
        case codex
        case antigravity

        var id: String { rawValue }

        func matches(_ source: UsageSource) -> Bool {
            switch self {
            case .all: true
            case .claudeCode: source == .claudeCode
            case .claudeDesktop: source == .claudeDesktop
            case .codex: source == .codex
            case .antigravity: source == .antigravity
            }
        }
    }

    /// One table row with sortable values.
    struct Row: Identifiable, Hashable {
        var group: UsageGroup
        var id: String { group.id }
        var name: String
        var lastTimestamp: Date { group.lastTimestamp }
        var toolName: String
        var model: String { group.model }
        var confidence: String
        var tokensTotal: Int { group.tokens.total }
        var energyMid: Double { group.energyWh.mid }
        var co2: Double { group.co2GramsMid }
    }

    @State private var grouping: UsageGrouping = .session
    @State private var sourceFilter: SourceFilter = .all
    @State private var searchText = ""
    @State private var groups: [UsageGroup] = []
    @State private var unmapped: [String] = []
    @State private var sortOrder = [KeyPathComparator(\Row.lastTimestamp, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("details.groupBy", selection: $grouping) {
                    Text("details.group.session").tag(UsageGrouping.session)
                    Text("details.group.project").tag(UsageGrouping.project)
                    Text("details.group.model").tag(UsageGrouping.model)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                // Only tools in use; with a single tool there is nothing to filter.
                let used = context.model.usedSources
                if used.count > 1 {
                    Picker("details.tool", selection: $sourceFilter) {
                        Text("details.tool.all").tag(SourceFilter.all)
                        if used.contains(.claudeCode) { Text("source.claudeCode").tag(SourceFilter.claudeCode) }
                        if used.contains(.claudeDesktop) { Text("source.claudeDesktop").tag(SourceFilter.claudeDesktop) }
                        if used.contains(.codex) { Text("source.codex").tag(SourceFilter.codex) }
                        if used.contains(.antigravity) { Text("source.antigravity").tag(SourceFilter.antigravity) }
                    }
                    .fixedSize()
                }
                Spacer()
            }
            if !unmapped.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    SymbolIcon(Icons.info).foregroundStyle(.orange)
                    Text(String(format: String(localized: "details.unmapped"), unmapped.joined(separator: ", ")))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("column.lastActive", value: \.lastTimestamp) { row in
                    Text(Formatting.dateTime(row.lastTimestamp)).monospacedDigit().lineLimit(1)
                }
                .width(min: 150, ideal: 160)
                TableColumn("column.tool", value: \.toolName) { row in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.source(row.group.source)).frame(width: 8, height: 8)
                        Text(row.toolName).lineLimit(1)
                    }
                }
                // Wide enough for "Claude Desktop · Cowork"; a narrow window scrolls the table sideways instead.
                .width(min: 150, ideal: 170)
                TableColumn(nameColumnTitle, value: \.name) { row in
                    Text(verbatim: row.name)
                        .help(row.group.projectPath ?? row.group.key)
                }
                .width(min: 120, ideal: 180)
                TableColumn("column.model", value: \.model) { row in
                    Text(verbatim: row.model)
                }
                .width(min: 120, ideal: 160)
                TableColumn("column.confidence", value: \.confidence) { row in
                    Text(row.confidence)
                        .foregroundStyle(row.group.tierConfidence == .unmapped ? .orange : .secondary)
                }
                .width(min: 70, ideal: 90)
                TableColumn("column.tokens", value: \.tokensTotal) { row in
                    Text(ValueFormatting.tokens(row.tokensTotal)).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
                TableColumn("column.energy", value: \.energyMid) { row in
                    Text(context.settings.formatEnergy(row.energyMid).text)
                        .monospacedDigit()
                        .help(rangeHelp(row.group.energyWh))
                }
                .width(min: 70, ideal: 90)
                TableColumn("column.carbon", value: \.co2) { row in
                    Text(ValueFormatting.carbon(grams: row.co2).text).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
            }
        }
        .padding(20)
        .searchable(text: $searchText, prompt: Text("details.search"))
        .storeQuery(context.model, id: grouping) { [grouping] store in
            (try store.groupedUsage(by: grouping), try store.unmappedModels().map(\.model))
        } assign: { result, models in
            groups = result
            unmapped = models
        }
    }

    private var nameColumnTitle: LocalizedStringKey {
        switch grouping {
        case .session: "column.session"
        case .project: "column.project"
        case .model: "column.model"
        }
    }

    private var rows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return groups
            .filter { sourceFilter.matches($0.source) }
            .map { group in
                Row(
                    group: group,
                    name: displayName(group),
                    toolName: SourceText.name(group.source, client: group.client),
                    confidence: Formatting.confidence(group.tierConfidence)
                )
            }
            .filter { row in
                query.isEmpty
                    || row.name.lowercased().contains(query)
                    || row.model.lowercased().contains(query)
                    || (row.group.projectPath?.lowercased().contains(query) ?? false)
            }
            .sorted(using: sortOrder)
    }

    private func displayName(_ group: UsageGroup) -> String {
        switch grouping {
        case .session:
            return "\(Formatting.projectName(group.projectPath)) \u{2013} \(group.key.prefix(8))"
        case .project:
            return Formatting.projectName(group.key)
        case .model:
            return group.key
        }
    }

    private func rangeHelp(_ estimate: Estimate) -> String {
        let range = context.settings.formatEnergy(estimate)
        return String(format: String(localized: "popover.energy.range"), range.low.text, range.high.text)
    }
}
