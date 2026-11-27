import SwiftUI

struct AssetDetailView: View {
    let asset: CryptoAsset
    let hub: MarketQuoteHub
    let tickerStore: CryptoTickerStore
    let watchlist: WatchlistStore
    let alertStore: PriceAlertStore
    let liveActivity: LiveActivityManager
    let settings: AppSettings
    let aiCache: AIAnalysisCache
    let onOpenAISettings: () -> Void
    let onShowToast: (String) -> Void

    @State private var isShowingAddAlert = false
    @State private var alertDirection: PriceAlertDirection = .above
    @State private var alertPriceInput = ""
    @State private var alertRepeating = false
    @State private var alertNote = ""

    @State private var isGeneratingAI = false
    @State private var aiError: String?

    private var quote: CryptoQuote? { hub.quotes[asset.id] }
    private var isFavorite: Bool { watchlist.isFavorite(asset) }
    private var isPrimaryLive: Bool { settings.primaryLiveAsset == asset }
    private var assetAlerts: [PriceAlert] { alertStore.alerts(for: asset) }
    private var cachedReport: AIAnalysisReport? { aiCache.report(for: asset, interval: tickerStore.selectedInterval) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                priceOverviewCard
                chartCard
                quickAlertCard
                aiAnalysisCard
            }
            .padding(14)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(asset.pairLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    let added = watchlist.toggleFavorite(asset)
                    onShowToast(added ? "已加入自选" : "已移出自选")
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .orange : .primary)
                }

                Button {
                    settings.setPrimaryLiveAsset(asset)
                    if liveActivity.isActive == false { liveActivity.start() }
                    onShowToast("已固定为灵动岛主标的：\(asset.symbol)")
                } label: {
                    Image(systemName: isPrimaryLive ? "platter.filled.top.iphone" : "platter.top.applewatch.case")
                        .foregroundStyle(isPrimaryLive ? Color.accentColor : .primary)
                }

                Menu {
                    if let quote {
                        Button("复制最新价格") {
                            UIPasteboard.general.string = MarketFormatter.price(quote.price)
                            onShowToast("已复制价格")
                        }
                    }
                    Button(settings.isLiveActivityAsset(asset) ? "从灵动岛移除" : "加入灵动岛观测列表") {
                        let added = settings.toggleLiveActivityAsset(asset)
                        onShowToast(added ? "已加入灵动岛观测" : "已从灵动岛移除")
                    }
                    if let url = asset.okxTradeURL {
                        Button("在 Safari 打开 OKX") {
                            UIApplication.shared.open(url)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { tickerStore.activateDetail(for: asset) }
        .onDisappear { tickerStore.deactivateDetail() }
    }

    // MARK: 核心报价卡片

    private var priceOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        CoinAvatar(symbol: asset.symbol, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(asset.name)
                                .font(.subheadline.weight(.semibold))
                            if let badge = asset.kindBadge {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    if let quote {
                        Text(MarketFormatter.price(quote.price))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .onTapGesture {
                                UIPasteboard.general.string = MarketFormatter.price(quote.price)
                                onShowToast("已复制价格")
                            }

                        let color = settings.changeColor(for: quote.changePercentage24h)
                        HStack(spacing: 8) {
                            Text(MarketFormatter.changePercent(quote.changePercentage24h))
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(color)

                            Text(MarketFormatter.changeAmount(quote.changeAmount24h))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(color)

                            Text("UTC+0")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("连接实时报价...")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    statBlock("24h 成交额", quote.map { MarketFormatter.compactVolume($0.volumeCurrency24h, isCurrency: true) } ?? "--")
                    statBlock("24h 成交量", quote.map { "\(MarketFormatter.compactVolume($0.volume24h)) \(asset.symbol)" } ?? "--")
                }
            }

            if let quote, quote.high24h > quote.low24h {
                DayRangeBar(
                    low: quote.low24h,
                    high: quote.high24h,
                    current: quote.price,
                    accent: settings.changeColor(for: quote.changePercentage24h)
                )
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 图表卡片

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(KlineInterval.allCases) { interval in
                    let isSelected = interval == tickerStore.selectedInterval
                    Button {
                        tickerStore.selectInterval(interval)
                    } label: {
                        Text(interval.shortLabel)
                            .font(.caption.weight(isSelected ? .semibold : .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isSelected ? Color.accentColor : Color.clear)
                            )
                            .foregroundStyle(isSelected ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))

            InteractiveMarketChart(
                klines: tickerStore.klines,
                interval: tickerStore.selectedInterval,
                isLoading: tickerStore.isLoadingKlines,
                errorMessage: tickerStore.klineError,
                settings: settings,
                onRetry: { tickerStore.reloadKlines() }
            )
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 快捷价格提醒卡片

    private var quickAlertCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("价格提醒", systemImage: "bell.badge")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(isShowingAddAlert ? "收起" : "添加提醒") {
                    if isShowingAddAlert {
                        withAnimation { isShowingAddAlert = false }
                    } else {
                        if let price = quote?.price, alertPriceInput.isEmpty {
                            alertPriceInput = MarketFormatter.price(price * 1.02, includeSymbol: false).replacingOccurrences(of: ",", with: "")
                        }
                        withAnimation { isShowingAddAlert = true }
                    }
                }
                .font(.subheadline.weight(.medium))
            }

            if isShowingAddAlert {
                VStack(spacing: 10) {
                    Picker("方向", selection: $alertDirection) {
                        ForEach(PriceAlertDirection.allCases) { dir in
                            Text(dir.label).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        TextField("目标价格 (USDT)", text: $alertPriceInput)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)

                        Button("保存") { saveAlert() }
                            .buttonStyle(.borderedProminent)
                            .disabled(parsedAlertPrice == nil)
                    }

                    TextField("备注（可选）", text: $alertNote)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Toggle("到达后重复提醒（5 分钟冷却）", isOn: $alertRepeating)
                        .font(.caption)
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            if assetAlerts.isEmpty == false {
                ForEach(assetAlerts) { alert in
                    HStack {
                        Image(systemName: alert.direction.symbol)
                            .font(.caption.bold())
                            .foregroundStyle(alert.direction == .above ? settings.upColor : settings.downColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(alert.direction.label) \(MarketFormatter.price(alert.targetPrice))")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            if alert.note.isEmpty == false {
                                Text(alert.note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { alert.isEnabled },
                            set: { _ in alertStore.toggleAlert(id: alert.id) }
                        ))
                        .labelsHidden()
                        Button(role: .destructive) {
                            alertStore.deleteAlert(id: alert.id)
                        } label: {
                            Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if isShowingAddAlert == false {
                Text("到达目标价时推送本机通知与已配置的微信 / Bark 外部通道。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: AI 行情深度解读卡片

    private var aiAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 行情解读", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                if let report = cachedReport {
                    Text(MarketFormatter.clockTime(report.generatedAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let report = cachedReport {
                    Button {
                        UIPasteboard.general.string = report.content
                        onShowToast("已复制 AI 分析报告")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("配置", action: onOpenAISettings)
                    .font(.caption)
            }

            if settings.aiConfiguration.isReady == false {
                HStack {
                    Text("前往设置配置 OpenAI、DeepSeek、通义千问或 Kimi 后，即可基于实时 K 线生成深度解读。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("去配置", action: onOpenAISettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Button {
                        Task { await runAIAnalysis() }
                    } label: {
                        HStack(spacing: 6) {
                            if isGeneratingAI { ProgressView().controlSize(.small) }
                            Text(isGeneratingAI ? "深度分析中..." : (cachedReport == nil ? "生成 \(tickerStore.selectedInterval.shortLabel) 解读" : "重新生成"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isGeneratingAI || tickerStore.klines.isEmpty)

                    Text("模型：\(settings.aiConfiguration.model)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let aiError {
                    Text(aiError)
                        .font(.caption)
                        .foregroundStyle(MarketColors.red)
                }

                if let report = cachedReport {
                    Text(report.content)
                        .font(.subheadline)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var parsedAlertPrice: Double? {
        let cleaned = alertPriceInput.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Double(cleaned), v > 0, v.isFinite else { return nil }
        return v
    }

    private func saveAlert() {
        guard let price = parsedAlertPrice else { return }
        alertStore.addAlert(asset: asset, direction: alertDirection, targetPrice: price, isRepeating: alertRepeating, note: alertNote)
        alertPriceInput = ""
        alertNote = ""
        withAnimation { isShowingAddAlert = false }
        onShowToast("已添加 \(asset.symbol) 价格提醒")
    }

    private func runAIAnalysis() async {
        isGeneratingAI = true
        aiError = nil
        defer { isGeneratingAI = false }
        do {
            let context = MarketAnalysisContext(asset: asset, interval: tickerStore.selectedInterval, quote: quote, klines: tickerStore.klines)
            let report = try await AIAnalysisService().analyze(context: context, configuration: settings.aiConfiguration)
            aiCache.store(report, for: asset, interval: tickerStore.selectedInterval)
        } catch {
            aiError = error.localizedDescription
        }
    }
}
