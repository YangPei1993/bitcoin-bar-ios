import ActivityKit
import Foundation

// MARK: - 灵动岛 & 锁屏实时活动管理器

@MainActor
@Observable
final class LiveActivityManager {
    private(set) var isActive = false
    private(set) var statusMessage: String?

    @ObservationIgnored private let hub: MarketQuoteHub
    @ObservationIgnored private let portfolio: PortfolioStore
    @ObservationIgnored private let riskEngine: RiskMonitorEngine
    @ObservationIgnored private let settings: AppSettings

    @ObservationIgnored private var currentActivity: Activity<TickerActivityAttributes>?
    @ObservationIgnored private var throttleTask: Task<Void, Never>?
    @ObservationIgnored private var lastPushTime: Date = .distantPast
    /// 灵动岛更新最小间隔（1.5 秒，平滑实时且避免系统 ActivityKit 节流）
    private static let minUpdateInterval: TimeInterval = 1.5

    init(
        hub: MarketQuoteHub,
        portfolio: PortfolioStore,
        riskEngine: RiskMonitorEngine,
        settings: AppSettings
    ) {
        self.hub = hub
        self.portfolio = portfolio
        self.riskEngine = riskEngine
        self.settings = settings

        restoreExistingActivityIfAny()

        hub.addListener { [weak self] assetID, _ in
            guard let self, self.isActive else { return }
            if self.settings.liveActivityAssets.contains(where: { $0.id == assetID }) {
                self.scheduleUpdate()
            }
        }
    }

    var areActivitiesEnabledBySystem: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: 启动 / 关闭 / 立即刷新

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard areActivitiesEnabledBySystem else {
            statusMessage = "请在 iPhone「设置 → bitcoin-bar → 实时活动」中开启权限。"
            return
        }

        // 先结束可能残留的旧实况活动，确保灵动岛只保持 1 个干净实例
        for activity in Activity<TickerActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }

        hub.setDemand(settings.liveActivityAssets, for: "live_activity")
        portfolio.setLiveActivityActive(true)

        let attributes = TickerActivityAttributes(title: "bitcoin-bar")
        let initialState = buildContentState()

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: Date().addingTimeInterval(300)),
                pushType: nil
            )
            currentActivity = activity
            isActive = true
            statusMessage = nil
            lastPushTime = Date()

            // 启动时顺手刷新一次实时快照与账户余额
            Task {
                await hub.refreshNow()
                if portfolio.enabledAccounts.isEmpty == false {
                    await portfolio.refreshAll()
                }
                await pushUpdateNow()
            }
        } catch {
            isActive = false
            statusMessage = "启动灵动岛失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        throttleTask?.cancel()
        throttleTask = nil

        let activities = Activity<TickerActivityAttributes>.activities
        currentActivity = nil
        isActive = false
        hub.setDemand([], for: "live_activity")
        portfolio.setLiveActivityActive(false)

        for activity in activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func syncConfigAndUpdate() {
        guard isActive else { return }
        hub.setDemand(settings.liveActivityAssets, for: "live_activity")
        scheduleUpdate(immediate: true)
    }

    func scheduleUpdate(immediate: Bool = false) {
        guard isActive else { return }

        let elapsed = Date().timeIntervalSince(lastPushTime)
        if immediate || elapsed >= Self.minUpdateInterval {
            throttleTask?.cancel()
            throttleTask = nil
            Task { await pushUpdateNow() }
            return
        }

        guard throttleTask == nil else { return }
        let delay = Self.minUpdateInterval - elapsed
        throttleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false, let self else { return }
            self.throttleTask = nil
            await self.pushUpdateNow()
        }
    }

    func pushUpdateNow() async {
        guard let activity = currentActivity ?? Activity<TickerActivityAttributes>.activities.first else {
            isActive = false
            return
        }
        currentActivity = activity
        lastPushTime = Date()
        let state = buildContentState()
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(300)))
    }

    // MARK: 内部状态构造与恢复

    private func restoreExistingActivityIfAny() {
        if let existing = Activity<TickerActivityAttributes>.activities.first {
            currentActivity = existing
            isActive = true
            hub.setDemand(settings.liveActivityAssets, for: "live_activity")
            portfolio.setLiveActivityActive(true)
            scheduleUpdate(immediate: true)
        }
    }

    private func buildContentState() -> TickerActivityAttributes.ContentState {
        let watched = settings.liveActivityAssets
        let primary = settings.primaryLiveAsset
        let primaryQuote = hub.quotes[primary.id]

        let items: [LiveTickerItem] = watched.map { asset in
            let q = hub.quotes[asset.id]
            return LiveTickerItem(
                id: asset.id,
                symbol: asset.symbol,
                price: q?.price ?? 0,
                changePercentage24h: q?.changePercentage24h ?? 0,
                isContract: asset.instrumentKind != .spot
            )
        }

        let hasEquity = portfolio.enabledAccounts.isEmpty == false && portfolio.hasAnySnapshot
        let equity: Double? = hasEquity ? portfolio.totalEquityUSD() : nil
        let pnl: Double? = hasEquity ? portfolio.totalUnrealizedPnL() : nil

        let criticalRisk = riskEngine.activePortfolioRisks.first(where: { $0.severity == .critical })?.title
            ?? riskEngine.activePortfolioRisks.first?.title

        return TickerActivityAttributes.ContentState(
            primarySymbol: primary.symbol,
            primaryAssetID: primary.id,
            primaryPrice: primaryQuote?.price ?? 0,
            primaryChange24h: primaryQuote?.changePercentage24h ?? 0,
            watchedItems: items,
            totalEquityUSD: equity,
            unrealizedPnL: pnl,
            hideAmounts: portfolio.hideAmounts,
            showBalanceInCompact: settings.liveActivityShowsBalance,
            criticalRiskLabel: criticalRisk,
            isGreenUp: settings.priceColorStyle == .greenUp,
            updatedAt: Date()
        )
    }
}
