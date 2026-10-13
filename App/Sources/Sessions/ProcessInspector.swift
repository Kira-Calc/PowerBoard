import AppKit
import Darwin
import ElectricityCore
import os

/// Reads process information with libproc. Only the current user's processes are visible.
enum ProcessInspector {
    struct Info {
        var pid: pid_t
        var parent: pid_t
        var name: String
        /// Controlling terminal device path, such as "/dev/ttys001".
        var tty: String?
    }

    /// Executable path. More reliable than the process name, which Claude Code replaces with its version.
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    /// True when the process runs an executable whose path mentions `tool` (for example "claude" or "codex").
    static func runs(_ pid: pid_t, tool: String) -> Bool {
        guard let path = executablePath(pid)?.lowercased() else { return false }
        return path.contains("/\(tool)")
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    static func info(_ pid: pid_t) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let name = withUnsafeBytes(of: bsd.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        var tty: String?
        if bsd.e_tdev != UInt32.max, let device = devname(dev_t(bitPattern: bsd.e_tdev), S_IFCHR) {
            tty = "/dev/" + String(cString: device)
        }
        return Info(pid: pid, parent: pid_t(bsd.pbi_ppid), name: name, tty: tty)
    }

    /// Parent process ID through sysctl, which also works for processes owned by root (such as `login`),
    /// where `proc_pidinfo` is not allowed.
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Paths of regular files the process has open.
    static func openFiles(_ pid: pid_t) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride)
        let used = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let path = withUnsafeBytes(of: vnode.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// Current working directory of a process.
    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// The nearest ancestor that is a regular app with a Dock icon (a terminal, an editor or a desktop app).
    /// Helper apps inside another app's bundle (such as Codex (Service).app inside ChatGPT.app) are skipped:
    /// bringing them forward shows nothing.
    @MainActor
    static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular,
               !(app.bundleURL?.path.contains(".app/Contents/") ?? false) {
                return app
            }
            guard let parent = parent(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }
}

/// Brings the window or tab that runs a process to the front.
enum TerminalJumper {
    static let logger = Logger(subsystem: AppIdentity.bundleID, category: "jump")

    /// Describes what a jump would do, without doing it. Used for diagnostics.
    @MainActor
    static func describe(pid: pid_t) -> String {
        let app = ProcessInspector.owningApp(of: pid)
        return "pid \(pid) app \(app?.bundleIdentifier ?? "none") tty \(ProcessInspector.info(pid)?.tty ?? "none")"
    }

    /// Brings a session forward: its desktop app when it has one, otherwise the terminal or app that runs its process.
    @MainActor
    static func jump(to session: ActiveSession) {
        jump(to: session.pid, app: session.appBundleID)
    }

    /// Brings `app` forward when given (opening it if needed), otherwise the terminal or app running `pid`.
    @MainActor
    static func jump(to pid: pid_t, app bundleID: String?) {
        if let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            logger.info("Jump to app \(bundleID, privacy: .public)")
            NSApp.yieldActivation(to: app)
            app.activate()
            return
        }
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        guard pid > 0 else { return }
        jump(to: pid)
    }

    @MainActor
    static func jump(to pid: pid_t) {
        logger.info("Jump requested: \(describe(pid: pid), privacy: .public)")
        guard let app = ProcessInspector.owningApp(of: pid) else {
            logger.error("No app found for pid \(pid)")
            return
        }
        let tty = ProcessInspector.info(pid)?.tty
        // Since macOS 14 an app may only bring another app forward after yielding activation to it.
        NSApp.yieldActivation(to: app)
        switch app.bundleIdentifier {
        case "com.apple.Terminal" where tty != nil:
            if run(terminalScript(tty: tty!)) { return }
        case "com.googlecode.iterm2" where tty != nil:
            if run(iTermScript(tty: tty!)) { return }
        default:
            break
        }
        app.activate()
    }

    /// Runs an AppleScript and returns whether it reported success. The first use asks for Automation permission.
    @MainActor
    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript failed: \(error, privacy: .public)")
        }
        return error == nil && result?.booleanValue == true
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }
}
