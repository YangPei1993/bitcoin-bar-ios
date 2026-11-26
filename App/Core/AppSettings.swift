import Foundation
import Security
import SwiftUI

// MARK: - 偏好枚举

nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

nonisolated enum PriceColorStyle: String, CaseIterable, Identifiable, Sendable {
    case greenUp
    case redUp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .greenUp: return "绿涨红跌（国际）"
        case .redUp: return "红涨绿跌（中式）"
        }
    }

    var shortLabel: String {
        switch self {
        case .greenUp: return "绿涨红跌"
        case .redUp: return "红涨绿跌"
        }
    }
}

// MARK: - 钥匙串安全存储（iOS Keychain）

nonisolated enum KeychainStore {
    private static let service = "com.paul.bitcoin-bar-ios.secrets"

    static func save(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        guard trimmed.isEmpty == false, let data = trimmed.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - iOS 应用全局设置

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let appearance = "AppSettings.appearance"
        static let priceColorStyle = "AppSettings.priceColorStyle"
        static let liveActivityAssets = "AppSettings.liveActivityAssets"
        static let liveActivityShowsBalance = "AppSettings.liveActivityShowsBalance"
        static let aiProvider = "AppSettings.ai.provider"
        static let aiBaseURL = "AppSettings.ai.baseURL"
        static let aiModel = "AppSettings.ai.model"
        static let aiKeyAccount = "ai.apiKey"
    }

    private static let defaultLiveAssets: [CryptoAsset] = [
        CryptoAsset(id: "BTC-USDT", symbol: "BTC", name: "Bitcoin", instrumentKind: .spot),
        CryptoAsset(id: "ETH-USDT", symbol: "ETH", name: "Ethereum", instrumentKind: .spot),
        CryptoAsset(id: "SOL-USDT", symbol: "SOL", name: "Solana", instrumentKind: .spot)
    ]

    var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
        }
    }

    var priceColorStyle: PriceColorStyle {
        didSet {
            UserDefaults.standard.set(priceColorStyle.rawValue, forKey: Keys.priceColorStyle)
            onLiveActivityConfigChanged?()
        }
    }

    /// 灵动岛观测标的列表（第 1 个为药丸收起态主观测标的，最多保留 3 个在展开态/锁屏同屏展示）
    var liveActivityAssets: [CryptoAsset] {
        didSet {
            let trimmed = Array(liveActivityAssets.prefix(3))
            if trimmed != liveActivityAssets {
                liveActivityAssets = trimmed
                return
            }
            if let data = try? JSONEncoder().encode(trimmed) {
                UserDefaults.standard.set(data, forKey: Keys.liveActivityAssets)
            }
            onLiveActivityConfigChanged?()
        }
    }

    /// 灵动岛收起态右侧优先展示账户总余额（若未绑定账户则自动降级显示主标的 24h 涨跌幅）
    var liveActivityShowsBalance: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityShowsBalance, forKey: Keys.liveActivityShowsBalance)
            onLiveActivityConfigChanged?()
        }
    }

    var aiConfiguration: AIProviderConfiguration {
        didSet {
            UserDefaults.standard.set(aiConfiguration.provider.rawValue, forKey: Keys.aiProvider)
            UserDefaults.standard.set(aiConfiguration.baseURL, forKey: Keys.aiBaseURL)
            UserDefaults.standard.set(aiConfiguration.model, forKey: Keys.aiModel)
            KeychainStore.save(aiConfiguration.apiKey, account: Keys.aiKeyAccount)
        }
    }

    @ObservationIgnored var onLiveActivityConfigChanged: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        self.priceColorStyle = PriceColorStyle(rawValue: defaults.string(forKey: Keys.priceColorStyle) ?? "") ?? .greenUp

        if let data = defaults.data(forKey: Keys.liveActivityAssets),
           let decoded = try? JSONDecoder().decode([CryptoAsset].self, from: data),
           decoded.isEmpty == false {
            self.liveActivityAssets = Array(decoded.prefix(3))
        } else {
            self.liveActivityAssets = Self.defaultLiveAssets
        }

        self.liveActivityShowsBalance = defaults.object(forKey: Keys.liveActivityShowsBalance) as? Bool ?? true

        let provider = AIProvider(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .openAI
        let baseURL = defaults.string(forKey: Keys.aiBaseURL) ?? provider.defaultBaseURL
        let model = defaults.string(forKey: Keys.aiModel) ?? provider.defaultModel
        let apiKey = KeychainStore.load(account: Keys.aiKeyAccount)
        self.aiConfiguration = AIProviderConfiguration(
            provider: provider,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model
        )
    }

    // MARK: 灵动岛观测标的快捷操作

    var primaryLiveAsset: CryptoAsset {
        liveActivityAssets.first ?? Self.defaultLiveAssets[0]
    }

    func setPrimaryLiveAsset(_ asset: CryptoAsset) {
        var list = liveActivityAssets.filter { $0 != asset }
        list.insert(asset, at: 0)
        liveActivityAssets = Array(list.prefix(3))
    }

    func toggleLiveActivityAsset(_ asset: CryptoAsset) -> Bool {
        if let idx = liveActivityAssets.firstIndex(of: asset) {
            if liveActivityAssets.count > 1 {
                liveActivityAssets.remove(at: idx)
            }
            return false
        } else {
            var list = liveActivityAssets
            if list.count >= 3 {
                list.removeLast()
            }
            list.append(asset)
            liveActivityAssets = list
            return true
        }
    }

    func isLiveActivityAsset(_ asset: CryptoAsset) -> Bool {
        liveActivityAssets.contains(asset)
    }

    // MARK: 涨跌语义色

    var upColor: Color {
        priceColorStyle == .greenUp ? MarketColors.green : MarketColors.red
    }

    var downColor: Color {
        priceColorStyle == .greenUp ? MarketColors.red : MarketColors.green
    }

    func changeColor(for value: Double) -> Color {
        if value > 0 { return upColor }
        if value < 0 { return downColor }
        return MarketColors.neutral
    }

    func candleColor(for point: KlinePoint) -> Color {
        point.close >= point.open ? upColor : downColor
    }
}
