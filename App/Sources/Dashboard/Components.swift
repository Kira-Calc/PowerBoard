import ElectricityCore
import SwiftUI

/// Scrollable page body with standard padding.
struct PageContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rounded panel used for cards on dashboard pages.
struct Card<Content: View>: View {
    /// Stretches to the height of the row, so cards side by side end at the same line.
    /// Use inside a row with `.fixedSize(horizontal: false, vertical: true)`.
    var fillHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A small neutral label that marks a value as measured at AI providers' servers.
struct ServerTag: View {
    var body: some View {
        Text("tag.server")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

/// Card title with a colored icon badge and an optional info button.
struct CardHeader: View {
    let icon: Icon
    let color: Color
    let title: LocalizedStringKey
    var info: EstimateTopic?
    var context: DashboardContext?
    var serverTag = false
    /// Explanations shown behind an info button, when `info` is not set.
    var tips: [LocalizedStringKey] = []

    var body: some View {
        HStack(spacing: 8) {
            IconBadge(icon, color: color)
            Text(title).font(.headline)
            if serverTag { ServerTag() }
            Spacer()
            if let info, let context {
                EstimateInfoButton(topic: info, context: context)
            } else if !tips.isEmpty {
                InfoTip(tips)
            }
        }
    }
}

/// An info button that shows explanations in a popover, so they are not printed under every control.
struct InfoTip: View {
    let paragraphs: [LocalizedStringKey]
    @State private var isShown = false

    init(_ paragraphs: [LocalizedStringKey]) {
        self.paragraphs = paragraphs
    }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            SymbolIcon(Icons.info, size: 14)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(Text("info.tip"))
        .accessibilityLabel(Text("info.tip"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    Text(paragraphs[index]).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
    }
}

/// Grid explanations, shared by the info buttons and the methodology page.
@MainActor
enum GridTips {
    static let level: [LocalizedStringKey] = ["grid.liveNote", "grid.info.dot", "grid.mixed", "grid.recent.note", "grid.staticNote", "grid.infoOnly"]
    static let today: [LocalizedStringKey] = ["grid.today.note"]
    static let sources: [LocalizedStringKey] = ["grid.watttime.createNote", "grid.emaps.note", "grid.thresholds.note"]
}

/// What an info button explains.
enum EstimateTopic {
    case energy
    case carbon
    case tokens
}

/// Shows how an estimate is calculated and where the factors come from (SPEC 9.1).
struct EstimateInfoButton: View {
    let topic: EstimateTopic
    let context: DashboardContext
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            SymbolIcon(Icons.info, size: 15)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(Text("info.button"))
        .accessibilityLabel(Text("info.button"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    explanation
                }
                .padding(16)
                .frame(width: 380, alignment: .leading)
            }
            .frame(maxHeight: 420)
        }
    }

    @ViewBuilder
    private var explanation: some View {
        let settings = context.settings
        let factors = context.model.factors
        switch topic {
        case .energy:
            Text("info.energy.title").font(.headline)
            Text("info.energy.scope").fixedSize(horizontal: false, vertical: true)
            Text("info.energy.formula").font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true)
            Text(String(format: String(localized: "info.energy.cacheRatios"),
                        Formatting.ratio(settings.cacheWriteRatio), Formatting.ratio(settings.cacheReadRatio)))
            if let factors {
                Text(String(format: String(localized: "info.energy.range"),
                            Formatting.ratio(factors.uncertainty.low), Formatting.ratio(factors.uncertainty.high)))
                FactorTable(factors: factors)
                Text(String(format: String(localized: "info.factors.version"), factors.version))
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: factors.source)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .carbon:
            Text("info.carbon.title").font(.headline)
            Text("info.carbon.formula").font(.callout.monospaced())
            Text(String(format: String(localized: "info.carbon.grid"), Formatting.number(settings.gridGramsPerKWh, decimals: 0), Units.gramsPerKWh))
            Text("info.carbon.basis").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .tokens:
            Text("info.tokens.title").font(.headline)
            Text("info.tokens.body").fixedSize(horizontal: false, vertical: true)
            Text(String(format: String(localized: "overview.cache.note"), Formatting.ratio(settings.cacheReadRatio * 100) + "%"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Table of energy factors per tier.
struct FactorTable: View {
    let factors: EnergyFactors

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("factors.tier").foregroundStyle(.secondary)
                Text("factors.input").foregroundStyle(.secondary)
                Text("factors.output").foregroundStyle(.secondary)
            }
            .font(.caption)
            ForEach(Formatting.tierOrder.filter { factors.tiers[$0] != nil }, id: \.self) { tier in
                GridRow {
                    Text(Formatting.tierName(tier))
                    Text(Formatting.number(factors.tiers[tier]?.input ?? 0, decimals: 0)).monospacedDigit()
                    Text(Formatting.number(factors.tiers[tier]?.output ?? 0, decimals: 0)).monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}

/// Text helpers shared by dashboard pages.
enum Formatting {
    static let tierOrder = ["small", "medium", "large", "xlarge"]

    static func number(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }

    /// Ratios such as 0.08 or 1.
    static func ratio(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func tierName(_ tier: String) -> String {
        Bundle.main.localizedString(forKey: "tier.\(tier)", value: tier, table: nil)
    }

    static func confidence(_ confidence: TierConfidence) -> String {
        Bundle.main.localizedString(forKey: "confidence.\(confidence.rawValue)", value: confidence.rawValue, table: nil)
    }

    /// Last folder name of a project path (SPEC 13). The full path is shown only on hover.
    static func projectName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return String(localized: "project.unknown") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "2 minutes ago", "just now".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 30 { return String(localized: "time.justNow") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Runs a store query off the main thread whenever `dataVersion` changes.
struct StoreQuery<Value: Sendable>: ViewModifier {
    let model: AppModel
    let extraID: AnyHashable
    let query: @Sendable (UsageStore) throws -> Value
    let assign: (Value) -> Void

    func body(content: Content) -> some View {
        content.task(id: [AnyHashable(model.dataVersion), extraID]) {
            guard let store = model.store else { return }
            let result = await Task.detached { try? query(store) }.value
            if let result { assign(result) }
        }
    }
}

extension View {
    func storeQuery<Value: Sendable>(
        _ model: AppModel,
        id: AnyHashable = 0,
        _ query: @escaping @Sendable (UsageStore) throws -> Value,
        assign: @escaping (Value) -> Void
    ) -> some View {
        modifier(StoreQuery(model: model, extraID: id, query: query, assign: assign))
    }
}
