import ElectricityCore
import SwiftUI

/// Grid cleanliness: current level per provider, candidate locations, today's energy by level, and data sources (SPEC 9.4, 10).
struct CleanlinessPage: View {
    let context: DashboardContext
    @State private var byLevel: [GridLevel?: Double] = [:]

    private var table: GridRegionTable? { try? GridRegionTable.bundled() }

    var body: some View {
        PageContainer {
            if !context.model.gridConfigured {
                Card {
                    CardHeader(icon: Icons.leaf, color: Palette.clean, title: "grid.notConnected.title")
                    Text("grid.notConnected.body").fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(GridProvider.allCases, id: \.self) { provider in
                providerCard(provider, status: context.model.gridStatuses[provider] ?? .unknown(provider))
            }
            todayByLevel
            GridSourcesCard(grid: context.grid, model: context.model)
        }
        .storeQuery(context.model, id: AnyHashable(context.model.snapshot?.generatedAt)) { store in
            let day = LocalPeriod.day.interval(containing: Date())
            return try store.energyByGridLevel(from: day.start, to: day.end)
        } assign: { byLevel = $0 }
    }

    private func providerCard(_ provider: GridProvider, status: GridStatus) -> some View {
        let candidates = table?.candidates(for: provider) ?? []
        return Card {
            HStack(spacing: 10) {
                GridDot(level: status.level, certainty: status.certainty, size: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: GridText.provider(provider)).font(.headline)
                        InfoTip(GridTips.level)
                    }
                    if status.level == nil {
                        Text(status.source == .static ? String(localized: "grid.staticOnly") : GridText.summary(status))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let level = status.level {
                    Text(GridText.level(level))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(GridText.color(level))
                }
            }
            if let share = status.recentCleanShare, let end = status.recentMixEnd {
                Text(String(format: String(localized: "grid.recent.summary"),
                            String(format: "%.0f%%", share * 100), end.formatted(date: .abbreviated, time: .shortened)))
                    .font(.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("grid.column.location")
                    Text("grid.column.weight").gridColumnAlignment(.trailing)
                    Text("grid.column.level")
                    Text(verbatim: Units.gramsPerKWh).gridColumnAlignment(.trailing)
                    Text("grid.column.clean").gridColumnAlignment(.trailing)
                    Text("grid.column.recent").gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    let reading = status.candidates.first { $0.candidateID == candidate.id }
                    let level = status.candidateLevels[candidate.id]
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: GridText.candidateName(candidate))
                            if let region = reading?.region {
                                Text(verbatim: region).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .help(candidate.note)
                        Text(verbatim: "\(Int((candidate.weight * 100).rounded()))%").monospacedDigit()
                        HStack(spacing: 5) {
                            GridDot(level: level, certainty: .estimated, size: 7)
                            Text(level.map(GridText.level) ?? "–")
                            if let percentile = reading?.percentile {
                                Text(verbatim: "\(Int(percentile.rounded()))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text(verbatim: reading?.gramsPerKWh.map { String(format: "%.0f", $0) } ?? "–").monospacedDigit()
                        Text(verbatim: reading?.cleanShare.map { String(format: "%.0f%%", $0 * 100) } ?? "–").monospacedDigit()
                        Text(verbatim: reading?.recentMix.map { String(format: "%.0f%%", $0.cleanShare * 100) } ?? "–")
                            .monospacedDigit()
                            .help(reading?.recentMix.map { "EIA \($0.balancingAuthority)" } ?? "")
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var todayByLevel: some View {
        Card {
            CardHeader(icon: Icons.lightning, color: Palette.energy, title: "grid.today", tips: GridTips.today)
            if byLevel.isEmpty {
                Text("empty.today").foregroundStyle(.secondary)
            } else {
                GridLevelBar(byLevel: byLevel, settings: context.settings)
            }
        }
    }
}

/// WattTime account (sign in or create), optional Electricity Maps key, and level thresholds.
struct GridSourcesCard: View {
    let grid: GridCoordinator
    let model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var organization = ""
    @State private var creating = false
    @State private var emapsKey = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        @Bindable var settings = grid.settings
        Card {
            CardHeader(icon: Icons.leaf, color: Palette.clean, title: "grid.sources", tips: GridTips.sources)
            Form {
                Section {
                    if let user = settings.watttimeUsername {
                        LabeledContent("grid.watttime.signedIn") {
                            HStack {
                                Text(verbatim: user)
                                Button("grid.watttime.signOut") {
                                    settings.signOut()
                                    grid.reconfigure()
                                }
                            }
                        }
                    } else {
                        Picker("", selection: $creating) {
                            Text("grid.watttime.signIn").tag(false)
                            Text("grid.watttime.create").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        TextField("grid.watttime.username", text: $username)
                        SecureField("grid.watttime.password", text: $password)
                        if creating {
                            TextField("grid.watttime.email", text: $email)
                            TextField("grid.watttime.organization", text: $organization)
                        }
                        HStack {
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Button(creating ? "grid.watttime.createButton" : "grid.watttime.signInButton") { submit() }
                                .disabled(busy || username.isEmpty || password.isEmpty || (creating && (email.isEmpty || organization.isEmpty)))
                        }
                    }
                } header: {
                    Text(verbatim: "WattTime")
                }
                Section {
                    if settings.hasElectricityMapsKey {
                        LabeledContent("grid.emaps.key") {
                            Button("grid.emaps.remove") {
                                try? settings.setElectricityMapsKey(nil)
                                grid.reconfigure()
                            }
                        }
                    } else {
                        HStack {
                            SecureField("grid.emaps.key", text: $emapsKey)
                            Button("grid.emaps.save") {
                                try? settings.setElectricityMapsKey(emapsKey.trimmingCharacters(in: .whitespaces))
                                emapsKey = ""
                                grid.reconfigure()
                            }
                            .disabled(emapsKey.isEmpty)
                        }
                    }
                } header: {
                    Text("grid.emaps.title")
                }
                Section("grid.thresholds") {
                    LabeledContent("grid.thresholds.cleaner") {
                        Stepper(value: $settings.cleanerBelow, in: 5...95, step: 5) {
                            Text(verbatim: "< \(Int(settings.cleanerBelow.rounded()))").monospacedDigit()
                        }
                    }
                    LabeledContent("grid.thresholds.lessClean") {
                        Stepper(value: $settings.lessCleanAbove, in: 5...95, step: 5) {
                            Text(verbatim: "> \(Int(settings.lessCleanAbove.rounded()))").monospacedDigit()
                        }
                    }
                }
                .onChange(of: settings.cleanerBelow) { grid.reconfigure() }
                .onChange(of: settings.lessCleanAbove) { grid.reconfigure() }
            }
            .formStyle(.grouped)
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            } else if let error = model.gridError, settings.watttimeUsername != nil {
                Text(errorText(error)).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func submit() {
        busy = true
        message = nil
        let creating = self.creating
        let (username, password, email, organization) = (self.username, self.password, self.email, self.organization)
        Task {
            do {
                if creating {
                    try await WattTimeClient.register(username: username, password: password, email: email, organization: organization)
                }
                // Check the credentials before saving them.
                _ = try await WattTimeClient(credentials: WattTimeCredentials(username: username, password: password)).login()
                try grid.settings.signIn(username: username, password: password)
                self.password = ""
                grid.reconfigure()
            } catch let error as GridAPIError {
                message = errorText(error)
            } catch {
                message = String(format: String(localized: "grid.error.network"), error.localizedDescription)
            }
            busy = false
        }
    }

    private func errorText(_ error: GridAPIError) -> String {
        switch error {
        case .unauthorized: String(localized: "grid.error.unauthorized")
        case .http(_, let text?): String(format: String(localized: "grid.error.service"), text)
        default: String(localized: "grid.error.unavailable")
        }
    }
}
