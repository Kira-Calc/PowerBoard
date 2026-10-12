import AppKit
import ElectricityCore
import Foundation
import UserNotifications

/// A conversation whose agent process is still running.
struct ActiveSession: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        /// The agent is working on a turn.
        case running
        /// The turn finished; the agent is waiting for the user.
        case done
        /// The agent needs something from the user, such as a permission answer.
        case waiting
    }

    var id: String { sessionID }
    var sessionID: String
    var source: UsageSource
    var projectPath: String?
    /// Conversation title from the agent, when it provides one.
    var title: String?
    var status: Status
    var statusSince: Date?
    var pid: pid_t
    var energyWh: Double
}

/// Finds running agent conversations every 2 seconds and reports turns that finish.
///
/// Claude Code: `~/.claude/sessions/<pid>.json` gives the session and its busy or idle state.
/// Codex: the task state comes from its log; a session is live while a `codex` process keeps its log file open.
@MainActor
final class ActiveSessionMonitor {
    private static let interval: Duration = .seconds(2)
    /// How long the menu bar shows the completion alert.
    static let alertDuration: Duration = .seconds(8)

    private let model: AppModel
    private let settings: AppSettings
    private var task: Task<Void, Never>?
    private var alertReset: Task<Void, Never>?
    private var previous: [String: ActiveSession.Status] = [:]

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        alertReset?.cancel()
    }

    private func refresh() async {
        let store = model.store
        let titles = self.titles
        let sessions = await Task.detached { Self.collect(store: store, titles: titles) }.value
        let finished = sessions.filter { previous[$0.sessionID] == .running && $0.status == .done }
        previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0.status) })
        if model.activeSessions != sessions { model.activeSessions = sessions }
        if let session = finished.first {
            if settings.completionAlertEnabled { showAlert(for: session) }
            if settings.completionNotificationEnabled { CompletionNotifier.post(session) }
        }
    }

    private func showAlert(for session: ActiveSession) {
        model.completionAlert = CompletionAlert(session: session, at: Date())
        alertReset?.cancel()
        alertReset = Task { [weak self] in
            try? await Task.sleep(for: Self.alertDuration)
            guard !Task.isCancelled else { return }
            self?.model.completionAlert = nil
        }
    }

    private let titles = TitleCache()

    /// Runs off the main thread: reads session files, scans processes and queries energy.
    nonisolated static func collect(store: UsageStore?, titles: TitleCache) -> [ActiveSession] {
        var sessions: [ActiveSession] = []

        for live in LiveClaudeSession.read(directory: LiveClaudeSession.standardDirectory)
        where ProcessInspector.isAlive(live.pid) && ProcessInspector.runs(live.pid, tool: "claude") {
            let status: ActiveSession.Status = switch live.status {
            case .busy: .running
            case .idle: .done
            case .other: .waiting
            }
            sessions.append(ActiveSession(sessionID: live.sessionID, source: .claudeCode, projectPath: live.cwd,
                                          title: titles.title(for: live.sessionID), status: status, statusSince: live.statusChangedAt, pid: live.pid, energyWh: 0))
        }

        if let store, let activities = try? store.activities(since: Date().addingTimeInterval(-7 * 24 * 3600)),
           !activities.isEmpty {
            // Map open log files to the codex process that holds them.
            var owner: [String: pid_t] = [:]
            for pid in ProcessInspector.allPIDs() {
                guard ProcessInspector.runs(pid, tool: "codex") else { continue }
                for path in ProcessInspector.openFiles(pid) where path.hasSuffix(".jsonl") {
                    owner[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = pid
                }
            }
            for activity in activities where activity.source == .codex {
                guard let pid = owner[activity.logPath] else { continue }
                sessions.append(ActiveSession(sessionID: activity.sessionID, source: .codex, projectPath: activity.projectPath,
                                              title: nil, status: activity.running ? .running : .done, statusSince: activity.eventAt,
                                              pid: pid, energyWh: 0))
            }
        }

        if let store, let energy = try? store.sessionEnergy(sessions.map(\.sessionID)) {
            for index in sessions.indices { sessions[index].energyWh = energy[sessions[index].sessionID] ?? 0 }
        }
        // Running first, then waiting, then finished; most recent change first within each group.
        func rank(_ status: ActiveSession.Status) -> Int {
            switch status {
            case .running: 0
            case .waiting: 1
            case .done: 2
            }
        }
        return sessions.sorted {
            (rank($0.status), -($0.statusSince?.timeIntervalSince1970 ?? 0)) < (rank($1.status), -($1.statusSince?.timeIntervalSince1970 ?? 0))
        }
    }
}

struct CompletionAlert: Equatable {
    var session: ActiveSession
    var at: Date
}

/// Sends a system notification when a conversation finishes. Clicking it opens the conversation's terminal.
enum CompletionNotifier {
    static let category = "conversation.finished"
    static let pidKey = "pid"

    @MainActor
    static func post(_ session: ActiveSession) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.finished.title")
        let place = "\(Formatting.projectName(session.projectPath)), \(SourceText.name(session.source))"
        content.body = session.title.map { "\($0)\n\(place)" } ?? place
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = [pidKey: Int(session.pid)]
        let request = UNNotificationRequest(identifier: "finished-\(session.sessionID)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Caches conversation titles. A log is read again only when it changed and at most every 30 seconds.
final class TitleCache: @unchecked Sendable {
    private struct Entry {
        var title: String?
        var modified: Date?
        var checked: Date
    }

    // Accessed only from the monitor's refresh, which runs one at a time.
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var paths: [String: URL] = [:]

    func title(for sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let entry = entries[sessionID], now.timeIntervalSince(entry.checked) < 30 { return entry.title }
        if paths[sessionID] == nil {
            paths[sessionID] = ClaudeCodeTitle.logURL(sessionID: sessionID, roots: LogLocations.standard().claudeCode)
        }
        guard let url = paths[sessionID] else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let entry = entries[sessionID], entry.modified == modified {
            entries[sessionID]?.checked = now
            return entry.title
        }
        let title = ClaudeCodeTitle.latest(inLogAt: url)
        entries[sessionID] = Entry(title: title, modified: modified, checked: now)
        return title
    }
}
