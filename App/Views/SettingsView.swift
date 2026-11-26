import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let hub: MarketQuoteHub
    let watchlist: WatchlistStore
    let tickerStore: CryptoTickerStore
    let portfolioStore: PortfolioStore
    @Bindable var dispatcher: NotificationDispatcher
    let liveActivity: LiveActivityManager
    let onShowToast: (String) -> Void

    var body: some View {
        Form {
            // 1. 灵动岛配置
            Section("灵动岛 & 锁屏实时显示") {
                Toggle("开启灵动岛实时盯盘", isOn: Binding(
                    get: { liveActivity.isActive },
                    set: { enabled in
                        if enabled { liveActivity.start() } else { liveActivity.stop() }
                        if let msg = liveActivity.statusMessage { onShowToast(msg) }
                    }
                ))

                Toggle("药丸右侧优先显示账户总余额", isOn: $settings.liveActivityShowsBalance)

                NavigationLink {
                    LiveActivityPickerView(settings: settings, watchlist: watchlist, tickerStore: tickerStore)
                } label: {
                    HStack {
                        Text("观测标的（最多 3 个）")
                        Spacer()
                        Text(settings.liveActivityAssets.map(\.symbol).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("灵动岛左侧实时展示第 1 个主观测标的现价，右侧显示账户总余额，长按展开同屏查看总资产、未实现盈亏与 3 个观测标的。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 2. 外观与配色
            Section("外观与配色") {
                Picker("界面主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }

                Picker("涨跌配色", selection: $settings.priceColorStyle) {
                    ForEach(PriceColorStyle.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
            }

            // 3. 交易所账户 / 推送通道 / AI 助手
            Section("账户与扩展能力") {
                NavigationLink {
                    ExchangeAccountsSettingsView(portfolioStore: portfolioStore)
                } label: {
                    HStack {
                        Label("OKX / 币安只读账户", systemImage: "wallet.bifold")
                        Spacer()
                        Text("\(portfolioStore.accounts.count) 个")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    PushChannelsSettingsView(dispatcher: dispatcher)
                } label: {
                    HStack {
                        Label("微信 / Bark / 短信推送通道", systemImage: "paperplane.circle")
                        Spacer()
                        Text("\(dispatcher.enabledChannelCount) 已启用")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    AISettingsSubView(settings: settings)
                } label: {
                    HStack {
                        Label("AI 行情解读模型", systemImage: "sparkles")
                        Spacer()
                        Text(settings.aiConfiguration.provider.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // 4. 连接状态与关于
            Section("行情数据源与关于") {
                HStack {
                    Circle()
                        .fill(hub.connectionState.isHealthy ? MarketColors.green : .orange)
                        .frame(width: 8, height: 8)
                    Text("行情流状态：\(hub.connectionState.label)")
                        .font(.subheadline)
                    Spacer()
                    Button("重连") { hub.reconnectNow() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("bitcoin-bar for iOS")
                        .font(.subheadline.weight(.semibold))
                    Text("开源、零后端服务器。所有交易所只读密钥、AI Key 与推送 Webhook 仅加密保存在本机 iOS 钥匙串中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 灵动岛观测标的挑选页

private struct LiveActivityPickerView: View {
    @Bindable var settings: AppSettings
    let watchlist: WatchlistStore
    let tickerStore: CryptoTickerStore

    private var candidates: [CryptoAsset] {
        var list = settings.liveActivityAssets
        for asset in watchlist.favoriteAssets + tickerStore.featuredSpotAssets + tickerStore.featuredContractAssets {
            if list.contains(asset) == false { list.append(asset) }
        }
        return list
    }

    var body: some View {
        List {
            Section("当前灵动岛观测（第 1 位为药丸主标的）") {
                ForEach(Array(settings.liveActivityAssets.enumerated()), id: \.element.id) { idx, asset in
                    HStack(spacing: 10) {
                        CoinAvatar(symbol: asset.symbol, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(asset.pairLabel).font(.subheadline.weight(.semibold))
                            Text(idx == 0 ? "主观测标的（收起态左侧展示）" : "展开态与锁屏展示")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if idx > 0 {
                            Button("设为主标") {
                                settings.setPrimaryLiveAsset(asset)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            }

            Section("点击添加或移除（最多 3 个）") {
                ForEach(candidates) { asset in
                    let selected = settings.isLiveActivityAsset(asset)
                    Button {
                        _ = settings.toggleLiveActivityAsset(asset)
                    } label: {
                        HStack {
                            CoinAvatar(symbol: asset.symbol, size: 24)
                            Text(asset.pairLabel).foregroundStyle(.primary)
                            if let badge = asset.kindBadge {
                                Text(badge).font(.caption2).foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("灵动岛观测标的")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - OKX / 币安账户管理页

struct ExchangeAccountsSettingsView: View {
    let portfolioStore: PortfolioStore

    @State private var isShowingForm = false
    @State private var editingID: UUID?
    @State private var exchange: ExchangeKind = .okx
    @State private var name = ""
    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var passphrase = ""
    @State private var customBaseURL = ""
    @State private var isSimulated = false
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        List {
            Section {
                Label("请仅创建“只读（Read-Only）”权限的 API Key，切勿勾选交易或提币权限。所有密钥仅保存在本机 iOS 钥匙串。", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("已绑定账户（\(portfolioStore.accounts.count)）") {
                if portfolioStore.accounts.isEmpty {
                    Text("尚未绑定任何交易所账户").foregroundStyle(.secondary)
                } else {
                    ForEach(portfolioStore.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(account.exchange.shortLabel)
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(account.exchange == .okx ? Color.primary : Color.orange, in: RoundedRectangle(cornerRadius: 4))
                                    Text(account.name).font(.subheadline.weight(.semibold))
                                    if account.isSimulated {
                                        Text("模拟盘").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Text("Key：\(account.maskedKey)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                if let err = portfolioStore.accountErrors[account.id] {
                                    Text(err).font(.caption2).foregroundStyle(MarketColors.red)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { account.isEnabled },
                                set: { _ in portfolioStore.toggleAccountEnabled(id: account.id) }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { openEdit(account) }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            portfolioStore.deleteAccount(id: portfolioStore.accounts[idx].id)
                        }
                    }
                }
            }
        }
        .navigationTitle("交易所账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openNew()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingForm) {
            NavigationStack {
                Form {
                    Section("基本信息") {
                        Picker("交易所", selection: $exchange) {
                            ForEach(ExchangeKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .disabled(editingID != nil)

                        TextField("账户备注（如 OKX 主号）", text: $name)
                    }

                    Section("只读 API 凭据（存入钥匙串）") {
                        SecureField(editingID == nil ? "API Key" : "留空保持原 API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(editingID == nil ? "Secret Key" : "留空保持原 Secret Key", text: $secretKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if exchange.requiresPassphrase {
                            SecureField(editingID == nil ? "Passphrase" : "留空保持原 Passphrase", text: $passphrase)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Toggle("OKX 模拟盘 API", isOn: $isSimulated)
                        }
                    }

                    Section("高级选项（可选）") {
                        TextField("自定义域名（留空用官方）", text: $customBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    Section {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack {
                                if isTesting { ProgressView().padding(.trailing, 4) }
                                Text(isTesting ? "验证连接中..." : "测试连接")
                            }
                        }
                        .disabled(isTesting)

                        if let testResult {
                            Text(testResult)
                                .font(.caption)
                                .foregroundStyle(testOK ? MarketColors.green : MarketColors.red)
                        }
                    }
                }
                .navigationTitle(editingID == nil ? "新增账户" : "编辑账户")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isShowingForm = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            portfolioStore.saveAccount(
                                editingID: editingID,
                                exchange: exchange,
                                name: name,
                                customBaseURL: customBaseURL,
                                isSimulated: isSimulated,
                                credentials: ExchangeCredentials(apiKey: apiKey, secretKey: secretKey, passphrase: passphrase)
                            )
                            isShowingForm = false
                        }
                        .disabled(canSave == false)
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        if editingID != nil { return true }
        let okKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let okSec = secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let okPass = exchange.requiresPassphrase == false || passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return okKey && okSec && okPass
    }

    private func openNew() {
        editingID = nil
        exchange = .okx
        name = ""
        apiKey = ""
        secretKey = ""
        passphrase = ""
        customBaseURL = ""
        isSimulated = false
        testResult = nil
        isShowingForm = true
    }

    private func openEdit(_ acc: ExchangeAccountProfile) {
        editingID = acc.id
        exchange = acc.exchange
        name = acc.name
        apiKey = ""
        secretKey = ""
        passphrase = ""
        customBaseURL = acc.customBaseURL
        isSimulated = acc.isSimulated
        testResult = nil
        isShowingForm = true
    }

    private func test() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        let existing = editingID.map { portfolioStore.credentials(for: $0) }
        let creds = ExchangeCredentials(
            apiKey: apiKey.isEmpty ? (existing?.apiKey ?? "") : apiKey,
            secretKey: secretKey.isEmpty ? (existing?.secretKey ?? "") : secretKey,
            passphrase: passphrase.isEmpty ? (existing?.passphrase ?? "") : passphrase
        )
        let profile = ExchangeAccountProfile(id: editingID ?? UUID(), exchange: exchange, name: name.isEmpty ? exchange.shortLabel : name, customBaseURL: customBaseURL, isSimulated: isSimulated)
        do {
            let snap = try await portfolioStore.testConnection(profile: profile, credentials: creds)
            testOK = true
            testResult = "连接成功！总权益约 \(MarketFormatter.price(snap.totalEquityUSD))，当前持仓 \(snap.positions.count) 个。"
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }
}

// MARK: - 外部推送通道与语音播报设置页

struct PushChannelsSettingsView: View {
    @Bindable var dispatcher: NotificationDispatcher

    @State private var isShowingForm = false
    @State private var editingID: UUID?
    @State private var kind: NotificationChannelKind = .bark
    @State private var name = ""
    @State private var routing: ChannelRoutingRule = .riskOnly
    @State private var secret = ""
    @State private var extra1 = ""
    @State private var extra2 = ""
    @State private var extra3 = ""
    @State private var isTesting = false
    @State private var testMsg: String?
    @State private var testOK = false

    var body: some View {
        List {
            Section("本机语音与静音") {
                Toggle("全局静音（暂停所有推送）", isOn: $dispatcher.isMuted)
                Picker("中文语音播报", selection: $dispatcher.voiceMode) {
                    ForEach(VoiceAlertMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Button("试听语音告警") {
                    dispatcher.speakAlert("极危告警。BTC 永续多单距离强平不足 5%，请立即关注保证金。")
                }
            }

            Section("已配置推送通道（\(dispatcher.channels.count)）") {
                if dispatcher.channels.isEmpty {
                    Text("点击右上角 + 添加微信、企业微信、Bark、飞书、Telegram 或 Twilio 短信通道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dispatcher.channels) { ch in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(ch.name).font(.subheadline.weight(.semibold))
                                    Text(ch.routingRule.shortLabel)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text("\(ch.kind.label) · \(ch.maskedSecret)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { ch.isEnabled },
                                set: { _ in dispatcher.toggleChannel(id: ch.id) }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { openEdit(ch) }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            dispatcher.deleteChannel(id: dispatcher.channels[idx].id)
                        }
                    }
                }
            }
        }
        .navigationTitle("推送通道")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { openNew() } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isShowingForm) {
            NavigationStack {
                Form {
                    Section {
                        Picker("通道类型", selection: $kind) {
                            ForEach(NotificationChannelKind.allCases) { k in
                                Text(k.label).tag(k)
                            }
                        }
                        .disabled(editingID != nil)

                        Text(kind.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("通道备注", text: $name)

                        Picker("推送范围", selection: $routing) {
                            ForEach(ChannelRoutingRule.allCases) { r in
                                Text(r.label).tag(r)
                            }
                        }
                    }

                    Section("通道密钥（存入钥匙串）") {
                        SecureField(editingID == nil ? kind.primarySecretPlaceholder : "留空保持原配置不变", text: $secret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        if kind == .telegram {
                            TextField("Chat ID（如 123456789）", text: $extra1)
                        } else if kind == .twilioSMS {
                            TextField("Account SID", text: $extra1).textInputAutocapitalization(.never)
                            TextField("发送号码（From）", text: $extra2)
                            TextField("接收手机号（如 +86...）", text: $extra3)
                        } else if kind == .customWebhook {
                            TextField("可选鉴权 Bearer Token", text: $extra1).textInputAutocapitalization(.never)
                        }
                    }

                    Section {
                        Button {
                            Task { await runTest() }
                        } label: {
                            HStack {
                                if isTesting { ProgressView().padding(.trailing, 4) }
                                Text(isTesting ? "发送中..." : "发送测试消息")
                            }
                        }
                        .disabled(isTesting)

                        if let testMsg {
                            Text(testMsg).font(.caption).foregroundStyle(testOK ? MarketColors.green : MarketColors.red)
                        }
                    }
                }
                .navigationTitle(editingID == nil ? "添加推送通道" : "编辑推送通道")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { isShowingForm = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            dispatcher.saveChannel(
                                editingID: editingID,
                                kind: kind,
                                name: name,
                                routingRule: routing,
                                secret: secret,
                                extraField1: extra1,
                                extraField2: extra2,
                                extraField3: extra3
                            )
                            isShowingForm = false
                        }
                        .disabled(editingID == nil && secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func openNew() {
        editingID = nil
        kind = .bark
        name = ""
        routing = .riskOnly
        secret = ""
        extra1 = ""
        extra2 = ""
        extra3 = ""
        testMsg = nil
        isShowingForm = true
    }

    private func openEdit(_ ch: NotificationChannelConfig) {
        editingID = ch.id
        kind = ch.kind
        name = ch.name
        routing = ch.routingRule
        secret = ""
        extra1 = ch.extraField1
        extra2 = ch.extraField2
        extra3 = ch.extraField3
        testMsg = nil
        isShowingForm = true
    }

    private func runTest() async {
        isTesting = true
        testMsg = nil
        defer { isTesting = false }
        let resolvedSecret = secret.isEmpty ? (editingID.map { dispatcher.secret(for: $0) } ?? "") : secret
        let cfg = NotificationChannelConfig(id: editingID ?? UUID(), kind: kind, name: name.isEmpty ? kind.label : name, routingRule: routing, extraField1: extra1, extraField2: extra2, extraField3: extra3)
        do {
            try await dispatcher.testChannel(config: cfg, secret: resolvedSecret)
            testOK = true
            testMsg = "测试消息发送成功！请检查对应客户端。"
        } catch {
            testOK = false
            testMsg = error.localizedDescription
        }
    }
}

// MARK: - AI 模型设置页

struct AISettingsSubView: View {
    @Bindable var settings: AppSettings
    @State private var isTesting = false
    @State private var testMsg: String?
    @State private var testOK = false

    var body: some View {
        Form {
            Section("服务商预设") {
                Picker("服务商", selection: providerBinding) {
                    ForEach(AIProvider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                Text(settings.aiConfiguration.provider.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("接口与密钥（存钥匙串）") {
                TextField("Base URL", text: $settings.aiConfiguration.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名称", text: $settings.aiConfiguration.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(settings.aiConfiguration.provider.requiresAPIKey ? "API Key" : "可留空", text: $settings.aiConfiguration.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        if isTesting { ProgressView().padding(.trailing, 4) }
                        Text(isTesting ? "测试连接中..." : "测试连接")
                    }
                }
                .disabled(isTesting)

                if let testMsg {
                    Text(testMsg).font(.caption).foregroundStyle(testOK ? MarketColors.green : MarketColors.red)
                }
            }
        }
        .navigationTitle("AI 行情助手")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { settings.aiConfiguration.provider },
            set: { provider in
                var cfg = settings.aiConfiguration
                cfg.provider = provider
                cfg.baseURL = provider.defaultBaseURL
                cfg.model = provider.defaultModel
                settings.aiConfiguration = cfg
                testMsg = nil
            }
        )
    }

    private func runTest() async {
        isTesting = true
        testMsg = nil
        defer { isTesting = false }
        do {
            let reply = try await AIAnalysisService().testConnection(configuration: settings.aiConfiguration)
            testOK = true
            testMsg = "连接正常，模型回复：\(reply)"
        } catch {
            testOK = false
            testMsg = error.localizedDescription
        }
    }
}
