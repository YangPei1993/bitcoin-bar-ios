import AudioToolbox
import Foundation
import UserNotifications

// MARK: - 价格提醒模型

nonisolated enum PriceAlertDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case above
    case below

    var id: String { rawValue }

    var label: String {
        switch self {
        case .above: return "涨破"
        case .below: return "跌破"
        }
    }

    var symbol: String {
        switch self {
        case .above: return "arrow.up.right"
        case .below: return "arrow.down.right"
        }
    }
}

nonisolated struct PriceAlert: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let asset: CryptoAsset
    var direction: PriceAlertDirection
    var targetPrice: Double
    var isEnabled: Bool
    var isRepeating: Bool
    var note: String
    let createdAt: Date
    var lastTriggeredAt: Date?

    init(
        id: UUID = UUID(),
        asset: CryptoAsset,
        direction: PriceAlertDirection,
        targetPrice: Double,
        isEnabled: Bool = true,
        isRepeating: Bool = false,
        note: String = "",
        createdAt: Date = Date(),
        lastTriggeredAt: Date? = nil
    ) {
        self.id = id
        self.asset = asset
        self.direction = direction
        self.targetPrice = targetPrice
        self.isEnabled = isEnabled
        self.isRepeating = isRepeating
        self.note = note
        self.createdAt = createdAt
        self.lastTriggeredAt = lastTriggeredAt
    }

    func matches(price: Double) -> Bool {
        switch direction {
        case .above: return price >= targetPrice
        case .below: return price <= targetPrice
        }
    }
}

// MARK: - 价格提醒 Store

@MainActor
@Observable
final class PriceAlertStore {
    private static let storageKey = "PriceAlertStore.alerts"
    private static let repeatCooldownSeconds: TimeInterval = 300

    private(set) var alerts: [PriceAlert] = []
    private(set) var notificationAuthorized = false

    @ObservationIgnored private let hub: MarketQuoteHub
    @ObservationIgnored private let dispatcher: NotificationDispatcher?

    init(hub: MarketQuoteHub, dispatcher: NotificationDispatcher? = nil) {
        self.hub = hub
        self.dispatcher = dispatcher

        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([PriceAlert].self, from: data) {
            self.alerts = decoded
        }

        syncHubDemand()

        hub.addListener { [weak self] assetID, quote in
            self?.evaluate(assetID: assetID, price: quote.price)
        }

        Task { await refreshAuthorizationStatus() }
    }

    var activeAlertCount: Int {
        alerts.filter(\.isEnabled).count
    }

    func alerts(for asset: CryptoAsset) -> [PriceAlert] {
        alerts.filter { $0.asset == asset }
    }

    func addAlert(
        asset: CryptoAsset,
        direction: PriceAlertDirection,
        targetPrice: Double,
        isRepeating: Bool = false,
        note: String = ""
    ) {
        guard targetPrice > 0, targetPrice.isFinite else { return }
        let alert = PriceAlert(
            asset: asset,
            direction: direction,
            targetPrice: targetPrice,
            isEnabled: true,
            isRepeating: isRepeating,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        alerts.insert(alert, at: 0)
        persist()
        syncHubDemand()

        Task { await requestAuthorizationIfNeeded() }
    }

    func toggleAlert(id: UUID) {
        guard let idx = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[idx].isEnabled.toggle()
        persist()
        syncHubDemand()
    }

    func deleteAlert(id: UUID) {
        alerts.removeAll { $0.id == id }
        persist()
        syncHubDemand()
    }

    func clearTriggeredHistory() {
        alerts.removeAll { $0.isEnabled == false && $0.lastTriggeredAt != nil }
        persist()
        syncHubDemand()
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            notificationAuthorized = granted
        case .authorized, .provisional:
            notificationAuthorized = true
        default:
            notificationAuthorized = false
        }
    }

    func sendTestNotification() {
        dispatcher?.dispatch(
            AlertPayload(
                severity: .info,
                category: "通知测试",
                title: "bitcoin-bar 提醒测试",
                body: "iOS 本地通知与推送通道已就绪，触发目标价时将第一时间通知您。"
            )
        )
    }

    private func evaluate(assetID: String, price: Double) {
        let now = Date()
        var mutated = false

        for idx in alerts.indices {
            let alert = alerts[idx]
            guard alert.isEnabled, alert.asset.id == assetID else { continue }
            guard alert.matches(price: price) else { continue }
            if let last = alert.lastTriggeredAt, now.timeIntervalSince(last) < Self.repeatCooldownSeconds {
                continue
            }

            alerts[idx].lastTriggeredAt = now
            if alert.isRepeating == false {
                alerts[idx].isEnabled = false
            }
            mutated = true
            notifyTriggered(alerts[idx], currentPrice: price)
        }

        if mutated {
            persist()
            syncHubDemand()
        }
    }

    private func notifyTriggered(_ alert: PriceAlert, currentPrice: Double) {
        let title = "\(alert.asset.symbol) \(alert.direction.label) \(MarketFormatter.price(alert.targetPrice))"
        var body = "\(alert.asset.pairLabel) 当前价格 \(MarketFormatter.price(currentPrice))"
        if alert.note.isEmpty == false {
            body += " · \(alert.note)"
        }

        if let dispatcher {
            dispatcher.dispatch(
                AlertPayload(
                    severity: .info,
                    category: "价格提醒",
                    title: title,
                    body: body,
                    assetID: alert.asset.id,
                    openPortfolio: false
                )
            )
        } else {
            AudioServicesPlaySystemSound(1007)
        }
    }

    private func syncHubDemand() {
        hub.setDemand(alerts.filter(\.isEnabled).map(\.asset), for: "alerts")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
