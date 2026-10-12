import ElectricityCore
import SwiftUI

/// Grid cleanliness summary for the overview page: each provider's level now and today's energy by level.
struct GridOverviewCard: View {
    let context: DashboardContext
    let byLevel: [GridLevel?: Double]
    let openDetails: () -> Void

    var body: some View {
        Card {
            HStack {
                CardHeader(icon: Icons.leaf, color: Palette.clean, title: "grid.overview.title", tips: GridTips.level + GridTips.today)
                Button("grid.overview.details", action: openDetails)
                    .buttonStyle(.link)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(context.model.usedProviders, id: \.self) { provider in
                    row(context.model.gridStatuses[provider] ?? .unknown(provider))
                }
            }
            if !byLevel.isEmpty {
                Divider()
                GridLevelBar(byLevel: byLevel, settings: context.settings, compact: true)
            }
        }
    }

    private func row(_ status: GridStatus) -> some View {
        GridRow {
            HStack(spacing: 8) {
                GridDot(level: status.level ?? status.recentLevel, certainty: status.certainty, size: 10)
                Text(verbatim: GridText.provider(status.provider)).font(.body.weight(.medium))
            }
            if let level = status.level {
                RollingText(GridText.level(level))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GridText.color(level))
                    .help(status.percentile.map { String(format: String(localized: "grid.overview.percentile"), Int($0.rounded())) } ?? "")
            } else if let level = status.recentLevel {
                // No live data: the latest published day compared with the 30 days before it (EIA).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(GridText.level(level))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GridText.color(level))
                    Text(String(format: String(localized: "grid.overview.recentDetail"),
                                status.recentCleanShare.map { String(format: "%.0f%%", $0 * 100) } ?? "–"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(GridText.recentHelp(status))
            } else if let share = status.recentCleanShare {
                Text(String(format: String(localized: "grid.overview.recent"), String(format: "%.0f%%", share * 100)))
                    .foregroundStyle(.secondary)
                    .help(status.recentMixEnd.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
            } else {
                Text(context.model.gridLoading ? String(localized: "grid.loading") : GridText.level(nil)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: GridText.timeLabel(status))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Today's energy split by the grid level recorded with each record.
struct GridLevelBar: View {
    let byLevel: [GridLevel?: Double]
    let settings: AppSettings
    var compact = false

    private let levels: [GridLevel?] = [.cleaner, .typical, .lessClean, nil]

    var body: some View {
        let total = max(byLevel.values.reduce(0, +), 0.000_001)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(levels, id: \.self) { level in
                        let wh = byLevel[level] ?? 0
                        if wh > 0 {
                            Rectangle()
                                .fill(level == nil ? Color.secondary.opacity(0.25) : GridText.color(level))
                                .frame(width: max(2, proxy.size.width * wh / total))
                        }
                    }
                }
                .clipShape(Capsule())
                .animation(.smooth, value: byLevel.values.reduce(0, +))
            }
            .frame(height: compact ? 8 : 10)
            HStack(spacing: 16) {
                ForEach(levels, id: \.self) { level in
                    HStack(spacing: 5) {
                        if level == nil {
                            Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
                        } else {
                            Circle().fill(GridText.color(level)).frame(width: 8, height: 8)
                        }
                        Text(level == nil ? String(localized: "grid.today.noLevel") : GridText.level(level))
                        RollingText(settings.formatEnergy(byLevel[level] ?? 0).text).foregroundStyle(.secondary)
                    }
                    .font(compact ? .caption : .callout)
                }
            }
        }
    }
}
