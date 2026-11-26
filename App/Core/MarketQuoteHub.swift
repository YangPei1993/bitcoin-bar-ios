import Foundation
import Network
import UIKit

// MARK: - 连接状态与价格跳动模型

nonisolated enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting(attempt: Int)
    case fallbackPolling
    case offline

    var label: String {
        switch self {
        case .idle: return "等待行情"
        case .connecting: return "连接实时行情..."
        case .live: return "实时推送"
        case .reconnecting(let attempt): return "重连中（第 \(attempt) 次）"
        case .fallbackPolling: return "快照轮询中"
        case .offline: return "网络已断开"
        }
    }

    var isHealthy: Bool {
        self == .live
    }
}

nonisolated enum PriceDirection: Equatable, Sendable {
    case up
    case down
}

nonisolated struct PriceTickFlash: Equatable, Sendable {
    let direction: PriceDirection
    let sequence: Int
}

// MARK: - iOS 统一行情中枢

@MainActor
@Observable
final class MarketQuoteHub {
    private static let maxSubscribedAssets = 60

    private(set) var quotes: [String: CryptoQuote] = [:]
    private(set) var flashes: [String: PriceTickFlash] = [:]
    private(set) var connectionState: ConnectionState = .idle
    private(set) var lastUpdatedAt: Date?
    private(set) var isRefreshingSnapshot = false

    @ObservationIgnored private let service: OKXMarketDataService
    @ObservationIgnored private var demands: [String: [CryptoAsset]] = [:]
    @ObservationIgnored private var activeAssets: [CryptoAsset] = []
    @ObservationIgnored private var activeAssetIDs: [String] = []
    @ObservationIgnored private var pendingQuotes: [String: CryptoQuote] = [:]
    @ObservationIgnored private var listeners: [(String, CryptoQuote) -> Void] = []
    @ObservationIgnored private var batchObservers: [(Set<String>) -> Void] = []
    @ObservationIgnored private var flashSequence = 0

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackPollTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var isNetworkAvailable = true
    @ObservationIgnored private var isStarted = false

    init(service: OKXMarketDataService = OKXMarketDataService()) {
        self.service = service
    }

    func start() {
        guard isStarted == false else { return }
        isStarted = true
        setupSystemMonitors()
        startFlushLoop()
        startFallbackPollLoop()
        rebuildStreamIfNeeded(force: true)
    }

    func stop() {
        isStarted = false
        streamTask?.cancel()
        fallbackPollTask?.cancel()
        flushTask?.cancel()
        snapshotTask?.cancel()
        streamTask = nil
        fallbackPollTask = nil
        flushTask = nil
        snapshotTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
        connectionState = .idle
    }

    func addListener(_ listener: @escaping (String, CryptoQuote) -> Void) {
        listeners.append(listener)
    }

    /// 在 quotes 字典真正提交更新后触发，确保订阅者（如灵动岛）读到的是最新价
    func addBatchObserver(_ observer: @escaping (Set<String>) -> Void) {
        batchObservers.append(observer)
    }

    func setDemand(_ assets: [CryptoAsset], for source: String) {
        demands[source] = assets
        recomputeActiveAssets()
    }

    func ingest(_ incoming: [String: CryptoQuote]) {
        guard incoming.isEmpty == false else { return }
        applyBatch(incoming, notifyListeners: true)
    }

    func refreshNow() async {
        let targets = activeAssets
        guard targets.isEmpty == false else { return }
        isRefreshingSnapshot = true
        defer { isRefreshingSnapshot = false }

        let fetched = await service.fetchQuotes(for: targets)
        if fetched.isEmpty == false {
            applyBatch(fetched, notifyListeners: true)
        }
    }

    func reconnectNow() {
        ProviderHealth.shared.markOKXHealthy()
        rebuildStreamIfNeeded(force: true)
        Task { await refreshNow() }
    }

    // MARK: 订阅合并

    private func recomputeActiveAssets() {
        let priorityOrder = ["live_activity", "detail", "alerts", "volatility", "panel"]
        var merged: [CryptoAsset] = []
        var seen = Set<String>()

        for key in priorityOrder {
            for asset in demands[key] ?? [] where seen.insert(asset.id).inserted {
                merged.append(asset)
                if merged.count >= Self.maxSubscribedAssets { break }
            }
            if merged.count >= Self.maxSubscribedAssets { break }
        }

        for (key, list) in demands where priorityOrder.contains(key) == false {
            for asset in list where seen.insert(asset.id).inserted {
                merged.append(asset)
                if merged.count >= Self.maxSubscribedAssets { break }
            }
            if merged.count >= Self.maxSubscribedAssets { break }
        }

        let newIDs = merged.map(\.id).sorted()
        activeAssets = merged

        let missingAssets = merged.filter { quotes[$0.id] == nil }
        if missingAssets.isEmpty == false, isStarted {
            scheduleSnapshot(for: missingAssets)
        }

        guard newIDs != activeAssetIDs else { return }
        activeAssetIDs = newIDs
        if isStarted {
            rebuildStreamIfNeeded(force: true)
        }
    }

    private func scheduleSnapshot(for assets: [CryptoAsset]) {
        snapshotTask?.cancel()
        let service = service
        snapshotTask = Task { [weak self] in
            let fetched = await service.fetchQuotes(for: assets)
            guard Task.isCancelled == false, let self else { return }
            if fetched.isEmpty == false {
                self.applyBatch(fetched, notifyListeners: true)
            }
        }
    }

    private func rebuildStreamIfNeeded(force: Bool) {
        guard isStarted else { return }
        if force {
            streamTask?.cancel()
            streamTask = nil
        }

        guard activeAssets.isEmpty == false else {
            connectionState = .idle
            return
        }

        guard isNetworkAvailable else {
            connectionState = .offline
            return
        }

        let subscribedAssets = activeAssets
        let service = service
        connectionState = .connecting
        scheduleSnapshot(for: subscribedAssets)

        streamTask = Task { [weak self] in
            var attempt = 0

            while Task.isCancelled == false {
                guard let self else { return }
                self.connectionState = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)

                let startTime = Date()
                do {
                    try await service.streamQuotes(for: subscribedAssets) { assetID, quote in
                        await MainActor.run { [weak self] in
                            self?.enqueueLiveQuote(assetID: assetID, quote: quote)
                        }
                    }
                    attempt += 1
                } catch is CancellationError {
                    return
                } catch {
                    if Date().timeIntervalSince(startTime) > 20 {
                        attempt = 1
                    } else {
                        attempt += 1
                    }
                }

                guard Task.isCancelled == false else { return }
                if self.isNetworkAvailable == false {
                    self.connectionState = .offline
                    return
                }

                let baseDelay = min(pow(2.0, Double(max(attempt - 1, 0))), 30.0)
                let jitter = Double.random(in: 0...0.8)
                self.connectionState = attempt >= 3 ? .fallbackPolling : .reconnecting(attempt: attempt)
                try? await Task.sleep(for: .seconds(baseDelay + jitter))
            }
        }
    }

    private func enqueueLiveQuote(assetID: String, quote: CryptoQuote) {
        if connectionState != .live {
            connectionState = .live
        }
        pendingQuotes[assetID] = quote
        for listener in listeners {
            listener(assetID, quote)
        }
    }

    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(300))
                guard Task.isCancelled == false, let self else { return }
                self.flushPendingQuotes()
            }
        }
    }

    private func flushPendingQuotes() {
        guard pendingQuotes.isEmpty == false else { return }
        let batch = pendingQuotes
        pendingQuotes.removeAll(keepingCapacity: true)
        applyBatch(batch, notifyListeners: false)
    }

    private func applyBatch(_ batch: [String: CryptoQuote], notifyListeners: Bool) {
        var latestDate = lastUpdatedAt
        for (assetID, newQuote) in batch {
            if let oldQuote = quotes[assetID], oldQuote.price != newQuote.price {
                flashSequence &+= 1
                flashes[assetID] = PriceTickFlash(
                    direction: newQuote.price > oldQuote.price ? .up : .down,
                    sequence: flashSequence
                )
            }
            quotes[assetID] = newQuote
            if let current = latestDate {
                if newQuote.updatedAt > current { latestDate = newQuote.updatedAt }
            } else {
                latestDate = newQuote.updatedAt
            }

            if notifyListeners {
                for listener in listeners {
                    listener(assetID, newQuote)
                }
            }
        }
        lastUpdatedAt = latestDate ?? Date()
        let updatedIDs = Set(batch.keys)
        for observer in batchObservers {
            observer(updatedIDs)
        }
    }

    private func startFallbackPollLoop() {
        fallbackPollTask?.cancel()
        fallbackPollTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(8))
                guard Task.isCancelled == false, let self else { return }
                guard self.isNetworkAvailable,
                      self.activeAssets.isEmpty == false,
                      self.connectionState != .live else { continue }

                let fetched = await self.service.fetchQuotes(for: self.activeAssets)
                guard Task.isCancelled == false else { return }
                if fetched.isEmpty == false {
                    self.applyBatch(fetched, notifyListeners: true)
                }
            }
        }
    }

    private func setupSystemMonitors() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = available
                if available == false {
                    self.streamTask?.cancel()
                    self.streamTask = nil
                    self.connectionState = .offline
                } else if wasAvailable == false {
                    ProviderHealth.shared.markOKXHealthy()
                    self.rebuildStreamIfNeeded(force: true)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.paul.bitcoin-bar-ios.network-monitor"))
        pathMonitor = monitor

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                ProviderHealth.shared.markOKXHealthy()
                self.rebuildStreamIfNeeded(force: true)
            }
        }
    }
}
