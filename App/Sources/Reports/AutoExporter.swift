import AppKit
import ElectricityCore
import Foundation
import Observation
import os
import SwiftUI

/// Settings for automatic exports (SPEC 12).
@MainActor
@Observable
final class AutoExportSettings {
    private enum Key {
        static func enabled(_ period: ReportPeriod) -> String { "autoExport.\(period.rawValue)" }
        static let minutes = "autoExport.minutes"
        static let format = "autoExport.format"
        static let language = "autoExport.language"
        static let hideProjects = "autoExport.hideProjects"
        static let sections = "autoExport.sections"
        static let folder = "autoExport.folderBookmark"
        static func lastExported(_ period: ReportPeriod) -> String { "autoExport.last.\(period.rawValue)" }
    }

    /// Periods that can be exported automatically.
    static let periods: [ReportPeriod] = [.day, .week, .month]

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var enabled: Set<ReportPeriod>
    var minutes: Int { didSet { defaults.set(minutes, forKey: Key.minutes) } }
    var format: ExportFormat { didSet { defaults.set(format.rawValue, forKey: Key.format) } }
    var language: ExportLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    var hideProjects: Bool { didSet { defaults.set(hideProjects, forKey: Key.hideProjects) } }
    var sections: ReportSections { didSet { defaults.set(sections.rawValue, forKey: Key.sections) } }
    /// The chosen folder, kept as a bookmark so it is found again after it is moved or renamed.
    private(set) var folderBookmark: Data?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Set(Self.periods.filter { defaults.bool(forKey: Key.enabled($0)) })
        minutes = defaults.object(forKey: Key.minutes) as? Int ?? 9 * 60
        format = defaults.string(forKey: Key.format).flatMap(ExportFormat.init) ?? .pdf
        language = defaults.string(forKey: Key.language).flatMap(ExportLanguage.init) ?? .app
        hideProjects = defaults.bool(forKey: Key.hideProjects)
        sections = (defaults.object(forKey: Key.sections) as? Int).map(ReportSections.init) ?? .all
        folderBookmark = defaults.data(forKey: Key.folder)
    }

    func isEnabled(_ period: ReportPeriod) -> Bool { enabled.contains(period) }

    func setEnabled(_ period: ReportPeriod, _ on: Bool) {
        if on { enabled.insert(period) } else { enabled.remove(period) }
        defaults.set(on, forKey: Key.enabled(period))
    }

    var folderURL: URL? {
        guard let folderBookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: folderBookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
    }

    func setFolder(_ url: URL) {
        folderBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(folderBookmark, forKey: Key.folder)
    }

    func lastExported(_ period: ReportPeriod) -> String? { defaults.string(forKey: Key.lastExported(period)) }
    func markExported(_ period: ReportPeriod, key: String) { defaults.set(key, forKey: Key.lastExported(period)) }
}

/// Exports the previous day, week or month once it is complete, at the chosen time. Checks every minute.
@MainActor
final class AutoExporter {
    private let model: AppModel
    let settings = AutoExportSettings()
    private var timer: Task<Void, Never>?
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "export")

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(now: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        timer?.cancel()
    }

    private func check(now: Date) async {
        guard !settings.enabled.isEmpty, let store = model.store, let folder = settings.folderURL else { return }
        let calendar = Calendar.current
        let minutesNow = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minutesNow >= settings.minutes else { return }
        for period in AutoExportSettings.periods where settings.isEnabled(period) {
            let previous = period.shifted(period.interval(containing: now), by: -1)
            let key = ISO8601DateFormatter().string(from: previous.start)
            guard settings.lastExported(period) != key else { continue }
            do {
                let mixes = await model.energyMixes(for: previous)
                let report = try ReportBuilder.build(store: store, period: period, containing: previous.start, energyMixes: mixes)
                let data = try ReportExport.data(settings.format, report: report, store: store,
                                                 strings: settings.language.strings, hideProjects: settings.hideProjects,
                                                 sections: settings.sections)
                let accessing = folder.startAccessingSecurityScopedResource()
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                try data.write(to: folder.appendingPathComponent(ReportExport.fileName(settings.format, report: report)), options: .atomic)
                settings.markExported(period, key: key)
            } catch {
                logger.error("Automatic export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Automatic export settings, shown at the bottom of the Reports page.
struct AutoExportCard: View {
    @Bindable var settings: AutoExportSettings

    var body: some View {
        Card {
            CardHeader(icon: Icons.export, color: Palette.neutral, title: "autoExport.title", tips: ["autoExport.note"])
            Form {
                HStack(spacing: 16) {
                    ForEach(AutoExportSettings.periods, id: \.self) { period in
                        Toggle(isOn: Binding(get: { settings.isEnabled(period) }, set: { settings.setEnabled(period, $0) })) {
                            Text(Self.periodKey(period))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                DatePicker("autoExport.time", selection: time, displayedComponents: .hourAndMinute)
                Picker("export.format", selection: $settings.format) {
                    ForEach(ExportFormat.allCases) { Text($0.titleKey).tag($0) }
                }
                Picker("export.language", selection: $settings.language) {
                    Text("export.language.app").tag(ExportLanguage.app)
                    Text(verbatim: "简体中文").tag(ExportLanguage.chinese)
                    Text(verbatim: "English").tag(ExportLanguage.english)
                }
                ExportContentPicker(format: settings.format, sections: $settings.sections, hideProjects: $settings.hideProjects)
                LabeledContent("autoExport.folder") {
                    HStack {
                        Text(verbatim: settings.folderURL?.path ?? String(localized: "autoExport.folder.none"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("autoExport.folder.choose", action: chooseFolder)
                    }
                }
            }
            .formStyle(.columns)
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(settings.minutes * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "autoExport.folder.choose")
        if panel.runModal() == .OK, let url = panel.url { settings.setFolder(url) }
    }

    private static func periodKey(_ period: ReportPeriod) -> LocalizedStringKey {
        switch period {
        case .day: "autoExport.daily"
        case .week: "autoExport.weekly"
        case .month, .year: "autoExport.monthly"
        }
    }
}
