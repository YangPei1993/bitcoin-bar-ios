import ActivityKit
import AppIntents
import Foundation

// MARK: - 灵动岛 / 锁屏一键原地刷新 Intent（无需打开 App 即可刷新余额与现价）

nonisolated struct RefreshLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "刷新灵动岛行情与余额"
    static var description = IntentDescription("立即拉取最新币种现价与账户总余额并更新到灵动岛。")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            LiveActivityRefreshBridge.onTrigger?()
        }
        if let handler = await MainActor.run(body: { LiveActivityRefreshBridge.asyncHandler }) {
            await handler()
        }
        return .result()
    }
}

/// 主 App 启动时注册的刷新桥接（LiveActivityIntent 在主 App 进程内执行）
@MainActor
enum LiveActivityRefreshBridge {
    static var onTrigger: (() -> Void)?
    static var asyncHandler: (@MainActor () async -> Void)?
}

// MARK: - 灵动岛 & 锁屏实时活动共享模型（App 与 LiveActivityExtension 共享）

/// 单个灵动岛观测标的的轻量化快照
nonisolated struct LiveTickerItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let symbol: String
    let price: Double
    let changePercentage24h: Double
    let isContract: Bool
}

nonisolated struct TickerActivityAttributes: ActivityAttributes, Sendable {
    /// 静态属性：启动灵动岛时确定
    let title: String

    /// 动态状态：随实时行情与账户余额持续刷新
    struct ContentState: Codable, Hashable, Sendable {
        /// 主观测标的（灵动岛收起态左侧优先展示）
        let primarySymbol: String
        let primaryAssetID: String
        let primaryPrice: Double
        let primaryChange24h: Double

        /// 全部观测标的列表（展开态 & 锁屏横幅最多展示 3 个）
        let watchedItems: [LiveTickerItem]

        /// 账户总资产估值（USD，nil 表示未绑定或尚未同步）
        let totalEquityUSD: Double?
        /// 合约未实现总盈亏（USD）
        let unrealizedPnL: Double?
        /// 防窥隐私模式（为 true 时隐藏所有余额与盈亏金额）
        let hideAmounts: Bool
        /// 是否在灵动岛收起态右侧优先展示总余额
        let showBalanceInCompact: Bool

        /// 当前最高级别风险提示（如 "SOL 距强平 4.3%"），存在时在灵动岛高亮警示
        let criticalRiskLabel: String?
        /// 涨跌配色偏好（true = 绿涨红跌，false = 红涨绿跌）
        let isGreenUp: Bool
        /// 最近更新时间
        let updatedAt: Date
    }
}

/// 灵动岛共享的紧凑金额格式化工具（App 与 Extension 共用）
nonisolated enum LiveActivityFormatter {
    static func price(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let absVal = abs(value)
        if absVal >= 10_000 {
            return "$\(commaNumber(value, digits: 0))"
        }
        if absVal >= 100 {
            return "$\(commaNumber(value, digits: 1))"
        }
        if absVal >= 1 {
            return "$\(commaNumber(value, digits: 2))"
        }
        if absVal >= 0.01 {
            return "$\(String(format: "%.4f", value))"
        }
        return "$\(String(format: "%.6f", value))"
    }

    static func compactBalance(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let absVal = abs(value)
        if absVal >= 1_000_000 {
            return "$\(String(format: "%.2fM", value / 1_000_000))"
        }
        if absVal >= 10_000 {
            return "$\(String(format: "%.1fK", value / 1_000))"
        }
        return "$\(commaNumber(value, digits: 0))"
    }

    static func fullBalance(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return "$\(commaNumber(value, digits: 2))"
    }

    static func signedUSD(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let sign = value > 0 ? "+" : (value < 0 ? "-" : "")
        return "\(sign)$\(commaNumber(abs(value), digits: abs(value) >= 1000 ? 0 : 2))"
    }

    static func changePercent(_ value: Double, digits: Int = 2) -> String {
        guard value.isFinite else { return "--" }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.\(digits)f", value))%"
    }

    private static func commaNumber(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }
}
