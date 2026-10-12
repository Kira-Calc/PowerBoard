import Charts
import ElectricityCore
import SwiftUI

/// Live overview of today's usage (SPEC 9.1).
struct OverviewPage: View {
    let context: DashboardContext
    var openSection: (DashboardSection) -> Void = { _ in }
    @State private var byLevel: [GridLevel?: Double] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sessions: [SessionSummary] = []

    var body: some View {
        let settings = context.settings
        PageContainer {
            if let today = context.model.snapshot?.today, today.energyWh.mid > 0 {
                // Equal-height cards: the row takes the height of its tallest card.
                HStack(alignment: .top, spacing: 16) {
                    energyCard(today, settings: settings)
                    carbonCard(today)
                }
                .fixedSize(horizontal: false, vertical: true)
                Card {
                    CardHeader(icon: Icons.terminalWindow, color: .blue, title: "sessions.title")
                    if context.model.activeSessions.isEmpty {
                        Text("sessions.empty").foregroundStyle(.secondary)
                    } else {
                        ActiveSessionsList(sessions: context.model.activeSessions, settings: context.settings)
                            .padding(.horizontal, -8)
                    }
                }
                GridOverviewCard(context: context, byLevel: byLevel) { openSection(.cleanliness) }
                UsageChartCard(context: context)
                tokenCard(today.tokens)
                equivalents(today.energyWh.mid)
                recentSessions
            } else {
                Card {
                    CardHeader(icon: Icons.lightning, color: Palette.energy, title: "popover.today.energy")
                    Text(context.model.isBackfilling ? "popover.loading" : "empty.today")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .storeQuery(context.model, id: AnyHashable(context.model.snapshot?.generatedAt)) { store in
            let day = LocalPeriod.day.interval(containing: Date())
            return (try store.sessions(activeSince: Date().addingTimeInterval(-24 * 3600), limit: 8),
                    try store.energyByGridLevel(from: day.start, to: day.end))
        } assign: { recent, levels in
            sessions = recent
            withAnimation(.smooth) { byLevel = levels }
        }
    }

    private func bigValue(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("popover.about")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            RollingText(text)
                .font(.system(size: 36, weight: .semibold))
        }
    }

    private func energyCard(_ today: Snapshot.Today, settings: AppSettings) -> some View {
        let energy = settings.displayedEnergy(today)
        let range = settings.formatEnergy(energy.total)
        return Card {
            CardHeader(icon: Icons.lightning, color: Palette.energy,
                       title: energy.includesLocal ? "popover.today.energyWithLocal" : "popover.today.energy",
                       info: .energy, context: context, serverTag: !energy.includesLocal)
            bigValue(range.mid.text)
            RollingText(String(format: String(localized: "popover.energy.range"), range.low.text, range.high.text))
                .foregroundStyle(.secondary)
            if let local = energy.local {
                EnergyBreakdown(server: energy.server.mid, local: local, settings: settings)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private func carbonCard(_ today: Snapshot.Today) -> some View {
        Card {
            CardHeader(icon: Icons.cloud, color: Palette.carbon, title: "popover.carbon", info: .carbon, context: context)
            bigValue("\(ValueFormatting.carbon(grams: today.co2G).text) \(Units.co2e)")
            Text(String(format: String(localized: "overview.carbon.basis"), Formatting.number(context.settings.gridGramsPerKWh, decimals: 0), Units.gramsPerKWh))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private func tokenCard(_ tokens: Snapshot.Tokens) -> some View {
        Card {
            CardHeader(icon: Icons.coins, color: Palette.tokens, title: "popover.tokens", info: .tokens, context: context)
            HStack(alignment: .top, spacing: 0) {
                tokenValue("popover.tokens.input", tokens.input)
                tokenValue("popover.tokens.output", tokens.output)
                tokenValue("popover.tokens.cacheWrite", tokens.cacheWrite)
                tokenValue("popover.tokens.cacheRead", tokens.cacheRead)
            }
        }
    }

    private func tokenValue(_ title: LocalizedStringKey, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            RollingText(ValueFormatting.tokens(value))
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func equivalents(_ energyWh: Double) -> some View {
        TimelineView(.periodic(from: .now, by: EquivalentText.rotationInterval)) { timeline in
            let seed = EquivalentText.rotationSeed(timeline.date)
            let items = context.settings.enabledEquivalents(from: context.model.equivalents)
            equivalentCard(EquivalentSelector.rotating(energyWh: energyWh, items: items, limit: 3, seed: seed))
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: seed)
        }
    }

    @ViewBuilder
    private func equivalentCard(_ matches: [EquivalentMatch]) -> some View {
        if !matches.isEmpty {
            Card {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.item.id) { index, match in
                        if index > 0 {
                            Divider().padding(.horizontal, 16)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(EquivalentText.kind(match.item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(EquivalentText.amount(match))
                                .font(.title2.weight(.semibold))
                                .monospacedDigit()
                            Text(EquivalentText.name(match.item))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                        .accessibilityElement(children: .combine)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recentSessions: some View {
        Card {
            CardHeader(icon: Icons.terminalWindow, color: Palette.neutral, title: "overview.sessions")
            if sessions.isEmpty {
                Text("overview.sessions.empty").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("column.tool")
                        Text("column.project")
                        Text("column.model")
                        Text("column.lastActive")
                        Text("column.energy").gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(sessions, id: \.sessionID) { session in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(Palette.source(session.source)).frame(width: 8, height: 8)
                                Text(SourceText.name(session.source))
                            }
                            Text(Formatting.projectName(session.projectPath))
                                .help(session.projectPath ?? "")
                            Text(verbatim: session.model).foregroundStyle(.secondary)
                            Text(Formatting.time(session.lastTimestamp)).foregroundStyle(.secondary).monospacedDigit()
                            RollingText(context.settings.formatEnergy(session.energyWhMid).text)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
