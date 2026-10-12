import ElectricityCore
import SwiftUI

/// Panel shown when a menu bar item is clicked (SPEC 8.1).
struct PopoverView: View {
    let model: AppModel
    let settings: AppSettings
    let openDashboard: (DashboardSection?) -> Void
    let quit: () -> Void
    var closePopover: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.activeSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(icon: Icons.terminalWindow, color: .blue, title: "sessions.title")
                    ActiveSessionsList(sessions: model.activeSessions, settings: settings, compact: true, onJump: closePopover)
                        .padding(.horizontal, -8)
                }
                Divider()
            }
            if let today = model.snapshot?.today, today.energyWh.mid > 0 {
                EnergySection(today: today, settings: settings, model: model)
                Divider()
                TokenSection(tokens: today.tokens)
                CarbonSection(grams: today.co2G)
                EquivalentSection(energyWh: today.energyWh.mid, items: settings.enabledEquivalents(from: model.equivalents))
                Divider()
                SourceSection(today: today, settings: settings, sources: model.usedSources)
            } else {
                EmptyState(model: model)
            }
            if let progress = model.scanProgress, model.isBackfilling {
                Text(String(format: String(localized: "popover.backfill"), progress.filesDone, progress.filesTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Divider()
            Footer(openDashboard: openDashboard, quit: quit)
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// Section title with a colored icon badge, and an optional value on the trailing side.
private struct SectionHeader<Trailing: View>: View {
    let icon: Icon
    let color: Color
    let title: LocalizedStringKey
    var serverTag = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            IconBadge(icon, color: color)
            Text(title)
            if serverTag { ServerTag() }
            Spacer(minLength: 8)
            trailing
        }
        .font(.headline)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(icon: Icon, color: Color, title: LocalizedStringKey, serverTag: Bool = false) {
        self.init(icon: icon, color: color, title: title, serverTag: serverTag) { EmptyView() }
    }
}

private struct EnergySection: View {
    let today: Snapshot.Today
    let settings: AppSettings
    let model: AppModel

    var body: some View {
        let energy = settings.displayedEnergy(today)
        let range = settings.formatEnergy(energy.total)
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(icon: Icons.lightning, color: Palette.energy,
                          title: energy.includesLocal ? "popover.today.energyWithLocal" : "popover.today.energy",
                          serverTag: !energy.includesLocal)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("popover.about")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                RollingText(range.mid.text)
                    .font(.system(size: 30, weight: .semibold))
            }
            .padding(.top, 2)
            RollingText(String(format: String(localized: "popover.energy.range"), range.low.text, range.high.text))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let local = energy.local {
                EnergyBreakdown(server: energy.server.mid, local: local, settings: settings)
                    .padding(.top, 4)
            }
            // Live level when connected; otherwise the latest published day, labeled as such.
            if let status = model.mainGridStatus, model.gridConfigured || status.recentLevel != nil {
                GridLine(status: status).padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Server and local parts of the displayed energy.
struct EnergyBreakdown: View {
    let server: Double
    let local: Double
    let settings: AppSettings

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Circle().fill(Palette.energy).frame(width: 7, height: 7)
                Text("energy.part.server")
                RollingText(String(format: String(localized: "popover.energy.value"), settings.formatEnergy(server).text))
                    .gridColumnAlignment(.trailing)
            }
            GridRow {
                Circle().fill(Palette.local).frame(width: 7, height: 7)
                Text("energy.part.local")
                RollingText(String(format: String(localized: "energy.part.local.value"), settings.formatEnergy(local).text))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct TokenSection: View {
    let tokens: Snapshot.Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(icon: Icons.coins, color: Palette.tokens, title: "popover.tokens") {
                RollingText(ValueFormatting.tokens(tokens.total))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("popover.tokens.input")
                    RollingText(ValueFormatting.tokens(tokens.input)).gridColumnAlignment(.trailing)
                    Text("popover.tokens.output")
                    RollingText(ValueFormatting.tokens(tokens.output)).gridColumnAlignment(.trailing)
                }
                GridRow {
                    Text("popover.tokens.cacheWrite")
                    RollingText(ValueFormatting.tokens(tokens.cacheWrite))
                    Text("popover.tokens.cacheRead")
                    RollingText(ValueFormatting.tokens(tokens.cacheRead))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, IconBadge.defaultSize + 8)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CarbonSection: View {
    let grams: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(icon: Icons.cloud, color: Palette.carbon, title: "popover.carbon") {
                RollingText(String(format: String(localized: "popover.carbon.value"), ValueFormatting.carbon(grams: grams).text, Units.co2e))
            }
            Text("popover.carbon.basis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, IconBadge.defaultSize + 8)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EquivalentSection: View {
    let energyWh: Double
    let items: [EquivalentItem]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: EquivalentText.rotationInterval)) { timeline in
            let seed = EquivalentText.rotationSeed(timeline.date)
            rows(EquivalentSelector.rotating(energyWh: energyWh, items: items, limit: 2, seed: seed))
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: seed)
        }
    }

    @ViewBuilder
    private func rows(_ matches: [EquivalentMatch]) -> some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(matches, id: \.item.id) { match in
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(EquivalentText.kind(match.item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(EquivalentText.name(match.item))
                        }
                        Spacer()
                        Text(EquivalentText.amount(match))
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.leading, IconBadge.defaultSize + 8)
        }
    }
}

private struct SourceSection: View {
    let today: Snapshot.Today
    let settings: AppSettings
    let sources: [UsageSource]

    private struct Row: Identifiable {
        var id: String
        var name: String
        var wh: Double
        var color: Color
    }

    var body: some View {
        let rows = sources.map { source in
            Row(id: source.rawValue, name: SourceText.name(source), wh: today.energyWhMid(for: source), color: Palette.source(source))
        }
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: Icons.terminalWindow, color: Palette.neutral, title: "popover.bySource")
            let maxWh = max(rows.map(\.wh).max() ?? 0, 0.000_001)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name)
                            .font(.callout)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.15))
                                Capsule()
                                    .fill(row.color)
                                    .frame(width: max(3, proxy.size.width * row.wh / maxWh))
                            }
                        }
                        .frame(height: 5)
                        RollingText(settings.formatEnergy(row.wh).text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.name) \(settings.formatEnergy(row.wh).text)")
                }
            }
        }
    }
}

private struct EmptyState: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(icon: Icons.lightning, color: Palette.energy, title: "popover.today.energy")
            Text(model.isBackfilling ? "popover.loading" : "empty.today")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Footer: View {
    let openDashboard: (DashboardSection?) -> Void
    let quit: () -> Void

    var body: some View {
        HStack {
            Button {
                openDashboard(.overview)
            } label: {
                Label { Text("popover.openDashboard") } icon: { SymbolIcon(Icons.gauge, size: 14) }
            }
            Spacer()
            Button {
                openDashboard(.general)
            } label: {
                SymbolIcon(Icons.gearSix)
            }
            .buttonStyle(.borderless)
            .help(Text("popover.settings"))
            .accessibilityLabel(Text("popover.settings"))
            Button(action: quit) {
                SymbolIcon(Icons.power)
            }
            .buttonStyle(.borderless)
            .help(String(format: String(localized: "menu.quit"), AppIdentity.displayName))
            .accessibilityLabel(String(format: String(localized: "menu.quit"), AppIdentity.displayName))
        }
    }
}

/// Localized names for usage sources.
enum SourceText {
    static func name(_ source: UsageSource) -> String {
        switch source {
        case .claudeCode: String(localized: "source.claudeCode")
        case .codex: String(localized: "source.codex")
        case .antigravity: String(localized: "source.antigravity")
        }
    }
}

/// Localized text for everyday comparisons (SPEC 9.6).
enum EquivalentText {
    // Keys are built at runtime, so they are looked up directly instead of through a string literal,
    // which would turn the interpolation into a format key.
    static func name(_ item: EquivalentItem) -> String {
        Bundle.main.localizedString(forKey: "equivalent.\(item.id).name", value: item.id, table: nil)
    }

    static func kind(_ item: EquivalentItem) -> String {
        switch item.kind {
        case .appliance: String(localized: "equivalent.kind.appliance")
        case .food: String(localized: "equivalent.kind.food")
        case .digital: String(localized: "equivalent.kind.digital")
        case .household: String(localized: "equivalent.kind.household")
        }
    }

    /// Seconds between rotations of the comparisons shown.
    static let rotationInterval: TimeInterval = 8

    static func rotationSeed(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 / rotationInterval))
    }

    static func unit(_ item: EquivalentItem) -> String {
        Bundle.main.localizedString(forKey: "equivalent.\(item.id).unit", value: "", table: nil)
    }

    static func amount(_ match: EquivalentMatch) -> String {
        switch match.amount {
        case .count(let count):
            let number = count >= 10
                ? count.formatted(.number.precision(.fractionLength(0)))
                : count.formatted(.number.precision(.fractionLength(1)))
            return String(format: String(localized: "equivalent.amount"), number, unit(match.item))
        case .duration(let seconds):
            let duration = Duration.seconds(max(1, seconds.rounded()))
            let text = duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
            return String(format: String(localized: "equivalent.amount.duration"), text)
        case .fraction(let denominator):
            return String(format: String(localized: "equivalent.amount.fraction"), denominator, unit(match.item))
        case .lessThanHundredth:
            return String(format: String(localized: "equivalent.amount.tiny"), unit(match.item))
        }
    }
}
