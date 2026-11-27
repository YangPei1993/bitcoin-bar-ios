import CryptoKit
import Foundation

// MARK: - 交易所与账户模型

nonisolated enum ExchangeKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case okx
    case binance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .okx: return "OKX"
        case .binance: return "币安 Binance"
        }
    }

    var shortLabel: String {
        switch self {
        case .okx: return "OKX"
        case .binance: return "币安"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .okx: return "https://www.okx.com"
        case .binance: return "https://api.binance.com"
        }
    }

    var requiresPassphrase: Bool {
        self == .okx
    }
}

/// 账户元信息（不含任何密钥，可安全序列化存储）
nonisolated struct ExchangeAccountProfile: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var exchange: ExchangeKind
    var name: String
    var customBaseURL: String
    var isSimulated: Bool
    var isEnabled: Bool
    /// 仅保存脱敏展示片段（如 "a3f9••••8b2c"）
    var maskedKey: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        exchange: ExchangeKind,
        name: String,
        customBaseURL: String = "",
        isSimulated: Bool = false,
        isEnabled: Bool = true,
        maskedKey: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.exchange = exchange
        self.name = name
        self.customBaseURL = customBaseURL
        self.isSimulated = isSimulated
        self.isEnabled = isEnabled
        self.maskedKey = maskedKey
        self.createdAt = createdAt
    }

    var resolvedBaseURL: String {
        let trimmed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return exchange.defaultBaseURL }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    static func maskAPIKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else {
            return trimmed.isEmpty ? "" : "••••"
        }
        return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
    }
}

/// 账户敏感凭据（仅通过 Keychain 加密读写，绝不写入 UserDefaults）
nonisolated struct ExchangeCredentials: Equatable, Sendable {
    var apiKey: String
    var secretKey: String
    var passphrase: String

    var trimmed: ExchangeCredentials {
        ExchangeCredentials(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            passphrase: passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - 资产余额与合约仓位模型

nonisolated enum AccountBucket: String, Sendable {
    case trading = "交易"
    case funding = "资金"
    case spot = "现货"
    case futures = "合约"
}

nonisolated struct AccountBalanceItem: Identifiable, Equatable, Sendable {
    let id: String
    let accountID: UUID
    let accountName: String
    let exchange: ExchangeKind
    let bucket: AccountBucket
    let currency: String
    let total: Double
    let available: Double
    let frozen: Double
    let usdValue: Double
}

nonisolated enum PositionSide: String, Sendable {
    case long
    case short

    var label: String {
        switch self {
        case .long: return "多"
        case .short: return "空"
        }
    }
}

nonisolated struct AccountPositionItem: Identifiable, Equatable, Sendable {
    let id: String
    let accountID: UUID
    let accountName: String
    let exchange: ExchangeKind
    /// 对应本应用可直接打开详情的行情 ID（如 BTC-USDT-SWAP）
    let marketAsset: CryptoAsset
    let displayPair: String
    let side: PositionSide
    let marginMode: String
    /// 交易所原始持仓方向（OKX: "long" / "short" / "net"），用于精确平仓与挂 TP/SL
    let rawPosSide: String
    /// 交易所原始保证金模式（OKX: "cross" / "isolated"）
    let rawMarginMode: String
    let leverage: Double
    let quantity: Double
    let notionalUSD: Double
    let entryPrice: Double
    let markPrice: Double
    let liquidationPrice: Double?
    let unrealizedPnL: Double
    /// 收益率百分比，例如 12.5 表示 +12.5%
    let roePercent: Double

    init(
        id: String,
        accountID: UUID,
        accountName: String,
        exchange: ExchangeKind,
        marketAsset: CryptoAsset,
        displayPair: String,
        side: PositionSide,
        marginMode: String,
        rawPosSide: String? = nil,
        rawMarginMode: String? = nil,
        leverage: Double,
        quantity: Double,
        notionalUSD: Double,
        entryPrice: Double,
        markPrice: Double,
        liquidationPrice: Double?,
        unrealizedPnL: Double,
        roePercent: Double
    ) {
        self.id = id
        self.accountID = accountID
        self.accountName = accountName
        self.exchange = exchange
        self.marketAsset = marketAsset
        self.displayPair = displayPair
        self.side = side
        self.marginMode = marginMode
        self.rawPosSide = rawPosSide ?? side.rawValue
        self.rawMarginMode = rawMarginMode ?? (marginMode == "逐仓" ? "isolated" : "cross")
        self.leverage = leverage
        self.quantity = quantity
        self.notionalUSD = notionalUSD
        self.entryPrice = entryPrice
        self.markPrice = markPrice
        self.liquidationPrice = liquidationPrice
        self.unrealizedPnL = unrealizedPnL
        self.roePercent = roePercent
    }
}

nonisolated struct AccountSnapshot: Equatable, Sendable {
    let accountID: UUID
    let exchange: ExchangeKind
    let totalEquityUSD: Double
    let totalUnrealizedPnL: Double
    let balances: [AccountBalanceItem]
    let positions: [AccountPositionItem]
    let updatedAt: Date
    let warningMessage: String?
}

// MARK: - 交易所私有只读 API 服务

nonisolated struct ExchangeAccountService: Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static let stablecoins: Set<String> = [
        "USDT", "USDC", "FDUSD", "DAI", "TUSD", "USDE", "BUSD", "PYUSD", "USDG", "USDP", "USD"
    ]

    func fetchSnapshot(
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> AccountSnapshot {
        let clean = credentials.trimmed
        guard clean.apiKey.isEmpty == false, clean.secretKey.isEmpty == false else {
            throw ExchangeAPIError.missingCredentials
        }
        if profile.exchange.requiresPassphrase && clean.passphrase.isEmpty {
            throw ExchangeAPIError.missingPassphrase
        }

        switch profile.exchange {
        case .okx:
            return try await fetchOKXSnapshot(profile: profile, credentials: clean)
        case .binance:
            return try await fetchBinanceSnapshot(profile: profile, credentials: clean)
        }
    }

    // MARK: - OKX V5 只读接口

    private func fetchOKXSnapshot(
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> AccountSnapshot {
        async let tradingTask = okxGET(
            OKXEnvelope<OKXTradingAccountData>.self,
            path: "/api/v5/account/balance",
            profile: profile,
            credentials: credentials
        )
        async let positionsTask = okxGET(
            OKXEnvelope<OKXPositionData>.self,
            path: "/api/v5/account/positions",
            profile: profile,
            credentials: credentials
        )

        let tradingResponse = try await tradingTask
        let positionsResponse = try await positionsTask

        // 资金账户独立容错（部分 API Key 未勾选资金账户权限时不影响交易账户与仓位展示）
        let fundingResponse = try? await okxGET(
            OKXEnvelope<OKXFundingBalanceData>.self,
            path: "/api/v5/asset/balances",
            profile: profile,
            credentials: credentials
        )

        var balances: [AccountBalanceItem] = []
        var tradingEquity = 0.0
        var priceLookup: [String: Double] = [:]

        if let account = tradingResponse.data.first {
            tradingEquity = Double(account.totalEq ?? "") ?? 0
            for detail in account.details {
                let total = Double(detail.eq ?? "") ?? Double(detail.cashBal ?? "") ?? 0
                let available = Double(detail.availEq ?? "") ?? Double(detail.availBal ?? "") ?? 0
                let frozen = Double(detail.frozenBal ?? "") ?? max(total - available, 0)
                let usd = Double(detail.eqUsd ?? "") ?? 0
                guard total > 0 || usd > 0.0001 else { continue }

                if total > 0 && usd > 0 {
                    priceLookup[detail.ccy] = usd / total
                }

                balances.append(
                    AccountBalanceItem(
                        id: "\(profile.id.uuidString)-trading-\(detail.ccy)",
                        accountID: profile.id,
                        accountName: profile.name,
                        exchange: .okx,
                        bucket: .trading,
                        currency: detail.ccy,
                        total: total,
                        available: available,
                        frozen: frozen,
                        usdValue: usd
                    )
                )
            }
        }

        // 资金账户余额与估值
        var fundingEquity = 0.0
        if let fundingItems = fundingResponse?.data {
            let needPrice = fundingItems.contains { item in
                let bal = Double(item.bal) ?? 0
                return bal > 0 && Self.stablecoins.contains(item.ccy) == false && priceLookup[item.ccy] == nil
            }
            if needPrice {
                let spotPrices = (try? await fetchOKXSpotPrices(baseURL: profile.resolvedBaseURL)) ?? [:]
                priceLookup.merge(spotPrices) { current, _ in current }
            }

            for item in fundingItems {
                let total = Double(item.bal) ?? 0
                guard total > 0 else { continue }
                let available = Double(item.availBal ?? "") ?? 0
                let frozen = Double(item.frozenBal ?? "") ?? max(total - available, 0)
                let unitUSD = Self.stablecoins.contains(item.ccy) ? 1.0 : (priceLookup[item.ccy] ?? 0)
                let usd = total * unitUSD
                fundingEquity += usd

                balances.append(
                    AccountBalanceItem(
                        id: "\(profile.id.uuidString)-funding-\(item.ccy)",
                        accountID: profile.id,
                        accountName: profile.name,
                        exchange: .okx,
                        bucket: .funding,
                        currency: item.ccy,
                        total: total,
                        available: available,
                        frozen: frozen,
                        usdValue: usd
                    )
                )
            }
        }

        // 当前持仓解析
        var positions: [AccountPositionItem] = []
        for raw in positionsResponse.data {
            let rawPos = Double(raw.pos) ?? 0
            guard abs(rawPos) > 0 else { continue }

            let side: PositionSide
            switch raw.posSide?.lowercased() {
            case "long": side = .long
            case "short": side = .short
            default: side = rawPos >= 0 ? .long : .short
            }

            let entry = Double(raw.avgPx ?? "") ?? 0
            let mark = Double(raw.markPx ?? "") ?? Double(raw.last ?? "") ?? entry
            let liqVal = Double(raw.liqPx ?? "")
            let liq = (liqVal != nil && (liqVal ?? 0) > 0) ? liqVal : nil
            let upl = Double(raw.upl ?? "") ?? 0
            let uplRatio = (Double(raw.uplRatio ?? "") ?? 0) * 100
            let notional = abs(Double(raw.notionalUsd ?? "") ?? 0)
            let leverage = Double(raw.lever ?? "") ?? 1
            let marginMode = raw.mgnMode == "isolated" ? "逐仓" : "全仓"

            let parts = raw.instId.split(separator: "-")
            let baseSymbol = parts.first.map(String.init) ?? raw.instId
            let quoteSymbol = parts.count >= 2 ? String(parts[1]) : "USDT"
            let kind = OKXInstrumentKind(rawValue: raw.instType ?? "SWAP") ?? .swap
            let asset = CryptoAsset(
                id: raw.instId,
                symbol: baseSymbol,
                name: "\(AssetNames.name(for: baseSymbol)) \(kind.label)",
                instrumentKind: kind
            )

            let rawPosSide = (raw.posSide?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "net"
            let rawMarginMode = (raw.mgnMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "cross"

            positions.append(
                AccountPositionItem(
                    id: "\(profile.id.uuidString)-\(raw.instId)-\(side.rawValue)-\(marginMode)",
                    accountID: profile.id,
                    accountName: profile.name,
                    exchange: .okx,
                    marketAsset: asset,
                    displayPair: "\(baseSymbol)/\(quoteSymbol)",
                    side: side,
                    marginMode: marginMode,
                    rawPosSide: rawPosSide,
                    rawMarginMode: rawMarginMode,
                    leverage: leverage,
                    quantity: abs(rawPos),
                    notionalUSD: notional,
                    entryPrice: entry,
                    markPrice: mark,
                    liquidationPrice: liq,
                    unrealizedPnL: upl,
                    roePercent: uplRatio
                )
            )
        }

        let totalPnL = positions.reduce(0) { $0 + $1.unrealizedPnL }
        let totalEquity = max(tradingEquity + fundingEquity, balances.reduce(0) { $0 + $1.usdValue })

        return AccountSnapshot(
            accountID: profile.id,
            exchange: .okx,
            totalEquityUSD: totalEquity,
            totalUnrealizedPnL: totalPnL,
            balances: balances.sorted { $0.usdValue > $1.usdValue },
            positions: positions.sorted { abs($0.notionalUSD) > abs($1.notionalUSD) },
            updatedAt: Date(),
            warningMessage: nil
        )
    }

    private func okxGET<T: Decodable>(
        _ type: T.Type,
        path: String,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> T {
        guard let url = URL(string: "\(profile.resolvedBaseURL)\(path)") else {
            throw ExchangeAPIError.invalidBaseURL
        }

        let timestamp = Self.okxTimestamp()
        let prehash = "\(timestamp)GET\(path)"
        let signature = Self.hmacSHA256Base64(message: prehash, secret: credentials.secretKey)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "OK-ACCESS-KEY")
        request.setValue(signature, forHTTPHeaderField: "OK-ACCESS-SIGN")
        request.setValue(timestamp, forHTTPHeaderField: "OK-ACCESS-TIMESTAMP")
        request.setValue(credentials.passphrase, forHTTPHeaderField: "OK-ACCESS-PASSPHRASE")
        if profile.isSimulated {
            request.setValue("1", forHTTPHeaderField: "x-simulated-trading")
        }

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw ExchangeAPIError.badResponse
        }

        if let envelope = try? JSONDecoder().decode(OKXStatusHeader.self, from: data),
           envelope.code != "0" {
            throw mapOKXError(code: envelope.code, message: envelope.msg)
        }

        guard (200...299).contains(http.statusCode) else {
            throw ExchangeAPIError.httpError(http.statusCode, "OKX 接口返回异常状态")
        }

        return try JSONDecoder().decode(type, from: data)
    }

    private func fetchOKXSpotPrices(baseURL: String) async throws -> [String: Double] {
        guard let url = URL(string: "\(baseURL)/api/v5/market/tickers?instType=SPOT") else { return [:] }
        let (data, _) = try await performRequest(URLRequest(url: url))
        let response = try JSONDecoder().decode(OKXEnvelope<OKXPublicTickerMini>.self, from: data)
        var prices: [String: Double] = [:]
        for item in response.data {
            let parts = item.instId.split(separator: "-")
            guard parts.count == 2, parts[1] == "USDT", let last = Double(item.last) else { continue }
            prices[String(parts[0])] = last
        }
        return prices
    }

    // MARK: - 币安（Binance）只读接口

    private func fetchBinanceSnapshot(
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> AccountSnapshot {
        let spotBase = profile.resolvedBaseURL
        let futuresBase = spotBase == ExchangeKind.binance.defaultBaseURL
            ? "https://fapi.binance.com"
            : spotBase

        // 并发获取：现货账户 + 公开现货行情（用于估算 USD）+ U 本位合约账户与仓位
        async let spotAccountTask = binanceGET(
            BinanceSpotAccount.self,
            baseURL: spotBase,
            path: "/api/v3/account",
            credentials: credentials
        )
        async let spotPricesTask: [String: Double] = (try? await fetchBinanceSpotPrices(baseURL: spotBase)) ?? [:]

        // 合约接口独立容错：若用户未开通合约或 API Key 仅开现货只读，仍正常展示现货资产
        async let futuresBalancesTask: Result<[BinanceFuturesBalance], Error> = {
            do {
                let result = try await binanceGET(
                    [BinanceFuturesBalance].self,
                    baseURL: futuresBase,
                    path: "/fapi/v2/balance",
                    credentials: credentials
                )
                return .success(result)
            } catch {
                return .failure(error)
            }
        }()

        async let futuresPositionsTask: Result<[BinanceFuturesPosition], Error> = {
            do {
                let result = try await binanceGET(
                    [BinanceFuturesPosition].self,
                    baseURL: futuresBase,
                    path: "/fapi/v2/positionRisk",
                    credentials: credentials
                )
                return .success(result)
            } catch {
                return .failure(error)
            }
        }()

        let spotAccount = try await spotAccountTask
        let spotPrices = await spotPricesTask
        let futuresBalancesResult = await futuresBalancesTask
        let futuresPositionsResult = await futuresPositionsTask

        var balances: [AccountBalanceItem] = []
        var warning: String?

        // 1. 现货余额
        let btcPrice = spotPrices["BTCUSDT"] ?? 0
        for item in spotAccount.balances {
            let free = Double(item.free) ?? 0
            let locked = Double(item.locked) ?? 0
            let total = free + locked
            guard total > 0 else { continue }

            let unitUSD: Double
            if Self.stablecoins.contains(item.asset) {
                unitUSD = 1.0
            } else if let direct = spotPrices["\(item.asset)USDT"] {
                unitUSD = direct
            } else if let viaBTC = spotPrices["\(item.asset)BTC"], btcPrice > 0 {
                unitUSD = viaBTC * btcPrice
            } else {
                unitUSD = 0
            }

            let usd = total * unitUSD
            balances.append(
                AccountBalanceItem(
                    id: "\(profile.id.uuidString)-spot-\(item.asset)",
                    accountID: profile.id,
                    accountName: profile.name,
                    exchange: .binance,
                    bucket: .spot,
                    currency: item.asset,
                    total: total,
                    available: free,
                    frozen: locked,
                    usdValue: usd
                )
            )
        }

        // 2. U 本位合约余额
        switch futuresBalancesResult {
        case .success(let futuresBalances):
            for item in futuresBalances {
                let wallet = Double(item.balance) ?? 0
                let unPnl = Double(item.crossUnPnl ?? "") ?? 0
                let equity = wallet + unPnl
                guard abs(wallet) > 0.000001 || abs(equity) > 0.000001 else { continue }

                let avail = Double(item.availableBalance ?? "") ?? wallet
                let unitUSD = Self.stablecoins.contains(item.asset)
                    ? 1.0
                    : (spotPrices["\(item.asset)USDT"] ?? 0)
                let usd = equity * unitUSD

                balances.append(
                    AccountBalanceItem(
                        id: "\(profile.id.uuidString)-futures-\(item.asset)",
                        accountID: profile.id,
                        accountName: profile.name,
                        exchange: .binance,
                        bucket: .futures,
                        currency: item.asset,
                        total: equity,
                        available: max(avail, 0),
                        frozen: max(equity - avail, 0),
                        usdValue: usd
                    )
                )
            }
        case .failure:
            warning = "仅同步了现货资产（合约未开通或 API 未勾选合约读取权限）"
        }

        // 3. U 本位合约持仓
        var positions: [AccountPositionItem] = []
        if case .success(let rawPositions) = futuresPositionsResult {
            for raw in rawPositions {
                let amt = Double(raw.positionAmt) ?? 0
                guard abs(amt) > 0 else { continue }

                let side: PositionSide
                switch raw.positionSide?.uppercased() {
                case "LONG": side = .long
                case "SHORT": side = .short
                default: side = amt >= 0 ? .long : .short
                }

                let entry = Double(raw.entryPrice) ?? 0
                let mark = Double(raw.markPrice) ?? entry
                let liqVal = Double(raw.liquidationPrice)
                let liq = (liqVal != nil && (liqVal ?? 0) > 0) ? liqVal : nil
                let upl = Double(raw.unRealizedProfit) ?? 0
                let leverage = max(Double(raw.leverage) ?? 1, 1)
                let notional = abs(Double(raw.notional ?? "") ?? (abs(amt) * mark))
                let initialMargin = notional / leverage
                let roe = initialMargin > 0 ? (upl / initialMargin) * 100 : 0
                let marginMode = raw.marginType?.lowercased() == "isolated" ? "逐仓" : "全仓"

                let (base, quote) = Self.splitBinanceSymbol(raw.symbol)
                let asset = CryptoAsset(
                    id: "\(base)-\(quote)-SWAP",
                    symbol: base,
                    name: "\(AssetNames.name(for: base)) 永续合约",
                    instrumentKind: .swap
                )

                positions.append(
                    AccountPositionItem(
                        id: "\(profile.id.uuidString)-\(raw.symbol)-\(side.rawValue)-\(marginMode)",
                        accountID: profile.id,
                        accountName: profile.name,
                        exchange: .binance,
                        marketAsset: asset,
                        displayPair: "\(base)/\(quote)",
                        side: side,
                        marginMode: marginMode,
                        leverage: leverage,
                        quantity: abs(amt),
                        notionalUSD: notional,
                        entryPrice: entry,
                        markPrice: mark,
                        liquidationPrice: liq,
                        unrealizedPnL: upl,
                        roePercent: roe
                    )
                )
            }
        }

        let totalPnL = positions.reduce(0) { $0 + $1.unrealizedPnL }
        let totalEquity = balances.reduce(0) { $0 + $1.usdValue }

        return AccountSnapshot(
            accountID: profile.id,
            exchange: .binance,
            totalEquityUSD: totalEquity,
            totalUnrealizedPnL: totalPnL,
            balances: balances.sorted { $0.usdValue > $1.usdValue },
            positions: positions.sorted { abs($0.notionalUSD) > abs($1.notionalUSD) },
            updatedAt: Date(),
            warningMessage: warning
        )
    }

    private func binanceGET<T: Decodable>(
        _ type: T.Type,
        baseURL: String,
        path: String,
        credentials: ExchangeCredentials
    ) async throws -> T {
        let timestampMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let query = "recvWindow=10000&timestamp=\(timestampMs)"
        let signature = Self.hmacSHA256Hex(message: query, secret: credentials.secretKey)

        guard let url = URL(string: "\(baseURL)\(path)?\(query)&signature=\(signature)") else {
            throw ExchangeAPIError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-MBX-APIKEY")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw ExchangeAPIError.badResponse
        }

        guard (200...299).contains(http.statusCode) else {
            if let apiErr = try? JSONDecoder().decode(BinanceErrorResponse.self, from: data) {
                throw mapBinanceError(code: apiErr.code, message: apiErr.msg)
            }
            throw ExchangeAPIError.httpError(http.statusCode, "币安接口返回异常状态")
        }

        return try JSONDecoder().decode(type, from: data)
    }

    private static let priceCacheLock = NSLock()
    private static var binancePriceCache: (fetchedAt: Date, baseURL: String, prices: [String: Double])?

    private func fetchBinanceSpotPrices(baseURL: String) async throws -> [String: Double] {
        // 20 秒短缓存，避免每 5 秒刷新余额时重复下载全市场价格列表
        let cached: [String: Double]? = Self.priceCacheLock.withLock {
            if let entry = Self.binancePriceCache,
               entry.baseURL == baseURL,
               Date().timeIntervalSince(entry.fetchedAt) < 20 {
                return entry.prices
            }
            return nil
        }
        if let cached { return cached }

        guard let url = URL(string: "\(baseURL)/api/v3/ticker/price") else { return [:] }
        let (data, _) = try await performRequest(URLRequest(url: url))
        let list = try JSONDecoder().decode([BinancePriceTicker].self, from: data)
        var prices: [String: Double] = [:]
        prices.reserveCapacity(list.count)
        for item in list {
            if let value = Double(item.price) {
                prices[item.symbol] = value
            }
        }
        Self.priceCacheLock.withLock {
            Self.binancePriceCache = (Date(), baseURL, prices)
        }
        return prices
    }

    // MARK: - 网络与加密签名工具

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw ExchangeAPIError.timeout
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                throw ExchangeAPIError.networkUnreachable
            default:
                throw ExchangeAPIError.requestFailed(error.localizedDescription)
            }
        } catch {
            throw ExchangeAPIError.requestFailed(error.localizedDescription)
        }
    }

    private static func okxTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    private static func hmacSHA256Base64(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    private static func hmacSHA256Hex(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func splitBinanceSymbol(_ symbol: String) -> (String, String) {
        for quote in ["USDT", "USDC", "FDUSD", "BUSD", "BTC"] {
            if symbol.hasSuffix(quote) && symbol.count > quote.count {
                let base = String(symbol.dropLast(quote.count))
                return (base, quote)
            }
        }
        return (symbol, "USDT")
    }

    private func mapOKXError(code: String, message: String?) -> ExchangeAPIError {
        switch code {
        case "50111", "50113", "50114", "50105":
            return .authenticationFailed("API Key、Secret 或 Passphrase 验证失败（OKX \(code)）")
        case "50110":
            return .ipNotWhitelisted("当前网络 IP 未加入该 OKX API Key 白名单")
        case "50119", "50120":
            return .permissionDenied("该 OKX API Key 权限不足或环境不匹配（请检查是否开启模拟盘）")
        case "50102":
            return .timestampOutOfSync("本机系统时间与 OKX 服务器偏差过大，请校准系统时间")
        default:
            return .requestFailed("OKX 错误 \(code)：\(message ?? "未知错误")")
        }
    }

    private func mapBinanceError(code: Int, message: String) -> ExchangeAPIError {
        switch code {
        case -2014, -2015:
            return .authenticationFailed("币安 API Key 无效、IP 未在白名单或权限不足（\(code)）")
        case -1022:
            return .authenticationFailed("币安 Secret Key 签名校验失败，请检查是否填写完整")
        case -1021:
            return .timestampOutOfSync("本机系统时间与币安服务器偏差过大，请开启系统自动校准时间")
        case -1003:
            return .requestFailed("币安接口请求频率受限，请稍后重试")
        default:
            return .requestFailed("币安错误 \(code)：\(message)")
        }
    }
}

// MARK: - 错误定义

nonisolated enum ExchangeAPIError: LocalizedError {
    case missingCredentials
    case missingPassphrase
    case invalidBaseURL
    case authenticationFailed(String)
    case ipNotWhitelisted(String)
    case permissionDenied(String)
    case timestampOutOfSync(String)
    case timeout
    case networkUnreachable
    case badResponse
    case httpError(Int, String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "请填写完整的 API Key 和 Secret Key。"
        case .missingPassphrase:
            return "OKX 账户需要填写创建 API 时设置的 Passphrase。"
        case .invalidBaseURL:
            return "自定义接口域名格式无效，请以 https:// 开头。"
        case .authenticationFailed(let msg):
            return msg
        case .ipNotWhitelisted(let msg):
            return msg
        case .permissionDenied(let msg):
            return msg
        case .timestampOutOfSync(let msg):
            return msg
        case .timeout:
            return "请求交易所接口超时，请检查网络连接或代理配置。"
        case .networkUnreachable:
            return "无法连接到交易所服务器，请检查网络或代理设置。"
        case .badResponse:
            return "交易所接口响应异常。"
        case .httpError(let code, let msg):
            return "\(msg)（HTTP \(code)）"
        case .requestFailed(let msg):
            return msg
        }
    }
}

// MARK: - OKX DTO

nonisolated private struct OKXStatusHeader: Decodable {
    let code: String
    let msg: String?
}

nonisolated private struct OKXEnvelope<Item: Decodable>: Decodable {
    let code: String
    let msg: String?
    let data: [Item]
}

nonisolated private struct OKXTradingAccountData: Decodable {
    let totalEq: String?
    let details: [OKXBalanceDetail]
}

nonisolated private struct OKXBalanceDetail: Decodable {
    let ccy: String
    let eq: String?
    let cashBal: String?
    let eqUsd: String?
    let availBal: String?
    let availEq: String?
    let frozenBal: String?
}

nonisolated private struct OKXFundingBalanceData: Decodable {
    let ccy: String
    let bal: String
    let availBal: String?
    let frozenBal: String?
}

nonisolated private struct OKXPositionData: Decodable {
    let instId: String
    let instType: String?
    let mgnMode: String?
    let posSide: String?
    let pos: String
    let avgPx: String?
    let markPx: String?
    let last: String?
    let liqPx: String?
    let upl: String?
    let uplRatio: String?
    let lever: String?
    let notionalUsd: String?
}

nonisolated private struct OKXPublicTickerMini: Decodable {
    let instId: String
    let last: String
}

// MARK: - Binance DTO

nonisolated private struct BinanceErrorResponse: Decodable {
    let code: Int
    let msg: String
}

nonisolated private struct BinanceSpotAccount: Decodable {
    let balances: [BinanceSpotBalance]
}

nonisolated private struct BinanceSpotBalance: Decodable {
    let asset: String
    let free: String
    let locked: String
}

nonisolated private struct BinanceFuturesBalance: Decodable {
    let asset: String
    let balance: String
    let availableBalance: String?
    let crossUnPnl: String?
}

nonisolated private struct BinanceFuturesPosition: Decodable {
    let symbol: String
    let positionAmt: String
    let entryPrice: String
    let markPrice: String
    let unRealizedProfit: String
    let liquidationPrice: String
    let leverage: String
    let marginType: String?
    let positionSide: String?
    let notional: String?
}

nonisolated private struct BinancePriceTicker: Decodable {
    let symbol: String
    let price: String
}
