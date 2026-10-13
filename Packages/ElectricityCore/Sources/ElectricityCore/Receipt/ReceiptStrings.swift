import Foundation

/// Receipt text in Simplified Chinese and English (appendix R10). The receipt is rendered for export and
/// printing in a fixed language, so its text lives here rather than in the app's String Catalog.
public struct ReceiptStrings: Sendable {
    public let language: CLILanguageCode

    public init(_ language: CLILanguageCode) {
        self.language = language
    }

    public var report: ReportStrings { ReportStrings(language) }

    public func callAsFunction(_ key: Key) -> String {
        language == .zh ? key.chinese : key.english
    }

    public enum Key: Sendable, Hashable {
        case subtitle, customer, serial, kind, period, timeZone, printed, cashier
        case item, tokens, energyWh, others(Int)
        case tokenMix, input, output, cacheWrite, cacheRead, cacheNote
        case energySubtotal, range, carbon, basis, basisGridAverage, cleanliness, cleanShare(Int)
        case dailyEnergy, monthlyEnergy, peakDay(String)
        case equivalents, noUsageToday, noUsagePeriod
        case total, disclaimer, methodHint, foodNote, thanks

        var english: String {
            switch self {
            case .subtitle: "AI POWER RECEIPT"
            case .customer: "FOR"
            case .serial: "No."
            case .kind: "Type"
            case .period: "Period"
            case .timeZone: "Zone"
            case .printed: "Printed"
            case .cashier: "Cashier"
            case .item: "Item"
            case .tokens: "Tokens"
            case .energyWh: "Wh"
            case .others(let count): count == 1 ? "1 other" : "\(count) others"
            case .tokenMix: "Token mix"
            case .input: "Input"
            case .output: "Output"
            case .cacheWrite: "Cache wr."
            case .cacheRead: "Cache rd."
            case .cacheNote: "Cache reads weigh less in the energy estimate."
            case .energySubtotal: "Energy"
            case .range: "Range"
            case .carbon: "CO2"
            case .basis: "Basis"
            case .basisGridAverage: "Grid average"
            case .cleanliness: "Grid"
            case .cleanShare(let percent): "\(percent)% clean"
            case .dailyEnergy: "Energy by day"
            case .monthlyEnergy: "Energy by month"
            case .peakDay(let value): "Peak \(value)"
            case .equivalents: "Equivalent to"
            case .noUsageToday: "No energy used today yet"
            case .noUsagePeriod: "No energy used in this period"
            case .total: "TOTAL"
            case .disclaimer: "Estimates only. Not a proof of purchase."
            case .methodHint: "Method: Dashboard > About > Methodology"
            case .foodNote: "Food items compare energy content only."
            case .thanks: "THANK YOU"
            }
        }

        var chinese: String {
            switch self {
            case .subtitle: "本机 AI 用电小票"
            case .customer: "顾客"
            case .serial: "单号"
            case .kind: "类型"
            case .period: "时段"
            case .timeZone: "时区"
            case .printed: "打印"
            case .cashier: "收银员"
            case .item: "项目"
            case .tokens: "Tokens"
            case .energyWh: "电量 Wh"
            case .others(let count): "其他 \(count) 项"
            case .tokenMix: "Token 构成"
            case .input: "输入"
            case .output: "输出"
            case .cacheWrite: "缓存写"
            case .cacheRead: "缓存读"
            case .cacheNote: "缓存读取的耗电权重较低"
            case .energySubtotal: "电量小计"
            case .range: "估算区间"
            case .carbon: "CO2"
            case .basis: "口径"
            case .basisGridAverage: "电网平均"
            case .cleanliness: "洁净度"
            case .cleanShare(let percent): "清洁电力 \(percent)%"
            case .dailyEnergy: "每日用电"
            case .monthlyEnergy: "每月用电"
            case .peakDay(let value): "最高 \(value)"
            case .equivalents: "相当于"
            case .noUsageToday: "今天还没有用电"
            case .noUsagePeriod: "这段时间还没有用电"
            case .total: "合计"
            case .disclaimer: "本单据为估算值，不作报销凭证"
            case .methodHint: "计算方法见 操作台 > 关于 > 方法说明"
            case .foodNote: "食物项比较的是热量本身"
            case .thanks: "谢谢惠顾"
            }
        }
    }
}
