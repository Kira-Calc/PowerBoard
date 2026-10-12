import AppKit
import ElectricityCore
import SwiftUI

/// Summary of the calculation method, built from the bundled factor files (SPEC 9.5, "About").
/// The full METHODOLOGY.md is bundled and opens in the default Markdown viewer.
struct MethodologyPage: View {
    let context: DashboardContext

    var body: some View {
        PageContainer {
            HStack {
                Spacer()
                Button("methodology.openFull") {
                    if let url = Bundle.main.url(forResource: "METHODOLOGY", withExtension: "md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Link("methodology.openOnline", destination: URL(string: AppIdentity.methodologyURL)!)
            }
            Card {
                CardHeader(icon: Icons.bookOpen, color: Palette.neutral, title: "methodology.what")
                Text("methodology.what.body").fixedSize(horizontal: false, vertical: true)
                Text("methodology.notCovered").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                CardHeader(icon: Icons.function, color: Palette.neutral, title: "methodology.formula")
                Text("info.energy.formula").font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true)
                Text("info.carbon.formula").font(.callout.monospaced())
                Text(String(format: String(localized: "info.energy.cacheRatios"),
                            Formatting.ratio(context.settings.cacheWriteRatio), Formatting.ratio(context.settings.cacheReadRatio)))
            }
            if let factors = context.model.factors {
                Card {
                    CardHeader(icon: Icons.table, color: Palette.neutral, title: "methodology.factors")
                    FactorTable(factors: factors)
                    Text(String(format: String(localized: "info.energy.range"),
                                Formatting.ratio(factors.uncertainty.low), Formatting.ratio(factors.uncertainty.high)))
                    Text("methodology.rangeAssumption").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(String(format: String(localized: "info.factors.version"), factors.version)).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: factors.source).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Card {
                CardHeader(icon: Icons.leaf, color: Palette.clean, title: "methodology.grid")
                ForEach(Array((GridTips.level + GridTips.today).enumerated()), id: \.offset) { _, key in
                    Text(key).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let table = context.model.tierTable {
                Card {
                    CardHeader(icon: Icons.terminalWindow, color: .gray, title: "methodology.tiers")
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("methodology.tiers.match")
                            Text("factors.tier")
                            Text("column.confidence")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(table.rules, id: \.match) { rule in
                            GridRow {
                                Text(verbatim: rule.match).font(.callout.monospaced())
                                Text(Formatting.tierName(rule.tier))
                                Text(Formatting.confidence(rule.confidence))
                            }
                        }
                        GridRow {
                            Text("methodology.tiers.other")
                            Text(Formatting.tierName(table.fallback.tier))
                            Text(Formatting.confidence(table.fallback.confidence))
                        }
                    }
                }
            }
        }
    }
}

/// Version, license and third-party notices (SPEC 9.5).
struct AboutPage: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppIdentity.version
    }

    var body: some View {
        PageContainer {
            Card {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: AppIdentity.displayName).font(.title2.weight(.semibold))
                        Text(String(format: String(localized: AppIdentity.isBeta ? "about.version.beta" : "about.version"), version)).foregroundStyle(.secondary)
                    }
                }
                Text("about.license").fixedSize(horizontal: false, vertical: true)
                Text("about.notTracked").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("about.privacy").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                CardHeader(icon: Icons.bookOpen, color: .gray, title: "about.notices")
                Text(verbatim: notices)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
