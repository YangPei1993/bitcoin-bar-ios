import AudioToolbox
import Foundation
import UserNotifications

// MARK: - 余额提醒模型

nonisolated enum BalanceAlertDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case above
    case below

    var id: String { rawValue }

    var label: String {
        switch self {
        case .above: return "高于"
        case .below: return "低于"
        }
    }

    var symbol: String {
        switch self {
        case .above: return "arrow.up.right"
        case .below: return "arrow.down.right"
        }
    }
}

nonisolated enum BalanceAlertScope: Hashable, Codable, Sendable {
    case totalEquity
    case accountEquity(accountID: UUID, accountName: String)
    case currencyBalance(accountID: UUID, accountName: String, currency: String)

    var title: String {
        switch self {
        case .totalEquity: return "全部账户总资产"
        case .accountEquity(_, let name): return "\(name) 总权益"
        case .currencyBalance(_, let name, let ccy): return "\(name) · \(ccy) 余额"
        }
    }

    var unitSuffix: String {
        switch self {
        case .totalEquity, .accountEquity: return "USD"
        case .currencyBalance(_, _, let ccy): return ccy
        }
    }

    var isUSD: Bool {
        switch self {
        case .totalEquity, .accountEquity: return true
        case .currencyBalance: return false
        }
    }

    var boundAccountID: UUID? {
        switch self {
        case .totalEquity: return nil
        case .accountEquity(let id, _), .currencyBalance(let id, _, _): return id
        }
    }
}

nonisolated struct BalanceAlert: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var scope: BalanceAlertScope
    var direction: BalanceAlertDirection
    var threshold: Double
    var isEnabled: Bool
    var isRepeating: Bool
    var note: String
    let createdAt: Date
    var lastTriggeredAt: Date?

    init(
        id: UUID = UUID(),
        scope: BalanceAlertScope,
        direction: BalanceAlertDirection,
        threshold: Double,
        isEnabled: Bool = true,
        isRepeating: Bool = false,
        note: String = "",
        createdAt: Date = Date(),
        lastTriggeredAt: Date? = nil
    ) {
        self.id = id
        self.scope = scope
        self.direction = direction
        self.threshold = threshold
        self.isEnabled = isEnabled
        self.isRepeating = isRepeating
        self.note = note
        self.createdAt = createdAt
        self.lastTriggeredAt = lastTriggeredAt
    }

    func matches(value: Double) -> Bool {
        switch direction {
        case .above: return value >= threshold
        case .below: return value <= threshold
        }
    }

    var formattedThreshold: String {
        if scope.isUSD {
            return MarketFormatter.price(threshold)
        }
        return "\(MarketFormatter.price(threshold, includeSymbol: false)) \(scope.unitSuffix)"
    }
}

// MARK: - iOS 交易所资产、仓位与余额提醒 Store

@MainActor
@Observable
final class PortfolioStore {
    private enum Keys {
        static let profiles = "PortfolioStore.accountProfiles"
        static let balanceAlerts = "PortfolioStore.balanceAlerts"
        static let hideAmounts = "PortfolioStore.hideAmounts"
        static let hideSmallBalances = "PortfolioStore.hideSmallBalances"
    }

    private static let repeatCooldownSeconds: TimeInterval = 600

    private(set) var accounts: [ExchangeAccountProfile] = []
    private(set) var snapshots: [UUID: AccountSnapshot] = [:]
    private(set) var accountErrors: [UUID: String] = [:]
    private(set) var balanceAlerts: [BalanceAlert] = []
    private(set) var isRefreshing = false
    private(set) var lastUpdatedAt: Date?

    var hideAmounts: Bool {
        didSet {
            UserDefaults.standard.set(hideAmounts, forKey: Keys.hideAmounts)
            onSnapshotsUpdated?()
        }
    }

    var hideSmallBalances: Bool {
        didSet {
            UserDefaults.standard.set(hideSmallBalances, forKey: Keys.hideSmallBalances)
        }
    }

    @ObservationIgnored private let service: ExchangeAccountService
    @ObservationIgnored private let dispatcher: NotificationDispatcher?
    @ObservationIgnored private var foregroundRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundAlertTask: Task<Void, Never>?
    @ObservationIgnored private var externalRiskMonitorEnabled = false
    @ObservationIgnored private var liveActivityActive = false
    @ObservationIgnored var onSnapshotsUpdated: (() -> Void)?

    init(
        service: ExchangeAccountService = ExchangeAccountService(),
        dispatcher: NotificationDispatcher? = nil
    ) {
        self.service = service
        self.dispatcher = dispatcher
        let defaults = UserDefaults.standard
        self.hideAmounts = defaults.object(forKey: Keys.hideAmounts) as? Bool ?? false
        self.hideSmallBalances = defaults.object(forKey: Keys.hideSmallBalances) as? Bool ?? true

        if let data = defaults.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([ExchangeAccountProfile].self, from: data) {
            self.accounts = decoded
        }

        if let data = defaults.data(forKey: Keys.balanceAlerts),
           let decoded = try? JSONDecoder().decode([BalanceAlert].self, from: data) {
            self.balanceAlerts = decoded
        }

        syncBackgroundAlertMonitor()
    }

    var enabledAccounts: [ExchangeAccountProfile] {
        accounts.filter(\.isEnabled)
    }

    var activeBalanceAlertCount: Int {
        balanceAlerts.filter(\.isEnabled).count
    }

    var hasAnySnapshot: Bool {
        enabledAccounts.contains { snapshots[$0.id] != nil }
    }

    func totalEquityUSD(accountID: UUID? = nil) -> Double {
        filteredSnapshots(accountID: accountID).reduce(0) { $0 + $1.totalEquityUSD }
    }

    func totalUnrealizedPnL(accountID: UUID? = nil) -> Double {
        filteredSnapshots(accountID: accountID).reduce(0) { $0 + $1.totalUnrealizedPnL }
    }

    func positions(accountID: UUID? = nil) -> [AccountPositionItem] {
        filteredSnapshots(accountID: accountID)
            .flatMap(\.positions)
            .sorted { abs($0.notionalUSD) > abs($1.notionalUSD) }
    }

    func balances(accountID: UUID? = nil) -> [AccountBalanceItem] {
        let all = filteredSnapshots(accountID: accountID).flatMap(\.balances)
        let filtered = hideSmallBalances ? all.filter { $0.usdValue >= 1.0 || ($0.usdValue == 0 && $0.total > 0) } : all
        return filtered.sorted { $0.usdValue > $1.usdValue }
    }

    func activeWarnings(accountID: UUID? = nil) -> [(String, String)] {
        let targets = accountID == nil ? enabledAccounts : enabledAccounts.filter { $0.id == accountID }
        var messages: [(String, String)] = []
        for account in targets {
            if let error = accountErrors[account.id] {
                messages.append((account.name, error))
            } else if let warning = snapshots[account.id]?.warningMessage {
                messages.append((account.name, warning))
            }
        }
        return messages
    }

    private func filteredSnapshots(accountID: UUID?) -> [AccountSnapshot] {
        let enabledIDs = Set(enabledAccounts.map(\.id))
        if let accountID {
            guard enabledIDs.contains(accountID), let snap = snapshots[accountID] else { return [] }
            return [snap]
        }
        return enabledAccounts.compactMap { snapshots[$0.id] }
    }

    // MARK: 余额提醒

    func addBalanceAlert(
        scope: BalanceAlertScope,
        direction: BalanceAlertDirection,
        threshold: Double,
        isRepeating: Bool = false,
        note: String = ""
    ) {
        guard threshold >= 0, threshold.isFinite else { return }
        let alert = BalanceAlert(
            scope: scope,
            direction: direction,
            threshold: threshold,
            isEnabled: true,
            isRepeating: isRepeating,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        balanceAlerts.insert(alert, at: 0)
        persistBalanceAlerts()
        syncBackgroundAlertMonitor()
        Task { await requestNotificationPermissionIfNeeded() }
    }

    func toggleBalanceAlert(id: UUID) {
        guard let idx = balanceAlerts.firstIndex(where: { $0.id == id }) else { return }
        balanceAlerts[idx].isEnabled.toggle()
        persistBalanceAlerts()
        syncBackgroundAlertMonitor()
    }

    func deleteBalanceAlert(id: UUID) {
        balanceAlerts.removeAll { $0.id == id }
        persistBalanceAlerts()
        syncBackgroundAlertMonitor()
    }

    func clearTriggeredBalanceAlerts() {
        balanceAlerts.removeAll { $0.isEnabled == false && $0.lastTriggeredAt != nil }
        persistBalanceAlerts()
        syncBackgroundAlertMonitor()
    }

    func setExternalRiskMonitoringEnabled(_ enabled: Bool) {
        externalRiskMonitorEnabled = enabled
        syncBackgroundAlertMonitor()
    }

    func setLiveActivityActive(_ active: Bool) {
        liveActivityActive = active
        backgroundAlertTask?.cancel()
        backgroundAlertTask = nil
        syncBackgroundAlertMonitor()
        if active && enabledAccounts.isEmpty == false {
            Task { await refreshAll() }
        }
    }

    private func evaluateBalanceAlerts() {
        guard balanceAlerts.contains(where: \.isEnabled) else { return }
        let now = Date()
        var mutated = false

        for idx in balanceAlerts.indices {
            let alert = balanceAlerts[idx]
            guard alert.isEnabled else { continue }
            guard let value = currentValue(for: alert.scope) else { continue }
            guard alert.matches(value: value) else { continue }
            if let last = alert.lastTriggeredAt, now.timeIntervalSince(last) < Self.repeatCooldownSeconds {
                continue
            }

            balanceAlerts[idx].lastTriggeredAt = now
            if alert.isRepeating == false {
                balanceAlerts[idx].isEnabled = false
            }
            mutated = true
            notifyBalanceAlert(balanceAlerts[idx], currentValue: value)
        }

        if mutated {
            persistBalanceAlerts()
            syncBackgroundAlertMonitor()
        }
    }

    private func currentValue(for scope: BalanceAlertScope) -> Double? {
        switch scope {
        case .totalEquity:
            guard enabledAccounts.isEmpty == false,
                  enabledAccounts.allSatisfy({ snapshots[$0.id] != nil }) else { return nil }
            return totalEquityUSD(accountID: nil)
        case .accountEquity(let accountID, _):
            return snapshots[accountID]?.totalEquityUSD
        case .currencyBalance(let accountID, _, let currency):
            guard let snap = snapshots[accountID] else { return nil }
            return snap.balances
                .filter { $0.currency.caseInsensitiveCompare(currency) == .orderedSame }
                .reduce(0.0) { $0 + $1.total }
        }
    }

    private func notifyBalanceAlert(_ alert: BalanceAlert, currentValue: Double) {
        let formattedNow = alert.scope.isUSD
            ? MarketFormatter.price(currentValue)
            : "\(MarketFormatter.price(currentValue, includeSymbol: false)) \(alert.scope.unitSuffix)"

        let title = "\(alert.scope.title) \(alert.direction.label) \(alert.formattedThreshold)"
        var body = "当前余额：\(formattedNow)"
        if alert.note.isEmpty == false {
            body += " · \(alert.note)"
        }

        if let dispatcher {
            dispatcher.dispatch(
                AlertPayload(
                    severity: .info,
                    category: "余额提醒",
                    title: title,
                    body: body,
                    assetID: nil,
                    openPortfolio: true
                )
            )
        } else {
            AudioServicesPlaySystemSound(1007)
        }
    }

    private func requestNotificationPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private func syncBackgroundAlertMonitor() {
        let shouldRun = (activeBalanceAlertCount > 0 || externalRiskMonitorEnabled || liveActivityActive) && enabledAccounts.isEmpty == false
        if shouldRun {
            guard backgroundAlertTask == nil else { return }
            backgroundAlertTask = Task { [weak self] in
                while Task.isCancelled == false {
                    guard let self else { return }
                    let intervalSeconds: Double = self.liveActivityActive ? 5 : 20
                    try? await Task.sleep(for: .seconds(intervalSeconds))
                    guard Task.isCancelled == false else { return }
                    if self.foregroundRefreshTask == nil {
                        await self.refreshAll()
                    }
                }
            }
        } else {
            backgroundAlertTask?.cancel()
            backgroundAlertTask = nil
        }
    }

    // MARK: 账户 CRUD

    func credentials(for accountID: UUID) -> ExchangeCredentials {
        ExchangeCredentials(
            apiKey: KeychainStore.load(account: keychainKey(accountID, field: "apiKey")),
            secretKey: KeychainStore.load(account: keychainKey(accountID, field: "secretKey")),
            passphrase: KeychainStore.load(account: keychainKey(accountID, field: "passphrase"))
        )
    }

    @discardableResult
    func saveAccount(
        editingID: UUID?,
        exchange: ExchangeKind,
        name: String,
        customBaseURL: String,
        isSimulated: Bool,
        credentials: ExchangeCredentials
    ) -> ExchangeAccountProfile {
        let cleanCreds = credentials.trimmed
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(exchange.shortLabel) 主账户"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)

        let id = editingID ?? UUID()
        let existingCreds = editingID.map { self.credentials(for: $0) }

        let finalAPIKey = cleanCreds.apiKey.isEmpty ? (existingCreds?.apiKey ?? "") : cleanCreds.apiKey
        let finalSecret = cleanCreds.secretKey.isEmpty ? (existingCreds?.secretKey ?? "") : cleanCreds.secretKey
        let finalPass = cleanCreds.passphrase.isEmpty ? (existingCreds?.passphrase ?? "") : cleanCreds.passphrase

        KeychainStore.save(finalAPIKey, account: keychainKey(id, field: "apiKey"))
        KeychainStore.save(finalSecret, account: keychainKey(id, field: "secretKey"))
        KeychainStore.save(finalPass, account: keychainKey(id, field: "passphrase"))

        let profile = ExchangeAccountProfile(
            id: id,
            exchange: exchange,
            name: resolvedName,
            customBaseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            isSimulated: exchange == .okx ? isSimulated : false,
            isEnabled: true,
            maskedKey: ExchangeAccountProfile.maskAPIKey(finalAPIKey)
        )

        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx] = profile
        } else {
            accounts.append(profile)
        }
        persistProfiles()
        syncBackgroundAlertMonitor()

        Task { await refreshAccount(profile) }
        return profile
    }

    func toggleAccountEnabled(id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].isEnabled.toggle()
        persistProfiles()
        syncBackgroundAlertMonitor()
        if accounts[idx].isEnabled {
            let target = accounts[idx]
            Task { await refreshAccount(target) }
        } else {
            onSnapshotsUpdated?()
        }
    }

    func deleteAccount(id: UUID) {
        accounts.removeAll { $0.id == id }
        snapshots.removeValue(forKey: id)
        accountErrors.removeValue(forKey: id)
        balanceAlerts.removeAll { $0.scope.boundAccountID == id }
        KeychainStore.save("", account: keychainKey(id, field: "apiKey"))
        KeychainStore.save("", account: keychainKey(id, field: "secretKey"))
        KeychainStore.save("", account: keychainKey(id, field: "passphrase"))
        persistProfiles()
        persistBalanceAlerts()
        syncBackgroundAlertMonitor()
        onSnapshotsUpdated?()
    }

    func testConnection(profile: ExchangeAccountProfile, credentials: ExchangeCredentials) async throws -> AccountSnapshot {
        try await service.fetchSnapshot(profile: profile, credentials: credentials)
    }

    // MARK: 并发同步

    func startAutoRefresh() {
        guard foregroundRefreshTask == nil else { return }
        foregroundRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopAutoRefresh() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    func refreshAll() async {
        let targets = enabledAccounts
        guard targets.isEmpty == false else { return }
        guard isRefreshing == false else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let service = service
        let pairs: [(ExchangeAccountProfile, ExchangeCredentials)] = targets.map { ($0, credentials(for: $0.id)) }

        await withTaskGroup(of: (UUID, Result<AccountSnapshot, Error>).self) { group in
            for (profile, creds) in pairs {
                group.addTask {
                    do {
                        let snap = try await service.fetchSnapshot(profile: profile, credentials: creds)
                        return (profile.id, .success(snap))
                    } catch {
                        return (profile.id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshots[id] = snapshot
                    accountErrors.removeValue(forKey: id)
                    lastUpdatedAt = Date()
                case .failure(let error):
                    accountErrors[id] = error.localizedDescription
                }
            }
        }

        evaluateBalanceAlerts()
        onSnapshotsUpdated?()
    }

    func refreshAccount(_ profile: ExchangeAccountProfile) async {
        let creds = credentials(for: profile.id)
        do {
            let snapshot = try await service.fetchSnapshot(profile: profile, credentials: creds)
            snapshots[profile.id] = snapshot
            accountErrors.removeValue(forKey: profile.id)
            lastUpdatedAt = Date()
            evaluateBalanceAlerts()
            onSnapshotsUpdated?()
        } catch {
            accountErrors[profile.id] = error.localizedDescription
        }
    }

    private func keychainKey(_ id: UUID, field: String) -> String {
        "exchange.\(id.uuidString).\(field)"
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    private func persistBalanceAlerts() {
        if let data = try? JSONEncoder().encode(balanceAlerts) {
            UserDefaults.standard.set(data, forKey: Keys.balanceAlerts)
        }
    }
}
