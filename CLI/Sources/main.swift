import ArgumentParser
import ElectricityCore
import Foundation

/// Settings the app shares with the CLI through its preferences domain.
enum SharedSettings {
    static var defaults: UserDefaults? { UserDefaults(suiteName: AppIdentity.bundleID) }

    static var language: CLILanguageCode? {
        defaults?.string(forKey: "cli.language").flatMap(CLILanguageCode.init)
    }

    static var format: StatusLineFormat? {
        defaults?.string(forKey: "cli.format").flatMap(StatusLineFormat.init)
    }
}

extension CLILanguageCode: @retroactive ExpressibleByArgument {}
extension StatusLineFormat: @retroactive ExpressibleByArgument {}
extension ReportPeriod: @retroactive ExpressibleByArgument {}

/// Absolute path of this executable, with symbolic links resolved.
func executablePath() -> String {
    let path = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

func readSnapshot() -> Snapshot? {
    try? SnapshotFile.read(from: AppPaths.snapshot)
}

struct CLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AppIdentity.cliName,
        abstract: "Estimated server-side energy use of Claude Code, Codex and Antigravity on this Mac.",
        version: AppIdentity.version,
        subcommands: [StatusLine.self, Today.self, Report.self, InstallStatusLine.self, UninstallStatusLine.self]
    )
}

// MARK: statusline

struct StatusLine: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statusline",
        abstract: "Print one line for the Claude Code status line. Reads Claude Code's JSON from standard input."
    )

    @Option(help: "Output language: en or zh.")
    var lang: CLILanguageCode?

    @Option(help: "Output format: default or compact.")
    var format: StatusLineFormat?

    @Option(help: "Run this command first (with the same input) and show its output before ours.")
    var chain: String?

    func run() {
        // Claude Code pipes JSON on standard input; when run by hand from a terminal, do not wait for input.
        let input = isatty(STDIN_FILENO) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        let sessionID = (try? JSONSerialization.jsonObject(with: input) as? [String: Any])?["session_id"] as? String

        let ours = StatusLineFormatter.render(
            snapshot: readSnapshot(),
            sessionID: sessionID,
            language: lang ?? SharedSettings.language ?? .en,
            format: format ?? SharedSettings.format ?? .default,
            color: ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        )
        if let chain, let previous = Self.runChained(chain, input: input), !previous.isEmpty {
            print("\(previous) | \(ours)")
        } else {
            print(ours)
        }
    }

    /// Runs the original status line command and returns the first line of its output.
    static func runChained(_ command: String, input: Data) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: today

struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show today's estimated energy, carbon and tokens.")

    @Flag(help: "Print JSON.")
    var json = false

    @Option(help: "Output language: en or zh.")
    var lang: CLILanguageCode?

    func run() throws {
        guard let snapshot = readSnapshot() else {
            print(StatusLineFormatter.render(snapshot: nil, sessionID: nil, language: lang ?? SharedSettings.language ?? .en, format: .default, color: false))
            return
        }
        if json {
            let data = try SnapshotFile.encoder().encode(snapshot.today)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let today = snapshot.today
        let energy = ValueFormatting.energy(today.energyWh)
        let tokens = today.tokens
        let zh = (lang ?? SharedSettings.language ?? .en) == .zh
        let stale = snapshot.isStale(now: Date(), maxAge: StatusLineFormatter.staleAfter)
        if zh {
            print("今日 AI 推理耗电（服务器端，估算）：约 \(energy.mid.text)，区间 \(energy.low.text) 到 \(energy.high.text)")
            print("碳排：约 \(ValueFormatting.carbon(grams: today.co2G).text) CO2e")
            print("Token：输入 \(ValueFormatting.tokens(tokens.input))，输出 \(ValueFormatting.tokens(tokens.output))，缓存写入 \(ValueFormatting.tokens(tokens.cacheWrite))，缓存读取 \(ValueFormatting.tokens(tokens.cacheRead))")
            if stale { print("（数据未更新：\(AppIdentity.displayName) 没有在运行）") }
        } else {
            print("AI inference energy today (server-side, estimated): about \(energy.mid.text), range \(energy.low.text) to \(energy.high.text)")
            print("Carbon: about \(ValueFormatting.carbon(grams: today.co2G).text) CO2e")
            print("Tokens: input \(ValueFormatting.tokens(tokens.input)), output \(ValueFormatting.tokens(tokens.output)), cache write \(ValueFormatting.tokens(tokens.cacheWrite)), cache read \(ValueFormatting.tokens(tokens.cacheRead))")
            if stale { print("(Not updated: \(AppIdentity.displayName) is not running.)") }
        }
    }
}

// MARK: report

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a day, week, month or year report.")

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case md, json, csv
    }

    @Option(help: "day, week, month or year.")
    var period: ReportPeriod = .day

    @Option(help: "A date inside the period, YYYY-MM-DD. Default: today.")
    var date: String?

    @Option(help: "md, json or csv (raw records).")
    var format: Format = .md

    @Option(help: "Output language: en or zh.")
    var lang: CLILanguageCode?

    @Flag(help: "Replace project paths with numbered names.")
    var hideProjects = false

    func run() throws {
        var day = Date()
        if let date {
            var style = Date.ISO8601FormatStyle().year().month().day()
            style.timeZone = .current
            guard let parsed = try? Date(date, strategy: style) else {
                throw ValidationError("Use the date format YYYY-MM-DD.")
            }
            day = parsed
        }
        guard FileManager.default.fileExists(atPath: AppPaths.database.path) else {
            print(StatusLineFormatter.render(snapshot: nil, sessionID: nil, language: lang ?? SharedSettings.language ?? .en, format: .default, color: false))
            return
        }
        let store = try UsageStore(url: AppPaths.database)
        let report = try ReportBuilder.build(store: store, period: period, containing: day)
        let options = ExportOptions(language: lang ?? SharedSettings.language ?? .en, hideProjects: hideProjects)
        switch format {
        case .md:
            print(ReportExporter.markdown(report, options: options), terminator: "")
        case .json:
            let records = try store.events(from: report.interval.start, to: report.interval.end)
            FileHandle.standardOutput.write(try ReportExporter.json(report, records: records, options: options))
            print()
        case .csv:
            let records = try store.events(from: report.interval.start, to: report.interval.end)
            // No byte order mark on standard output; it is meant for files opened in spreadsheets.
            FileHandle.standardOutput.write(ReportExporter.csv(records, options: options).dropFirst(3))
        }
    }
}

// MARK: install / uninstall

struct InstallStatusLine: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-statusline",
        abstract: "Show energy in the Claude Code status line. Backs up ~/.claude/settings.json first."
    )

    @Flag(help: "Replace an existing status line without asking.")
    var replace = false

    @Flag(help: "Keep an existing status line command and show ours after it, without asking.")
    var combine = false

    func run() throws {
        let installer = StatusLineInstaller.standard(executablePath: executablePath())
        var mode: StatusLineInstaller.Mode = combine ? .combine : .replace
        if case .other(let command) = try installer.inspect(), !replace, !combine {
            guard isatty(STDIN_FILENO) != 0 else {
                throw ValidationError("A status line is already set. Run again with --replace or --combine.")
            }
            print("Claude Code already has a status line\(command.map { ": \($0)" } ?? ".")")
            if command == nil {
                print("It is not a shell command, so it can only be replaced.")
            }
            print(command == nil ? "Replace it? [r]eplace, [q]uit: " : "[r]eplace it, [c]ombine both, or [q]uit: ", terminator: "")
            switch readLine()?.lowercased().first {
            case "r": mode = .replace
            case "c" where command != nil: mode = .combine
            default:
                print("No changes made.")
                return
            }
        }
        let backup = try installer.install(mode: mode)
        print("Installed. Claude Code shows energy in its status line from the next prompt.")
        if let backup { print("Backup: \(backup.path)") }
    }
}

struct UninstallStatusLine: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall-statusline",
        abstract: "Remove the status line and restore the previous one. Backs up ~/.claude/settings.json first."
    )

    func run() throws {
        let installer = StatusLineInstaller.standard(executablePath: executablePath())
        do {
            let backup = try installer.uninstall()
            print("Removed. The previous status line is restored.")
            if let backup { print("Backup: \(backup.path)") }
        } catch StatusLineInstaller.InstallError.notInstalled {
            print("The status line is not installed. No changes made.")
        }
    }
}

CLI.main()
