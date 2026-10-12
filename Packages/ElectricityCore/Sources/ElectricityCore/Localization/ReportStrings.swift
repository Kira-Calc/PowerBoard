import Foundation

/// Report and CLI text in English and Simplified Chinese. The app uses its String Catalog;
/// this small table serves the CLI and text exports, which do not run inside the app bundle.
public struct ReportStrings: Sendable {
    public let language: CLILanguageCode

    public init(_ language: CLILanguageCode) {
        self.language = language
    }

    public var locale: Locale { Locale(identifier: language == .zh ? "zh-Hans" : "en") }

    public func callAsFunction(_ key: Key) -> String {
        switch language {
        case .en: key.english
        case .zh: key.chinese
        }
    }

    public enum Key: Sendable {
        case title(ReportPeriod)
        case summary, energy, range, carbon, tokens, input, output, cacheWrite, cacheRead
        case comparedWithPrevious, noPrevious, byTool, byModel, byProject, peak, sessions
        case tool, model, project, confidence, energyColumn, carbonColumn, tokensColumn
        case noUsage, hiddenProject, unknownProject, method, footer
        case gridBasis(String), factorVersion(String)
        case trend, about, generated(String), headline, previousPeriod
        case rollingTitle(ReportPeriod)
        case energyChart, energyCumulative, tokenChart, tokenCumulative
        case energyMix, cleanShare, mixBasisPeriod, mixBasisRecent, byGridLevel, unrecordedLevel
        case fuel(FuelGroup), gridLevel(GridLevel)

        var english: String {
            switch self {
            case .title(let period):
                switch period {
                case .day: "Daily report"
                case .week: "Weekly report"
                case .month: "Monthly report"
                case .year: "Yearly report"
                }
            case .summary: "Summary"
            case .energy: "AI inference energy (server-side, estimated)"
            case .range: "Range"
            case .carbon: "Carbon"
            case .tokens: "Tokens"
            case .input: "Input"
            case .output: "Output"
            case .cacheWrite: "Cache write"
            case .cacheRead: "Cache read"
            case .comparedWithPrevious: "vs. previous period"
            case .noPrevious: "No usage in the previous period"
            case .byTool: "By tool"
            case .byModel: "By model"
            case .byProject: "By project"
            case .peak: "Busiest time"
            case .sessions: "Conversations"
            case .tool: "Tool"
            case .model: "Model"
            case .project: "Project"
            case .confidence: "Confidence"
            case .energyColumn: "Energy (mid)"
            case .carbonColumn: "Carbon (mid)"
            case .tokensColumn: "Tokens"
            case .noUsage: "No usage in this period."
            case .hiddenProject: "Project"
            case .unknownProject: "Unknown project"
            case .method: "Method"
            case .footer: "Estimates. Method: \(AppIdentity.methodologyURL)"
            case .gridBasis(let value): "Grid carbon intensity: \(value) gCO2e/kWh, cloud provider average (AWS)."
            case .factorVersion(let value): "Energy factor version: \(value)."
            case .trend: "Trend"
            case .about: "About"
            case .generated(let value): "Generated \(value)"
            case .headline: "AI inference energy"
            case .previousPeriod: "Previous period"
            case .rollingTitle(let period):
                switch period {
                case .day: "Last 24 hours"
                case .week: "Last 7 days"
                case .month: "Last 30 days"
                case .year: "Last 12 months"
                }
            case .energyChart: "Energy"
            case .energyCumulative: "Energy, cumulative"
            case .tokenChart: "Tokens"
            case .tokenCumulative: "Tokens, cumulative"
            case .energyMix: "Energy mix (estimated)"
            case .cleanShare: "Fossil-free"
            case .mixBasisPeriod: "Generation mix of the data center regions over the same hours (US EIA), weighted by each tool's energy."
            case .mixBasisRecent: "Some hours have no published data yet, so the average mix of about the last 30 days is used for them (US EIA)."
            case .byGridLevel: "By grid level (WattTime)"
            case .unrecordedLevel: "Not recorded"
            case .fuel(let group):
                switch group {
                case .nuclear: "Nuclear"
                case .wind: "Wind"
                case .hydro: "Hydro"
                case .solar: "Solar"
                case .otherClean: "Geothermal"
                case .gas: "Natural gas"
                case .coal: "Coal"
                case .other: "Other"
                }
            case .gridLevel(let level):
                switch level {
                case .cleaner: "Cleaner"
                case .typical: "Typical"
                case .lessClean: "Less clean"
                }
            }
        }

        var chinese: String {
            switch self {
            case .title(let period):
                switch period {
                case .day: "日报"
                case .week: "周报"
                case .month: "月报"
                case .year: "年度报告"
                }
            case .summary: "汇总"
            case .energy: "AI 推理耗电（服务器端，估算）"
            case .range: "区间"
            case .carbon: "碳排"
            case .tokens: "Token"
            case .input: "输入"
            case .output: "输出"
            case .cacheWrite: "缓存写入"
            case .cacheRead: "缓存读取"
            case .comparedWithPrevious: "与上一期相比"
            case .noPrevious: "上一期没有用量"
            case .byTool: "按工具"
            case .byModel: "按模型"
            case .byProject: "按项目"
            case .peak: "用量最高的时段"
            case .sessions: "对话数"
            case .tool: "工具"
            case .model: "模型"
            case .project: "项目"
            case .confidence: "可信度"
            case .energyColumn: "电量（中值）"
            case .carbonColumn: "碳排（中值）"
            case .tokensColumn: "Token"
            case .noUsage: "这一期没有用量。"
            case .hiddenProject: "项目"
            case .unknownProject: "未知项目"
            case .method: "计算方法"
            case .footer: "估算值。方法见 \(AppIdentity.methodologyURL)"
            case .gridBasis(let value): "电网碳强度：\(value) gCO2e/kWh，云服务商电网平均值（AWS）。"
            case .factorVersion(let value): "能耗系数版本：\(value)。"
            case .trend: "趋势"
            case .about: "约"
            case .generated(let value): "生成于 \(value)"
            case .headline: "AI 推理耗电"
            case .previousPeriod: "上一期"
            case .rollingTitle(let period):
                switch period {
                case .day: "过去 24 小时"
                case .week: "过去 7 天"
                case .month: "过去 30 天"
                case .year: "过去 12 个月"
                }
            case .energyChart: "用电"
            case .energyCumulative: "累计用电"
            case .tokenChart: "Token"
            case .tokenCumulative: "累计 Token"
            case .energyMix: "能源结构（估算）"
            case .cleanShare: "清洁电力"
            case .mixBasisPeriod: "按数据中心所在地区同一时段的发电结构（美国 EIA），以各工具的用电量加权估算。"
            case .mixBasisRecent: "部分时段还没有已发布的数据，这些时段使用最近约 30 天的平均结构（美国 EIA）。"
            case .byGridLevel: "按电网等级（WattTime）"
            case .unrecordedLevel: "未记录"
            case .fuel(let group):
                switch group {
                case .nuclear: "核电"
                case .wind: "风电"
                case .hydro: "水电"
                case .solar: "太阳能"
                case .otherClean: "地热"
                case .gas: "燃气"
                case .coal: "燃煤"
                case .other: "其他"
                }
            case .gridLevel(let level):
                switch level {
                case .cleaner: "较清洁"
                case .typical: "一般"
                case .lessClean: "较不清洁"
                }
            }
        }
    }

    public func sourceName(_ source: UsageSource?) -> String {
        switch source {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case nil: "-"
        }
    }

    public func confidence(_ confidence: TierConfidence?) -> String {
        switch (confidence, language) {
        case (.measured, .en): "Measured"
        case (.measured, .zh): "实测"
        case (.extrapolated, .en): "Extrapolated"
        case (.extrapolated, .zh): "外推"
        case (.assumed, .en): "Assumed"
        case (.assumed, .zh): "假设"
        case (.unmapped, .en): "No factor"
        case (.unmapped, .zh): "无对应系数"
        case (nil, _): "-"
        }
    }

    /// "Weekly report", or "Last 7 days" for a rolling report.
    public func title(_ report: Report) -> String {
        self(report.rolling ? .rollingTitle(report.period) : .title(report.period))
    }

    /// The period of a report: the calendar label, or start and end with times for a rolling report.
    public func periodLabel(_ report: Report, calendar: Calendar = .current) -> String {
        guard report.rolling else { return periodLabel(report.period, report.interval, calendar: calendar) }
        var calendar = calendar
        calendar.locale = locale
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let style = report.period == .day || report.period == .week
            ? base.month(.abbreviated).day().hour().minute()
            : base.year().month(.abbreviated).day()
        return "\(report.interval.start.formatted(style)) – \(report.interval.end.formatted(style))"
    }

    /// "2026-10-12", "2026-10-12 to 2026-10-18", "2026-10", "2026".
    public func periodLabel(_ period: ReportPeriod, _ interval: DateInterval, calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let day = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch period {
        case .day:
            return interval.start.formatted(day)
        case .week:
            let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "\(interval.start.formatted(day)) – \(last.formatted(day))"
        case .month:
            return interval.start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).year().month(.wide))
        case .year:
            return interval.start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).year())
        }
    }
}
