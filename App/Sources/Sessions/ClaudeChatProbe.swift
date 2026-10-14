import ApplicationServices
import ElectricityCore
import Foundation

/// Watches ordinary chat in the Claude desktop app.
///
/// The chat is the claude.ai web page inside the app: conversations and usage stay on Anthropic's servers and nothing
/// readable is written locally except the page's own caches, which hold conversation text and are not read. So the
/// row comes from two signals:
/// - the app was frontmost in the last `shownFor` seconds (the row appears);
/// - with Accessibility permission, the window shows a Stop button while a reply is being written. Only button roles
///   and labels are compared; no text is kept. Without the permission the row only says the app was used.
/// CPU and network use of the app were measured first and do not work: while the model thinks the app sends a few
/// dozen bytes every few seconds and uses almost no CPU, the same as when idle.
/// The row has no energy figure.
final class ClaudeChatProbe: @unchecked Sendable {
    static let sessionID = "claude-desktop-chat"
    /// The row stays this long after the app was last frontmost or last replied.
    nonisolated static let shownFor: TimeInterval = 10 * 60
    /// The window is only searched while the app was used this recently: replies follow a message the user sent.
    nonisolated static let watchFor: TimeInterval = 30 * 60
    /// Elements visited at most per search, so a very long conversation cannot stall the monitor.
    nonisolated static let maxElements = 20_000

    /// What the main actor knows about the app.
    struct AppState: Sendable {
        var pid: pid_t
        var isFrontmost: Bool
        var lastFrontmost: Date?
    }

    // Accessed only from the monitor's refresh, which runs one at a time.
    private let lock = NSLock()
    private var replySince: Date?
    private var lastReplyEnd: Date?

    /// The chat row, or nil when the app is not running or has not been used for a while.
    /// `otherWorkRunning`: a Code tab or Cowork session of the app is working, whose Stop button looks the same.
    func session(app: AppState?, otherWorkRunning: Bool, now: Date) -> ActiveSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let app else {
            replySince = nil
            lastReplyEnd = nil
            return nil
        }
        let lastFront = app.isFrontmost ? now : app.lastFrontmost
        let watching = lastFront.map { now.timeIntervalSince($0) < Self.watchFor } ?? false
        let replying = watching && !otherWorkRunning && AXIsProcessTrusted() && Self.showsStopButton(pid: app.pid)
        if replying {
            if replySince == nil { replySince = now }
        } else if replySince != nil {
            replySince = nil
            lastReplyEnd = now
        }

        let lastUse = replying ? now : [lastFront, lastReplyEnd].compactMap { $0 }.max()
        guard let lastUse, now.timeIntervalSince(lastUse) < Self.shownFor else { return nil }
        var row = ActiveSession(sessionID: Self.sessionID, source: .claudeDesktop, projectPath: nil, title: nil,
                                status: replying ? .running : .done, statusSince: replying ? replySince : lastUse,
                                pid: 0, energyWh: 0, client: UsageClient.chat, appBundleID: ClaudeDesktopSession.appBundleID)
        // "Finished" only when a reply was seen ending; otherwise the app was just used.
        row.chatReplied = replying || lastReplyEnd != nil
        if !replying, let end = lastReplyEnd, lastFront.map({ $0 > end }) != true { row.statusSince = end }
        return row
    }

    /// Whether a window of the app has a button labelled "Stop…" (or "停止…"), as the chat shows while it replies.
    private static func showsStopButton(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // Electron builds its accessibility tree only when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var visited = 0
        func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var result: AnyObject?
            AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return result
        }
        func search(_ element: AXUIElement, depth: Int) -> Bool {
            visited += 1
            guard depth < 64, visited < maxElements else { return false }
            if value(element, kAXRoleAttribute) as? String == kAXButtonRole,
               let label = value(element, kAXDescriptionAttribute) as? String, isStopLabel(label) {
                return true
            }
            let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.contains { search($0, depth: depth + 1) }
        }
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.contains { search($0, depth: 0) }
    }

    /// "Stop response", "停止生成", …, but not the Stop buttons of dictation or voice mode.
    nonisolated static func isStopLabel(_ label: String) -> Bool {
        let text = label.lowercased()
        guard text.hasPrefix("stop") || text.hasPrefix("停止") else { return false }
        return !["dictat", "voice", "record", "听写", "语音", "录"].contains { text.contains($0) }
    }
}

extension ActiveSession {
    /// The row for ordinary chat in the Claude desktop app.
    var isClaudeChat: Bool { sessionID == ClaudeChatProbe.sessionID }
}
