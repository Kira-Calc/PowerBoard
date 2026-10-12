import AppKit
import ElectricityCore
import ServiceManagement
import SwiftUI

// MARK: General

struct GeneralSettingsPage: View {
    let context: DashboardContext
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var settings = context.settings
        Form {
            Section {
                Toggle("general.launchAtLogin", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Toggle(isOn: $settings.includeLocalEnergy) {
                    HStack(spacing: 6) {
                        Text("general.localEnergy")
                        InfoTip(["general.localEnergy.note"])
                    }
                }
                .disabled(!context.model.localPowerAvailable && !settings.includeLocalEnergy)
                .onChange(of: settings.includeLocalEnergy) { context.coordinator.applyLocalEnergySetting() }
                if !context.model.localPowerAvailable {
                    Text("general.localEnergy.unavailable").font(.caption).foregroundStyle(.orange)
                } else if let watts = context.model.localWatts {
                    LabeledContent("general.localEnergy.now") {
                        RollingText(String(format: "%.1f W", watts))
                    }
                }
            }
            Section {
                Picker("general.appLanguage", selection: $settings.appLanguage) {
                    Text("general.language.system").tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                if settings.appLanguage != settings.appLanguageAtLaunch {
                    HStack {
                        Text("general.language.restartNote").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("general.language.restart") { Relauncher.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = String(format: String(localized: "general.launchAtLogin.error"), error.localizedDescription)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

enum Relauncher {
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        // Quit first so the new instance owns the status items and the database.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

// MARK: Data sources

struct SourcesSettingsPage: View {
    let context: DashboardContext
    @State private var confirmClear = false
    @State private var showUnused = false

    var body: some View {
        @Bindable var settings = context.settings
        Form {
            ForEach(context.model.usedSources, id: \.self) { source in
                sourceSection(source)
            }
            // Tools without records stay reachable here, so a log folder in a custom place can still be added.
            let unused = UsageSource.allCases.filter { !context.model.usedSources.contains($0) }
            if !unused.isEmpty {
                Section {
                    Toggle("sources.otherTools", isOn: $showUnused)
                }
                if showUnused {
                    ForEach(unused, id: \.self) { source in
                        sourceSection(source)
                    }
                }
            }
            Section {
                HStack {
                    Text("sources.notTracked").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        context.coordinator.rescan()
                    } label: {
                        Label { Text("sources.rescan") } icon: { SymbolIcon(Icons.arrowsClockwise, size: 14) }
                    }
                }
            }
            Section("sources.data") {
                Picker("sources.retention", selection: $settings.retention) {
                    Text("sources.retention.forever").tag(DataRetention.forever)
                    Text("sources.retention.twoYears").tag(DataRetention.twoYears)
                    Text("sources.retention.oneYear").tag(DataRetention.oneYear)
                }
                .onChange(of: settings.retention) { context.coordinator.applyRetention() }
                HStack {
                    Spacer()
                    Button("sources.clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("sources.clear.confirm.title", isPresented: $confirmClear) {
            Button("sources.clear", role: .destructive) {
                Task { await context.coordinator.clearAllData() }
            }
        } message: {
            Text("sources.clear.confirm.message")
        }
    }

    @ViewBuilder
    private func sourceSection(_ source: UsageSource) -> some View {
        let status = context.model.sourceStatuses[source]
        Section {
            LabeledContent("sources.status") {
                HStack(spacing: 6) {
                    Circle().fill(status?.isFound == true ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(status?.isFound == true ? "sources.status.ok" : "source.notFound")
                }
            }
            if status?.isFound == false {
                Text(Self.notFoundKey(source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("sources.lastRead") {
                Text(status?.lastRead.map(Formatting.dateTime) ?? String(localized: "sources.lastRead.none"))
                    .monospacedDigit()
            }
            LabeledContent("sources.records") {
                Text((status?.stats.eventCount ?? 0).formatted()).monospacedDigit()
            }
            LabeledContent("sources.files") {
                Text((status?.stats.filesTracked ?? 0).formatted()).monospacedDigit()
            }
            LabeledContent("sources.skipped") {
                Text((status?.stats.skippedLines ?? 0).formatted())
                    .monospacedDigit()
                    .foregroundStyle((status?.stats.skippedLines ?? 0) > 0 ? .orange : .primary)
            }
            DisclosureGroup("sources.paths") {
                ForEach(status?.roots ?? [], id: \.self) { root in
                    let custom = context.settings.customPaths(for: source).contains(root.path)
                    HStack {
                        Circle()
                            .fill(status?.existingRoots.contains(root) == true ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(verbatim: root.path).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        if custom {
                            Button {
                                context.settings.removeCustomPath(root.path, for: source)
                                context.coordinator.applySourcePaths()
                            } label: {
                                SymbolIcon(Icons.close, size: 12)
                            }
                            .buttonStyle(.borderless)
                            .help(Text("sources.removePath"))
                            .accessibilityLabel(Text("sources.removePath"))
                        }
                    }
                }
                Button {
                    addPath(for: source)
                } label: {
                    Label { Text("sources.addPath") } icon: { SymbolIcon(Icons.plus, size: 12) }
                }
            }
        } header: {
            HStack(spacing: 8) {
                IconBadge(Icons.terminalWindow, color: Palette.source(source), size: 20)
                Text(SourceText.name(source))
            }
        }
    }

    private static func notFoundKey(_ source: UsageSource) -> LocalizedStringKey {
        switch source {
        case .claudeCode: "sources.notFound.claudeCode"
        case .codex: "sources.notFound.codex"
        case .antigravity: "sources.notFound.antigravity"
        }
    }

    private func addPath(for source: UsageSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "sources.addPath.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        context.settings.addCustomPath(url.path, for: source)
        context.coordinator.applySourcePaths()
    }
}

// MARK: Display

struct DisplaySettingsPage: View {
    let context: DashboardContext

    var body: some View {
        @Bindable var settings = context.settings
        Form {
            Section("settings.menuBar") {
                Picker("settings.split", selection: $settings.menuBarSplit) {
                    Text("settings.split.combined").tag(MenuBarSplit.combined)
                    Text("settings.split.separate").tag(MenuBarSplit.separate)
                }
                if settings.menuBarSplit == .combined {
                    Picker("settings.combined", selection: $settings.combinedDisplay) {
                        Text("settings.item.energy").tag(CombinedDisplay.energy)
                        Text("settings.item.tokens").tag(CombinedDisplay.tokens)
                        Text("settings.combined.both").tag(CombinedDisplay.energyAndTokens)
                    }
                }
                ForEach(settings.visibleMetrics) { metric in
                    Picker(selection: Binding(
                        get: { settings.content(for: metric) },
                        set: { settings.setContent($0, for: metric) }
                    )) {
                        ForEach(MenuBarContent.options(for: metric)) { content in
                            Text(Self.contentKey(content)).tag(content)
                        }
                    } label: {
                        Text(Self.metricKey(metric))
                    }
                }
                Picker("settings.unit", selection: $settings.energyUnit) {
                    Text("settings.automatic").tag(EnergyUnit.auto)
                    Text(verbatim: "Wh").tag(EnergyUnit.wh)
                    Text(verbatim: "kWh").tag(EnergyUnit.kwh)
                }
                Picker("settings.decimals", selection: $settings.decimals) {
                    Text("settings.automatic").tag(DecimalsSetting.automatic)
                    Text(verbatim: "0").tag(DecimalsSetting.zero)
                    Text(verbatim: "1").tag(DecimalsSetting.one)
                    Text(verbatim: "2").tag(DecimalsSetting.two)
                }
            }
            TerminalStatusLineSection(settings: settings)
        }
        .formStyle(.grouped)
    }

    private static func metricKey(_ metric: MenuBarMetric) -> LocalizedStringKey {
        switch metric {
        case .energy: "settings.item.energy"
        case .tokens: "settings.item.tokens"
        case .carbon: "settings.item.carbon"
        }
    }

    private static func contentKey(_ content: MenuBarContent) -> LocalizedStringKey {
        switch content {
        case .iconOnly: "settings.content.iconOnly"
        case .iconAndValue: "settings.content.iconAndValue"
        case .valueOnly: "settings.content.valueOnly"
        case .sparkline: "settings.content.sparkline"
        }
    }
}

// MARK: Calculation method

struct MethodSettingsPage: View {
    let context: DashboardContext
    @State private var confirmRecalculate = false

    var body: some View {
        @Bindable var settings = context.settings
        Form {
            if let factors = context.model.factors {
                Section("method.factors") {
                    LabeledContent("method.factors.version") { Text(verbatim: factors.version).monospacedDigit() }
                    Text(verbatim: factors.source).font(.caption).foregroundStyle(.secondary)
                    FactorTable(factors: factors)
                }
            }
            Section {
                ratioField("method.cacheWrite", value: $settings.cacheWriteRatio)
                ratioField("method.cacheRead", value: $settings.cacheReadRatio)
                LabeledContent("method.grid") {
                    HStack(spacing: 6) {
                        TextField("method.grid", value: $settings.gridGramsPerKWh, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(verbatim: Units.gramsPerKWh).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("method.grid.basis") { Text("popover.carbon.basis") }
                HStack {
                    Spacer()
                    InfoTip(["method.newRecordsNote"])
                    Button("method.reset") { settings.resetCalculationDefaults() }
                }
            } header: {
                Text("method.parameters")
            }
            .onChange(of: settings.cacheWriteRatio) { context.coordinator.applyCalculationSettings() }
            .onChange(of: settings.cacheReadRatio) { context.coordinator.applyCalculationSettings() }
            .onChange(of: settings.gridGramsPerKWh) { context.coordinator.applyCalculationSettings() }
            Section {
                HStack {
                    Spacer()
                    InfoTip(["method.recalculate.note"])
                    if context.model.isRecalculating {
                        ProgressView().controlSize(.small)
                    }
                    Button("method.recalculate") { confirmRecalculate = true }
                        .disabled(context.model.isRecalculating)
                }
            }
            Section("method.equivalents") {
                ForEach(context.model.equivalents) { item in
                    Toggle(isOn: Binding(
                        get: { !settings.disabledEquivalents.contains(item.id) },
                        set: { settings.setEquivalent(item.id, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(EquivalentText.name(item))
                            Text(EquivalentText.kind(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("method.recalculate.confirm.title", isPresented: $confirmRecalculate) {
            Button("method.recalculate") {
                Task { await context.coordinator.recalculateAll() }
            }
        } message: {
            Text("method.recalculate.confirm.message")
        }
    }

    private func ratioField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(max($0, 0), 10) }
            ), format: .number.precision(.fractionLength(0...3)))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
        }
    }
}

// MARK: Notifications

struct NotificationSettingsPage: View {
    let context: DashboardContext
    @State private var authorizationDenied = false

    var body: some View {
        @Bindable var settings = context.settings
        Form {
            Section {
                Toggle("notifications.daily", isOn: $settings.dailyReportEnabled)
                DatePicker("notifications.time", selection: dailyTime, displayedComponents: .hourAndMinute)
                    .disabled(!settings.dailyReportEnabled && !settings.weeklyReportEnabled)
                Toggle(isOn: $settings.weeklyReportEnabled) {
                    HStack(spacing: 6) {
                        Text("notifications.weekly")
                        InfoTip(["notifications.weekly.note"])
                    }
                }
            }
            Section {
                Toggle("notifications.threshold", isOn: $settings.thresholdEnabled)
                LabeledContent("notifications.threshold.value") {
                    HStack(spacing: 6) {
                        TextField("notifications.threshold.value", value: $settings.thresholdWh, format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text(verbatim: "Wh").foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.thresholdEnabled)
            }
            Section("notifications.completion") {
                Toggle("notifications.completion.menuBar", isOn: $settings.completionAlertEnabled)
                Toggle("notifications.completion.popover", isOn: $settings.completionOpensPopover)
                    .disabled(!settings.completionAlertEnabled)
                Toggle("notifications.completion.system", isOn: $settings.completionNotificationEnabled)
            }
            if authorizationDenied {
                Section {
                    Text("notifications.denied").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.dailyReportEnabled) { _, on in if on { requestAuthorization() } }
        .onChange(of: settings.weeklyReportEnabled) { _, on in if on { requestAuthorization() } }
        .onChange(of: settings.thresholdEnabled) { _, on in if on { requestAuthorization() } }
        .onChange(of: settings.completionNotificationEnabled) { _, on in if on { requestAuthorization() } }
    }

    private var dailyTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(context.settings.dailyReportMinutes * 60))
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                context.settings.dailyReportMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func requestAuthorization() {
        Task {
            let granted = await NotificationScheduler.requestAuthorization()
            authorizationDenied = !granted
        }
    }
}


// MARK: Terminal status line

/// Installs the `powerboard` status line into Claude Code (SPEC 8.3), with the same logic as `powerboard install-statusline`.
struct TerminalStatusLineSection: View {
    @Bindable var settings: AppSettings
    @State private var existing: StatusLineInstaller.Existing = .none
    @State private var askMode = false
    @State private var message: String?
    @State private var isError = false

    private var installer: StatusLineInstaller {
        StatusLineInstaller.standard(
            executablePath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(AppIdentity.cliName)").path
        )
    }

    private var isInstalled: Bool {
        if case .ours = existing { return true }
        return false
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isInstalled }, set: { $0 ? requestInstall() : uninstall() })) {
                HStack(spacing: 6) {
                    Text("terminal.toggle")
                    InfoTip(["terminal.toggle.note", "terminal.codexNote"])
                }
            }
            if case .ours(let chained?) = existing {
                LabeledContent("terminal.combinedWith") { Text(verbatim: chained).font(.callout.monospaced()).lineLimit(1) }
            }
            Picker("terminal.language", selection: $settings.cliLanguage) {
                Text(verbatim: "English").tag(CLILanguage.english)
                Text(verbatim: "简体中文").tag(CLILanguage.chinese)
            }
            Picker("terminal.format", selection: $settings.cliFormat) {
                Text("terminal.format.default").tag(StatusLineFormat.default)
                Text("terminal.format.compact").tag(StatusLineFormat.compact)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(isError ? .orange : .secondary).textSelection(.enabled)
            }
        } header: {
            Text("terminal.section")
        }
        .onAppear(perform: refresh)
        .confirmationDialog("terminal.existing.title", isPresented: $askMode) {
            Button("terminal.existing.combine") { install(.combine) }
            Button("terminal.existing.replace") { install(.replace) }
            Button("terminal.existing.cancel", role: .cancel) {}
        } message: {
            if case .other(let command?) = existing {
                Text(String(format: String(localized: "terminal.existing.message"), command))
            }
        }
    }

    private func refresh() {
        do {
            existing = try installer.inspect()
        } catch {
            show(error)
        }
    }

    private func requestInstall() {
        refresh()
        switch existing {
        case .other(command: .some):
            askMode = true
        default:
            install(.replace)
        }
    }

    private func install(_ mode: StatusLineInstaller.Mode) {
        do {
            let backup = try installer.install(mode: mode)
            isError = false
            message = backup.map { String(format: String(localized: "terminal.installed.backup"), $0.path) }
                ?? String(localized: "terminal.installed")
        } catch {
            show(error)
        }
        refresh()
    }

    private func uninstall() {
        do {
            let backup = try installer.uninstall()
            isError = false
            message = backup.map { String(format: String(localized: "terminal.removed.backup"), $0.path) }
        } catch {
            show(error)
        }
        refresh()
    }

    private func show(_ error: Error) {
        isError = true
        switch error as? StatusLineInstaller.InstallError {
        case .settingsNotAnObject: message = String(localized: "terminal.error.settings")
        case .cannotCombine: message = String(localized: "terminal.error.combine")
        case .notInstalled: message = nil
        case nil: message = error.localizedDescription
        }
    }
}
