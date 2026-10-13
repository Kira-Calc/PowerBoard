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
    /// Client within the tool ("CLI", "Desktop", "Code", …), when known.
    var client: String? = nil
    /// For sessions in a desktop app without a terminal: the app to bring forward when the row is clicked.
    var appBundleID: String? = nil
}

/// Finds running agent conversations every 2 seconds and reports turns that finish.
///
/// Claude Code: `~/.claude/sessions/<pid>.json` gives the session and its busy or idle state.
/// Claude Desktop: the Code tab's session index gives recent sessions; a log written in the last 30 seconds means
/// the agent is working.
/// Codex: the task state comes from its log; a session is live while a `codex` process keeps its log file open, or,
/// for the desktop app and VS Code, while its latest task is recent.
/// Antigravity (`agy`): a running process with a conversation database open.
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

        // Claude Code processes started by the Claude desktop app belong to Claude Desktop and are brought forward
        // through the app, not a terminal.
        for index in sessions.indices where sessions[index].source == .claudeCode {
            if let path = ProcessInspector.executablePath(sessions[index].pid), Self.isClaudeDesktopBinary(path) {
                sessions[index].source = .claudeDesktop
                sessions[index].client = UsageClient.desktopCode
                sessions[index].appBundleID = ClaudeDesktopSession.appBundleID
            }
        }

        // Claude desktop app, Code tab: sessions active in the last 30 minutes.
        let now = Date()
        let known = Set(sessions.map(\.sessionID))
        for desktop in ClaudeDesktopSession.read() where !desktop.isArchived && !known.contains(desktop.sessionID) {
            let logDate = Self.claudeLogDate(sessionID: desktop.sessionID)
            let last = [desktop.lastActivityAt, logDate].compactMap { $0 }.max()
            guard let last, now.timeIntervalSince(last) < 30 * 60 else { continue }
            let running = logDate.map { now.timeIntervalSince($0) < 30 } ?? false
            sessions.append(ActiveSession(sessionID: desktop.sessionID, source: .claudeDesktop, projectPath: desktop.cwd,
                                          title: desktop.title ?? titles.title(for: desktop.sessionID),
                                          status: running ? .running : .done, statusSince: last, pid: 0, energyWh: 0,
                                          client: UsageClient.desktopCode, appBundleID: ClaudeDesktopSession.appBundleID))
        }

        if let store, let activities = try? store.activities(since: now.addingTimeInterval(-7 * 24 * 3600)),
           !activities.isEmpty {
            // Map open log files to the codex process that holds them.
            var owner: [String: pid_t] = [:]
            for pid in ProcessInspector.allPIDs() {
                guard ProcessInspector.runs(pid, tool: "codex") else { continue }
                for path in ProcessInspector.openFiles(pid) where path.hasSuffix(".jsonl") {
                    owner[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = pid
                }
            }
            let codex = activities.filter { $0.source == .codex }
            let clients = (try? store.sessionClients(codex.map(\.sessionID))) ?? [:]
            for activity in codex {
                let client = clients[activity.sessionID]
                let app = client.flatMap { Self.appBundleID(codexClient: $0) }
                if let pid = owner[activity.logPath] {
                    sessions.append(ActiveSession(sessionID: activity.sessionID, source: .codex, projectPath: activity.projectPath,
                                                  title: nil, status: activity.running ? .running : .done, statusSince: activity.eventAt,
                                                  pid: pid, energyWh: 0, client: client, appBundleID: app))
                } else if let app, activity.running || now.timeIntervalSince(activity.eventAt) < 30 * 60 {
                    // The desktop app and VS Code may not keep the log open between turns.
                    sessions.append(ActiveSession(sessionID: activity.sessionID, source: .codex, projectPath: activity.projectPath,
                                                  title: nil, status: activity.running ? .running : .done, statusSince: activity.eventAt,
                                                  pid: 0, energyWh: 0, client: client, appBundleID: app))
                }
            }
        }

        // Codex logs written in the last 30 minutes, read straight from disk so a new or busy session shows up within
        // seconds, before its records reach the database. Only the first line (session ID, originator, folder) is read.
        for recent in Self.recentCodexLogs(now: now) {
            let running = now.timeIntervalSince(recent.modified) < 15
            if let index = sessions.firstIndex(where: { $0.sessionID == recent.sessionID }) {
                if running && sessions[index].status == .done {
                    sessions[index].status = .running
                    sessions[index].statusSince = recent.modified
                }
                continue
            }
            let client = UsageClient.codex(originator: recent.originator)
            sessions.append(ActiveSession(sessionID: recent.sessionID, source: .codex, projectPath: recent.cwd, title: nil,
                                          status: running ? .running : .done, statusSince: recent.modified, pid: 0, energyWh: 0,
                                          client: client, appBundleID: client.flatMap { Self.appBundleID(codexClient: $0) }))
        }

        // Antigravity CLI (`agy`): a running process and the conversation database it has open.
        for pid in ProcessInspector.allPIDs() where ProcessInspector.runs(pid, tool: "agy") {
            for path in ProcessInspector.openFiles(pid) where path.contains("/conversations/") && path.hasSuffix(".db") {
                let url = URL(fileURLWithPath: path)
                let sessionID = url.deletingPathExtension().lastPathComponent
                guard !sessions.contains(where: { $0.sessionID == sessionID }) else { continue }
                let changed = [path, path + "-wal"].compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
                let running = changed.map { now.timeIntervalSince($0) < 15 } ?? false
                sessions.append(ActiveSession(sessionID: sessionID, source: .antigravity, projectPath: ProcessInspector.workingDirectory(pid),
                                              title: nil, status: running ? .running : .done, statusSince: changed, pid: pid, energyWh: 0,
                                              client: UsageClient.cli))
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

    /// The Claude desktop app runs its own copy of Claude Code from inside its support folder or app bundle.
    nonisolated static func isClaudeDesktopBinary(_ path: String) -> Bool {
        path.contains("/Application Support/Claude/claude-code") || path.contains("/Claude.app/")
    }

    /// Codex desktop runs inside the ChatGPT app; the VS Code extension inside VS Code.
    nonisolated static func appBundleID(codexClient client: String) -> String? {
        switch client {
        case UsageClient.desktop: "com.openai.codex"
        case UsageClient.vscode: "com.microsoft.VSCode"
        default: nil
        }
    }

    struct RecentCodexLog {
        var sessionID: String
        var originator: String?
        var cwd: String?
        var modified: Date
    }

    /// Codex logs (`~/.codex/sessions/YYYY/MM/DD/*.jsonl`, today and yesterday) changed in the last 30 minutes.
    /// Sessions whose originator is the CLI are left to the process check, which knows when they end.
    nonisolated static func recentCodexLogs(now: Date) -> [RecentCodexLog] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let calendar = Calendar.current
        var result: [RecentCodexLog] = []
        for day in [now, now.addingTimeInterval(-86400)] {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) < 30 * 60,
                      let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: 256 * 1024),
                      let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      let sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String)
                else { continue }
                let originator = payload["originator"] as? String
                guard UsageClient.codex(originator: originator) != UsageClient.cli else { continue }
                result.append(RecentCodexLog(sessionID: sessionID, originator: originator, cwd: payload["cwd"] as? String, modified: modified))
            }
        }
        return result
    }

    /// Modification time of a Claude Code log, `~/.claude/projects/*/<session>.jsonl`.
    nonisolated static func claudeLogDate(sessionID: String) -> Date? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let file = folder.appendingPathComponent(sessionID + ".jsonl")
            if let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date { return date }
        }
        return nil
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
    static let appKey = "app"

    @MainActor
    static func post(_ session: ActiveSession) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.finished.title")
        let place = "\(Formatting.projectName(session.projectPath)), \(SourceText.name(session.source, client: session.client))"
        content.body = session.title.map { "\($0)\n\(place)" } ?? place
        content.sound = .default
        content.categoryIdentifier = category
        var info: [String: Any] = [pidKey: Int(session.pid)]
        if let bundleID = session.appBundleID { info[appKey] = bundleID }
        content.userInfo = info
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
