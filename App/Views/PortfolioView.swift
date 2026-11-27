import SwiftUI

private enum PortfolioSubTab: String, CaseIterable, Identifiable {
    case positions
    case orders
    case balances

    var id: String { rawValue }

    var label: String {
        switch self {
        case .positions: return "仓位"
        case .orders: return "委托"
        case .balances: return "余额"
        }
    }
}

struct PortfolioView: View {
    @Bindable var portfolio: PortfolioStore
    @Bindable var tradingStore: OKXTradingStore
    let riskEngine: RiskMonitorEngine
    let liveActivity: LiveActivityManager
    let settings: AppSettings
    let onOpenAccountSettings: () -> Void
    let onSelectPositionAsset: (CryptoAsset) -> Void
    let onShowToast: (String) -> Void

    @State private var selectedAccountID: UUID?
    @State private var subTab: PortfolioSubTab = .positions
    @State private var closingPosition: AccountPositionItem?
    @State private var tpslPosition: AccountPositionItem?

    @State private var isShowingAddBalanceAlert = false
    @State private var draftScopeKey = "total"
    @State private var draftCurrency = "USDT"
    @State private var draftDirection: BalanceAlertDirection = .below
    @State private var draftThreshold = ""
    @State private var draftRepeating = false
    @State private var draftNote = ""

    var body: some View {
        Group {
            if portfolio.accounts.isEmpty {
                emptyAccountsView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if portfolio.enabledAccounts.count > 1 {
                            accountFilterStrip
                        }
                        equitySummaryCard
                        activeRiskBannerIfNeeded
                        warningsBannerIfNeeded
                        subTabHeader
                        if subTab == .positions {
                            positionsSection
                        } else if subTab == .orders {
                            OpenOrdersSectionView(
                                tradingStore: tradingStore,
                                selectedAccountID: selectedAccountID,
                                settings: settings,
                                onShowToast: onShowToast
                            )
                        } else {
                            balancesSection
                        }
                    }
                    .padding(14)
                }
                .background(Color(.systemGroupedBackground))
                .refreshable {
                    await portfolio.refreshAll()
                    await tradingStore.refreshOrders()
                    await liveActivity.pushUpdateNow()
                }
            }
        }
        .navigationTitle("资产与仓位")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    portfolio.hideAmounts.toggle()
                } label: {
                    Image(systemName: portfolio.hideAmounts ? "eye.slash" : "eye")
                }

                Button(action: onOpenAccountSettings) {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .onAppear {
            if portfolio.enabledAccounts.isEmpty == false {
                portfolio.startAutoRefresh()
                Task { await tradingStore.refreshOrders() }
            }
        }
        .onDisappear {
            portfolio.stopAutoRefresh()
        }
        .onChange(of: subTab) { _, newTab in
            if newTab == .orders {
                Task { await tradingStore.refreshOrders() }
            }
        }
        .sheet(isPresented: $isShowingAddBalanceAlert) {
            addBalanceAlertSheet
        }
        .sheet(item: $closingPosition) { pos in
            ClosePositionSheet(position: pos, settings: settings, tradingStore: tradingStore) { msg in
                onShowToast(msg)
            }
        }
        .sheet(item: $tpslPosition) { pos in
            TPSLSheet(position: pos, settings: settings, tradingStore: tradingStore) { msg in
                onShowToast(msg)
            }
        }
    }

    private var emptyAccountsView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "wallet.bifold.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("接入 OKX / 币安只读账户")
                .font(.title3.weight(.bold))
            Text("在一个界面里实时查看现货余额、合约仓位、预估强平距离，并同步到 iPhone 灵动岛与强平预警。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 8) {
                Label("仅需只读权限，绝不触碰交易与提币", systemImage: "checkmark.shield.fill")
                Label("密钥加密存本机 iOS 钥匙串，零中转服务器", systemImage: "lock.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            Button {
                onOpenAccountSettings()
            } label: {
                Text("绑定 OKX / 币安账户")
                    .font(.headline)
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var accountFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("全部账户", selected: selectedAccountID == nil) { selectedAccountID = nil }
                ForEach(portfolio.enabledAccounts) { acc in
                    filterChip(acc.name, selected: selectedAccountID == acc.id) { selectedAccountID = acc.id }
                }
            }
        }
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(selected ? Color.accentColor : Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private var equitySummaryCard: some View {
        let equity = portfolio.totalEquityUSD(accountID: selectedAccountID)
        let pnl = portfolio.totalUnrealizedPnL(accountID: selectedAccountID)
        let pnlColor = settings.changeColor(for: pnl)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedAccountTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    prepareBalanceAlert(scopeKey: selectedAccountID.map { "account:\($0.uuidString)" } ?? "total", currency: "USDT", suggested: equity)
                } label: {
                    Label("余额提醒", systemImage: "bell.badge")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    liveActivity.toggle()
                    onShowToast(liveActivity.isActive ? "余额已同步到灵动岛" : "已关闭灵动岛")
                } label: {
                    Label(liveActivity.isActive ? "灵动岛中" : "上灵动岛", systemImage: "platter.filled.top.iphone")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(liveActivity.isActive ? MarketColors.green : .accentColor)
                .controlSize(.mini)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(portfolio.hideAmounts ? "****" : MarketFormatter.price(equity))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("合约未实现盈亏")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(portfolio.hideAmounts ? "****" : MarketFormatter.changeAmount(pnl))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(portfolio.hideAmounts ? .secondary : pnlColor)
                }
            }

            HStack {
                Label("\(portfolio.positions(accountID: selectedAccountID).count) 个持仓", systemImage: "chart.bar.xaxis")
                Spacer()
                if let updated = portfolio.lastUpdatedAt {
                    Text("同步于 \(MarketFormatter.clockTime(updated))")
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var activeRiskBannerIfNeeded: some View {
        if riskEngine.activePortfolioRisks.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(riskEngine.activePortfolioRisks) { risk in
                    let color: Color = risk.severity == .critical ? MarketColors.red : .orange
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: risk.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(risk.title).font(.caption.weight(.bold)).foregroundStyle(color)
                            Text(risk.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MarketColors.red.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var warningsBannerIfNeeded: some View {
        let warnings = portfolio.activeWarnings(accountID: selectedAccountID)
        if warnings.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, item in
                    Label("\(item.0)：\(item.1)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var subTabHeader: some View {
        HStack {
            Picker("", selection: $subTab) {
                ForEach(PortfolioSubTab.allCases) { tab in
                    let count: Int = switch tab {
                    case .positions: portfolio.positions(accountID: selectedAccountID).count
                    case .orders: tradingStore.pendingOrders(accountID: selectedAccountID).count + tradingStore.algoOrders(accountID: selectedAccountID).count
                    case .balances: portfolio.balances(accountID: selectedAccountID).count
                    }
                    Text("\(tab.label) (\(count))").tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if subTab == .balances {
                Toggle("隐藏<$1", isOn: $portfolio.hideSmallBalances)
                    .font(.caption2)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var positionsSection: some View {
        let items = portfolio.positions(accountID: selectedAccountID)
        if items.isEmpty {
            ContentUnavailableView("当前暂无合约持仓", systemImage: "tray", description: Text("下拉可立即同步交易所最新仓位。"))
                .padding(.vertical, 24)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(items) { pos in
                    PositionCardIOS(
                        position: pos,
                        hideAmounts: portfolio.hideAmounts,
                        canTrade: tradingStore.config.tradingEnabled && pos.exchange == .okx,
                        settings: settings,
                        onTap: {
                            onSelectPositionAsset(pos.marketAsset)
                        },
                        onClose: {
                            closingPosition = pos
                        },
                        onTPSL: {
                            tpslPosition = pos
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var balancesSection: some View {
        let items = portfolio.balances(accountID: selectedAccountID)
        if items.isEmpty {
            ContentUnavailableView("暂无符合条件的余额", systemImage: "banknote")
                .padding(.vertical, 24)
        } else {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        CoinAvatar(symbol: item.currency, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(item.currency).font(.subheadline.weight(.semibold))
                                Text(item.bucket.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.secondary)
                                Text(item.exchange.shortLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(item.accountName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(portfolio.hideAmounts ? "****" : MarketFormatter.price(item.total, includeSymbol: false))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                            Text(portfolio.hideAmounts ? "****" : (item.usdValue > 0 ? "≈ \(MarketFormatter.price(item.usdValue))" : "--"))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Button {
                            prepareBalanceAlert(scopeKey: "ccy:\(item.accountID.uuidString):\(item.currency)", currency: item.currency, suggested: item.total)
                        } label: {
                            Image(systemName: "bell")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var addBalanceAlertSheet: some View {
        NavigationStack {
            Form {
                Section("监控对象") {
                    Picker("范围", selection: $draftScopeKey) {
                        Text("全部账户总资产 (USD)").tag("total")
                        ForEach(portfolio.enabledAccounts) { acc in
                            Text("\(acc.name) 总权益 (USD)").tag("account:\(acc.id.uuidString)")
                            Text("\(acc.name) 指定币种数量").tag("currency:\(acc.id.uuidString)")
                        }
                    }

                    if draftScopeKey.hasPrefix("currency:") {
                        TextField("币种代码（如 USDT、BTC）", text: $draftCurrency)
                            .textInputAutocapitalization(.characters)
                    }
                }

                Section("触发阈值") {
                    Picker("条件", selection: $draftDirection) {
                        ForEach(BalanceAlertDirection.allCases) { dir in
                            Text(dir.label).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(draftScopeKey.hasPrefix("currency:") ? "阈值数量" : "阈值金额 (USD)", text: $draftThreshold)
                        .keyboardType(.decimalPad)

                    TextField("备注（可选，如补保证金）", text: $draftNote)
                    Toggle("到达后重复提醒（10 分钟冷却）", isOn: $draftRepeating)
                }
            }
            .navigationTitle("添加余额提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isShowingAddBalanceAlert = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { submitBalanceAlert() }
                        .disabled(Double(draftThreshold.replacingOccurrences(of: ",", with: "")) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var selectedAccountTitle: String {
        guard let selectedAccountID,
              let acc = portfolio.accounts.first(where: { $0.id == selectedAccountID }) else {
            return "总资产估值 (USD)"
        }
        return "\(acc.name) · 净值 (USD)"
    }

    private func prepareBalanceAlert(scopeKey: String, currency: String, suggested: Double) {
        if scopeKey.hasPrefix("ccy:") {
            let parts = scopeKey.split(separator: ":")
            if parts.count == 3 {
                draftScopeKey = "currency:\(parts[1])"
                draftCurrency = String(parts[2])
            }
        } else {
            draftScopeKey = scopeKey
            draftCurrency = currency
        }
        draftDirection = .below
        draftRepeating = false
        draftNote = ""
        draftThreshold = suggested > 0 ? MarketFormatter.price(suggested * 0.85, includeSymbol: false).replacingOccurrences(of: ",", with: "") : ""
        isShowingAddBalanceAlert = true
    }

    private func submitBalanceAlert() {
        let cleaned = draftThreshold.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let val = Double(cleaned), val >= 0 else { return }

        let scope: BalanceAlertScope
        if draftScopeKey == "total" {
            scope = .totalEquity
        } else if draftScopeKey.hasPrefix("account:"),
                  let uuid = UUID(uuidString: String(draftScopeKey.dropFirst("account:".count))),
                  let acc = portfolio.accounts.first(where: { $0.id == uuid }) {
            scope = .accountEquity(accountID: acc.id, accountName: acc.name)
        } else if draftScopeKey.hasPrefix("currency:"),
                  let uuid = UUID(uuidString: String(draftScopeKey.dropFirst("currency:".count))),
                  let acc = portfolio.accounts.first(where: { $0.id == uuid }) {
            let ccy = draftCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard ccy.isEmpty == false else { return }
            scope = .currencyBalance(accountID: acc.id, accountName: acc.name, currency: ccy)
        } else {
            scope = .totalEquity
        }

        portfolio.addBalanceAlert(scope: scope, direction: draftDirection, threshold: val, isRepeating: draftRepeating, note: draftNote)
        isShowingAddBalanceAlert = false
        onShowToast("已添加余额提醒：\(scope.title)")
    }
}

private struct PositionCardIOS: View {
    let position: AccountPositionItem
    let hideAmounts: Bool
    let canTrade: Bool
    let settings: AppSettings
    let onTap: () -> Void
    let onClose: () -> Void
    let onTPSL: () -> Void

    var body: some View {
        let sideColor = position.side == .long ? settings.upColor : settings.downColor
        let pnlColor = settings.changeColor(for: position.unrealizedPnL)
        let liqDistance = RiskMonitorEngine.liquidationDistancePercent(for: position)

        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        CoinAvatar(symbol: position.marketAsset.symbol, size: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(position.displayPair).font(.subheadline.weight(.bold))
                                Text(position.side.label)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(sideColor, in: RoundedRectangle(cornerRadius: 4))
                                Text("\(Int(position.leverage.rounded()))x \(position.marginMode)")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Text("\(position.exchange.shortLabel) · \(position.accountName)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if let liqDistance, liqDistance <= 12 {
                                    let isCrit = liqDistance <= 5
                                    Text("距强平 \(String(format: "%.1f", liqDistance))%")
                                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                                        .foregroundStyle(isCrit ? .white : .orange)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(isCrit ? MarketColors.red : Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(hideAmounts ? "****" : MarketFormatter.changeAmount(position.unrealizedPnL))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(hideAmounts ? .secondary : pnlColor)
                            Text(MarketFormatter.changePercent(position.roePercent))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(pnlColor)
                        }
                    }

                    HStack(spacing: 6) {
                        metric("持仓价值", hideAmounts ? "****" : MarketFormatter.price(position.notionalUSD))
                        metric("开仓均价", MarketFormatter.price(position.entryPrice))
                        metric("标记价格", MarketFormatter.price(position.markPrice))
                        metric("预估强平", position.liquidationPrice.map { MarketFormatter.price($0) } ?? "--", accent: position.liquidationPrice != nil ? .orange : nil)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canTrade {
                Divider()
                HStack(spacing: 10) {
                    Button(action: onTPSL) {
                        Label("止盈止损", systemImage: "scope")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onClose) {
                        Label("快捷平仓", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MarketColors.red)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metric(_ title: String, _ value: String, accent: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
