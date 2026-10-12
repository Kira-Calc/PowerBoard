import AppKit
import ElectricityCore
import SwiftUI
import UserNotifications

@main
struct PowerBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Command-comma opens the dashboard at its settings (SPEC 9).
            CommandGroup(replacing: .appSettings) {
                Button("menu.settings") { appDelegate.openDashboard(section: .general) }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Declared first so it runs before settings are read or the database is opened.
    private let migration = LegacyMigration.run()
    private let model = AppModel()
    private let settings = AppSettings()
    private lazy var ingestCoordinator = IngestCoordinator(model: model, settings: settings)
    private lazy var notifications = NotificationScheduler(model: model, settings: settings)
    private lazy var sessionMonitor = ActiveSessionMonitor(model: model, settings: settings)
    private lazy var autoExporter = AutoExporter(model: model)
    private lazy var gridCoordinator = GridCoordinator(model: model, ingest: ingestCoordinator)
    private lazy var dashboard = DashboardWindowController(
        context: DashboardContext(model: model, settings: settings, coordinator: ingestCoordinator, autoExport: autoExporter.settings, grid: gridCoordinator)
    )
    private var statusItemController: StatusItemController?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (logout, `kill`) goes through normal termination so the snapshot is marked as stopped.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source

        UNUserNotificationCenter.current().delegate = self
        if settings.completionNotificationEnabled {
            Task { _ = await NotificationScheduler.requestAuthorization() }
        }

        statusItemController = StatusItemController(
            model: model,
            settings: settings,
            openDashboard: { [weak self] section in self?.openDashboard(section: section) }
        )
        ingestCoordinator.start()
        notifications.start()
        sessionMonitor.start()
        autoExporter.start()
        gridCoordinator.start()

        // Development aid: `open <App> --args -describeJump <pid>` logs how a conversation would be opened.
        if case let pid = UserDefaults.standard.integer(forKey: "describeJump"), pid > 0 {
            print("Describe: \(TerminalJumper.describe(pid: pid_t(pid)))") // Printed so it can be read when the binary is run directly.
        }

        // Development aid: `<App binary> -exportTest <folder>` writes this week's report in every format and
        // both languages, then quits. Used to check that each export opens correctly.
        if let folder = UserDefaults.standard.string(forKey: "exportTest"), let store = model.store {
            Task { await runExportTest(folder: folder, store: store) }
        }

        // Development aid: `open <App> --args -openDashboard overview` opens a page at launch.
        if let name = UserDefaults.standard.string(forKey: "openDashboard") {
            openDashboard(section: DashboardSection(rawValue: name) ?? .overview)
        }
    }

    /// Writes this week's report (or the last 7 days with `-exportTestRolling YES`) in every format and both languages.
    private func runExportTest(folder: String, store: UsageStore) async {
            let url = URL(fileURLWithPath: folder)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let rolling = UserDefaults.standard.bool(forKey: "exportTestRolling")
                let interval = ReportBuilder.interval(period: .week, rolling: rolling, containing: Date())
                let mixes = await model.energyMixes(for: interval)
                let report = try ReportBuilder.build(store: store, period: .week, containing: Date(), rolling: rolling, energyMixes: mixes)
                for language in [ExportLanguage.chinese, .english] {
                    for format in ExportFormat.allCases {
                        let data = try ReportExport.data(format, report: report, store: store, strings: language.strings, hideProjects: false)
                        let name = "\(language.rawValue)-" + ReportExport.fileName(format, report: report)
                        try data.write(to: url.appendingPathComponent(name))
                        print("Wrote \(name) (\(data.count) bytes)")
                    }
                }
            } catch {
                print("Export test failed: \(error)")
            }
            NSApp.terminate(nil)
    }

    func openDashboard(section: DashboardSection?) {
        dashboard.show(section: section)
    }

    // Show banners even while the dashboard is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a "conversation finished" notification opens that conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let pid = response.notification.request.content.userInfo[CompletionNotifier.pidKey] as? Int else { return }
        await MainActor.run { TerminalJumper.jump(to: pid_t(pid)) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        notifications.stop()
        sessionMonitor.stop()
        autoExporter.stop()
        gridCoordinator.stop()
        ingestCoordinator.stop()
    }
}
