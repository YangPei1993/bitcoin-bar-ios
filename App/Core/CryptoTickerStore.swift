import Foundation

// MARK: - 基础模型

nonisolated struct CryptoAsset: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let symbol: String
    let name: String
    let instrumentKind: OKXInstrumentKind

    var displaySymbol: String {
        id
    }

    /// 计价币种，如 USDT
    var quoteCurrency: String {
        let parts = id.split(separator: "-")
        return parts.count >= 2 ? String(parts[1]) : "USDT"
    }

    /// 交易对展示文案，如 BTC/USDT
    var pairLabel: String {
        "\(symbol)/\(quoteCurrency)"
    }

    /// 合约类型角标；现货返回 nil
    var kindBadge: String? {
        switch instrumentKind {
        case .spot:
            return nil
        case .swap:
            return "永续"
        case .futures:
            return "交割"
        }
    }

    var okxTradeURL: URL? {
        let lowercasedID = id.lowercased()
        switch instrumentKind {
        case .spot:
            return URL(string: "https://www.okx.com/trade-spot/\(lowercasedID)")
        case .swap:
            return URL(string: "https://www.okx.com/trade-swap/\(lowercasedID)")
        case .futures:
            return URL(string: "https://www.okx.com/trade-futures/\(lowercasedID)")
        }
    }

    // 以 id 作为唯一标识：不同数据源返回的名称可能不同，避免收藏判重失效
    static func == (lhs: CryptoAsset, rhs: CryptoAsset) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated enum AssetSearchTab: String, CaseIterable, Identifiable, Sendable {
    case spot
    case contract

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spot:
            return "现货"
        case .contract:
            return "合约"
        }
    }
}

nonisolated enum QuoteSource: String, Equatable, Sendable {
    case okx
    case gate
}

nonisolated struct CryptoQuote: Equatable, Sendable {
    let price: Double
    let changePercentage24h: Double
    let updatedAt: Date
    let high24h: Double
    let low24h: Double
    /// 24h 成交量（基础币数量）
    let volume24h: Double
    /// 24h 成交额（计价币，通常为 USDT）
    let volumeCurrency24h: Double
    /// 行情来源，用于防止跨数据源面值不同的合约（如盘前/股票永续）互相污染
    let source: QuoteSource

    init(
        price: Double,
        changePercentage24h: Double,
        updatedAt: Date,
        high24h: Double,
        low24h: Double,
        volume24h: Double,
        volumeCurrency24h: Double,
        source: QuoteSource = .okx
    ) {
        self.price = price
        self.changePercentage24h = changePercentage24h
        self.updatedAt = updatedAt
        self.high24h = high24h
        self.low24h = low24h
        self.volume24h = volume24h
        self.volumeCurrency24h = volumeCurrency24h
        self.source = source
    }

    /// 24h 涨跌额
    var changeAmount24h: Double {
        let ratio = 1 + changePercentage24h / 100
        guard ratio != 0 else { return 0 }
        return price - price / ratio
    }
}

nonisolated struct MarketEntry: Identifiable, Sendable {
    let asset: CryptoAsset
    let quote: CryptoQuote

    var id: String { asset.id }
}

nonisolated struct KlinePoint: Identifiable, Equatable, Sendable {
    let openTime: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double

    var id: Date { openTime }
}

nonisolated enum KlineInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600
    case fourHours = 14400
    case oneDay = 86400
    case oneWeek = 604800

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneMinute:
            return "1 分钟"
        case .fiveMinutes:
            return "5 分钟"
        case .fifteenMinutes:
            return "15 分钟"
        case .oneHour:
            return "1 小时"
        case .fourHours:
            return "4 小时"
        case .oneDay:
            return "日线"
        case .oneWeek:
            return "周线"
        }
    }

    var shortLabel: String {
        switch self {
        case .oneMinute:
            return "1分"
        case .fiveMinutes:
            return "5分"
        case .fifteenMinutes:
            return "15分"
        case .oneHour:
            return "1时"
        case .fourHours:
            return "4时"
        case .oneDay:
            return "日K"
        case .oneWeek:
            return "周K"
        }
    }

    var okxBar: String {
        switch self {
        case .oneMinute:
            return "1m"
        case .fiveMinutes:
            return "5m"
        case .fifteenMinutes:
            return "15m"
        case .oneHour:
            return "1H"
        case .fourHours:
            return "4H"
        case .oneDay:
            return "1D"
        case .oneWeek:
            return "1W"
        }
    }

    var gateInterval: String {
        switch self {
        case .oneMinute:
            return "1m"
        case .fiveMinutes:
            return "5m"
        case .fifteenMinutes:
            return "15m"
        case .oneHour:
            return "1h"
        case .fourHours:
            return "4h"
        case .oneDay:
            return "1d"
        case .oneWeek:
            return "7d"
        }
    }

    /// K 线自动刷新间隔：短周期更频繁
    var refreshSeconds: Double {
        switch self {
        case .oneMinute:
            return 20
        case .fiveMinutes, .fifteenMinutes:
            return 45
        default:
            return 90
        }
    }
}

// MARK: - 行情领域 Store（K 线 / 搜索 / 市场榜单）

@MainActor
@Observable
final class CryptoTickerStore {
    private static let intervalKey = "CryptoTickerStore.selectedInterval"
    private static let maxKlineCount = 300

    /// 稳定币不参与热门/涨跌榜，避免噪音
    private static let stablecoins: Set<String> = [
        "USDT", "USDC", "FDUSD", "DAI", "TUSD", "USDE", "PYUSD", "USDD", "BUSD", "EURC", "USDG", "RLUSD", "USD1", "USDP"
    ]

    let featuredSpotAssets: [CryptoAsset] = [
        CryptoAsset(id: "BTC-USDT", symbol: "BTC", name: "Bitcoin", instrumentKind: .spot),
        CryptoAsset(id: "ETH-USDT", symbol: "ETH", name: "Ethereum", instrumentKind: .spot),
        CryptoAsset(id: "SOL-USDT", symbol: "SOL", name: "Solana", instrumentKind: .spot),
        CryptoAsset(id: "BNB-USDT", symbol: "BNB", name: "BNB", instrumentKind: .spot),
        CryptoAsset(id: "XRP-USDT", symbol: "XRP", name: "XRP", instrumentKind: .spot),
        CryptoAsset(id: "DOGE-USDT", symbol: "DOGE", name: "Dogecoin", instrumentKind: .spot),
        CryptoAsset(id: "ADA-USDT", symbol: "ADA", name: "Cardano", instrumentKind: .spot),
        CryptoAsset(id: "TRX-USDT", symbol: "TRX", name: "TRON", instrumentKind: .spot),
        CryptoAsset(id: "TON-USDT", symbol: "TON", name: "Toncoin", instrumentKind: .spot),
        CryptoAsset(id: "AVAX-USDT", symbol: "AVAX", name: "Avalanche", instrumentKind: .spot)
    ]

    let featuredContractAssets: [CryptoAsset] = [
        CryptoAsset(id: "BTC-USDT-SWAP", symbol: "BTC", name: "Bitcoin 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "ETH-USDT-SWAP", symbol: "ETH", name: "Ethereum 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "SOL-USDT-SWAP", symbol: "SOL", name: "Solana 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "BNB-USDT-SWAP", symbol: "BNB", name: "BNB 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "XRP-USDT-SWAP", symbol: "XRP", name: "XRP 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "DOGE-USDT-SWAP", symbol: "DOGE", name: "Dogecoin 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "ADA-USDT-SWAP", symbol: "ADA", name: "Cardano 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "TRX-USDT-SWAP", symbol: "TRX", name: "TRON 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "TON-USDT-SWAP", symbol: "TON", name: "Toncoin 永续合约", instrumentKind: .swap),
        CryptoAsset(id: "AVAX-USDT-SWAP", symbol: "AVAX", name: "Avalanche 永续合约", instrumentKind: .swap)
    ]

    // 详情页
    private(set) var selectedAsset: CryptoAsset
    private(set) var selectedInterval: KlineInterval
    private(set) var klines: [KlinePoint] = []
    private(set) var isLoadingKlines = false
    private(set) var klineError: String?

    // 搜索
    private(set) var searchResults: [CryptoAsset] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var lastSearchQuery = ""

    // 市场榜单
    private(set) var hotAssets: [CryptoAsset] = []
    private(set) var gainerAssets: [CryptoAsset] = []
    private(set) var loserAssets: [CryptoAsset] = []
    private(set) var overviewUpdatedAt: Date?
    private(set) var isLoadingOverview = false
    private(set) var overviewError: String?

    @ObservationIgnored private let service: OKXMarketDataService
    @ObservationIgnored private let hub: MarketQuoteHub
    @ObservationIgnored private var candleTask: Task<Void, Never>?
    @ObservationIgnored private var isDetailActive = false
    @ObservationIgnored private var searchIndexes: [AssetSearchTab: [CryptoAsset]] = [:]
    @ObservationIgnored private var searchIndexTasks: [AssetSearchTab: Task<[CryptoAsset], Error>] = [:]
    @ObservationIgnored private var searchGeneration = 0

    init(hub: MarketQuoteHub, service: OKXMarketDataService = OKXMarketDataService()) {
        self.hub = hub
        self.service = service
        self.selectedAsset = featuredSpotAssets[0]
        let storedInterval = UserDefaults.standard.integer(forKey: Self.intervalKey)
        self.selectedInterval = KlineInterval(rawValue: storedInterval) ?? .fifteenMinutes

        hub.addListener { [weak self] assetID, quote in
            self?.handleLiveQuote(assetID: assetID, quote: quote)
        }
    }

    var quote: CryptoQuote? {
        hub.quotes[selectedAsset.id]
    }

    // MARK: 详情页生命周期

    func activateDetail(for asset: CryptoAsset) {
        if selectedAsset != asset {
            selectedAsset = asset
            klines = []
        }
        isDetailActive = true
        hub.setDemand([asset], for: "detail")
        restartCandleLoop()
    }

    func deactivateDetail() {
        isDetailActive = false
        candleTask?.cancel()
        candleTask = nil
        hub.setDemand([], for: "detail")
    }

    func selectInterval(_ interval: KlineInterval) {
        guard selectedInterval != interval else { return }
        selectedInterval = interval
        klines = []
        UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey)
        if isDetailActive {
            restartCandleLoop()
        }
    }

    func reloadKlines() {
        restartCandleLoop()
    }

    private func restartCandleLoop() {
        candleTask?.cancel()
        let asset = selectedAsset
        let interval = selectedInterval
        let service = service
        isLoadingKlines = klines.isEmpty
        klineError = nil

        candleTask = Task { [weak self] in
            var failures = 0
            while Task.isCancelled == false {
                do {
                    let candles = try await service.fetchCandles(for: asset, interval: interval, limit: 200)
                    guard Task.isCancelled == false,
                          let self,
                          self.selectedAsset == asset,
                          self.selectedInterval == interval else { return }
                    self.klines = Array(candles.suffix(Self.maxKlineCount))
                    self.isLoadingKlines = false
                    self.klineError = nil
                    failures = 0
                } catch {
                    guard Task.isCancelled == false, let self else { return }
                    failures += 1
                    self.isLoadingKlines = false
                    if self.klines.isEmpty {
                        self.klineError = "K 线加载失败，请检查网络后重试"
                    }
                }

                // 失败时快速重试（5s/10s/...最多 30s），成功后按周期节奏刷新
                let wait = failures > 0 ? min(5 * Double(failures), 30) : interval.refreshSeconds
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// 实时价格驱动最后一根 K 线，按服务端 K 线网格对齐（避免日线/周线时区偏差）
    private func handleLiveQuote(assetID: String, quote: CryptoQuote) {
        guard isDetailActive,
              assetID == selectedAsset.id,
              let last = klines.last else { return }

        let step = Double(selectedInterval.rawValue)
        let elapsed = quote.updatedAt.timeIntervalSince(last.openTime)
        guard elapsed >= 0 else { return }

        if elapsed < step {
            var updated = last
            updated.high = max(updated.high, quote.price)
            updated.low = min(updated.low, quote.price)
            updated.close = quote.price
            klines[klines.count - 1] = updated
        } else {
            let buckets = floor(elapsed / step)
            let openTime = last.openTime.addingTimeInterval(buckets * step)
            klines.append(KlinePoint(openTime: openTime, open: last.close, high: max(last.close, quote.price), low: min(last.close, quote.price), close: quote.price, volume: 0))
            if klines.count > Self.maxKlineCount {
                klines.removeFirst(klines.count - Self.maxKlineCount)
            }
        }
    }

    // MARK: 搜索

    func prewarmSearchIndex() {
        Task { [weak self] in
            _ = try? await self?.searchIndex(for: .spot)
            _ = try? await self?.searchIndex(for: .contract)
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration

        guard trimmed.isEmpty == false else {
            searchResults = []
            searchError = nil
            isSearching = false
            lastSearchQuery = ""
            return
        }

        isSearching = true
        searchError = nil

        do {
            let spot = try await searchIndex(for: .spot)
            let contracts = (try? await searchIndex(for: .contract)) ?? []
            guard generation == searchGeneration else { return }
            searchResults = Self.rank(spot + contracts, query: trimmed)
            lastSearchQuery = trimmed
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchError = "搜索服务暂时不可用，请稍后重试"
        }

        if generation == searchGeneration {
            isSearching = false
        }
    }

    var hasLoadedSearchIndex: Bool {
        searchIndexes[.spot] != nil
    }

    private func searchIndex(for tab: AssetSearchTab) async throws -> [CryptoAsset] {
        if let cached = searchIndexes[tab] {
            return cached
        }

        // 复用进行中的请求，避免重复拉取全量列表
        if let task = searchIndexTasks[tab] {
            return try await task.value
        }

        let service = service
        let task = Task<[CryptoAsset], Error> {
            switch tab {
            case .spot:
                return try await service.fetchSpotAssets()
            case .contract:
                return try await service.fetchContractAssets()
            }
        }
        searchIndexTasks[tab] = task

        do {
            let assets = try await task.value
            searchIndexes[tab] = assets
            searchIndexTasks[tab] = nil
            return assets
        } catch {
            searchIndexTasks[tab] = nil
            throw error
        }
    }

    /// 搜索排序：代码完全匹配 > 代码前缀 > 交易对前缀 > 名称包含 > 交易对包含；同分时现货优先
    private static func rank(_ assets: [CryptoAsset], query: String) -> [CryptoAsset] {
        let upper = query.uppercased()

        func score(_ asset: CryptoAsset) -> Int? {
            if asset.symbol == upper { return 0 }
            if asset.symbol.hasPrefix(upper) { return 1 }
            if asset.id.uppercased().hasPrefix(upper) { return 2 }
            if asset.name.localizedCaseInsensitiveContains(query) { return 3 }
            if asset.id.localizedCaseInsensitiveContains(query) { return 4 }
            return nil
        }

        func kindRank(_ asset: CryptoAsset) -> Int {
            switch asset.instrumentKind {
            case .spot: return 0
            case .swap: return 1
            case .futures: return 2
            }
        }

        var seen = Set<String>()
        return assets
            .compactMap { asset -> (CryptoAsset, Int)? in
                guard let value = score(asset) else { return nil }
                return (asset, value)
            }
            .sorted { lhs, rhs in
                (lhs.1, kindRank(lhs.0), lhs.0.id) < (rhs.1, kindRank(rhs.0), rhs.0.id)
            }
            .map(\.0)
            .filter { seen.insert($0.id).inserted }
            .prefix(60)
            .map { $0 }
    }

    // MARK: 市场榜单

    func loadOverview(force: Bool = false) async {
        if force == false,
           let updatedAt = overviewUpdatedAt,
           Date().timeIntervalSince(updatedAt) < 30,
           hotAssets.isEmpty == false {
            return
        }

        guard isLoadingOverview == false else { return }
        isLoadingOverview = true
        defer { isLoadingOverview = false }

        do {
            let entries = try await service.fetchSpotMarketOverview()
            let tradable = entries.filter { Self.stablecoins.contains($0.asset.symbol) == false }

            hotAssets = tradable
                .sorted { $0.quote.volumeCurrency24h > $1.quote.volumeCurrency24h }
                .prefix(30)
                .map(\.asset)

            // 涨跌榜过滤掉成交额过低的币，避免"妖币"刷屏
            let liquid = tradable.filter { $0.quote.volumeCurrency24h >= 2_000_000 }
            gainerAssets = liquid
                .sorted { $0.quote.changePercentage24h > $1.quote.changePercentage24h }
                .prefix(30)
                .map(\.asset)
            loserAssets = liquid
                .sorted { $0.quote.changePercentage24h < $1.quote.changePercentage24h }
                .prefix(30)
                .map(\.asset)

            overviewUpdatedAt = Date()
            overviewError = nil

            var quotes: [String: CryptoQuote] = [:]
            for entry in entries {
                quotes[entry.asset.id] = entry.quote
            }
            hub.ingest(quotes)
        } catch {
            overviewError = "榜单加载失败，请检查网络"
        }
    }
}

nonisolated enum ColorToken: Sendable {
    case positive
    case negative
    case neutral
}

nonisolated enum OKXInstrumentKind: String, Hashable, Codable, Sendable {
    case spot = "SPOT"
    case swap = "SWAP"
    case futures = "FUTURES"

    var label: String {
        switch self {
        case .spot:
            return "现货"
        case .swap:
            return "永续"
        case .futures:
            return "交割"
        }
    }
}

// MARK: - 网络基础设施

nonisolated enum NetworkSession {
    /// REST 请求：短超时，快速失败后走降级
    static let rest: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "bitcoin-bar/2.0"
        ]
        return URLSession(configuration: configuration)
    }()

    /// WebSocket：由应用层心跳 + 看门狗控制存活
    static let webSocket: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

/// 数据源健康度：OKX 不可达时（如网络环境限制）10 分钟内直接走 Gate，避免每次都先超时
nonisolated final class ProviderHealth: @unchecked Sendable {
    static let shared = ProviderHealth()

    private let lock = NSLock()
    private var okxDegradedUntil: Date?

    var isOKXDegraded: Bool {
        lock.withLock {
            guard let until = okxDegradedUntil else { return false }
            return until > Date()
        }
    }

    func markOKXFailure() {
        lock.withLock {
            okxDegradedUntil = Date().addingTimeInterval(600)
        }
    }

    func markOKXHealthy() {
        lock.withLock {
            okxDegradedUntil = nil
        }
    }
}

/// WebSocket 活跃度记录，供看门狗判断连接是否"假死"
nonisolated final class SocketActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMessageAt = Date()
    private var lastPingAt = Date()
    private var receivedMessage = false
    private var receivedPayload = false

    func touch() {
        lock.withLock {
            lastMessageAt = Date()
            receivedMessage = true
        }
    }

    func markPayload() {
        lock.withLock {
            receivedPayload = true
        }
    }

    func markPing() {
        lock.withLock {
            lastPingAt = Date()
        }
    }

    var secondsSinceLastMessage: TimeInterval {
        lock.withLock { Date().timeIntervalSince(lastMessageAt) }
    }

    var secondsSinceLastPing: TimeInterval {
        lock.withLock { Date().timeIntervalSince(lastPingAt) }
    }

    var hasReceivedMessage: Bool {
        lock.withLock { receivedMessage }
    }

    var hasReceivedPayload: Bool {
        lock.withLock { receivedPayload }
    }
}

// MARK: - 行情数据服务（OKX 主 / Gate 备）

nonisolated struct OKXMarketDataService: Sendable {
    private static let okxWebSocketURL = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
    private static let gateSpotWebSocketURL = URL(string: "wss://api.gateio.ws/ws/v4/")!
    private static let gateFuturesWebSocketURL = URL(string: "wss://fx-ws.gateio.ws/v4/ws/usdt")!

    // MARK: 品种列表

    func fetchSpotAssets() async throws -> [CryptoAsset] {
        try await withFallback {
            try await fetchOKXSpotAssets()
        } fallback: {
            try await fetchGateSpotAssets()
        }
    }

    func fetchContractAssets() async throws -> [CryptoAsset] {
        try await withFallback {
            async let swaps = fetchInstruments(instType: .swap)
            async let futures = fetchInstruments(instType: .futures)
            return try await (swaps + futures).sorted(by: Self.compareAssets)
        } fallback: {
            try await fetchGateContractAssets()
        }
    }

    /// 全市场 USDT 现货行情（一次请求），用于热门/涨跌榜
    func fetchSpotMarketOverview() async throws -> [MarketEntry] {
        try await withFallback {
            let tickers = try await fetchOKXTickers(instType: .spot)
            return tickers.compactMap { ticker -> MarketEntry? in
                guard let instId = ticker.instId else { return nil }
                let parts = instId.split(separator: "-")
                guard parts.count == 2, parts[1] == "USDT", let quote = try? ticker.quote() else { return nil }
                let symbol = String(parts[0])
                let asset = CryptoAsset(id: instId, symbol: symbol, name: AssetNames.name(for: symbol), instrumentKind: .spot)
                return MarketEntry(asset: asset, quote: quote)
            }
        } fallback: {
            let tickers = try await fetchGateAllSpotTickers()
            return tickers.compactMap { ticker -> MarketEntry? in
                guard ticker.currencyPair.hasSuffix("_USDT"), let quote = try? ticker.quote() else { return nil }
                let symbol = ticker.currencyPair.split(separator: "_").first.map(String.init) ?? ticker.currencyPair
                let asset = CryptoAsset(id: "\(symbol)-USDT", symbol: symbol, name: AssetNames.name(for: symbol), instrumentKind: .spot)
                return MarketEntry(asset: asset, quote: quote)
            }
        }
    }

    // MARK: 行情快照

    func fetchTicker(for asset: CryptoAsset) async throws -> CryptoQuote {
        try await withFallback {
            try await fetchOKXTicker(for: asset)
        } fallback: {
            try await fetchGateTicker(for: asset)
        }
    }

    /// 批量拉取行情：数量多时按品类走全量接口（1~3 次请求），数量少时并发单查
    func fetchQuotes(for assets: [CryptoAsset]) async -> [String: CryptoQuote] {
        guard assets.isEmpty == false else { return [:] }

        var result: [String: CryptoQuote] = [:]
        let wantedIDs = Set(assets.map(\.id))

        if assets.count > 4 {
            let kinds = Set(assets.map(\.instrumentKind))
            for kind in kinds {
                guard let bulk = try? await fetchBulkQuotes(kind: kind) else { continue }
                for (assetID, quote) in bulk where wantedIDs.contains(assetID) {
                    result[assetID] = quote
                }
            }
        }

        let missing = assets.filter { result[$0.id] == nil }
        if missing.isEmpty == false {
            let singles = await withTaskGroup(of: (String, CryptoQuote)?.self) { group in
                for asset in missing.prefix(30) {
                    group.addTask {
                        guard let quote = try? await fetchTicker(for: asset) else { return nil }
                        return (asset.id, quote)
                    }
                }

                var quotes: [String: CryptoQuote] = [:]
                for await item in group {
                    guard let item else { continue }
                    quotes[item.0] = item.1
                }
                return quotes
            }
            result.merge(singles) { current, _ in current }
        }

        return result
    }

    func fetchCandles(for asset: CryptoAsset, interval: KlineInterval, limit: Int) async throws -> [KlinePoint] {
        try await withFallback {
            try await fetchOKXCandles(for: asset, interval: interval, limit: limit)
        } fallback: {
            try await fetchGateCandles(for: asset, interval: interval, limit: limit)
        }
    }

    // MARK: 实时推送

    /// 多品种实时行情推送。OKX 可用时走 OKX；OKX 从未连通则降级到 Gate。
    /// 方法在连接断开时抛错，由上层负责退避重连。
    func streamQuotes(
        for assets: [CryptoAsset],
        onUpdate: @escaping @Sendable (String, CryptoQuote) async -> Void
    ) async throws {
        guard assets.isEmpty == false else { return }

        if ProviderHealth.shared.isOKXDegraded == false {
            do {
                try await streamOKXTickers(for: assets, onUpdate: onUpdate)
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // OKX 曾经可用 → 交给上层退避重连；从未连通 → 立即降级到 Gate
                if ProviderHealth.shared.isOKXDegraded == false {
                    throw error
                }
            }
        }

        try await streamGateTickers(for: assets, onUpdate: onUpdate)
    }

    private func streamOKXTickers(
        for assets: [CryptoAsset],
        onUpdate: @escaping @Sendable (String, CryptoQuote) async -> Void
    ) async throws {
        let subscription = OKXSubscription(args: assets.map { OKXSubscriptionArg(channel: "tickers", instId: $0.id) })
        let payload = String(decoding: try JSONEncoder().encode(subscription), as: UTF8.self)
        let validIDs = Set(assets.map(\.id))
        let activity = SocketActivity()

        do {
            try await runWebSocket(
                url: Self.okxWebSocketURL,
                initialMessages: [payload],
                pingMessage: { "ping" },
                activity: activity
            ) { data in
                guard let message = try? JSONDecoder().decode(OKXWebSocketMessage.self, from: data) else { return }
                guard let tickers = message.data else { return }

                for ticker in tickers {
                    guard let assetID = ticker.instId ?? message.arg?.instId,
                          validIDs.contains(assetID),
                          let quote = try? ticker.quote() else { continue }
                    if activity.hasReceivedPayload == false {
                        activity.markPayload()
                        ProviderHealth.shared.markOKXHealthy()
                    }
                    await onUpdate(assetID, quote)
                }
            }
        } catch {
            if activity.hasReceivedPayload == false, Task.isCancelled == false {
                ProviderHealth.shared.markOKXFailure()
            }
            throw error
        }
    }

    private func streamGateTickers(
        for assets: [CryptoAsset],
        onUpdate: @escaping @Sendable (String, CryptoQuote) async -> Void
    ) async throws {
        // 同一个 Gate 交易对可能对应多个本地品种（例如不同来源的同币），用数组映射避免重复 key 崩溃
        var spotMap: [String: [String]] = [:]
        var futuresMap: [String: [String]] = [:]
        for asset in assets where asset.quoteCurrency == "USDT" {
            let pair = "\(asset.symbol)_USDT"
            switch asset.instrumentKind {
            case .spot:
                spotMap[pair, default: []].append(asset.id)
            case .swap:
                futuresMap[pair, default: []].append(asset.id)
            case .futures:
                continue
            }
        }

        guard spotMap.isEmpty == false || futuresMap.isEmpty == false else {
            throw MarketDataError.unsupportedInstrument
        }

        let spot = spotMap
        let futures = futuresMap

        try await withThrowingTaskGroup(of: Void.self) { group in
            if spot.isEmpty == false {
                group.addTask {
                    try await streamGateSpot(pairs: spot, onUpdate: onUpdate)
                }
            }
            if futures.isEmpty == false {
                group.addTask {
                    try await streamGateFutures(contracts: futures, onUpdate: onUpdate)
                }
            }

            _ = try await group.next()
            group.cancelAll()
            throw MarketDataError.streamClosed
        }
    }

    private func streamGateSpot(
        pairs: [String: [String]],
        onUpdate: @escaping @Sendable (String, CryptoQuote) async -> Void
    ) async throws {
        let subscription = GateWebSocketSubscription(
            time: Int(Date().timeIntervalSince1970),
            channel: "spot.tickers",
            event: "subscribe",
            payload: Array(pairs.keys)
        )
        let payload = String(decoding: try JSONEncoder().encode(subscription), as: UTF8.self)

        try await runWebSocket(
            url: Self.gateSpotWebSocketURL,
            initialMessages: [payload],
            pingMessage: { "{\"time\":\(Int(Date().timeIntervalSince1970)),\"channel\":\"spot.ping\"}" },
            activity: SocketActivity()
        ) { data in
            guard let message = try? JSONDecoder().decode(GateSpotTickerWebSocketMessage.self, from: data) else { return }
            if message.error != nil {
                throw MarketDataError.badResponse
            }
            guard message.event == "update",
                  let ticker = message.result,
                  let assetIDs = pairs[ticker.currencyPair],
                  let quote = try? ticker.quote(updatedAt: message.updatedAt) else { return }
            for assetID in assetIDs {
                await onUpdate(assetID, quote)
            }
        }
    }

    private func streamGateFutures(
        contracts: [String: [String]],
        onUpdate: @escaping @Sendable (String, CryptoQuote) async -> Void
    ) async throws {
        let subscription = GateWebSocketSubscription(
            time: Int(Date().timeIntervalSince1970),
            channel: "futures.tickers",
            event: "subscribe",
            payload: Array(contracts.keys)
        )
        let payload = String(decoding: try JSONEncoder().encode(subscription), as: UTF8.self)

        try await runWebSocket(
            url: Self.gateFuturesWebSocketURL,
            initialMessages: [payload],
            pingMessage: { "{\"time\":\(Int(Date().timeIntervalSince1970)),\"channel\":\"futures.ping\"}" },
            activity: SocketActivity()
        ) { data in
            guard let message = try? JSONDecoder().decode(GateFuturesTickerWebSocketMessage.self, from: data) else { return }
            if message.error != nil {
                throw MarketDataError.badResponse
            }
            guard message.event == "update" else { return }
            for ticker in message.result {
                guard let assetIDs = contracts[ticker.contract],
                      let quote = try? ticker.quote(updatedAt: message.updatedAt) else { continue }
                for assetID in assetIDs {
                    await onUpdate(assetID, quote)
                }
            }
        }
    }

    /// 通用 WebSocket 运行器：订阅 → 接收循环 + 心跳/看门狗；任一环节异常即关闭连接并抛错
    private func runWebSocket(
        url: URL,
        initialMessages: [String],
        pingMessage: @escaping @Sendable () -> String?,
        activity: SocketActivity,
        handler: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let socket = NetworkSession.webSocket.webSocketTask(with: url)
        socket.maximumMessageSize = 8 * 1024 * 1024
        socket.resume()

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for message in initialMessages {
                        try await socket.send(.string(message))
                    }

                    while Task.isCancelled == false {
                        let received = try await socket.receive()
                        activity.touch()

                        switch received {
                        case .string(let text):
                            if text == "pong" { continue }
                            try await handler(Data(text.utf8))
                        case .data(let data):
                            try await handler(data)
                        @unknown default:
                            continue
                        }
                    }
                }

                group.addTask {
                    while Task.isCancelled == false {
                        try await Task.sleep(for: .seconds(5))
                        // 建连阶段 15s 内必须收到消息；之后 45s 无任何消息视为假死
                        let limit: TimeInterval = activity.hasReceivedMessage ? 45 : 15
                        if activity.secondsSinceLastMessage > limit {
                            throw MarketDataError.streamTimeout
                        }
                        if activity.secondsSinceLastPing >= 15, let ping = pingMessage() {
                            try await socket.send(.string(ping))
                            activity.markPing()
                        }
                    }
                }

                do {
                    _ = try await group.next()
                    throw MarketDataError.streamClosed
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: 降级工具

    private func withFallback<T: Sendable>(
        primary: @Sendable () async throws -> T,
        fallback: @Sendable () async throws -> T
    ) async throws -> T {
        if ProviderHealth.shared.isOKXDegraded {
            return try await fallback()
        }

        do {
            return try await primary()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if Self.isNetworkUnreachable(error) {
                ProviderHealth.shared.markOKXFailure()
            }
            return try await fallback()
        }
    }

    private static func isNetworkUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    private func fetchBulkQuotes(kind: OKXInstrumentKind) async throws -> [String: CryptoQuote] {
        try await withFallback {
            let tickers = try await fetchOKXTickers(instType: kind)
            var quotes: [String: CryptoQuote] = [:]
            for ticker in tickers {
                guard let instId = ticker.instId, let quote = try? ticker.quote() else { continue }
                quotes[instId] = quote
            }
            return quotes
        } fallback: {
            var quotes: [String: CryptoQuote] = [:]
            switch kind {
            case .spot:
                for ticker in try await fetchGateAllSpotTickers() {
                    guard ticker.currencyPair.hasSuffix("_USDT"), let quote = try? ticker.quote() else { continue }
                    let symbol = ticker.currencyPair.split(separator: "_").first.map(String.init) ?? ticker.currencyPair
                    quotes["\(symbol)-USDT"] = quote
                }
            case .swap:
                for ticker in try await fetchGateAllFuturesTickers() {
                    guard ticker.contract.hasSuffix("_USDT"), let quote = try? ticker.quote() else { continue }
                    let symbol = ticker.contract.split(separator: "_").first.map(String.init) ?? ticker.contract
                    quotes["\(symbol)-USDT-SWAP"] = quote
                }
            case .futures:
                break
            }
            return quotes
        }
    }

    // MARK: OKX REST

    private func fetchOKXSpotAssets() async throws -> [CryptoAsset] {
        var components = URLComponents(string: "https://www.okx.com/api/v5/public/instruments")
        components?.queryItems = [URLQueryItem(name: "instType", value: "SPOT")]

        guard let url = components?.url else {
            throw MarketDataError.invalidURL
        }

        let response = try await fetch(OKXInstrumentsResponse.self, from: url)
        guard response.code == "0" else {
            throw MarketDataError.badResponse
        }

        return response.data
            .filter { $0.quoteCcy == "USDT" && $0.state == "live" }
            .map(\.asset)
            .sorted(by: Self.compareAssets)
    }

    private func fetchOKXTickers(instType: OKXInstrumentKind) async throws -> [OKXTicker] {
        var components = URLComponents(string: "https://www.okx.com/api/v5/market/tickers")
        components?.queryItems = [URLQueryItem(name: "instType", value: instType.rawValue)]

        guard let url = components?.url else {
            throw MarketDataError.invalidURL
        }

        let response = try await fetch(OKXTickerResponse.self, from: url)
        guard response.code == "0" else {
            throw MarketDataError.badResponse
        }
        return response.data
    }

    private func fetchOKXTicker(for asset: CryptoAsset) async throws -> CryptoQuote {
        var components = URLComponents(string: "https://www.okx.com/api/v5/market/ticker")
        components?.queryItems = [URLQueryItem(name: "instId", value: asset.id)]

        guard let url = components?.url else {
            throw MarketDataError.invalidURL
        }

        let response = try await fetch(OKXTickerResponse.self, from: url)
        guard response.code == "0", let ticker = response.data.first else {
            throw MarketDataError.badResponse
        }

        return try ticker.quote()
    }

    private func fetchOKXCandles(for asset: CryptoAsset, interval: KlineInterval, limit: Int) async throws -> [KlinePoint] {
        var components = URLComponents(string: "https://www.okx.com/api/v5/market/candles")
        components?.queryItems = [
            URLQueryItem(name: "instId", value: asset.id),
            URLQueryItem(name: "bar", value: interval.okxBar),
            URLQueryItem(name: "limit", value: String(min(limit, 300)))
        ]

        guard let url = components?.url else {
            throw MarketDataError.invalidURL
        }

        let response = try await fetch(OKXCandleResponse.self, from: url)
        guard response.code == "0" else {
            throw MarketDataError.badResponse
        }

        return try response.data.map { try $0.point() }.sorted { $0.openTime < $1.openTime }
    }

    private func fetchInstruments(instType: OKXInstrumentKind) async throws -> [CryptoAsset] {
        var components = URLComponents(string: "https://www.okx.com/api/v5/public/instruments")
        components?.queryItems = [URLQueryItem(name: "instType", value: instType.rawValue)]

        guard let url = components?.url else {
            throw MarketDataError.invalidURL
        }

        let response = try await fetch(OKXInstrumentsResponse.self, from: url)
        guard response.code == "0" else {
            throw MarketDataError.badResponse
        }

        return response.data
            .filter { $0.state == "live" }
            .map(\.asset)
    }

    // MARK: Gate REST

    private func fetchGateSpotAssets() async throws -> [CryptoAsset] {
        guard let url = URL(string: "https://api.gateio.ws/api/v4/spot/currency_pairs") else {
            throw MarketDataError.invalidURL
        }

        let pairs = try await fetch([GateSpotPair].self, from: url)
        return pairs
            .filter { $0.id.hasSuffix("_USDT") && ($0.tradeStatus ?? "tradable") == "tradable" }
            .map(\.asset)
            .sorted(by: Self.compareAssets)
    }

    private func fetchGateContractAssets() async throws -> [CryptoAsset] {
        guard let url = URL(string: "https://api.gateio.ws/api/v4/futures/usdt/contracts") else {
            throw MarketDataError.invalidURL
        }

        let contracts = try await fetch([GateFuturesContract].self, from: url)
        return contracts
            .filter { $0.name.hasSuffix("_USDT") && $0.inDelisting != true }
            .map(\.asset)
            .sorted(by: Self.compareAssets)
    }

    private func fetchGateAllSpotTickers() async throws -> [GateSpotTicker] {
        guard let url = URL(string: "https://api.gateio.ws/api/v4/spot/tickers") else {
            throw MarketDataError.invalidURL
        }
        return try await fetch([GateSpotTicker].self, from: url)
    }

    private func fetchGateAllFuturesTickers() async throws -> [GateFuturesTicker] {
        guard let url = URL(string: "https://api.gateio.ws/api/v4/futures/usdt/tickers") else {
            throw MarketDataError.invalidURL
        }
        return try await fetch([GateFuturesTicker].self, from: url)
    }

    private func fetchGateTicker(for asset: CryptoAsset) async throws -> CryptoQuote {
        guard asset.quoteCurrency == "USDT", asset.instrumentKind != .futures else {
            throw MarketDataError.unsupportedInstrument
        }

        if asset.instrumentKind == .spot {
            var components = URLComponents(string: "https://api.gateio.ws/api/v4/spot/tickers")
            components?.queryItems = [URLQueryItem(name: "currency_pair", value: gateSymbol(for: asset))]

            guard let url = components?.url else {
                throw MarketDataError.invalidURL
            }

            let tickers = try await fetch([GateSpotTicker].self, from: url)
            guard let ticker = tickers.first else {
                throw MarketDataError.badResponse
            }
            return try ticker.quote()
        } else {
            var components = URLComponents(string: "https://api.gateio.ws/api/v4/futures/usdt/tickers")
            components?.queryItems = [URLQueryItem(name: "contract", value: gateSymbol(for: asset))]

            guard let url = components?.url else {
                throw MarketDataError.invalidURL
            }

            let tickers = try await fetch([GateFuturesTicker].self, from: url)
            guard let ticker = tickers.first else {
                throw MarketDataError.badResponse
            }
            return try ticker.quote()
        }
    }

    private func fetchGateCandles(for asset: CryptoAsset, interval: KlineInterval, limit: Int) async throws -> [KlinePoint] {
        guard asset.quoteCurrency == "USDT", asset.instrumentKind != .futures else {
            throw MarketDataError.unsupportedInstrument
        }

        if asset.instrumentKind == .spot {
            var components = URLComponents(string: "https://api.gateio.ws/api/v4/spot/candlesticks")
            components?.queryItems = [
                URLQueryItem(name: "currency_pair", value: gateSymbol(for: asset)),
                URLQueryItem(name: "interval", value: interval.gateInterval),
                URLQueryItem(name: "limit", value: String(limit))
            ]

            guard let url = components?.url else {
                throw MarketDataError.invalidURL
            }

            let candles = try await fetch([GateSpotCandle].self, from: url)
            return try candles.map { try $0.point() }.sorted { $0.openTime < $1.openTime }
        } else {
            var components = URLComponents(string: "https://api.gateio.ws/api/v4/futures/usdt/candlesticks")
            components?.queryItems = [
                URLQueryItem(name: "contract", value: gateSymbol(for: asset)),
                URLQueryItem(name: "interval", value: interval.gateInterval),
                URLQueryItem(name: "limit", value: String(limit))
            ]

            guard let url = components?.url else {
                throw MarketDataError.invalidURL
            }

            let candles = try await fetch([GateFuturesCandle].self, from: url)
            return try candles.map { try $0.point() }.sorted { $0.openTime < $1.openTime }
        }
    }

    private func gateSymbol(for asset: CryptoAsset) -> String {
        "\(asset.symbol)_USDT"
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, response) = try await NetworkSession.rest.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MarketDataError.badResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw httpResponse.statusCode == 429 ? MarketDataError.rateLimited : MarketDataError.badResponse
        }

        return try JSONDecoder().decode(type, from: data)
    }

    private static func compareAssets(_ lhs: CryptoAsset, _ rhs: CryptoAsset) -> Bool {
        let lhsRank = preferredOrder[lhs.symbol] ?? Int.max
        let rhsRank = preferredOrder[rhs.symbol] ?? Int.max
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        if lhs.instrumentKind != rhs.instrumentKind {
            return lhs.instrumentKind.rawValue < rhs.instrumentKind.rawValue
        }

        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    // 预先构建排序字典，避免排序比较时重复创建
    private static let preferredOrder: [String: Int] = {
        let preferredSymbols = ["BTC", "ETH", "SOL", "BNB", "DOGE", "XRP", "ADA", "AVAX", "LTC", "PEPE"]
        return Dictionary(uniqueKeysWithValues: preferredSymbols.enumerated().map { ($0.element, $0.offset) })
    }()
}

// MARK: - OKX DTO

nonisolated private struct OKXTickerResponse: Decodable {
    let code: String
    let data: [OKXTicker]
}

nonisolated private struct OKXWebSocketMessage: Decodable {
    let event: String?
    let code: String?
    let msg: String?
    let arg: OKXSubscriptionArg?
    let data: [OKXTicker]?
}

nonisolated private struct OKXTicker: Decodable {
    let instId: String?
    let instType: String?
    let last: String
    let open24h: String
    let sodUtc0: String?
    let ts: String
    let high24h: String
    let low24h: String
    let volume24h: String
    let volumeCurrency24h: String

    enum CodingKeys: String, CodingKey {
        case instId
        case instType
        case last
        case open24h
        case sodUtc0
        case ts
        case high24h
        case low24h
        case volume24h = "vol24h"
        case volumeCurrency24h = "volCcy24h"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instId = try container.decodeIfPresent(String.self, forKey: .instId)
        instType = try container.decodeIfPresent(String.self, forKey: .instType)
        last = try container.decode(String.self, forKey: .last)
        open24h = try container.decode(String.self, forKey: .open24h)
        sodUtc0 = try container.decodeIfPresent(String.self, forKey: .sodUtc0)
        ts = try container.decode(String.self, forKey: .ts)
        high24h = try container.decodeIfPresent(String.self, forKey: .high24h) ?? last
        low24h = try container.decodeIfPresent(String.self, forKey: .low24h) ?? last
        volume24h = try container.decodeIfPresent(String.self, forKey: .volume24h) ?? "0"
        volumeCurrency24h = try container.decodeIfPresent(String.self, forKey: .volumeCurrency24h) ?? "0"
    }

    func quote() throws -> CryptoQuote {
        let price = try last.doubleValue()
        // 优先使用 UTC+0 00:00 开盘价 (sodUtc0) 计算当日涨跌幅；新上线品种缺失时回退 24h 开盘价
        let utc0Open = sodUtc0
            .flatMap { try? $0.doubleValue() }
            .flatMap { $0 > 0 ? $0 : nil }
        let open = try utc0Open ?? open24h.doubleValue()
        let change = open == 0 ? 0 : ((price - open) / open) * 100

        // 现货：vol24h=基础币数量，volCcy24h=计价币成交额
        // 衍生品：volCcy24h=基础币数量，成交额需要按价格折算
        let isDerivative = (instType ?? "SPOT") != "SPOT" || (instId?.split(separator: "-").count ?? 2) > 2
        let baseVolume: Double
        let quoteVolume: Double
        if isDerivative {
            baseVolume = (try? volumeCurrency24h.doubleValue()) ?? 0
            quoteVolume = baseVolume * price
        } else {
            baseVolume = (try? volume24h.doubleValue()) ?? 0
            quoteVolume = (try? volumeCurrency24h.doubleValue()) ?? 0
        }

        return CryptoQuote(
            price: price,
            changePercentage24h: change,
            updatedAt: Date(timeIntervalSince1970: try ts.doubleValue() / 1000),
            high24h: (try? high24h.doubleValue()) ?? price,
            low24h: (try? low24h.doubleValue()) ?? price,
            volume24h: baseVolume,
            volumeCurrency24h: quoteVolume
        )
    }
}

nonisolated private struct OKXCandleResponse: Decodable {
    let code: String
    let data: [OKXCandle]
}

nonisolated private struct OKXInstrumentsResponse: Decodable {
    let code: String
    let data: [OKXInstrument]
}

nonisolated private struct OKXCandle: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [String] = []

        while !container.isAtEnd {
            values.append(try container.decode(String.self))
        }

        self.values = values
    }

    func point() throws -> KlinePoint {
        guard values.count >= 5 else {
            throw MarketDataError.invalidMessage
        }

        return KlinePoint(
            openTime: Date(timeIntervalSince1970: try values[0].doubleValue() / 1000),
            open: try values[1].doubleValue(),
            high: try values[2].doubleValue(),
            low: try values[3].doubleValue(),
            close: try values[4].doubleValue(),
            volume: values.count > 5 ? ((try? values[5].doubleValue()) ?? 0) : 0
        )
    }
}

nonisolated private struct OKXInstrument: Decodable {
    let instId: String
    let instType: String
    let baseCcy: String
    let quoteCcy: String
    let uly: String?
    let instFamily: String?
    let state: String

    var asset: CryptoAsset {
        let kind = OKXInstrumentKind(rawValue: instType) ?? .spot
        let resolvedSymbol = symbol
        return CryptoAsset(
            id: instId,
            symbol: resolvedSymbol,
            name: displayName(for: resolvedSymbol, kind: kind),
            instrumentKind: kind
        )
    }

    private var symbol: String {
        if baseCcy.isEmpty == false {
            return baseCcy
        }

        if let uly, let token = uly.split(separator: "-").first {
            return String(token)
        }

        if let instFamily, let token = instFamily.split(separator: "-").first {
            return String(token)
        }

        if let token = instId.split(separator: "-").first {
            return String(token)
        }

        return instId
    }

    private func displayName(for symbol: String, kind: OKXInstrumentKind) -> String {
        let baseName = AssetNames.name(for: symbol)
        switch kind {
        case .spot:
            return baseName
        case .swap:
            return "\(baseName) 永续合约"
        case .futures:
            return "\(baseName) 交割合约"
        }
    }
}

nonisolated private struct OKXSubscription: Encodable {
    let op = "subscribe"
    let args: [OKXSubscriptionArg]
}

nonisolated private struct OKXSubscriptionArg: Codable {
    let channel: String
    let instId: String?
}

// MARK: - Gate DTO

nonisolated private struct GateWebSocketSubscription: Encodable {
    let time: Int
    let channel: String
    let event: String
    let payload: [String]
}

nonisolated private struct GateWebSocketError: Decodable {
    let code: Int?
    let message: String?
}

nonisolated private struct GateSpotTickerWebSocketMessage: Decodable {
    let time: TimeInterval?
    let timeMilliseconds: TimeInterval?
    let channel: String?
    let event: String?
    let error: GateWebSocketError?
    let result: GateSpotTicker?

    enum CodingKeys: String, CodingKey {
        case time
        case timeMilliseconds = "time_ms"
        case channel
        case event
        case error
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try? container.decodeIfPresent(TimeInterval.self, forKey: .time)
        timeMilliseconds = try? container.decodeIfPresent(TimeInterval.self, forKey: .timeMilliseconds)
        channel = try? container.decodeIfPresent(String.self, forKey: .channel)
        event = try? container.decodeIfPresent(String.self, forKey: .event)
        error = try? container.decodeIfPresent(GateWebSocketError.self, forKey: .error)
        result = try? container.decode(GateSpotTicker.self, forKey: .result)
    }

    var updatedAt: Date {
        if let timeMilliseconds {
            return Date(timeIntervalSince1970: timeMilliseconds / 1000)
        }

        if let time {
            return Date(timeIntervalSince1970: time)
        }

        return Date()
    }
}

nonisolated private struct GateFuturesTickerWebSocketMessage: Decodable {
    let time: TimeInterval?
    let timeMilliseconds: TimeInterval?
    let channel: String?
    let event: String?
    let error: GateWebSocketError?
    let result: [GateFuturesTicker]

    enum CodingKeys: String, CodingKey {
        case time
        case timeMilliseconds = "time_ms"
        case channel
        case event
        case error
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try? container.decodeIfPresent(TimeInterval.self, forKey: .time)
        timeMilliseconds = try? container.decodeIfPresent(TimeInterval.self, forKey: .timeMilliseconds)
        channel = try? container.decodeIfPresent(String.self, forKey: .channel)
        event = try? container.decodeIfPresent(String.self, forKey: .event)
        error = try? container.decodeIfPresent(GateWebSocketError.self, forKey: .error)
        result = (try? container.decode([GateFuturesTicker].self, forKey: .result)) ?? []
    }

    var updatedAt: Date {
        if let timeMilliseconds {
            return Date(timeIntervalSince1970: timeMilliseconds / 1000)
        }

        if let time {
            return Date(timeIntervalSince1970: time)
        }

        return Date()
    }
}

nonisolated private struct GateSpotPair: Decodable {
    let id: String
    let base: String
    let quote: String
    let tradeStatus: String?

    enum CodingKeys: String, CodingKey {
        case id
        case base
        case quote
        case tradeStatus = "trade_status"
    }

    var asset: CryptoAsset {
        CryptoAsset(
            id: "\(base)-\(quote)",
            symbol: base,
            name: AssetNames.name(for: base),
            instrumentKind: .spot
        )
    }
}

nonisolated private struct GateFuturesContract: Decodable {
    let name: String
    let inDelisting: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case inDelisting = "in_delisting"
    }

    var asset: CryptoAsset {
        let symbol = name.split(separator: "_").first.map(String.init) ?? name
        return CryptoAsset(
            id: "\(symbol)-USDT-SWAP",
            symbol: symbol,
            name: "\(AssetNames.name(for: symbol)) 永续合约",
            instrumentKind: .swap
        )
    }
}

nonisolated private struct GateSpotTicker: Decodable {
    let currencyPair: String
    let last: String
    let changePercentage: String
    let changeUtc0: String?
    let baseVolume: String
    let quoteVolume: String
    let high24h: String
    let low24h: String

    enum CodingKeys: String, CodingKey {
        case currencyPair = "currency_pair"
        case last
        case changePercentage = "change_percentage"
        case changeUtc0 = "change_utc0"
        case baseVolume = "base_volume"
        case quoteVolume = "quote_volume"
        case high24h = "high_24h"
        case low24h = "low_24h"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currencyPair = try container.decode(String.self, forKey: .currencyPair)
        last = try container.decode(String.self, forKey: .last)
        changePercentage = (try? container.decode(String.self, forKey: .changePercentage)) ?? "0"
        changeUtc0 = try? container.decodeIfPresent(String.self, forKey: .changeUtc0)
        baseVolume = (try? container.decode(String.self, forKey: .baseVolume)) ?? "0"
        quoteVolume = (try? container.decode(String.self, forKey: .quoteVolume)) ?? "0"
        high24h = (try? container.decode(String.self, forKey: .high24h)) ?? last
        low24h = (try? container.decode(String.self, forKey: .low24h)) ?? last
    }

    func quote(updatedAt: Date = Date()) throws -> CryptoQuote {
        let price = try last.doubleValue()
        let resolvedChange = changeUtc0.flatMap { try? $0.doubleValue() }
            ?? ((try? changePercentage.doubleValue()) ?? 0)
        return CryptoQuote(
            price: price,
            changePercentage24h: resolvedChange,
            updatedAt: updatedAt,
            high24h: (try? high24h.doubleValue()) ?? price,
            low24h: (try? low24h.doubleValue()) ?? price,
            volume24h: (try? baseVolume.doubleValue()) ?? 0,
            volumeCurrency24h: (try? quoteVolume.doubleValue()) ?? 0,
            source: .gate
        )
    }
}

nonisolated private struct GateFuturesTicker: Decodable {
    let contract: String
    let last: String
    let changePercentage: String
    let volume24hBase: String
    let volume24hQuote: String
    let high24h: String
    let low24h: String

    enum CodingKeys: String, CodingKey {
        case contract
        case last
        case changePercentage = "change_percentage"
        case volume24hBase = "volume_24h_base"
        case volume24hQuote = "volume_24h_quote"
        case high24h = "high_24h"
        case low24h = "low_24h"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contract = try container.decode(String.self, forKey: .contract)
        last = try container.decode(String.self, forKey: .last)
        changePercentage = (try? container.decode(String.self, forKey: .changePercentage)) ?? "0"
        volume24hBase = (try? container.decode(String.self, forKey: .volume24hBase)) ?? "0"
        volume24hQuote = (try? container.decode(String.self, forKey: .volume24hQuote)) ?? "0"
        high24h = (try? container.decode(String.self, forKey: .high24h)) ?? last
        low24h = (try? container.decode(String.self, forKey: .low24h)) ?? last
    }

    func quote(updatedAt: Date = Date()) throws -> CryptoQuote {
        let price = try last.doubleValue()
        return CryptoQuote(
            price: price,
            changePercentage24h: (try? changePercentage.doubleValue()) ?? 0,
            updatedAt: updatedAt,
            high24h: (try? high24h.doubleValue()) ?? price,
            low24h: (try? low24h.doubleValue()) ?? price,
            volume24h: (try? volume24hBase.doubleValue()) ?? 0,
            volumeCurrency24h: (try? volume24hQuote.doubleValue()) ?? 0,
            source: .gate
        )
    }
}

nonisolated private struct GateSpotCandle: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [String] = []

        while !container.isAtEnd {
            values.append(try container.decode(String.self))
        }

        self.values = values
    }

    func point() throws -> KlinePoint {
        guard values.count >= 6 else {
            throw MarketDataError.invalidMessage
        }

        // Gate 现货 K 线字段顺序：时间, 成交额, 收盘, 最高, 最低, 开盘, 成交量
        return KlinePoint(
            openTime: Date(timeIntervalSince1970: try values[0].doubleValue()),
            open: try values[5].doubleValue(),
            high: try values[3].doubleValue(),
            low: try values[4].doubleValue(),
            close: try values[2].doubleValue(),
            volume: values.count > 6 ? ((try? values[6].doubleValue()) ?? 0) : 0
        )
    }
}

nonisolated private struct GateFuturesCandle: Decodable {
    let open: String
    let volume: Double
    let time: TimeInterval
    let close: String
    let low: String
    let high: String

    enum CodingKeys: String, CodingKey {
        case open = "o"
        case volume = "v"
        case time = "t"
        case close = "c"
        case low = "l"
        case high = "h"
    }

    func point() throws -> KlinePoint {
        KlinePoint(
            openTime: Date(timeIntervalSince1970: time),
            open: try open.doubleValue(),
            high: try high.doubleValue(),
            low: try low.doubleValue(),
            close: try close.doubleValue(),
            volume: volume
        )
    }
}

private extension String {
    nonisolated func doubleValue() throws -> Double {
        guard let value = Double(self), value.isFinite else {
            throw MarketDataError.invalidNumber
        }

        return value
    }
}

nonisolated enum MarketDataError: LocalizedError {
    case invalidURL
    case badResponse
    case invalidMessage
    case invalidNumber
    case rateLimited
    case streamTimeout
    case streamClosed
    case unsupportedInstrument

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "行情接口地址无效。"
        case .badResponse:
            return "行情接口暂时不可用。"
        case .invalidMessage:
            return "行情数据格式异常。"
        case .invalidNumber:
            return "行情数值解析失败。"
        case .rateLimited:
            return "请求过于频繁，请稍后再试。"
        case .streamTimeout:
            return "实时连接超时。"
        case .streamClosed:
            return "实时连接已断开。"
        case .unsupportedInstrument:
            return "备用数据源暂不支持该品种。"
        }
    }
}

nonisolated enum AssetNames {
    static func name(for symbol: String) -> String {
        known[symbol] ?? symbol
    }

    private static let known: [String: String] = [
        "BTC": "Bitcoin",
        "ETH": "Ethereum",
        "SOL": "Solana",
        "BNB": "BNB",
        "DOGE": "Dogecoin",
        "XRP": "XRP",
        "ADA": "Cardano",
        "AVAX": "Avalanche",
        "LTC": "Litecoin",
        "AAVE": "Aave",
        "ARB": "Arbitrum",
        "ATOM": "Cosmos",
        "DOT": "Polkadot",
        "FIL": "Filecoin",
        "LINK": "Chainlink",
        "NEAR": "NEAR Protocol",
        "OP": "Optimism",
        "PEPE": "Pepe",
        "SHIB": "Shiba Inu",
        "SUI": "Sui",
        "TON": "Toncoin",
        "TRX": "TRON",
        "UNI": "Uniswap",
        "BCH": "Bitcoin Cash",
        "ETC": "Ethereum Classic",
        "APT": "Aptos",
        "WLD": "Worldcoin",
        "ORDI": "ORDI",
        "OKB": "OKB"
    ]
}
