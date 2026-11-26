import ActivityKit
import Foundation
import UIKit

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
    @ObservationIgnored private var stateObserverTask: Task<Void, Never>?
    @ObservationIgnored private var throttleTask: Task<Void, Never>?
    @ObservationIgnored private var bgExtendTask: Task<Void, Never>?
    @ObservationIgnored private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
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

        // 监听 hub 批量提交完成（此时 hub.quotes 已更新为最新价格）
        hub.addBatchObserver { [weak self] updatedIDs in
            guard let self, self.isActive else { return }
            let watchedIDs = Set(self.settings.liveActivityAssets.map(\.id))
            if updatedIDs.isDisjoint(with: watchedIDs) == false {
                self.scheduleUpdate()
            }
        }
    }

    var areActivitiesEnabledBySystem: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: 启动 / 关闭 / 刷新

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

        Task { await startAsync() }
    }

    private func startAsync() async {
        // 先干净结束已有旧活动，避免新旧实况活动并发竞争
        stateObserverTask?.cancel()
        stateObserverTask = nil
        for old in Activity<TickerActivityAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }

        hub.setDemand(settings.liveActivityAssets, for: "live_activity")
        portfolio.setLiveActivityActive(true)

        let attributes = TickerActivityAttributes(title: "bitcoin-bar")
        let initialState = buildContentState()

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            isActive = true
            statusMessage = nil
            lastPushTime = Date()
            observeState(of: activity)

            // 启动后立即并发拉取最新价格与账户余额并推送上岛
            await hub.refreshNow()
            if portfolio.enabledAccounts.isEmpty == false {
                await portfolio.refreshAll()
            }
            await pushUpdateNow()
        } catch {
            isActive = false
            statusMessage = "启动灵动岛失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        throttleTask?.cancel()
        throttleTask = nil
        stateObserverTask?.cancel()
        stateObserverTask = nil
        endBackgroundKeepAlive()

        let activities = Activity<TickerActivityAttributes>.activities
        currentActivity = nil
        isActive = false
        hub.setDemand([], for: "live_activity")
        portfolio.setLiveActivityActive(false)

        for activity in activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
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
        // .active 与 .stale 均为可更新的存活状态，仅排除 .ended / .dismissed
        let updatable: Activity<TickerActivityAttributes>? = {
            if let current = currentActivity, isUpdatable(current) {
                return current
            }
            return Activity<TickerActivityAttributes>.activities.first(where: { isUpdatable($0) })
        }()

        guard let activity = updatable else {
            isActive = false
            currentActivity = nil
            return
        }

        currentActivity = activity
        isActive = true
        lastPushTime = Date()
        let state = buildContentState()
        await activity.update(.init(state: state, staleDate: nil))
    }

    /// 锁屏解锁回到前台时恢复订阅与灵动岛绑定
    func ensureSyncedOnForeground() {
        endBackgroundKeepAlive()
        throttleTask?.cancel()
        throttleTask = nil

        if let existing = Activity<TickerActivityAttributes>.activities.first(where: { isUpdatable($0) }) {
            currentActivity = existing
            isActive = true
            hub.setDemand(settings.liveActivityAssets, for: "live_activity")
            portfolio.setLiveActivityActive(true)
            observeState(of: existing)
        } else {
            currentActivity = nil
            isActive = false
        }
    }

    private func isUpdatable(_ activity: Activity<TickerActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    // MARK: 退后台短时续命（切回主屏幕 / 锁屏后约 25 秒内仍持续实时刷新灵动岛）

    func beginBackgroundKeepAlive() {
        guard isActive else { return }
        endBackgroundKeepAlive()

        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "LiveActivityRefresh") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundKeepAlive()
            }
        }

        guard bgTaskID != .invalid else { return }
        bgExtendTask = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(3))
                guard Task.isCancelled == false, let self, self.isActive else { break }
                await self.hub.refreshNow()
                if self.portfolio.enabledAccounts.isEmpty == false {
                    await self.portfolio.refreshAll()
                }
                await self.pushUpdateNow()
            }
            self?.endBackgroundKeepAlive()
        }
    }

    func endBackgroundKeepAlive() {
        bgExtendTask?.cancel()
        bgExtendTask = nil
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }

    // MARK: 状态恢复与监听

    private func restoreExistingActivityIfAny() {
        if let existing = Activity<TickerActivityAttributes>.activities.first(where: { isUpdatable($0) }) {
            currentActivity = existing
            isActive = true
            hub.setDemand(settings.liveActivityAssets, for: "live_activity")
            portfolio.setLiveActivityActive(true)
            observeState(of: existing)
            scheduleUpdate(immediate: true)
        }
    }

    private func observeState(of activity: Activity<TickerActivityAttributes>) {
        stateObserverTask?.cancel()
        stateObserverTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard Task.isCancelled == false, let self else { return }
                if state == .ended || state == .dismissed {
                    self.currentActivity = nil
                    self.isActive = false
                    self.hub.setDemand([], for: "live_activity")
                    self.portfolio.setLiveActivityActive(false)
                    return
                }
            }
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
