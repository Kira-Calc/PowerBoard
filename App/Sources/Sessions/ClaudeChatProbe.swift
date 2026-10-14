import ElectricityCore
import Foundation

/// Guesses whether ordinary chat in the Claude desktop app is in use.
///
/// The chat is the claude.ai web page inside the app: conversations and usage stay on Anthropic's servers and nothing
/// readable is written locally except the page's own caches, which hold conversation text and are not read. So the
/// row is inferred from two signals only:
/// - the app was frontmost in the last `shownFor` seconds;
/// - its network process (Electron's `NetworkService` helper) keeps using CPU, as it does while a reply streams in.
/// The Code tab and Cowork run their own Claude Code processes, which do their own networking, so their work does not
/// show here. The row has no energy figure and sends no completion alerts.
final class ClaudeChatProbe: @unchecked Sendable {
    static let sessionID = "claude-desktop-chat"
    /// The row stays this long after the app was last frontmost or last busy.
    nonisolated static let shownFor: TimeInterval = 10 * 60
    /// Network process CPU, in milliseconds per second, above which the app is taken to be receiving data.
    nonisolated static let busyMillisecondsPerSecond = 15.0
    /// Busy samples in a row before the row shows "replying", and how long it keeps that after the last one.
    nonisolated static let busySamples = 2
    nonisolated static let busyHold: TimeInterval = 4

    /// What the main actor knows about the app.
    struct AppState: Sendable {
        var pid: pid_t
        var isFrontmost: Bool
        var lastFrontmost: Date?
    }

    // Accessed only from the monitor's refresh, which runs one at a time.
    private let lock = NSLock()
    private var networkPID: pid_t?
    private var lastSample: (cpu: UInt64, at: Date)?
    private var streak = 0
    private var busySince: Date?
    private var lastBusy: Date?

    /// The chat row, or nil when the app is not running or has not been used for a while.
    /// `otherWorkRunning`: a Code tab or Cowork session of the app is working, which would explain any activity.
    func session(app: AppState?, otherWorkRunning: Bool, now: Date) -> ActiveSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let app else {
            reset()
            return nil
        }
        let busy = !otherWorkRunning && sampleBusy(appPID: app.pid, now: now)
        if busy {
            streak += 1
        } else {
            streak = 0
        }
        if streak >= Self.busySamples {
            if busySince == nil { busySince = now }
            lastBusy = now
        }
        let replying = lastBusy.map { now.timeIntervalSince($0) < Self.busyHold } ?? false
        if !replying { busySince = nil }

        let lastUse = app.isFrontmost ? now : [app.lastFrontmost, lastBusy].compactMap { $0 }.max()
        guard let lastUse, now.timeIntervalSince(lastUse) < Self.shownFor else { return nil }
        return ActiveSession(sessionID: Self.sessionID, source: .claudeDesktop, projectPath: nil, title: nil,
                             status: replying ? .running : .done, statusSince: replying ? busySince : lastUse,
                             pid: 0, energyWh: 0, client: UsageClient.chat, appBundleID: ClaudeDesktopSession.appBundleID)
    }

    private func reset() {
        networkPID = nil
        lastSample = nil
        streak = 0
        busySince = nil
        lastBusy = nil
    }

    /// Whether the network process used more CPU than `busyMillisecondsPerSecond` since the previous sample.
    private func sampleBusy(appPID: pid_t, now: Date) -> Bool {
        if networkPID.map({ ProcessInspector.parent(of: $0) != appPID }) ?? true {
            networkPID = Self.findNetworkProcess(appPID: appPID)
            lastSample = nil
        }
        guard let pid = networkPID, let cpu = ProcessInspector.cpuTime(pid) else {
            networkPID = nil
            return false
        }
        defer { lastSample = (cpu, now) }
        guard let last = lastSample, cpu >= last.cpu else { return false }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return false }
        return Double(cpu - last.cpu) / 1_000_000 / seconds > Self.busyMillisecondsPerSecond
    }

    /// The helper started by the app with `--utility-sub-type=network.mojom.NetworkService`.
    private static func findNetworkProcess(appPID: pid_t) -> pid_t? {
        ProcessInspector.allPIDs().first { pid in
            ProcessInspector.parent(of: pid) == appPID
                && ProcessInspector.arguments(pid).contains { $0.hasPrefix("--utility-sub-type=network.") }
        }
    }
}

extension ActiveSession {
    /// The inferred row for ordinary chat in the Claude desktop app.
    var isClaudeChat: Bool { sessionID == ClaudeChatProbe.sessionID }
}
