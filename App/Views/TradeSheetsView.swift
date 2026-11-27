import SwiftUI

// MARK: - 1. K 线详情页快捷下单弹窗（双端复用）

struct QuickOrderSheet: View {
    let asset: CryptoAsset
    let referencePrice: Double
    let settings: AppSettings
    @Bindable var tradingStore: OKXTradingStore
    let initialSide: TradeOrderSide
    let onOpenTradingSettings: () -> Void
    let onOrderSucceeded: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedAccountID: UUID?
    @State private var side: TradeOrderSide
    @State private var orderType: TradeOrderType = .market
    @State private var marginMode: TradeMarginMode = .cross
    @State private var leverage: Int = 10
    @State private var limitPriceText: String = ""
    @State private var amountUSDText: String = ""
    @State private var showTPSL = false
    @State private var tpPriceText: String = ""
    @State private var slPriceText: String = ""

    @State private var spec: OKXInstrumentSpec?
    @State private var isLoadingSpec = false
    @State private var isConfirmingStep = false
    @State private var errorMessage: String?

    init(
        asset: CryptoAsset,
        referencePrice: Double,
        settings: AppSettings,
        tradingStore: OKXTradingStore,
        initialSide: TradeOrderSide = .buy,
        onOpenTradingSettings: @escaping () -> Void,
        onOrderSucceeded: @escaping (String) -> Void
    ) {
        self.asset = asset
        self.referencePrice = referencePrice
        self.settings = settings
        self.tradingStore = tradingStore
        self.initialSide = initialSide
        self.onOpenTradingSettings = onOpenTradingSettings
        self.onOrderSucceeded = onOrderSucceeded
        _side = State(initialValue: initialSide)
    }

    private var isDerivative: Bool {
        asset.instrumentKind != .spot
    }

    private var accounts: [ExchangeAccountProfile] {
        tradingStore.availableOKXAccounts
    }

    private var selectedAccount: ExchangeAccountProfile? {
        if let id = selectedAccountID, let matched = accounts.first(where: { $0.id == id }) {
            return matched
        }
        return accounts.first
    }

    private var availableUSDT: Double {
        guard let acc = selectedAccount else { return 0 }
        return tradingStore.availableUSDT(for: acc.id)
    }

    private var parsedLimitPrice: Double? {
        Double(limitPriceText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }

    private var parsedAmountUSD: Double? {
        Double(amountUSDText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }

    private var parsedTP: Double? {
        let trimmed = tpPriceText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Double(trimmed)
    }

    private var parsedSL: Double? {
        let trimmed = slPriceText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Double(trimmed)
    }

    private var effectivePrice: Double {
        if orderType == .limit, let p = parsedLimitPrice, p > 0 { return p }
        return referencePrice
    }

    private var estimatedPreview: (sizeText: String, actualNotional: Double, marginRequired: Double)? {
        guard let amount = parsedAmountUSD, amount > 0, effectivePrice > 0 else { return nil }
        if isDerivative == false && orderType == .market && side == .buy {
            let estCoin = amount / effectivePrice
            return ("约 \(MarketFormatter.price(estCoin, includeSymbol: false)) \(asset.symbol)", amount, amount)
        }
        if let spec, let aligned = spec.alignedOrderSize(fromNotionalUSD: amount, referencePrice: effectivePrice) {
            let unitName = isDerivative ? "张" : asset.symbol
            let margin = isDerivative ? (aligned.actualNotionalUSD / Double(max(leverage, 1))) : aligned.actualNotionalUSD
            return ("\(aligned.sizeString) \(unitName)", aligned.actualNotionalUSD, margin)
        }
        let estCoin = amount / effectivePrice
        let margin = isDerivative ? (amount / Double(max(leverage, 1))) : amount
        return ("约 \(MarketFormatter.price(estCoin, includeSymbol: false)) \(asset.symbol)", amount, margin)
    }

    private var maxAllowedLeverage: Int {
        max(Int((spec?.maxLeverage ?? 50).rounded(.down)), 1)
    }

    private var leveragePresets: [Int] {
        [3, 5, 10, 20, 50].filter { $0 <= maxAllowedLeverage }
    }

    var body: some View {
        NavigationStack {
            Group {
                if tradingStore.config.tradingEnabled == false {
                    tradingDisabledPlaceholder
                } else if accounts.isEmpty {
                    noOKXAccountPlaceholder
                } else if isConfirmingStep {
                    confirmationStepView
                } else {
                    orderFormView
                }
            }
            .navigationTitle(isConfirmingStep ? "二次确认下单" : "快捷下单 · \(asset.pairLabel)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isConfirmingStep ? "返回修改" : "取消") {
                        if isConfirmingStep {
                            withAnimation(.easeInOut(duration: 0.16)) { isConfirmingStep = false }
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 450, minHeight: 520, idealHeight: 600)
        #endif
        .onAppear {
            selectedAccountID = accounts.first?.id
            if limitPriceText.isEmpty && referencePrice > 0 {
                limitPriceText = plainNumber(referencePrice)
            }
            Task { await loadSpec() }
        }
    }

    // MARK: 未开启交易 / 无可用账户提示

    private var tradingDisabledPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("交易模式尚未开启")
                .font(.headline)
            Text("出于资金安全考虑，应用默认保持只读状态。请在「设置 → 交易与安全」中手动开启 OKX 交易功能，并可先勾选「仅模拟盘交易」进行测试。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("前往设置开启") {
                dismiss()
                onOpenTradingSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noOKXAccountPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "wallet.bifold")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(tradingStore.config.preferSimulatedOnly ? "未找到 OKX 模拟盘账户" : "未找到可用的 OKX 账户")
                .font(.headline)
            Text(
                tradingStore.config.preferSimulatedOnly
                    ? "当前已开启「仅模拟盘交易」保护锁，请先在设置中绑定一个勾选了「模拟盘」的 OKX API Key，或关闭模拟盘锁。"
                    : "请先在「设置 → 账户」中绑定具备「交易」权限的 OKX API Key（严禁勾选提币权限）。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            Button("前往账户设置") {
                dismiss()
                onOpenTradingSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 下单填写表单

    private var orderFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 账户与实盘/模拟盘醒目标识
                if let acc = selectedAccount {
                    accountHeaderBar(acc)
                }

                // 方向切换（做多/做空 或 买入/卖出）
                HStack(spacing: 8) {
                    sideButton(.buy, color: settings.upColor)
                    sideButton(.sell, color: settings.downColor)
                }

                // 委托类型 + 保证金模式/杠杆
                VStack(alignment: .leading, spacing: 10) {
                    Picker("委托类型", selection: $orderType) {
                        ForEach(TradeOrderType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    if isDerivative {
                        HStack(spacing: 10) {
                            Picker("仓位模式", selection: $marginMode) {
                                ForEach(TradeMarginMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 140)

                            Spacer()

                            Text("杠杆 \(leverage)x")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                        }

                        HStack(spacing: 6) {
                            ForEach(leveragePresets, id: \.self) { lev in
                                Button {
                                    leverage = lev
                                } label: {
                                    Text("\(lev)x")
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(
                                            leverage == lev ? Color.accentColor : Color.primary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 7)
                                        )
                                        .foregroundStyle(leverage == lev ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                // 价格与下单金额
                VStack(alignment: .leading, spacing: 10) {
                    if orderType == .limit {
                        HStack {
                            Text("委托价格 (USDT)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if referencePrice > 0 {
                                Button("填入现价 \(MarketFormatter.price(referencePrice))") {
                                    limitPriceText = spec?.alignedPrice(referencePrice) ?? plainNumber(referencePrice)
                                }
                                .font(.caption2)
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                        numericTextField("输入限价", text: $limitPriceText)
                    } else {
                        HStack {
                            Text("委托价格")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("市价最优成交（参考 \(MarketFormatter.price(referencePrice))）")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        Text(isDerivative ? "名义下单价值 (USDT)" : "下单金额 (USDT)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("可用 \(MarketFormatter.price(availableUSDT))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    numericTextField("输入 USDT 金额", text: $amountUSDText)

                    // 快捷金额比例胶囊
                    HStack(spacing: 6) {
                        ForEach([0.1, 0.25, 0.5, 0.8], id: \.self) { pct in
                            Button {
                                let base = availableUSDT * pct * Double(isDerivative ? max(leverage, 1) : 1)
                                let capped = tradingStore.config.maxSingleOrderUSD > 0
                                    ? min(base, tradingStore.config.maxSingleOrderUSD)
                                    : base
                                if capped > 0 {
                                    amountUSDText = String(format: "%.2f", capped)
                                }
                            } label: {
                                Text("\(Int(pct * 100))%")
                                    .font(.caption2.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(availableUSDT <= 0)
                        }
                    }

                    // 实时换算摘要
                    if let preview = estimatedPreview {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("折算数量：\(preview.sizeText)")
                                    .font(.caption2.weight(.medium))
                                    .monospacedDigit()
                                if isDerivative {
                                    Text("预计占用保证金：≈ \(MarketFormatter.price(preview.marginRequired))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if tradingStore.config.maxSingleOrderUSD > 0 {
                                Text("限额 \(MarketFormatter.price(tradingStore.config.maxSingleOrderUSD))")
                                    .font(.caption2)
                                    .foregroundStyle(preview.actualNotional > tradingStore.config.maxSingleOrderUSD ? MarketColors.red : .secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(12)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                // 可选开仓附带止盈止损
                if isDerivative {
                    DisclosureGroup("开仓附带止盈 / 止损（可选）", isExpanded: $showTPSL) {
                        VStack(spacing: 8) {
                            numericTextField("止盈触发价（标记价，可选）", text: $tpPriceText)
                            numericTextField("止损触发价（标记价，可选）", text: $slPriceText)
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(12)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
                }

                if let errorMessage {
                    errorBanner(errorMessage)
                }

                // 进入二次确认
                Button {
                    validateAndEnterConfirm()
                } label: {
                    HStack {
                        if isLoadingSpec { ProgressView().controlSize(.small) }
                        Text("预览\(side.label(for: asset.instrumentKind))订单")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(side == .buy ? settings.upColor : settings.downColor)
                .disabled((parsedAmountUSD ?? 0) <= 0 || isLoadingSpec)
            }
            .padding(16)
        }
    }

    // MARK: 二次确认步

    private var confirmationStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let acc = selectedAccount {
                    environmentBanner(isSimulated: acc.isSimulated, accountName: acc.name)
                }

                VStack(alignment: .leading, spacing: 10) {
                    confirmRow("交易标的", "\(asset.pairLabel) (\(asset.instrumentKind.label))")
                    confirmRow(
                        "交易方向",
                        side.label(for: asset.instrumentKind),
                        valueColor: side == .buy ? settings.upColor : settings.downColor
                    )
                    confirmRow("委托方式", orderType == .market ? "市价最优成交" : "限价 \(MarketFormatter.price(parsedLimitPrice ?? 0))")
                    if isDerivative {
                        confirmRow("保证金与杠杆", "\(marginMode.label) · \(leverage)x")
                    }
                    if let preview = estimatedPreview {
                        confirmRow("委托数量", preview.sizeText)
                        confirmRow("预估名义价值", MarketFormatter.price(preview.actualNotional))
                        if isDerivative {
                            confirmRow("预计占用保证金", MarketFormatter.price(preview.marginRequired))
                        }
                    }
                    if let tp = parsedTP, tp > 0 {
                        confirmRow("附带止盈价", MarketFormatter.price(tp), valueColor: MarketColors.green)
                    }
                    if let sl = parsedSL, sl > 0 {
                        confirmRow("附带止损价", MarketFormatter.price(sl), valueColor: MarketColors.red)
                    }
                }
                .padding(14)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                if let errorMessage {
                    errorBanner(errorMessage)
                }

                Button {
                    Task { await executeOrder() }
                } label: {
                    HStack(spacing: 6) {
                        if tradingStore.isSubmitting {
                            ProgressView().controlSize(.small)
                        } else if tradingStore.config.requireBiometrics {
                            Image(systemName: "faceid")
                        }
                        Text(tradingStore.config.requireBiometrics
                             ? "通过 \(BiometricAuthorizer.capabilityLabel) 确认下单"
                             : "确认立即提交订单")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(side == .buy ? settings.upColor : settings.downColor)
                .disabled(tradingStore.isSubmitting)
            }
            .padding(16)
        }
    }

    // MARK: 子组件与业务逻辑

    private func accountHeaderBar(_ acc: ExchangeAccountProfile) -> some View {
        HStack(spacing: 8) {
            Text(acc.isSimulated ? "模拟盘" : "实盘")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(acc.isSimulated ? Color.orange : MarketColors.red, in: Capsule())

            if accounts.count > 1 {
                Picker("账户", selection: Binding(
                    get: { selectedAccount?.id ?? acc.id },
                    set: { selectedAccountID = $0 }
                )) {
                    ForEach(accounts) { item in
                        Text("\(item.name)\(item.isSimulated ? " (模拟盘)" : "")").tag(item.id)
                    }
                }
                .labelsHidden()
            } else {
                Text("OKX · \(acc.name)")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            if let spec {
                Text("步长 \(spec.lotSzString)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func sideButton(_ target: TradeOrderSide, color: Color) -> some View {
        let isSelected = side == target
        return Button {
            side = target
        } label: {
            Text(target.label(for: asset.instrumentKind))
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isSelected ? color : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func loadSpec() async {
        isLoadingSpec = true
        defer { isLoadingSpec = false }
        if let fetched = try? await tradingStore.instrumentSpec(for: asset, accountID: selectedAccount?.id) {
            spec = fetched
            if leverage > Int(fetched.maxLeverage) {
                leverage = max(Int(fetched.maxLeverage), 1)
            }
        }
    }

    private func validateAndEnterConfirm() {
        errorMessage = nil
        guard let amount = parsedAmountUSD, amount > 0 else {
            errorMessage = "请输入大于 0 的下单金额。"
            return
        }
        if orderType == .limit && (parsedLimitPrice ?? 0) <= 0 {
            errorMessage = "限价单必须输入有效的委托价格。"
            return
        }
        if tradingStore.config.maxSingleOrderUSD > 0 && amount > tradingStore.config.maxSingleOrderUSD {
            errorMessage = "下单金额 \(MarketFormatter.price(amount)) 超出单笔安全上限 \(MarketFormatter.price(tradingStore.config.maxSingleOrderUSD))。"
            return
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            isConfirmingStep = true
        }
    }

    private func executeOrder() async {
        guard let acc = selectedAccount, let amount = parsedAmountUSD else { return }
        errorMessage = nil
        let req = PlaceOrderRequest(
            accountID: acc.id,
            asset: asset,
            side: side,
            orderType: orderType,
            marginMode: marginMode,
            leverage: leverage,
            notionalUSD: amount,
            limitPrice: orderType == .limit ? parsedLimitPrice : nil,
            referencePrice: referencePrice,
            takeProfitPrice: showTPSL ? parsedTP : nil,
            stopLossPrice: showTPSL ? parsedSL : nil
        )
        do {
            let ordId = try await tradingStore.placeOrder(req)
            onOrderSucceeded("下单成功（\(asset.symbol) \(side.shortLabel(for: asset.instrumentKind))，单号 \(ordId.suffix(6))）")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 2. 持仓快捷平仓弹窗（双端复用）

struct ClosePositionSheet: View {
    let position: AccountPositionItem
    let settings: AppSettings
    @Bindable var tradingStore: OKXTradingStore
    let onCloseSucceeded: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ratio: Double = 1.0
    @State private var orderType: TradeOrderType = .market
    @State private var limitPriceText: String = ""
    @State private var isConfirming = false
    @State private var errorMessage: String?

    private var accountProfile: ExchangeAccountProfile? {
        tradingStore.allEnabledOKXAccounts.first(where: { $0.id == position.accountID })
    }

    private var parsedLimitPrice: Double? {
        Double(limitPriceText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    environmentBanner(
                        isSimulated: accountProfile?.isSimulated ?? false,
                        accountName: position.accountName
                    )

                    // 仓位摘要卡
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(position.displayPair) · \(position.side.label)单 \(Int(position.leverage.rounded()))x \(position.marginMode)")
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Text(MarketFormatter.changeAmount(position.unrealizedPnL))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(settings.changeColor(for: position.unrealizedPnL))
                        }
                        HStack {
                            Text("开仓 \(MarketFormatter.price(position.entryPrice))")
                            Spacer()
                            Text("标记 \(MarketFormatter.price(position.markPrice))")
                            Spacer()
                            Text("总价值 \(MarketFormatter.price(position.notionalUSD))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .padding(12)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                    if isConfirming == false {
                        // 平仓方式 + 比例选择
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("平仓方式", selection: $orderType) {
                                Text("市价极速平仓").tag(TradeOrderType.market)
                                Text("限价挂单平仓").tag(TradeOrderType.limit)
                            }
                            .pickerStyle(.segmented)

                            if orderType == .limit {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("平仓委托价 (USDT)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("填入标记价") {
                                            limitPriceText = plainNumber(position.markPrice)
                                        }
                                        .font(.caption2)
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)
                                    }
                                    numericTextField("输入限价", text: $limitPriceText)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("平仓比例")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("约平 \(MarketFormatter.price(position.notionalUSD * ratio))")
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                }
                                HStack(spacing: 8) {
                                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { item in
                                        let selected = abs(ratio - item) < 0.01
                                        Button {
                                            ratio = item
                                        } label: {
                                            Text("\(Int(item * 100))%")
                                                .font(.caption.weight(.bold))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 7)
                                                .background(selected ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                                .foregroundStyle(selected ? .white : .primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                        if let errorMessage { errorBanner(errorMessage) }

                        Button {
                            errorMessage = nil
                            if orderType == .limit && (parsedLimitPrice ?? 0) <= 0 {
                                errorMessage = "请输入有效的平仓限价。"
                                return
                            }
                            withAnimation(.easeInOut(duration: 0.16)) { isConfirming = true }
                        } label: {
                            Text("下一步：确认平仓 \(Int((ratio * 100).rounded()))%")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MarketColors.red)
                    } else {
                        // 二次确认
                        VStack(alignment: .leading, spacing: 8) {
                            confirmRow("平仓标的", "\(position.displayPair) (\(position.side.label)单)")
                            confirmRow("平仓方式", orderType == .market ? "市价成交" : "限价 \(MarketFormatter.price(parsedLimitPrice ?? 0))")
                            confirmRow("平仓比例", "\(Int((ratio * 100).rounded()))%（约 \(MarketFormatter.price(position.notionalUSD * ratio))）")
                            confirmRow("预估实现盈亏", MarketFormatter.changeAmount(position.unrealizedPnL * ratio), valueColor: settings.changeColor(for: position.unrealizedPnL))
                        }
                        .padding(14)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                        if let errorMessage { errorBanner(errorMessage) }

                        Button {
                            Task { await submitClose() }
                        } label: {
                            HStack(spacing: 6) {
                                if tradingStore.isSubmitting {
                                    ProgressView().controlSize(.small)
                                } else if tradingStore.config.requireBiometrics {
                                    Image(systemName: "faceid")
                                }
                                Text(tradingStore.config.requireBiometrics
                                     ? "通过 \(BiometricAuthorizer.capabilityLabel) 确认平仓"
                                     : "确认执行平仓")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MarketColors.red)
                        .disabled(tradingStore.isSubmitting)
                    }
                }
                .padding(16)
            }
            .navigationTitle(isConfirming ? "二次确认平仓" : "快捷平仓 · \(position.displayPair)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isConfirming ? "返回" : "取消") {
                        if isConfirming {
                            withAnimation(.easeInOut(duration: 0.16)) { isConfirming = false }
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 430, minHeight: 420, idealHeight: 470)
        #endif
        .onAppear {
            limitPriceText = plainNumber(position.markPrice)
        }
    }

    private func submitClose() async {
        errorMessage = nil
        let req = ClosePositionRequest(
            position: position,
            ratio: ratio,
            orderType: orderType,
            limitPrice: orderType == .limit ? parsedLimitPrice : nil
        )
        do {
            try await tradingStore.closePosition(req)
            onCloseSucceeded("已提交平仓：\(position.displayPair) \(Int((ratio * 100).rounded()))%")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 3. 持仓止盈止损设置弹窗（双端复用）

struct TPSLSheet: View {
    let position: AccountPositionItem
    let settings: AppSettings
    @Bindable var tradingStore: OKXTradingStore
    let onTPSLSucceeded: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var tpText = ""
    @State private var slText = ""
    @State private var triggerType: TriggerPriceType = .mark
    @State private var isConfirming = false
    @State private var errorMessage: String?

    private var accountProfile: ExchangeAccountProfile? {
        tradingStore.allEnabledOKXAccounts.first(where: { $0.id == position.accountID })
    }

    private var parsedTP: Double? {
        let t = tpText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Double(t)
    }

    private var parsedSL: Double? {
        let t = slText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Double(t)
    }

    private func estimatedPnL(at targetPrice: Double) -> Double? {
        guard position.entryPrice > 0, position.notionalUSD > 0 else { return nil }
        let ratio = (targetPrice - position.entryPrice) / position.entryPrice
        let signed = position.side == .long ? ratio : -ratio
        return position.notionalUSD * signed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    environmentBanner(
                        isSimulated: accountProfile?.isSimulated ?? false,
                        accountName: position.accountName
                    )

                    // 参考价格条
                    HStack(spacing: 8) {
                        refBox("开仓均价", MarketFormatter.price(position.entryPrice))
                        refBox("当前标记价", MarketFormatter.price(position.markPrice))
                        refBox("预估强平", position.liquidationPrice.map { MarketFormatter.price($0) } ?? "--", accent: .orange)
                    }

                    if isConfirming == false {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("止盈触发价 (USDT)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(MarketColors.green)
                                    Spacer()
                                    if let tp = parsedTP, let pnl = estimatedPnL(at: tp) {
                                        Text("预计 \(MarketFormatter.changeAmount(pnl))")
                                            .font(.caption2.weight(.semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(settings.changeColor(for: pnl))
                                    }
                                }
                                numericTextField(position.side == .long ? "高于开仓价（留空不设）" : "低于开仓价（留空不设）", text: $tpText)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("止损触发价 (USDT)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(MarketColors.red)
                                    Spacer()
                                    if let sl = parsedSL, let pnl = estimatedPnL(at: sl) {
                                        Text("预计 \(MarketFormatter.changeAmount(pnl))")
                                            .font(.caption2.weight(.semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(settings.changeColor(for: pnl))
                                    }
                                }
                                numericTextField(position.side == .long ? "低于开仓价（留空不设）" : "高于开仓价（留空不设）", text: $slText)
                            }

                            Picker("触发基准价", selection: $triggerType) {
                                ForEach(TriggerPriceType.allCases) { item in
                                    Text(item.label).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text("触发后将以市价全平该方向当前全部持仓（使用 OKX 整仓止盈止损，双向同时设置时自动构成 OCO 互斥单）。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                        if let errorMessage { errorBanner(errorMessage) }

                        Button {
                            errorMessage = nil
                            guard (parsedTP ?? 0) > 0 || (parsedSL ?? 0) > 0 else {
                                errorMessage = "请至少填写止盈价或止损价其中一项。"
                                return
                            }
                            withAnimation(.easeInOut(duration: 0.16)) { isConfirming = true }
                        } label: {
                            Text("下一步：确认止盈止损")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            confirmRow("生效仓位", "\(position.displayPair) · \(position.side.label)单（全仓位）")
                            confirmRow("触发基准", triggerType.label)
                            confirmRow("止盈触发价", parsedTP.map { MarketFormatter.price($0) } ?? "未设置", valueColor: parsedTP != nil ? MarketColors.green : .secondary)
                            confirmRow("止损触发价", parsedSL.map { MarketFormatter.price($0) } ?? "未设置", valueColor: parsedSL != nil ? MarketColors.red : .secondary)
                            confirmRow("触发执行", "市价全平（reduceOnly）")
                        }
                        .padding(14)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                        if let errorMessage { errorBanner(errorMessage) }

                        Button {
                            Task { await submitTPSL() }
                        } label: {
                            HStack(spacing: 6) {
                                if tradingStore.isSubmitting {
                                    ProgressView().controlSize(.small)
                                } else if tradingStore.config.requireBiometrics {
                                    Image(systemName: "faceid")
                                }
                                Text(tradingStore.config.requireBiometrics
                                     ? "通过 \(BiometricAuthorizer.capabilityLabel) 确认挂单"
                                     : "确认提交止盈止损")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tradingStore.isSubmitting)
                    }
                }
                .padding(16)
            }
            .navigationTitle(isConfirming ? "二次确认止盈止损" : "止盈止损 · \(position.displayPair)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isConfirming ? "返回" : "取消") {
                        if isConfirming {
                            withAnimation(.easeInOut(duration: 0.16)) { isConfirming = false }
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 430, minHeight: 430, idealHeight: 490)
        #endif
    }

    private func refBox(_ title: String, _ value: String, accent: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    private func submitTPSL() async {
        errorMessage = nil
        let req = PlaceTPSLRequest(
            position: position,
            takeProfitPrice: parsedTP,
            stopLossPrice: parsedSL,
            triggerPriceType: triggerType
        )
        do {
            _ = try await tradingStore.placeTPSL(req)
            onTPSLSucceeded("已为 \(position.displayPair) 挂出止盈止损单")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 4. 当前委托列表与撤单组件（供资产页双端复用）

struct OpenOrdersSectionView: View {
    @Bindable var tradingStore: OKXTradingStore
    let selectedAccountID: UUID?
    let settings: AppSettings
    let onShowToast: (String) -> Void

    @State private var confirmCancelAll = false

    private var pending: [OKXPendingOrder] {
        tradingStore.pendingOrders(accountID: selectedAccountID)
    }

    private var algos: [OKXAlgoOrder] {
        tradingStore.algoOrders(accountID: selectedAccountID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("共 \(pending.count + algos.count) 笔挂单")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    Task { await tradingStore.refreshOrders() }
                } label: {
                    if tradingStore.isLoadingOrders {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                if pending.isEmpty == false || algos.isEmpty == false {
                    Button("一键全撤", role: .destructive) {
                        confirmCancelAll = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(tradingStore.config.tradingEnabled == false || tradingStore.isSubmitting)
                }
            }

            if let err = tradingStore.lastOrdersError {
                errorBanner(err)
            }

            if pending.isEmpty && algos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("当前暂无未成交委托或止盈止损单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                if pending.isEmpty == false {
                    Text("普通委托 (\(pending.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(pending) { order in
                        pendingOrderRow(order)
                    }
                }

                if algos.isEmpty == false {
                    Text("止盈止损策略单 (\(algos.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, pending.isEmpty ? 0 : 4)
                    ForEach(algos) { order in
                        algoOrderRow(order)
                    }
                }
            }
        }
        .alert("确认一键全撤？", isPresented: $confirmCancelAll) {
            Button("取消", role: .cancel) {}
            Button("确认撤单", role: .destructive) {
                Task {
                    do {
                        try await tradingStore.cancelAllOrders(accountID: selectedAccountID)
                        onShowToast("已撤销全部未成交委托")
                    } catch {
                        onShowToast(error.localizedDescription)
                    }
                }
            }
        } message: {
            Text("将撤销当前筛选范围内全部 \(pending.count + algos.count) 笔普通委托及止盈止损单。")
        }
    }

    private func pendingOrderRow(_ order: OKXPendingOrder) -> some View {
        let dirColor = order.isBuySide ? settings.upColor : settings.downColor
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(order.displayPair)
                        .font(.subheadline.weight(.bold))
                    Text(order.directionLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(dirColor, in: RoundedRectangle(cornerRadius: 4))
                    if order.isSimulated {
                        Text("模拟盘")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                HStack(spacing: 10) {
                    Text("委托价 \(MarketFormatter.price(order.price))")
                    Text("数量 \(MarketFormatter.price(order.size, includeSymbol: false))")
                    if order.filledSize > 0 {
                        Text("已成 \(MarketFormatter.price(order.filledSize, includeSymbol: false))")
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

                Text("\(order.accountName) · \(MarketFormatter.clockTime(order.createdAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("撤单") {
                Task {
                    do {
                        try await tradingStore.cancelOrder(order)
                        onShowToast("已撤单：\(order.displayPair)")
                    } catch {
                        onShowToast(error.localizedDescription)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(MarketColors.red)
            .disabled(tradingStore.config.tradingEnabled == false || tradingStore.isSubmitting)
        }
        .padding(11)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 11))
    }

    private func algoOrderRow(_ order: OKXAlgoOrder) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(order.displayPair)
                        .font(.subheadline.weight(.bold))
                    Text(order.directionLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    if order.isSimulated {
                        Text("模拟盘")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                HStack(spacing: 10) {
                    if let tp = order.tpTriggerPx {
                        Text("止盈 \(MarketFormatter.price(tp))")
                            .foregroundStyle(MarketColors.green)
                    }
                    if let sl = order.slTriggerPx {
                        Text("止损 \(MarketFormatter.price(sl))")
                            .foregroundStyle(MarketColors.red)
                    }
                    if order.closeFraction == "1" {
                        Text("整仓市价")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()

                Text("\(order.accountName) · \(MarketFormatter.clockTime(order.createdAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("撤销") {
                Task {
                    do {
                        try await tradingStore.cancelAlgoOrder(order)
                        onShowToast("已撤销止盈止损：\(order.displayPair)")
                    } catch {
                        onShowToast(error.localizedDescription)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(MarketColors.red)
            .disabled(tradingStore.config.tradingEnabled == false || tradingStore.isSubmitting)
        }
        .padding(11)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 11))
    }
}

// MARK: - 5. 交易与安全设置区（双端复用）

struct TradingSecuritySettingsContent: View {
    @Bindable var tradingStore: OKXTradingStore

    @State private var maxOrderInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $tradingStore.config.tradingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用 OKX 交易下单与平仓")
                        .font(.subheadline.weight(.semibold))
                    Text("默认关闭保持只读安全；开启后可在持仓卡平仓/设止盈止损，并在 K 线页快捷下单。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if tradingStore.config.tradingEnabled {
                Divider()

                Toggle(isOn: $tradingStore.config.preferSimulatedOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仅允许 OKX 模拟盘交易（推荐先开启测试）")
                            .font(.subheadline.weight(.medium))
                        Text("开启后强制拦截所有实盘账户的下单与平仓请求，防止误切实盘。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $tradingStore.config.requireBiometrics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("提交前要求 \(BiometricAuthorizer.capabilityLabel) 验证")
                            .font(.subheadline.weight(.medium))
                        Text("下单、平仓、挂止盈止损及撤单前弹出系统生物识别确认。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("单笔开仓最大金额上限 (USDT)")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(tradingStore.config.maxSingleOrderUSD > 0
                             ? MarketFormatter.price(tradingStore.config.maxSingleOrderUSD)
                             : "不限")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }

                    HStack(spacing: 6) {
                        ForEach([200.0, 500.0, 1000.0, 5000.0, 0.0], id: \.self) { val in
                            let selected = abs(tradingStore.config.maxSingleOrderUSD - val) < 0.01
                            Button {
                                tradingStore.config.maxSingleOrderUSD = val
                                maxOrderInput = val > 0 ? String(format: "%.0f", val) : "0"
                            } label: {
                                Text(val > 0 ? "$\(Int(val))" : "不限")
                                    .font(.caption2.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(selected ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(selected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        numericTextField("自定义金额上限（0 表示不限）", text: $maxOrderInput)
                        Button("应用") {
                            let cleaned = maxOrderInput.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                            if let val = Double(cleaned), val >= 0 {
                                tradingStore.config.maxSingleOrderUSD = val
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text("说明：单笔上限仅限制「开仓下单」；平仓、止盈止损与撤单不受限额阻拦，确保紧急风控畅通。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("安全提示：在 OKX 创建交易 API Key 时，请仅勾选「读取 + 交易」，严禁勾选「提币」，并强烈建议绑定 IP 白名单。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(9)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            maxOrderInput = tradingStore.config.maxSingleOrderUSD > 0
                ? String(format: "%.0f", tradingStore.config.maxSingleOrderUSD)
                : "0"
        }
    }
}

// MARK: - 跨平台 UI 辅助

private var cardBackground: Color {
    #if os(iOS)
    return Color(.secondarySystemGroupedBackground)
    #else
    return Color.primary.opacity(0.045)
    #endif
}

@ViewBuilder
private func numericTextField(_ placeholder: String, text: Binding<String>) -> some View {
    #if os(iOS)
    TextField(placeholder, text: text)
        .keyboardType(.decimalPad)
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
    #else
    TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
    #endif
}

private func environmentBanner(isSimulated: Bool, accountName: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: isSimulated ? "testtube.2" : "exclamationmark.triangle.fill")
            .foregroundStyle(isSimulated ? .orange : MarketColors.red)
        VStack(alignment: .leading, spacing: 1) {
            Text(isSimulated ? "OKX 模拟盘环境 · \(accountName)" : "OKX 实盘真实资金 · \(accountName)")
                .font(.caption.weight(.bold))
                .foregroundStyle(isSimulated ? .orange : MarketColors.red)
            Text(isSimulated ? "当前指令仅发往 OKX 模拟盘，不会影响真实资产。" : "请仔细核对方向、价格与金额，提交后将真实成交。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
    .padding(10)
    .background((isSimulated ? Color.orange : MarketColors.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
}

private func confirmRow(_ title: String, _ value: String, valueColor: Color? = nil) -> some View {
    HStack {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
        Spacer()
        Text(value)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(valueColor ?? .primary)
    }
}

private func errorBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 6) {
        Image(systemName: "xmark.octagon.fill")
            .foregroundStyle(MarketColors.red)
        Text(message)
            .font(.caption)
            .foregroundStyle(MarketColors.red)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MarketColors.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
}

private func plainNumber(_ value: Double) -> String {
    guard value > 0, value.isFinite else { return "" }
    if value >= 1000 { return String(format: "%.2f", value) }
    if value >= 1 { return String(format: "%.4f", value) }
    return String(format: "%.6f", value)
}
