import Foundation

// MARK: - 风控重复提醒策略

nonisolated enum RiskRepeatPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case onceUntilCleared
    case every30Minutes
    case every1Hour
    case every4Hours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onceUntilCleared: return "仅首次及显著恶化时提醒（防刷屏）"
        case .every30Minutes: return "每 30 分钟重复提醒"
        case .every1Hour: return "每 1 小时重复提醒"
        case .every4Hours: return "每 4 小时重复提醒"
        }
    }

    var repeatIntervalSeconds: TimeInterval? {
        switch self {
        case .onceUntilCleared: return nil
        case .every30Minutes: return 1800
        case .every1Hour: return 3600
        case .every4Hours: return 14400
        }
    }
}

// MARK: - 风控规则配置

nonisolated struct RiskAlertConfig: Equatable, Codable, Sendable {
    /// 强平距离预警（|标记价 - 强平价| / 标记价）
    var liquidationEnabled = true
    var liquidationWarningPercent: Double = 10.0
    var liquidationCriticalPercent: Double = 5.0

    /// 单仓浮亏 / ROE 预警
    var positionLossEnabled = true
    /// 亏损收益率百分比绝对值（如 25 表示 ROE <= -25%）
    var positionLossROEPercent: Double = 25.0
    /// 单仓浮亏金额阈值（USD，0 表示不启用金额阈值）
    var positionLossUSD: Double = 0

    /// 账户当日净值回撤预警
    var drawdownEnabled = true
    var drawdownThresholdPercent: Double = 8.0

    /// 短时剧烈异动 / 插针预警（针对自选与持仓币种）
    var volatilityEnabled = true
    var volatilityWindowMinutes: Int = 5
    var volatilityThresholdPercent: Double = 3.0

    /// 同类持续风险的重复提醒策略（默认仅首次触发 + 恶化再报，避免刷屏）
    var repeatPolicy: RiskRepeatPolicy = .onceUntilCleared

    var hasPortfolioRiskRuleEnabled: Bool {
        liquidationEnabled || positionLossEnabled || drawdownEnabled
    }
}

nonisolated struct ActiveRiskWarning: Identifiable, Equatable, Sendable {
    let id: String
    let severity: AlertSeverity
    let title: String
    let detail: String
}

// MARK: - 主动风控预警引擎

@MainActor
@Observable
final class RiskMonitorEngine {
    private enum Keys {
        static let config = "RiskMonitorEngine.config"
        static let dailyPeakDate = "RiskMonitorEngine.dailyPeakDate"
        static let dailyPeakEquity = "RiskMonitorEngine.dailyPeakEquity"
        static let dailyPeakAccounts = "RiskMonitorEngine.dailyPeakAccounts"
    }

    private struct TriggerRecord {
        let triggeredAt: Date
        /// 触发时的风险严重度指标（如强平距离越小越严峻，浮亏 ROE 越负越严峻）
        let metricValue: Double
    }

    private struct PriceSample {
        let time: Date
        let price: Double
        let source: QuoteSource
    }

    var config: RiskAlertConfig {
        didSet {
            persistConfig()
            onConfigChanged?(config)
            syncVolatilityDemand()
            evaluatePortfolioRisks()
        }
    }

    /// 当前仍处于风险状态的活跃预警（用于在资产页醒目高亮展示）
    private(set) var activePortfolioRisks: [ActiveRiskWarning] = []
    /// 今日记录的账户总净值峰值（用于回撤计算与展示）
    private(set) var dailyPeakEquityUSD: Double = 0

    @ObservationIgnored private let hub: MarketQuoteHub
    @ObservationIgnored private let watchlist: WatchlistStore
    @ObservationIgnored private let portfolio: PortfolioStore
    @ObservationIgnored private let dispatcher: NotificationDispatcher

    /// 触发记录表：key -> 上次触发时间与触发时指标
    @ObservationIgnored private var records: [String: TriggerRecord] = [:]
    /// 短时异动价格采样窗口：assetID -> [PriceSample]
    @ObservationIgnored private var priceSamples: [String: [PriceSample]] = [:]
    @ObservationIgnored private var dailyPeakAccountsSignature = ""
    @ObservationIgnored var onConfigChanged: ((RiskAlertConfig) -> Void)?

    init(
        hub: MarketQuoteHub,
        watchlist: WatchlistStore,
        portfolio: PortfolioStore,
        dispatcher: NotificationDispatcher
    ) {
        self.hub = hub
        self.watchlist = watchlist
        self.portfolio = portfolio
        self.dispatcher = dispatcher

        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.config),
           let decoded = try? JSONDecoder().decode(RiskAlertConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = RiskAlertConfig()
        }

        let today = Self.dayStamp(Date())
        if defaults.string(forKey: Keys.dailyPeakDate) == today {
            self.dailyPeakEquityUSD = defaults.double(forKey: Keys.dailyPeakEquity)
            self.dailyPeakAccountsSignature = defaults.string(forKey: Keys.dailyPeakAccounts) ?? ""
        }

        hub.addListener { [weak self] assetID, quote in
            self?.handleLivePriceForVolatility(assetID: assetID, quote: quote)
        }

        syncVolatilityDemand()
    }

    /// 当开启短时异动监控时，持续向行情中枢注册自选与持仓币种
    func syncVolatilityDemand() {
        guard config.volatilityEnabled else {
            hub.setDemand([], for: "volatility")
            return
        }
        var targets = watchlist.favoriteAssets
        for position in portfolio.positions() {
            if targets.contains(position.marketAsset) == false {
                targets.append(position.marketAsset)
            }
        }
        hub.setDemand(Array(targets.prefix(20)), for: "volatility")
    }

    /// 计算单个仓位距离强平价的百分比（返回 nil 表示无强平价）
    nonisolated static func liquidationDistancePercent(for position: AccountPositionItem) -> Double? {
        guard let liq = position.liquidationPrice, liq > 0, position.markPrice > 0 else { return nil }
        return abs(position.markPrice - liq) / position.markPrice * 100
    }

    // MARK: 1. 仓位与账户风控评估

    func evaluatePortfolioRisks() {
        var warnings: [ActiveRiskWarning] = []
        var activeKeys = Set<String>()
        let positions = portfolio.positions()

        // A. 强平距离预警 & B. 单仓浮亏预警
        for position in positions {
            if config.liquidationEnabled,
               let distance = Self.liquidationDistancePercent(for: position) {
                let critLimit = min(config.liquidationCriticalPercent, config.liquidationWarningPercent)
                let warnLimit = max(config.liquidationWarningPercent, critLimit)

                if distance <= critLimit {
                    let key = "liq-crit-\(position.id)"
                    activeKeys.insert(key)
                    let title = "\(position.displayPair) \(position.side.label)单距强平仅 \(String(format: "%.1f", distance))%"
                    let detail = "\(position.exchange.shortLabel) 标记价 \(MarketFormatter.price(position.markPrice))，预估强平 \(MarketFormatter.price(position.liquidationPrice ?? 0))，请立即关注保证金！"
                    warnings.append(ActiveRiskWarning(id: key, severity: .critical, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        metricValue: -distance,
                        worsenDelta: 1.5, // 距强平再缩近 1.5% 视为显著恶化
                        severity: .critical,
                        category: "强平极危预警",
                        title: title,
                        body: detail,
                        assetID: position.marketAsset.id,
                        openPortfolio: true
                    )
                } else if distance <= warnLimit {
                    let key = "liq-warn-\(position.id)"
                    activeKeys.insert(key)
                    let title = "\(position.displayPair) \(position.side.label)单距强平 \(String(format: "%.1f", distance))%"
                    let detail = "\(position.exchange.shortLabel) 标记价 \(MarketFormatter.price(position.markPrice))，预估强平 \(MarketFormatter.price(position.liquidationPrice ?? 0))。"
                    warnings.append(ActiveRiskWarning(id: key, severity: .warning, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        metricValue: -distance,
                        worsenDelta: 2.0,
                        severity: .warning,
                        category: "强平距离预警",
                        title: title,
                        body: detail,
                        assetID: position.marketAsset.id,
                        openPortfolio: true
                    )
                }
            }

            if config.positionLossEnabled {
                let roeBreached = config.positionLossROEPercent > 0 && position.roePercent <= -config.positionLossROEPercent
                let usdBreached = config.positionLossUSD > 0 && position.unrealizedPnL <= -config.positionLossUSD

                if roeBreached || usdBreached {
                    let key = "loss-\(position.id)"
                    activeKeys.insert(key)
                    let title = "\(position.displayPair) \(position.side.label)单浮亏 \(MarketFormatter.changeAmount(position.unrealizedPnL)) (\(MarketFormatter.changePercent(position.roePercent)))"
                    let detail = "\(position.exchange.shortLabel) · \(position.accountName)，开仓价 \(MarketFormatter.price(position.entryPrice))，现标记价 \(MarketFormatter.price(position.markPrice))。"
                    warnings.append(ActiveRiskWarning(id: key, severity: .warning, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        metricValue: abs(position.roePercent),
                        worsenDelta: 25.0, // 浮亏 ROE 再恶化 25% 才再次提醒
                        severity: .warning,
                        category: "单仓浮亏预警",
                        title: title,
                        body: detail,
                        assetID: position.marketAsset.id,
                        openPortfolio: true
                    )
                }
            }
        }

        // C. 账户当日净值回撤预警
        if config.drawdownEnabled,
           portfolio.enabledAccounts.isEmpty == false,
           portfolio.enabledAccounts.allSatisfy({ portfolio.snapshots[$0.id] != nil }) {
            let currentEquity = portfolio.totalEquityUSD()
            updateDailyPeakIfNeeded(currentEquity: currentEquity)

            if dailyPeakEquityUSD > 10, currentEquity > 0 {
                let drawdownPct = (dailyPeakEquityUSD - currentEquity) / dailyPeakEquityUSD * 100
                if drawdownPct >= config.drawdownThresholdPercent {
                    let key = "drawdown-daily"
                    activeKeys.insert(key)
                    let title = "账户当日净值回撤 \(String(format: "%.1f", drawdownPct))%"
                    let detail = "今日峰值 \(MarketFormatter.price(dailyPeakEquityUSD))，当前总净值 \(MarketFormatter.price(currentEquity))，注意控制仓位风险。"
                    warnings.append(ActiveRiskWarning(id: key, severity: .critical, title: title, detail: detail))
                    fireIfAllowed(
                        key: key,
                        metricValue: drawdownPct,
                        worsenDelta: 5.0, // 回撤再扩大 5% 才再次提醒
                        severity: .critical,
                        category: "净值回撤预警",
                        title: title,
                        body: detail,
                        assetID: nil,
                        openPortfolio: true
                    )
                }
            }
        }

        // 仅当全部已启用账户均正常同步无报错时，才解除已恢复仓位的静默记录，防止网络抖动导致误重推
        if portfolio.accountErrors.isEmpty {
            for existingKey in records.keys where existingKey.hasPrefix("vol-") == false {
                if activeKeys.contains(existingKey) == false {
                    records.removeValue(forKey: existingKey)
                }
            }
        }

        activePortfolioRisks = warnings.sorted { $0.severity > $1.severity }
    }

    func resetDailyPeak() {
        let current = portfolio.totalEquityUSD()
        let sig = enabledAccountsSignature
        dailyPeakEquityUSD = current
        dailyPeakAccountsSignature = sig
        UserDefaults.standard.set(Self.dayStamp(Date()), forKey: Keys.dailyPeakDate)
        UserDefaults.standard.set(current, forKey: Keys.dailyPeakEquity)
        UserDefaults.standard.set(sig, forKey: Keys.dailyPeakAccounts)
        records.removeValue(forKey: "drawdown-daily")
        evaluatePortfolioRisks()
    }

    // MARK: 2. 短时剧烈异动 / 插针监测

    private func handleLivePriceForVolatility(assetID: String, quote: CryptoQuote) {
        guard config.volatilityEnabled, quote.price > 0 else { return }

        let watchedIDs = Set(watchlist.favoriteAssets.map(\.id))
            .union(portfolio.positions().map(\.marketAsset.id))
        guard watchedIDs.contains(assetID) else { return }

        let now = Date()
        let windowSeconds = TimeInterval(max(config.volatilityWindowMinutes, 1) * 60)
        var history = priceSamples[assetID] ?? []

        // 严格同源比较：若数据源在 OKX 与 Gate 之间切换，重置窗口避免跨源面值差异误报
        if let last = history.last, last.source != quote.source {
            priceSamples[assetID] = [PriceSample(time: now, price: quote.price, source: quote.source)]
            return
        }

        // 防异常断层脏数据：相邻采样在 30 秒内单步跳变超 35% 视为异常源切换/面值噪音，重置不误报
        if let last = history.last, last.price > 0 {
            let stepJump = abs(quote.price - last.price) / last.price * 100
            if now.timeIntervalSince(last.time) < 30 && stepJump >= 35.0 {
                priceSamples[assetID] = [PriceSample(time: now, price: quote.price, source: quote.source)]
                return
            }
        }

        if let last = history.last, now.timeIntervalSince(last.time) < 5 {
            // 降频采样，保持极低内存占用
        } else {
            history.append(PriceSample(time: now, price: quote.price, source: quote.source))
        }

        let cutoff = now.addingTimeInterval(-windowSeconds)
        history.removeAll { $0.time < cutoff }
        priceSamples[assetID] = history

        guard let oldest = history.first,
              oldest.price > 0,
              now.timeIntervalSince(oldest.time) >= 20 else { return }

        let changePct = (quote.price - oldest.price) / oldest.price * 100
        guard abs(changePct) >= config.volatilityThresholdPercent else { return }

        let key = "vol-\(assetID)"
        // 异动提醒固定至少冷却 15 分钟，避免剧烈波动期连续刷屏
        if let prev = records[key], now.timeIntervalSince(prev.triggeredAt) < 900 {
            return
        }

        let directionWord = changePct > 0 ? "急速拉升" : "快速下挫"
        let symbol = assetID.split(separator: "-").first.map(String.init) ?? assetID
        let title = "\(symbol) \(config.volatilityWindowMinutes)分钟\(directionWord) \(MarketFormatter.changePercent(changePct))"
        let body = "\(assetID) 现价 \(MarketFormatter.price(quote.price))（\(config.volatilityWindowMinutes) 分钟前 \(MarketFormatter.price(oldest.price))）"

        records[key] = TriggerRecord(triggeredAt: now, metricValue: abs(changePct))
        dispatcher.dispatch(
            AlertPayload(
                severity: .warning,
                category: "短时异动提醒",
                title: title,
                body: body,
                assetID: assetID,
                openPortfolio: false
            )
        )
    }

    // MARK: 防刷屏判定逻辑

    private var enabledAccountsSignature: String {
        portfolio.enabledAccounts.map(\.id.uuidString).sorted().joined(separator: ",")
    }

    private func updateDailyPeakIfNeeded(currentEquity: Double) {
        let today = Self.dayStamp(Date())
        let sig = enabledAccountsSignature
        let defaults = UserDefaults.standard

        // 跨日、或启用账户集合发生变化（增删/开关账户）时自动重新校准今日峰值，避免假回撤告警
        if defaults.string(forKey: Keys.dailyPeakDate) != today || dailyPeakAccountsSignature != sig {
            dailyPeakEquityUSD = currentEquity
            dailyPeakAccountsSignature = sig
            defaults.set(today, forKey: Keys.dailyPeakDate)
            defaults.set(currentEquity, forKey: Keys.dailyPeakEquity)
            defaults.set(sig, forKey: Keys.dailyPeakAccounts)
            records.removeValue(forKey: "drawdown-daily")
        } else if currentEquity > dailyPeakEquityUSD {
            dailyPeakEquityUSD = currentEquity
            defaults.set(currentEquity, forKey: Keys.dailyPeakEquity)
        }
    }

    private func fireIfAllowed(
        key: String,
        metricValue: Double,
        worsenDelta: Double,
        severity: AlertSeverity,
        category: String,
        title: String,
        body: String,
        assetID: String?,
        openPortfolio: Bool
    ) {
        let now = Date()

        if let prev = records[key] {
            let elapsed = now.timeIntervalSince(prev.triggeredAt)
            // 任何同类风险至少间隔 5 分钟，杜绝抖动连发
            guard elapsed >= 300 else { return }

            let significantlyWorsened = (metricValue - prev.metricValue) >= worsenDelta
            let repeatIntervalReached: Bool
            if let repeatSeconds = config.repeatPolicy.repeatIntervalSeconds {
                repeatIntervalReached = elapsed >= repeatSeconds
            } else {
                repeatIntervalReached = false
            }

            guard significantlyWorsened || repeatIntervalReached else {
                return
            }
        }

        records[key] = TriggerRecord(triggeredAt: now, metricValue: metricValue)
        dispatcher.dispatch(
            AlertPayload(
                severity: severity,
                category: category,
                title: title,
                body: body,
                assetID: assetID,
                openPortfolio: openPortfolio
            )
        )
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Keys.config)
        }
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
