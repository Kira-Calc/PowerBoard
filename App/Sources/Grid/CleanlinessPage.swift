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
        .storeQuery(context.model, id: AnyHashable(context.model.snapshot?.generatedAt)) { [window = context.settings.dayWindow] store in
            let day = window.interval(now: Date())
            return try store.energyByGridLevel(from: day.start, to: day.end)
        } assign: { byLevel = $0 }
    }

    private func providerCard(_ provider: GridProvider, status: GridStatus) -> some View {
        let candidates = table?.candidates(for: provider) ?? []
        return Card {
            HStack(spacing: 10) {
                GridDot(level: status.level ?? status.recentLevel, certainty: status.certainty, size: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: GridText.provider(provider)).font(.headline)
                        InfoTip(GridTips.level)
                    }
                    if status.level == nil && status.recentLevel == nil {
                        Text(status.source == .static ? String(localized: "grid.staticOnly") : GridText.summary(status))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let level = status.level {
                    Text(GridText.level(level))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(GridText.color(level))
                } else if let level = status.recentLevel {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(GridText.level(level))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(GridText.color(level))
                        Text("grid.recentLevel.tag").font(.caption).foregroundStyle(.secondary)
                    }
                    .help(GridText.recentHelp(status))
                }
            }
            if let share = status.recentCleanShare, let end = status.recentMixEnd {
                Text(String(format: String(localized: "grid.recent.summary"),
                            String(format: "%.0f%%", share * 100), end.formatted(date: .abbreviated, time: .shortened)))
                    .font(.callout)
            }
            // One line per location; a narrow window scrolls the table sideways instead of breaking names.
            ScrollView(.horizontal) {
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
                            Text(verbatim: GridText.candidateName(candidate)).lineLimit(1)
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
                        HStack(spacing: 5) {
                            Text(verbatim: reading?.recentMix.map { String(format: "%.0f%%", $0.cleanShare * 100) } ?? "–")
                            if let percentile = reading?.recentMix?.percentile {
                                Text(verbatim: "\(Int(percentile.rounded()))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .monospacedDigit()
                            .help(reading?.recentMix.map { "EIA \($0.balancingAuthority)" } ?? "")
                    }
                    .font(.callout)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var todayByLevel: some View {
        Card {
            CardHeader(icon: Icons.lightning, color: Palette.energy, title: LocalizedStringKey(context.settings.dayKey("grid.today")), tips: GridTips.today)
            if byLevel.isEmpty {
                Text(LocalizedStringKey(context.settings.dayKey("empty.today"))).foregroundStyle(.secondary)
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
    @State private var creating = false
    @State private var emapsKey = ""
    @State private var notice: Notice?
    @State private var busy = false

    /// A message shown at the top of the WattTime section, where it is seen right after pressing a button.
    struct Notice: Equatable {
        enum Kind { case error, info }
        var kind: Kind
        var text: String
    }

    var body: some View {
        @Bindable var settings = grid.settings
        Card {
            CardHeader(icon: Icons.leaf, color: Palette.clean, title: "grid.sources", tips: GridTips.sources)
            Form {
                Section {
                    if let notice {
                        NoticeRow(notice: notice)
                    } else if let error = model.gridError, settings.watttimeUsername != nil {
                        NoticeRow(notice: Notice(kind: .error, text: Self.errorText(error)))
                    }
                    if let user = settings.watttimeUsername {
                        LabeledContent("grid.watttime.signedIn") {
                            HStack {
                                Text(verbatim: user)
                                Button("grid.watttime.signOut") {
                                    settings.signOut()
                                    notice = nil
                                    grid.reconfigure()
                                }
                            }
                        }
                    } else if let pending = settings.pendingUsername {
                        pendingRows(username: pending, email: settings.pendingEmail ?? "")
                    } else {
                        accountForm
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
        }
    }

    // MARK: Sign in or create

    @ViewBuilder
    private var accountForm: some View {
        Picker("", selection: $creating) {
            Text("grid.watttime.signIn").tag(false)
            Text("grid.watttime.create").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: creating) { notice = nil }
        TextField("grid.watttime.username", text: $username)
        SecureField("grid.watttime.password", text: $password)
        if creating {
            PasswordRulesRow(password: password)
            TextField("grid.watttime.email", text: $email)
            if !email.isEmpty && !WattTimeAccountRules.isPlausibleEmail(email) {
                Text("grid.watttime.emailInvalid").font(.caption).foregroundStyle(.orange)
            }
        }
        HStack {
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(creating ? "grid.watttime.createButton" : "grid.watttime.signInButton") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        guard !busy, !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return false }
        return !creating || (WattTimeAccountRules.isValidPassword(password) && WattTimeAccountRules.isPlausibleEmail(email))
    }

    // MARK: Waiting for email verification

    @ViewBuilder
    private func pendingRows(username: String, email: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolIcon(Icons.mail, size: 16).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("grid.watttime.pending.title").font(.headline)
                Text(String(format: String(localized: "grid.watttime.pending.body"), email))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledContent("grid.watttime.username") { Text(verbatim: username) }
        HStack {
            Button("grid.watttime.pending.cancel", role: .destructive) {
                grid.settings.cancelPending()
                grid.startVerificationPolling()
                notice = nil
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("grid.watttime.pending.check") {
                busy = true
                notice = nil
                Task {
                    if await !grid.checkPendingNow() {
                        notice = Notice(kind: .info, text: String(localized: "grid.watttime.pending.notYet"))
                    }
                    busy = false
                }
            }
            .disabled(busy)
        }
    }

    private func submit() {
        busy = true
        notice = nil
        let creating = self.creating
        let username = self.username.trimmingCharacters(in: .whitespaces)
        let (password, email) = (self.password, self.email.trimmingCharacters(in: .whitespaces))
        Task {
            defer { busy = false }
            do {
                if creating {
                    try await WattTimeClient.register(username: username, password: password, email: email,
                                                      organization: WattTimeAccountRules.defaultOrganization)
                    // WattTime sends a verification email and refuses sign-in until the link is opened.
                    // Try once in case the account is usable at once; otherwise wait for verification.
                    if (try? await WattTimeClient(credentials: WattTimeCredentials(username: username, password: password)).login()) != nil {
                        try grid.settings.signIn(username: username, password: password)
                    } else {
                        try grid.settings.savePending(username: username, password: password, email: email)
                        grid.startVerificationPolling()
                    }
                } else {
                    // Check the credentials before saving them.
                    _ = try await WattTimeClient(credentials: WattTimeCredentials(username: username, password: password)).login()
                    try grid.settings.signIn(username: username, password: password)
                }
                self.password = ""
                grid.reconfigure()
            } catch let error as GridAPIError {
                notice = Notice(kind: .error, text: creating ? Self.registerErrorText(error) : Self.errorText(error))
            } catch {
                notice = Notice(kind: .error, text: String(format: String(localized: "grid.error.network"), error.localizedDescription))
            }
        }
    }

    /// Turns WattTime's English sign-up errors into the app's language; unknown ones are shown as sent.
    static func registerErrorText(_ error: GridAPIError) -> String {
        guard case .http(_, let text?) = error else { return errorText(error) }
        let lower = text.lowercased()
        if lower.contains("password must") { return String(localized: "grid.error.passwordRules") }
        if lower.contains("email is invalid") { return String(localized: "grid.watttime.emailInvalid") }
        if lower.contains("username") && (lower.contains("taken") || lower.contains("exist") || lower.contains("already")) {
            return String(localized: "grid.error.usernameTaken")
        }
        if lower.contains("email") && (lower.contains("exist") || lower.contains("already") || lower.contains("use")) {
            return String(localized: "grid.error.emailTaken")
        }
        return String(format: String(localized: "grid.error.service"), text)
    }

    static func errorText(_ error: GridAPIError) -> String {
        switch error {
        case .unauthorized: String(localized: "grid.error.unauthorized")
        case .http(_, let text?): String(format: String(localized: "grid.error.service"), text)
        default: String(localized: "grid.error.unavailable")
        }
    }
}

/// A message at the top of a form section: orange with a warning sign for errors, blue for information.
private struct NoticeRow: View {
    let notice: GridSourcesCard.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SymbolIcon(notice.kind == .error ? Icons.warning : Icons.info, size: 14)
                .foregroundStyle(notice.kind == .error ? Color.orange : Color.blue)
            Text(verbatim: notice.text)
                .foregroundStyle(notice.kind == .error ? Color.orange : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// WattTime's password rules, ticked off while typing.
private struct PasswordRulesRow: View {
    let password: String

    var body: some View {
        HStack(spacing: 14) {
            ForEach(WattTimeAccountRules.PasswordRule.allCases, id: \.self) { rule in
                let ok = WattTimeAccountRules.passes(rule, password)
                HStack(spacing: 4) {
                    SymbolIcon(ok ? Icons.checkmark : Icons.circle, size: 11)
                        .foregroundStyle(ok ? Palette.clean : Color.secondary)
                    Text(Self.label(rule))
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(ok ? "grid.watttime.rule.met" : "grid.watttime.rule.notMet"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func label(_ rule: WattTimeAccountRules.PasswordRule) -> LocalizedStringKey {
        switch rule {
        case .length: "grid.watttime.rule.length"
        case .letter: "grid.watttime.rule.letter"
        case .number: "grid.watttime.rule.number"
        case .special: "grid.watttime.rule.special"
        }
    }
}
