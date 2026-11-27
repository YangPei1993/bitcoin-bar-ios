import BackgroundTasks
import SwiftUI
import UserNotifications

// MARK: - iOS 应用全局容器

@MainActor
@Observable
final class AppContainer {
    static let refreshTaskID = "com.paul.bitcoin-bar-ios.refresh"

    let settings = AppSettings()
    let hub = MarketQuoteHub()
    let watchlist = WatchlistStore()
    let dispatcher = NotificationDispatcher()
    let aiCache = AIAnalysisCache()

    private(set) var tickerStore: CryptoTickerStore!
    private(set) var alertStore: PriceAlertStore!
    private(set) var portfolioStore: PortfolioStore!
    private(set) var tradingStore: OKXTradingStore!
    private(set) var riskEngine: RiskMonitorEngine!
    private(set) var liveActivity: LiveActivityManager!

    var selectedTab = 0
    var marketPath: [CryptoAsset] = []
    var portfolioPath: [CryptoAsset] = []
    var toastMessage: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        self.tickerStore = CryptoTickerStore(hub: hub)
        self.alertStore = PriceAlertStore(hub: hub, dispatcher: dispatcher)
        self.portfolioStore = PortfolioStore(dispatcher: dispatcher)
        self.tradingStore = OKXTradingStore(portfolio: portfolioStore)
        self.riskEngine = RiskMonitorEngine(hub: hub, watchlist: watchlist, portfolio: portfolioStore, dispatcher: dispatcher)
        self.liveActivity = LiveActivityManager(hub: hub, portfolio: portfolioStore, riskEngine: riskEngine, settings: settings)

        bindCallbacks()
        registerLiveActivityRefreshBridge()
        hub.start()
    }

    private func registerLiveActivityRefreshBridge() {
        LiveActivityRefreshBridge.asyncHandler = { [weak self] in
            guard let self else { return }
            self.liveActivity.ensureSyncedOnForeground()
            await self.hub.refreshNow()
            if self.portfolioStore.enabledAccounts.isEmpty == false {
                await self.portfolioStore.refreshAll()
            }
            await self.liveActivity.pushUpdateNow()
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard Task.isCancelled == false else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self?.toastMessage = nil
            }
        }
    }

    func openAssetDetail(_ asset: CryptoAsset) {
        selectedTab = 0
        marketPath = [asset]
    }

    func handleBackgroundRefresh() async {
        await hub.refreshNow()
        if portfolioStore.enabledAccounts.isEmpty == false {
            await portfolioStore.refreshAll()
        }
        await liveActivity.pushUpdateNow()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func bindCallbacks() {
        settings.onLiveActivityConfigChanged = { [weak self] in
            self?.liveActivity.syncConfigAndUpdate()
        }

        watchlist.onFavoritesChanged = { [weak self] _ in
            self?.riskEngine.syncVolatilityDemand()
        }

        dispatcher.onDisplayToast = { [weak self] payload in
            self?.showToast("\(payload.severity.emoji) \(payload.title)")
        }

        portfolioStore.onSnapshotsUpdated = { [weak self] in
            guard let self else { return }
            self.riskEngine.evaluatePortfolioRisks()
            self.riskEngine.syncVolatilityDemand()
            self.liveActivity.scheduleUpdate(immediate: true)
        }

        portfolioStore.setExternalRiskMonitoringEnabled(riskEngine.config.hasPortfolioRiskRuleEnabled)
        riskEngine.onConfigChanged = { [weak self] config in
            self?.portfolioStore.setExternalRiskMonitoringEnabled(config.hasPortfolioRiskRuleEnabled)
        }

        tradingStore.onTradeExecuted = { [weak self] in
            await self?.liveActivity.pushUpdateNow()
        }
    }
}

// MARK: - 通知代理

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    let onSelectRoute: @Sendable (String?, Bool) -> Void

    init(onSelectRoute: @escaping @Sendable (String?, Bool) -> Void) {
        self.onSelectRoute = onSelectRoute
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let assetID = info["assetID"] as? String
        let openPortfolio = (info["openTab"] as? String) == "portfolio"
        onSelectRoute(assetID, openPortfolio)
    }
}

// MARK: - 应用主入口

@main
struct BitcoinBarIOSApp: App {
    @State private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    private let notificationDelegate: NotificationDelegate

    init() {
        let stateContainer = AppContainer()
        _container = State(initialValue: stateContainer)

        let delegate = NotificationDelegate { assetID, openPortfolio in
            Task { @MainActor in
                if openPortfolio {
                    stateContainer.selectedTab = 1
                } else if let assetID {
                    let asset = stateContainer.watchlist.favoriteAssets.first(where: { $0.id == assetID })
                        ?? stateContainer.tickerStore.featuredSpotAssets.first(where: { $0.id == assetID })
                        ?? CryptoAsset(id: assetID, symbol: String(assetID.split(separator: "-").first ?? "BTC"), name: assetID, instrumentKind: assetID.contains("SWAP") ? .swap : .spot)
                    stateContainer.openAssetDetail(asset)
                }
            }
        }
        self.notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate

        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppContainer.refreshTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                stateContainer.scheduleBackgroundRefresh()
                await stateContainer.handleBackgroundRefresh()
                refreshTask.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(container: container)
                .preferredColorScheme(container.settings.appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        container.liveActivity.ensureSyncedOnForeground()
                        container.hub.reconnectNow()
                        Task {
                            if container.portfolioStore.enabledAccounts.isEmpty == false {
                                await container.portfolioStore.refreshAll()
                            }
                            await container.liveActivity.pushUpdateNow()
                        }
                    case .background:
                        container.liveActivity.beginBackgroundKeepAlive()
                        container.scheduleBackgroundRefresh()
                    default:
                        break
                    }
                }
        }
    }
}

// MARK: - 4 Tab 主框架

private struct RootTabView: View {
    @Bindable var container: AppContainer
    @State private var settingsPath = NavigationPath()

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $container.selectedTab) {
                // Tab 1: 行情
                NavigationStack(path: $container.marketPath) {
                    MarketListView(
                        hub: container.hub,
                        tickerStore: container.tickerStore,
                        watchlist: container.watchlist,
                        alertStore: container.alertStore,
                        liveActivity: container.liveActivity,
                        settings: container.settings,
                        onSelectAsset: { container.marketPath.append($0) },
                        onShowToast: { container.showToast($0) }
                    )
                    .navigationDestination(for: CryptoAsset.self) { asset in
                        assetDetailView(for: asset)
                    }
                }
                .tabItem { Label("行情", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(0)

                // Tab 2: 资产与仓位
                NavigationStack(path: $container.portfolioPath) {
                    PortfolioView(
                        portfolio: container.portfolioStore,
                        tradingStore: container.tradingStore,
                        riskEngine: container.riskEngine,
                        liveActivity: container.liveActivity,
                        settings: container.settings,
                        onOpenAccountSettings: {
                            container.selectedTab = 3
                        },
                        onSelectPositionAsset: { asset in
                            container.portfolioPath.append(asset)
                        },
                        onShowToast: { container.showToast($0) }
                    )
                    .navigationDestination(for: CryptoAsset.self) { asset in
                        assetDetailView(for: asset)
                    }
                }
                .tabItem { Label("资产", systemImage: "wallet.bifold") }
                .badge(container.riskEngine.activePortfolioRisks.count)
                .tag(1)

                // Tab 3: 风控与提醒
                NavigationStack {
                    RiskCenterView(
                        riskEngine: container.riskEngine,
                        alertStore: container.alertStore,
                        portfolioStore: container.portfolioStore,
                        dispatcher: container.dispatcher,
                        settings: container.settings,
                        onOpenChannels: {
                            container.selectedTab = 3
                        }
                    )
                }
                .tabItem { Label("风控", systemImage: "shield.lefthalf.filled") }
                .badge(container.alertStore.activeAlertCount + container.portfolioStore.activeBalanceAlertCount)
                .tag(2)

                // Tab 4: 设置
                NavigationStack(path: $settingsPath) {
                    SettingsView(
                        settings: container.settings,
                        hub: container.hub,
                        watchlist: container.watchlist,
                        tickerStore: container.tickerStore,
                        portfolioStore: container.portfolioStore,
                        tradingStore: container.tradingStore,
                        dispatcher: container.dispatcher,
                        liveActivity: container.liveActivity,
                        onShowToast: { container.showToast($0) }
                    )
                }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
            }

            if let toast = container.toastMessage {
                Text(toast)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.84), in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: container.toastMessage)
    }

    @ViewBuilder
    private func assetDetailView(for asset: CryptoAsset) -> some View {
        AssetDetailView(
            asset: asset,
            hub: container.hub,
            tickerStore: container.tickerStore,
            watchlist: container.watchlist,
            alertStore: container.alertStore,
            tradingStore: container.tradingStore,
            liveActivity: container.liveActivity,
            settings: container.settings,
            aiCache: container.aiCache,
            onOpenAISettings: {
                container.selectedTab = 3
            },
            onOpenTradingSettings: {
                container.selectedTab = 3
            },
            onShowToast: { container.showToast($0) }
        )
    }
}
