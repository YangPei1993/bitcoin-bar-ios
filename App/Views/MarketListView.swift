import SwiftUI

private enum MarketGroupTab: Hashable {
    case favorites
    case hot
    case gainers
    case losers
    case spot
    case contract
    case custom(String)
}

private enum MarketSortField {
    case defaultOrder
    case price
    case change24h
}

struct MarketListView: View {
    let hub: MarketQuoteHub
    let tickerStore: CryptoTickerStore
    let watchlist: WatchlistStore
    let alertStore: PriceAlertStore
    let liveActivity: LiveActivityManager
    let settings: AppSettings
    let onSelectAsset: (CryptoAsset) -> Void
    let onShowToast: (String) -> Void

    @State private var selectedTab: MarketGroupTab = .favorites
    @State private var searchText = ""
    @State private var sortField: MarketSortField = .defaultOrder
    @State private var sortAscending = false

    @State private var isShowingNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var quickAlertAsset: CryptoAsset?
    @State private var quickAlertDirection: PriceAlertDirection = .above
    @State private var quickAlertPrice = ""
    @State private var quickAlertRepeating = false

    var body: some View {
        VStack(spacing: 0) {
            if isSearchingMode == false {
                liveActivityControlBanner
                groupTabStrip
                sortHeaderRow
            }

            List {
                if isSearchingMode {
                    searchSection
                } else if needsOverview(for: selectedTab) && tickerStore.isLoadingOverview && rawTabAssets.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("加载实时榜单...")
                        Spacer()
                    }
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
                } else if displayedAssets.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(displayedAssets) { asset in
                        MarketRowCell(
                            asset: asset,
                            quote: hub.quotes[asset.id],
                            flash: hub.flashes[asset.id],
                            isFavorite: watchlist.isFavorite(asset),
                            isLiveActivityAsset: settings.isLiveActivityAsset(asset),
                            hasActiveAlert: alertStore.alerts(for: asset).contains(where: \.isEnabled),
                            showsVolumeSubtitle: selectedTab == .hot || selectedTab == .gainers || selectedTab == .losers,
                            settings: settings
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectAsset(asset) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                let added = watchlist.toggleFavorite(asset)
                                onShowToast(added ? "已加入自选" : "已移出自选")
                            } label: {
                                Label(watchlist.isFavorite(asset) ? "移出自选" : "加自选", systemImage: watchlist.isFavorite(asset) ? "star.slash" : "star.fill")
                            }
                            .tint(.orange)

                            Button {
                                openQuickAlert(for: asset)
                            } label: {
                                Label("提醒", systemImage: "bell.badge")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                settings.setPrimaryLiveAsset(asset)
                                if liveActivity.isActive == false {
                                    liveActivity.start()
                                }
                                onShowToast("灵动岛主标的已设为 \(asset.symbol)")
                            } label: {
                                Label("上岛", systemImage: "platter.filled.top.iphone")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            assetContextMenu(for: asset)
                        }
                    }
                    .onMove(perform: selectedTab == .favorites && sortField == .defaultOrder ? { src, dst in
                        watchlist.moveFavorites(fromOffsets: src, toOffset: dst)
                    } : nil)
                }
            }
            .listStyle(.plain)
            .refreshable {
                if needsOverview(for: selectedTab) {
                    await tickerStore.loadOverview(force: true)
                }
                await hub.refreshNow()
                if hub.connectionState.isHealthy == false {
                    hub.reconnectNow()
                }
            }
        }
        .navigationTitle("行情")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索现货、永续合约（如 BTC、SOL）")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                    Text(hub.connectionState.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if selectedTab == .favorites {
                    EditButton()
                        .font(.subheadline)
                }
            }
        }
        .onAppear {
            syncPanelDemand()
            tickerStore.prewarmSearchIndex()
        }
        .onChange(of: selectedTab) { _, newTab in
            sortField = .defaultOrder
            if needsOverview(for: newTab) {
                Task {
                    await tickerStore.loadOverview()
                    syncPanelDemand()
                }
            } else {
                syncPanelDemand()
            }
        }
        .onChange(of: watchlist.favoriteAssets) { _, _ in
            if selectedTab == .favorites { syncPanelDemand() }
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                await tickerStore.search("")
                return
            }
            try? await Task.sleep(for: .milliseconds(220))
            guard Task.isCancelled == false else { return }
            await tickerStore.search(trimmed)
        }
        .alert("新建自定义分组", isPresented: $isShowingNewGroupAlert) {
            TextField("如：AI 概念、主流观察", text: $newGroupName)
            Button("取消", role: .cancel) { newGroupName = "" }
            Button("创建") {
                if let group = watchlist.createGroup(named: newGroupName) {
                    selectedTab = .custom(group.id)
                    onShowToast("已创建分组“\(group.name)”")
                }
                newGroupName = ""
            }
        }
        .sheet(item: $quickAlertAsset) { asset in
            quickAlertSheet(for: asset)
        }
    }

    // MARK: 灵动岛快捷状态控制条

    private var liveActivityControlBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: liveActivity.isActive ? "platter.filled.top.and.arrow.up.iphone" : "platter.top.applewatch.case")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(liveActivity.isActive ? MarketColors.green : Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(liveActivity.isActive ? "灵动岛实时盯盘中" : "开启灵动岛实时显示")
                    .font(.caption.weight(.semibold))
                Text("观测：\(settings.liveActivityAssets.map(\.symbol).joined(separator: " · "))" + (settings.liveActivityShowsBalance ? " + 总余额" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(liveActivity.isActive ? "关闭" : "上岛") {
                liveActivity.toggle()
                if let err = liveActivity.statusMessage {
                    onShowToast(err)
                } else {
                    onShowToast(liveActivity.isActive ? "灵动岛已开启" : "灵动岛已关闭")
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(liveActivity.isActive ? .secondary : .accentColor)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: 横向胶囊分组栏

    private var groupTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tabPill("自选", tab: .favorites)
                tabPill("热门", tab: .hot)
                tabPill("涨幅", tab: .gainers)
                tabPill("跌幅", tab: .losers)
                tabPill("现货", tab: .spot)
                tabPill("合约", tab: .contract)

                ForEach(watchlist.customGroups) { group in
                    tabPill(group.name, tab: .custom(group.id))
                        .contextMenu {
                            Button("删除分组", role: .destructive) {
                                watchlist.deleteGroup(id: group.id)
                                if selectedTab == .custom(group.id) { selectedTab = .favorites }
                            }
                        }
                }

                Button {
                    newGroupName = ""
                    isShowingNewGroupAlert = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func tabPill(_ title: String, tab: MarketGroupTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 排序表头

    private var sortHeaderRow: some View {
        HStack {
            Text("交易对")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            sortButton("最新价", field: .price)
                .frame(width: 100, alignment: .trailing)
            sortButton("UTC+0 涨跌", field: .change24h)
                .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground).opacity(0.6))
    }

    private func sortButton(_ title: String, field: MarketSortField) -> some View {
        Button {
            if sortField == field {
                if sortAscending {
                    sortField = .defaultOrder
                    sortAscending = false
                } else {
                    sortAscending = true
                }
            } else {
                sortField = field
                sortAscending = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.caption2.weight(sortField == field ? .semibold : .medium))
            .foregroundStyle(sortField == field ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 搜索结果与空状态

    @ViewBuilder
    private var searchSection: some View {
        if tickerStore.isSearching && tickerStore.searchResults.isEmpty {
            HStack {
                Spacer()
                ProgressView("搜索全市场交易对...")
                Spacer()
            }
            .padding(.vertical, 28)
        } else if tickerStore.searchResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ForEach(tickerStore.searchResults) { asset in
                HStack(spacing: 12) {
                    CoinAvatar(symbol: asset.symbol, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(asset.pairLabel)
                                .font(.subheadline.weight(.semibold))
                            if let badge = asset.kindBadge {
                                Text(badge)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(asset.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        let added = watchlist.toggleFavorite(asset)
                        onShowToast(added ? "已加入自选" : "已移出自选")
                    } label: {
                        Image(systemName: watchlist.isFavorite(asset) ? "star.fill" : "star")
                            .foregroundStyle(watchlist.isFavorite(asset) ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    searchText = ""
                    onSelectAsset(asset)
                }
            }
        }
    }

    private var emptyStateRow: some View {
        ContentUnavailableView(
            selectedTab == .favorites ? "自选为空" : "分组暂无币种",
            systemImage: selectedTab == .favorites ? "star" : "folder",
            description: Text("点击顶部搜索框添加自选，或长按任意币种加入自定义分组。")
        )
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func assetContextMenu(for asset: CryptoAsset) -> some View {
        Button {
            let added = watchlist.toggleFavorite(asset)
            onShowToast(added ? "已加入自选" : "已移出自选")
        } label: {
            Label(watchlist.isFavorite(asset) ? "移出自选" : "加入自选", systemImage: watchlist.isFavorite(asset) ? "star.slash" : "star")
        }

        Button {
            settings.setPrimaryLiveAsset(asset)
            if liveActivity.isActive == false { liveActivity.start() }
            onShowToast("已设为灵动岛主标的：\(asset.symbol)")
        } label: {
            Label("设为灵动岛主观测标的", systemImage: "platter.filled.top.iphone")
        }

        Button {
            let added = settings.toggleLiveActivityAsset(asset)
            onShowToast(added ? "已加入灵动岛观测（最多 3 个）" : "已从灵动岛移除")
        } label: {
            Label(settings.isLiveActivityAsset(asset) ? "从灵动岛移除" : "加入灵动岛观测列表", systemImage: "eye")
        }

        if watchlist.customGroups.isEmpty == false {
            Menu("加入自定义分组") {
                ForEach(watchlist.customGroups) { group in
                    let exists = watchlist.contains(asset, inGroup: group.id)
                    Button {
                        let added = watchlist.toggle(asset, inGroup: group.id)
                        onShowToast(added ? "已加入“\(group.name)”" : "已移出“\(group.name)”")
                    } label: {
                        Text(exists ? "✓ \(group.name)" : group.name)
                    }
                }
            }
        }

        Button {
            openQuickAlert(for: asset)
        } label: {
            Label("添加价格提醒", systemImage: "bell.badge")
        }

        if let quote = hub.quotes[asset.id] {
            Button {
                UIPasteboard.general.string = MarketFormatter.price(quote.price)
                onShowToast("已复制价格 \(MarketFormatter.price(quote.price))")
            } label: {
                Label("复制最新价格", systemImage: "doc.on.doc")
            }
        }
    }

    private func quickAlertSheet(for asset: CryptoAsset) -> some View {
        NavigationStack {
            Form {
                Section("目标标的") {
                    HStack {
                        CoinAvatar(symbol: asset.symbol, size: 28)
                        Text(asset.pairLabel).font(.headline)
                        Spacer()
                        if let q = hub.quotes[asset.id] {
                            Text(MarketFormatter.price(q.price))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("触发条件") {
                    Picker("方向", selection: $quickAlertDirection) {
                        ForEach(PriceAlertDirection.allCases) { dir in
                            Text(dir.label).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("目标价格 (USDT)", text: $quickAlertPrice)
                        .keyboardType(.decimalPad)

                    Toggle("到达后重复提醒（5 分钟冷却）", isOn: $quickAlertRepeating)
                }
            }
            .navigationTitle("添加价格提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { quickAlertAsset = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let cleaned = quickAlertPrice.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if let val = Double(cleaned), val > 0 {
                            alertStore.addAlert(asset: asset, direction: quickAlertDirection, targetPrice: val, isRepeating: quickAlertRepeating)
                            onShowToast("已添加 \(asset.symbol) 价格提醒")
                            quickAlertAsset = nil
                        }
                    }
                    .disabled(Double(quickAlertPrice.replacingOccurrences(of: ",", with: "")) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: 数据源辅助

    private var isSearchingMode: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var rawTabAssets: [CryptoAsset] {
        switch selectedTab {
        case .favorites: return watchlist.favoriteAssets
        case .hot: return tickerStore.hotAssets
        case .gainers: return tickerStore.gainerAssets
        case .losers: return tickerStore.loserAssets
        case .spot: return tickerStore.featuredSpotAssets
        case .contract: return tickerStore.featuredContractAssets
        case .custom(let id): return watchlist.customGroups.first(where: { $0.id == id })?.assets ?? []
        }
    }

    private var displayedAssets: [CryptoAsset] {
        let base = rawTabAssets
        guard sortField != .defaultOrder else { return base }
        return base.sorted { lhs, rhs in
            let lq = hub.quotes[lhs.id]
            let rq = hub.quotes[rhs.id]
            let lv = sortField == .price ? (lq?.price ?? -Double.greatestFiniteMagnitude) : (lq?.changePercentage24h ?? -Double.greatestFiniteMagnitude)
            let rv = sortField == .price ? (rq?.price ?? -Double.greatestFiniteMagnitude) : (rq?.changePercentage24h ?? -Double.greatestFiniteMagnitude)
            return sortAscending ? (lv < rv) : (lv > rv)
        }
    }

    private var statusDotColor: Color {
        switch hub.connectionState {
        case .live: return MarketColors.green
        case .offline: return MarketColors.red
        default: return .orange
        }
    }

    private func needsOverview(for tab: MarketGroupTab) -> Bool {
        tab == .hot || tab == .gainers || tab == .losers
    }

    private func syncPanelDemand() {
        hub.setDemand(Array(rawTabAssets.prefix(30)), for: "panel")
    }

    private func openQuickAlert(for asset: CryptoAsset) {
        quickAlertDirection = .above
        quickAlertRepeating = false
        if let p = hub.quotes[asset.id]?.price {
            quickAlertPrice = MarketFormatter.price(p * 1.02, includeSymbol: false).replacingOccurrences(of: ",", with: "")
        } else {
            quickAlertPrice = ""
        }
        quickAlertAsset = asset
    }
}

// MARK: - iOS 行情行视图

private struct MarketRowCell: View {
    let asset: CryptoAsset
    let quote: CryptoQuote?
    let flash: PriceTickFlash?
    let isFavorite: Bool
    let isLiveActivityAsset: Bool
    let hasActiveAlert: Bool
    let showsVolumeSubtitle: Bool
    let settings: AppSettings

    @State private var flashColor: Color?

    var body: some View {
        HStack(spacing: 11) {
            CoinAvatar(symbol: asset.symbol, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(asset.symbol)
                        .font(.subheadline.weight(.semibold))
                    Text("/\(asset.quoteCurrency)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let badge = asset.kindBadge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.accentColor)
                    }
                    if isLiveActivityAsset {
                        Image(systemName: "platter.filled.top.iphone")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                    if hasActiveAlert {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.orange)
                    }
                }
                .lineLimit(1)

                Text(subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(quote.map { MarketFormatter.price($0.price) } ?? "--")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            changeBadge
        }
        .padding(.vertical, 4)
        .listRowBackground(flashColor?.opacity(0.14))
        .onChange(of: flash?.sequence) { _, _ in
            guard let flash else { return }
            flashColor = flash.direction == .up ? settings.upColor : settings.downColor
            withAnimation(.easeOut(duration: 0.6)) {
                flashColor = nil
            }
        }
    }

    @ViewBuilder
    private var changeBadge: some View {
        if let quote {
            let color = settings.changeColor(for: quote.changePercentage24h)
            Text(MarketFormatter.changePercent(quote.changePercentage24h))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 74, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Text("--")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 74, height: 28)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var subtitleText: String {
        if showsVolumeSubtitle, let quote, quote.volumeCurrency24h > 0 {
            return "24h 额 \(MarketFormatter.compactVolume(quote.volumeCurrency24h, isCurrency: true))"
        }
        return asset.name
    }
}
