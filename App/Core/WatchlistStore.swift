import Foundation
import SwiftUI

// MARK: - 自定义分组模型

nonisolated struct CustomWatchGroup: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var assets: [CryptoAsset]

    init(id: String = UUID().uuidString, name: String, assets: [CryptoAsset] = []) {
        self.id = id
        self.name = name
        self.assets = assets
    }
}

// MARK: - 自选与自定义分组 Store

@MainActor
@Observable
final class WatchlistStore {
    private enum Keys {
        /// 与旧版本保持一致，确保老用户自选无缝继承
        static let favoriteAssets = "CryptoTickerStore.favoriteAssets"
        static let favoritesInitialized = "WatchlistStore.favoritesInitialized"
        static let customGroups = "WatchlistStore.customGroups"
    }

    private static let defaultStarterAssets: [CryptoAsset] = [
        CryptoAsset(id: "BTC-USDT", symbol: "BTC", name: "Bitcoin", instrumentKind: .spot),
        CryptoAsset(id: "ETH-USDT", symbol: "ETH", name: "Ethereum", instrumentKind: .spot),
        CryptoAsset(id: "SOL-USDT", symbol: "SOL", name: "Solana", instrumentKind: .spot),
        CryptoAsset(id: "BNB-USDT", symbol: "BNB", name: "BNB", instrumentKind: .spot)
    ]

    private(set) var favoriteAssets: [CryptoAsset]
    private(set) var customGroups: [CustomWatchGroup]

    @ObservationIgnored var onFavoritesChanged: (([CryptoAsset]) -> Void)?

    init() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Keys.favoriteAssets),
           let decoded = try? JSONDecoder().decode([CryptoAsset].self, from: data) {
            self.favoriteAssets = decoded
            defaults.set(true, forKey: Keys.favoritesInitialized)
        } else if defaults.bool(forKey: Keys.favoritesInitialized) {
            self.favoriteAssets = []
        } else {
            // 新用户首次启动预置 4 个主流币，避免空屏
            self.favoriteAssets = Self.defaultStarterAssets
            defaults.set(true, forKey: Keys.favoritesInitialized)
            if let encoded = try? JSONEncoder().encode(Self.defaultStarterAssets) {
                defaults.set(encoded, forKey: Keys.favoriteAssets)
            }
        }

        if let data = defaults.data(forKey: Keys.customGroups),
           let decoded = try? JSONDecoder().decode([CustomWatchGroup].self, from: data) {
            self.customGroups = decoded
        } else {
            self.customGroups = []
        }
    }

    /// 悬浮窗展示的品种列表（最多 10 个，无自选时展示默认主流币）
    var floatingAssets: [CryptoAsset] {
        let source = favoriteAssets.isEmpty ? Self.defaultStarterAssets : favoriteAssets
        return Array(source.prefix(10))
    }

    // MARK: 自选管理

    func isFavorite(_ asset: CryptoAsset) -> Bool {
        favoriteAssets.contains(asset)
    }

    @discardableResult
    func toggleFavorite(_ asset: CryptoAsset) -> Bool {
        let added: Bool
        if let index = favoriteAssets.firstIndex(of: asset) {
            favoriteAssets.remove(at: index)
            added = false
        } else {
            favoriteAssets.append(asset)
            added = true
        }
        persistFavorites()
        return added
    }

    func moveFavorite(_ asset: CryptoAsset, by offset: Int) {
        guard let currentIndex = favoriteAssets.firstIndex(of: asset) else { return }
        let targetIndex = currentIndex + offset
        guard favoriteAssets.indices.contains(targetIndex) else { return }
        let moved = favoriteAssets.remove(at: currentIndex)
        favoriteAssets.insert(moved, at: targetIndex)
        persistFavorites()
    }

    func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) {
        favoriteAssets.move(fromOffsets: source, toOffset: destination)
        persistFavorites()
    }

    /// 按拖拽源 ID 与目标 ID 重排自选顺序
    func moveFavorite(sourceID: String, toTargetID targetID: String) {
        guard sourceID != targetID,
              let fromIndex = favoriteAssets.firstIndex(where: { $0.id == sourceID }),
              let toIndex = favoriteAssets.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = favoriteAssets.remove(at: fromIndex)
        favoriteAssets.insert(moved, at: toIndex)
        persistFavorites()
    }

    func pinFavoriteToTop(_ asset: CryptoAsset) {
        if let index = favoriteAssets.firstIndex(of: asset) {
            let moved = favoriteAssets.remove(at: index)
            favoriteAssets.insert(moved, at: 0)
        } else {
            favoriteAssets.insert(asset, at: 0)
        }
        persistFavorites()
    }

    // MARK: 自定义分组管理

    @discardableResult
    func createGroup(named name: String) -> CustomWatchGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let group = CustomWatchGroup(name: trimmed)
        customGroups.append(group)
        persistGroups()
        return group
    }

    func renameGroup(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let index = customGroups.firstIndex(where: { $0.id == id }) else { return }
        customGroups[index].name = trimmed
        persistGroups()
    }

    func deleteGroup(id: String) {
        customGroups.removeAll { $0.id == id }
        persistGroups()
    }

    func contains(_ asset: CryptoAsset, inGroup groupID: String) -> Bool {
        customGroups.first(where: { $0.id == groupID })?.assets.contains(asset) ?? false
    }

    @discardableResult
    func toggle(_ asset: CryptoAsset, inGroup groupID: String) -> Bool {
        guard let index = customGroups.firstIndex(where: { $0.id == groupID }) else { return false }
        if let assetIndex = customGroups[index].assets.firstIndex(of: asset) {
            customGroups[index].assets.remove(at: assetIndex)
            persistGroups()
            return false
        } else {
            customGroups[index].assets.append(asset)
            persistGroups()
            return true
        }
    }

    func remove(_ asset: CryptoAsset, fromGroup groupID: String) {
        guard let index = customGroups.firstIndex(where: { $0.id == groupID }) else { return }
        customGroups[index].assets.removeAll { $0 == asset }
        persistGroups()
    }

    // MARK: 持久化

    private func persistFavorites() {
        UserDefaults.standard.set(true, forKey: Keys.favoritesInitialized)
        if let data = try? JSONEncoder().encode(favoriteAssets) {
            UserDefaults.standard.set(data, forKey: Keys.favoriteAssets)
        }
        onFavoritesChanged?(favoriteAssets)
    }

    private func persistGroups() {
        if let data = try? JSONEncoder().encode(customGroups) {
            UserDefaults.standard.set(data, forKey: Keys.customGroups)
        }
    }
}
