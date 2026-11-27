import CryptoKit
import Foundation
import LocalAuthentication

// MARK: - 交易安全配置与生物识别

nonisolated struct TradingSecurityConfig: Equatable, Codable, Sendable {
    /// 全局交易总开关（默认关闭，保持只读安全态）
    var tradingEnabled: Bool = false
    /// 仅允许对 OKX 模拟盘账户下单（开启后强制拦截实盘账户，防误操作）
    var preferSimulatedOnly: Bool = false
    /// 下单 / 平仓 / 挂止盈止损 / 撤单前要求 Face ID / Touch ID / 系统密码验证
    var requireBiometrics: Bool = true
    /// 单笔开仓名义价值硬上限（USDT，0 表示不限；平仓与撤单不受限制以免影响风控止损）
    var maxSingleOrderUSD: Double = 1000
}

nonisolated enum BiometricAuthorizer {
    static var capabilityLabel: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "系统密码"
        }
    }

    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw OKXTradeError.biometricUnavailable(error?.localizedDescription ?? "当前设备未启用生物识别或锁屏密码")
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success == false {
                throw OKXTradeError.biometricCancelled
            }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw OKXTradeError.biometricCancelled
            default:
                throw OKXTradeError.biometricFailed(laError.localizedDescription)
            }
        }
    }
}

// MARK: - OKX 交易领域模型

nonisolated enum OKXPositionMode: String, Sendable {
    case longShort = "long_short_mode"
    case net = "net_mode"
}

nonisolated enum TradeOrderSide: String, CaseIterable, Identifiable, Sendable {
    case buy
    case sell

    var id: String { rawValue }

    func label(for kind: OKXInstrumentKind) -> String {
        switch (kind, self) {
        case (.spot, .buy): return "买入"
        case (.spot, .sell): return "卖出"
        case (_, .buy): return "做多 (开多)"
        case (_, .sell): return "做空 (开空)"
        }
    }

    func shortLabel(for kind: OKXInstrumentKind) -> String {
        switch (kind, self) {
        case (.spot, .buy): return "买"
        case (.spot, .sell): return "卖"
        case (_, .buy): return "多"
        case (_, .sell): return "空"
        }
    }
}

nonisolated enum TradeOrderType: String, CaseIterable, Identifiable, Sendable {
    case market
    case limit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .market: return "市价单"
        case .limit: return "限价单"
        }
    }
}

nonisolated enum TradeMarginMode: String, CaseIterable, Identifiable, Sendable {
    case cross
    case isolated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cross: return "全仓"
        case .isolated: return "逐仓"
        }
    }
}

nonisolated enum TriggerPriceType: String, CaseIterable, Identifiable, Sendable {
    case mark
    case last

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mark: return "标记价（防插针）"
        case .last: return "最新成交价"
        }
    }
}

/// 合约 / 现货交易规则与精度元数据
nonisolated struct OKXInstrumentSpec: Equatable, Sendable {
    let instId: String
    let instType: String
    let baseCcy: String
    let quoteCcy: String
    /// 合约面值（现货为 1）
    let ctVal: Decimal
    let ctValCcy: String
    /// 数量最小步长
    let lotSz: Decimal
    let lotSzString: String
    /// 最小下单量
    let minSz: Decimal
    /// 价格最小步长
    let tickSz: Decimal
    let tickSzString: String
    /// 最大允许杠杆
    let maxLeverage: Double

    var isDerivative: Bool {
        instType != "SPOT"
    }

    /// 计算 1 张合约（或 1 个现货基础币）的名义价值（USDT）
    func unitNotionalUSD(referencePrice: Double) -> Double {
        guard referencePrice > 0 else { return 0 }
        let ct = NSDecimalNumber(decimal: ctVal).doubleValue
        if isDerivative {
            if ctValCcy.uppercased() == "USDT" || ctValCcy.uppercased() == "USD" {
                return max(ct, 0)
            }
            return max(ct * referencePrice, 0)
        }
        return referencePrice
    }

    /// 将名义价值（USDT）换算并向下对齐到合法下单数量（张数或基础币数）
    func alignedOrderSize(fromNotionalUSD notionalUSD: Double, referencePrice: Double) -> (sizeString: String, numericSize: Double, actualNotionalUSD: Double)? {
        let unit = unitNotionalUSD(referencePrice: referencePrice)
        guard unit > 0, notionalUSD > 0 else { return nil }
        let rawCount = notionalUSD / unit
        let aligned = Self.floorToStep(rawCount, step: lotSz)
        let minNumeric = NSDecimalNumber(decimal: minSz).doubleValue
        guard aligned.numeric >= minNumeric, aligned.numeric > 0 else { return nil }
        let str = Self.formatDecimal(aligned.decimal, stepString: lotSzString)
        return (str, aligned.numeric, aligned.numeric * unit)
    }

    /// 将原始数量（如仓位张数）按步长向下对齐
    func alignedSize(rawQuantity: Double, allowMinFallback: Bool = false) -> (sizeString: String, numericSize: Double)? {
        guard rawQuantity > 0 else { return nil }
        let aligned = Self.floorToStep(rawQuantity, step: lotSz)
        let minNumeric = NSDecimalNumber(decimal: minSz).doubleValue
        if aligned.numeric >= minNumeric && aligned.numeric > 0 {
            return (Self.formatDecimal(aligned.decimal, stepString: lotSzString), aligned.numeric)
        }
        if allowMinFallback && rawQuantity >= minNumeric * 0.999 {
            return (Self.formatDecimal(minSz, stepString: lotSzString), minNumeric)
        }
        return nil
    }

    /// 将价格对齐到 tickSz 精度
    func alignedPrice(_ rawPrice: Double) -> String? {
        guard rawPrice > 0, rawPrice.isFinite else { return nil }
        let rounded = Self.roundToStep(rawPrice, step: tickSz)
        guard rounded.numeric > 0 else { return nil }
        return Self.formatDecimal(rounded.decimal, stepString: tickSzString)
    }

    static func floorToStep(_ value: Double, step: Decimal) -> (decimal: Decimal, numeric: Double) {
        let stepDouble = NSDecimalNumber(decimal: step).doubleValue
        guard stepDouble > 0, value.isFinite else { return (Decimal(value), value) }
        let decVal = Decimal(string: String(format: "%.12f", value)) ?? Decimal(value)
        var quotient = decVal / step
        var flooredQuotient = Decimal()
        NSDecimalRound(&flooredQuotient, &quotient, 0, .down)
        let result = flooredQuotient * step
        return (result, NSDecimalNumber(decimal: result).doubleValue)
    }

    static func roundToStep(_ value: Double, step: Decimal) -> (decimal: Decimal, numeric: Double) {
        let stepDouble = NSDecimalNumber(decimal: step).doubleValue
        guard stepDouble > 0, value.isFinite else { return (Decimal(value), value) }
        let decVal = Decimal(string: String(format: "%.12f", value)) ?? Decimal(value)
        var quotient = decVal / step
        var roundedQuotient = Decimal()
        NSDecimalRound(&roundedQuotient, &quotient, 0, .plain)
        let result = roundedQuotient * step
        return (result, NSDecimalNumber(decimal: result).doubleValue)
    }

    static func formatDecimal(_ value: Decimal, stepString: String) -> String {
        let decimals: Int
        if let dotIndex = stepString.firstIndex(of: ".") {
            let frac = stepString[stepString.index(after: dotIndex)...]
            decimals = frac.count
        } else {
            decimals = 0
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = max(decimals, 0)
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }
}

/// 开仓 / 下单请求参数
nonisolated struct PlaceOrderRequest: Sendable {
    let accountID: UUID
    let asset: CryptoAsset
    let side: TradeOrderSide
    let orderType: TradeOrderType
    let marginMode: TradeMarginMode
    let leverage: Int
    /// 期望名义金额（USDT，对于合约=保证金*杠杆；对于现货=成交金额）
    let notionalUSD: Double
    /// 限价单委托价（市价单可为 nil）
    let limitPrice: Double?
    /// 当前参考现价（用于估算张数与风控校验）
    let referencePrice: Double
    /// 可选附带止盈触发价
    let takeProfitPrice: Double?
    /// 可选附带止损触发价
    let stopLossPrice: Double?
}

/// 平仓请求参数
nonisolated struct ClosePositionRequest: Sendable {
    let position: AccountPositionItem
    /// 平仓比例（0.25 / 0.5 / 0.75 / 1.0）
    let ratio: Double
    let orderType: TradeOrderType
    let limitPrice: Double?
}

/// 止盈止损策略单请求参数
nonisolated struct PlaceTPSLRequest: Sendable {
    let position: AccountPositionItem
    let takeProfitPrice: Double?
    let stopLossPrice: Double?
    let triggerPriceType: TriggerPriceType
}

/// 当前普通未成交委托
nonisolated struct OKXPendingOrder: Identifiable, Equatable, Sendable {
    let id: String
    let ordId: String
    let accountID: UUID
    let accountName: String
    let isSimulated: Bool
    let instId: String
    let instType: String
    let side: String
    let posSide: String
    let ordType: String
    let tdMode: String
    let price: Double
    let size: Double
    let filledSize: Double
    let leverage: Double
    let state: String
    let createdAt: Date

    var displayPair: String {
        let parts = instId.split(separator: "-")
        if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        return instId
    }

    var directionLabel: String {
        let isDerivative = instType != "SPOT"
        if isDerivative {
            if posSide == "long" { return side == "buy" ? "开多" : "平多" }
            if posSide == "short" { return side == "sell" ? "开空" : "平空" }
            return side == "buy" ? "买入/做多" : "卖出/做空"
        }
        return side == "buy" ? "买入" : "卖出"
    }

    var isBuySide: Bool { side == "buy" }
}

/// 当前止盈止损策略委托
nonisolated struct OKXAlgoOrder: Identifiable, Equatable, Sendable {
    let id: String
    let algoId: String
    let accountID: UUID
    let accountName: String
    let isSimulated: Bool
    let instId: String
    let instType: String
    let side: String
    let posSide: String
    let ordType: String
    let tdMode: String
    let size: Double?
    let closeFraction: String?
    let tpTriggerPx: Double?
    let slTriggerPx: Double?
    let createdAt: Date

    var displayPair: String {
        let parts = instId.split(separator: "-")
        if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        return instId
    }

    var directionLabel: String {
        if posSide == "long" { return "平多止盈止损" }
        if posSide == "short" { return "平空止盈止损" }
        return side == "sell" ? "卖出止盈止损" : "买入止盈止损"
    }
}

/// 交易错误定义
nonisolated enum OKXTradeError: LocalizedError {
    case tradingDisabled
    case simulatedOnlyLock(String)
    case unsupportedExchange
    case accountNotFound
    case exceedsMaxOrderLimit(actual: Double, limit: Double)
    case invalidInput(String)
    case biometricUnavailable(String)
    case biometricCancelled
    case biometricFailed(String)
    case okxRejected(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .tradingDisabled:
            return "交易功能尚未开启，请先前往「设置 → 交易与安全」开启 OKX 交易开关。"
        case .simulatedOnlyLock(let name):
            return "已开启「仅模拟盘交易」保护锁，已拦截对实盘账户「\(name)」的操作。"
        case .unsupportedExchange:
            return "当前仅支持 OKX 账户执行交易操作。"
        case .accountNotFound:
            return "未找到对应的已启用 OKX 账户，请检查账户配置。"
        case .exceedsMaxOrderLimit(let actual, let limit):
            return "预估下单名义价值 \(MarketFormatter.price(actual)) 超出单笔安全上限 \(MarketFormatter.price(limit))，已拦截。如需调整请前往「设置 → 交易与安全」。"
        case .invalidInput(let msg):
            return msg
        case .biometricUnavailable(let msg):
            return "无法进行安全身份验证：\(msg)"
        case .biometricCancelled:
            return "已取消身份验证，未发送任何交易指令。"
        case .biometricFailed(let msg):
            return "身份验证未通过：\(msg)"
        case .okxRejected(let code, let message):
            return "OKX 拒单（\(code)）：\(message)"
        }
    }
}

// MARK: - OKX V5 私有交易接口服务

nonisolated struct OKXTradingService: Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 生成符合 OKX 规范的唯一幂等客户端订单号（纯字母数字，<= 32 字符）
    static func makeClientOrderID(prefix: String = "bb") -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = UInt32.random(in: 0x100000...0xFFFFFF)
        return "\(prefix)\(ms)\(String(rand, radix: 16))"
    }

    // MARK: 元数据与账户配置

    func fetchInstrumentSpec(
        instId: String,
        instType: String,
        baseURL: String
    ) async throws -> OKXInstrumentSpec {
        let query = "instType=\(instType)&instId=\(instId)"
        guard let url = URL(string: "\(baseURL)/api/v5/public/instruments?\(query)") else {
            throw ExchangeAPIError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await performRequest(request)
        let envelope = try JSONDecoder().decode(OKXTradeEnvelope<OKXRawInstrument>.self, from: data)
        guard envelope.code == "0", let raw = envelope.data.first else {
            throw OKXTradeError.okxRejected(code: envelope.code, message: envelope.msg ?? "未查询到交易对规则")
        }
        let ctValStr = (raw.ctVal?.isEmpty == false) ? raw.ctVal! : "1"
        let lotStr = (raw.lotSz?.isEmpty == false) ? raw.lotSz! : "0.0001"
        let minStr = (raw.minSz?.isEmpty == false) ? raw.minSz! : lotStr
        let tickStr = (raw.tickSz?.isEmpty == false) ? raw.tickSz! : "0.01"
        return OKXInstrumentSpec(
            instId: raw.instId,
            instType: raw.instType,
            baseCcy: raw.baseCcy ?? "",
            quoteCcy: raw.quoteCcy ?? "USDT",
            ctVal: Decimal(string: ctValStr) ?? 1,
            ctValCcy: raw.ctValCcy ?? raw.baseCcy ?? "",
            lotSz: Decimal(string: lotStr) ?? Decimal(string: "0.0001")!,
            lotSzString: lotStr,
            minSz: Decimal(string: minStr) ?? Decimal(string: "0.0001")!,
            tickSz: Decimal(string: tickStr) ?? Decimal(string: "0.01")!,
            tickSzString: tickStr,
            maxLeverage: Double(raw.lever ?? "") ?? 50
        )
    }

    func fetchAccountPositionMode(
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> OKXPositionMode {
        let resp = try await okxGET(
            OKXTradeEnvelope<OKXAccountConfigItem>.self,
            path: "/api/v5/account/config",
            profile: profile,
            credentials: credentials
        )
        let mode = resp.data.first?.posMode ?? "long_short_mode"
        return OKXPositionMode(rawValue: mode) ?? .longShort
    }

    func setLeverage(
        instId: String,
        leverage: Int,
        marginMode: TradeMarginMode,
        posSide: String?,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws {
        var body: [String: Any] = [
            "instId": instId,
            "lever": "\(max(leverage, 1))",
            "mgnMode": marginMode.rawValue
        ]
        // OKX 规范：仅逐仓双向持仓需要指定 posSide，全仓不传 posSide
        if marginMode == .isolated, let posSide, posSide == "long" || posSide == "short" {
            body["posSide"] = posSide
        }
        _ = try await okxPOST(
            OKXTradeEnvelope<OKXGenericTradeAck>.self,
            path: "/api/v5/account/set-leverage",
            body: body,
            profile: profile,
            credentials: credentials
        )
    }

    // MARK: 下单 / 平仓 / 止盈止损 / 撤单

    func placeOrder(
        instId: String,
        tdMode: String,
        side: String,
        posSide: String?,
        ordType: String,
        size: String,
        price: String?,
        tgtCcy: String?,
        reduceOnly: Bool,
        takeProfitPx: String?,
        stopLossPx: String?,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> String {
        let clOrdId = Self.makeClientOrderID(prefix: reduceOnly ? "bbcl" : "bbod")
        var body: [String: Any] = [
            "instId": instId,
            "tdMode": tdMode,
            "side": side,
            "ordType": ordType,
            "sz": size,
            "clOrdId": clOrdId
        ]
        if let posSide, posSide.isEmpty == false {
            body["posSide"] = posSide
        }
        if let price, price.isEmpty == false {
            body["px"] = price
        }
        if let tgtCcy, tgtCcy.isEmpty == false {
            body["tgtCcy"] = tgtCcy
        }
        if reduceOnly {
            body["reduceOnly"] = true
        }

        // 开仓附带止盈止损（市价触发）
        if takeProfitPx != nil || stopLossPx != nil {
            var attach: [String: Any] = [:]
            if let tp = takeProfitPx, tp.isEmpty == false {
                attach["tpTriggerPx"] = tp
                attach["tpOrdPx"] = "-1"
                attach["tpTriggerPxType"] = "mark"
            }
            if let sl = stopLossPx, sl.isEmpty == false {
                attach["slTriggerPx"] = sl
                attach["slOrdPx"] = "-1"
                attach["slTriggerPxType"] = "mark"
            }
            if attach.isEmpty == false {
                body["attachAlgoOrds"] = [attach]
            }
        }

        let resp = try await okxPOST(
            OKXTradeEnvelope<OKXOrderAck>.self,
            path: "/api/v5/trade/order",
            body: body,
            profile: profile,
            credentials: credentials
        )
        if let first = resp.data.first {
            if let sCode = first.sCode, sCode != "0" {
                throw OKXTradeError.okxRejected(code: sCode, message: first.sMsg ?? "下单被交易所拒绝")
            }
            return first.ordId ?? clOrdId
        }
        return clOrdId
    }

    /// 市价全平指定持仓
    func closePositionMarketAll(
        position: AccountPositionItem,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws {
        let clOrdId = Self.makeClientOrderID(prefix: "bbcp")
        var body: [String: Any] = [
            "instId": position.marketAsset.id,
            "mgnMode": position.rawMarginMode,
            "autoCcy": true,
            "clOrdId": clOrdId
        ]
        // 单向持仓（net）不能传 posSide，双向持仓传 long / short
        if position.rawPosSide == "long" || position.rawPosSide == "short" {
            body["posSide"] = position.rawPosSide
        }

        let resp = try await okxPOST(
            OKXTradeEnvelope<OKXGenericTradeAck>.self,
            path: "/api/v5/trade/close-position",
            body: body,
            profile: profile,
            credentials: credentials
        )
        if let first = resp.data.first, let sCode = first.sCode, sCode != "0" {
            throw OKXTradeError.okxRejected(code: sCode, message: first.sMsg ?? "市价全平失败")
        }
    }

    /// 为已有持仓挂止盈/止损策略单（全仓位市价触发）
    func placePositionTPSL(
        position: AccountPositionItem,
        takeProfitPx: String?,
        stopLossPx: String?,
        triggerType: TriggerPriceType,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> String {
        let hasTP = (takeProfitPx?.isEmpty == false)
        let hasSL = (stopLossPx?.isEmpty == false)
        guard hasTP || hasSL else {
            throw OKXTradeError.invalidInput("请至少填写止盈价或止损价。")
        }

        let algoClOrdId = Self.makeClientOrderID(prefix: "bbtp")
        let closeSide = position.side == .long ? "sell" : "buy"
        let ordType = (hasTP && hasSL) ? "oco" : "conditional"

        var body: [String: Any] = [
            "instId": position.marketAsset.id,
            "tdMode": position.rawMarginMode,
            "side": closeSide,
            "ordType": ordType,
            "closeFraction": "1",
            "reduceOnly": true,
            "algoClOrdId": algoClOrdId
        ]
        if position.rawPosSide == "long" || position.rawPosSide == "short" {
            body["posSide"] = position.rawPosSide
        } else {
            body["posSide"] = "net"
        }

        if let tp = takeProfitPx, tp.isEmpty == false {
            body["tpTriggerPx"] = tp
            body["tpOrdPx"] = "-1"
            body["tpTriggerPxType"] = triggerType.rawValue
        }
        if let sl = stopLossPx, sl.isEmpty == false {
            body["slTriggerPx"] = sl
            body["slOrdPx"] = "-1"
            body["slTriggerPxType"] = triggerType.rawValue
        }

        let resp = try await okxPOST(
            OKXTradeEnvelope<OKXAlgoAck>.self,
            path: "/api/v5/trade/order-algo",
            body: body,
            profile: profile,
            credentials: credentials
        )
        if let first = resp.data.first {
            if let sCode = first.sCode, sCode != "0" {
                throw OKXTradeError.okxRejected(code: sCode, message: first.sMsg ?? "挂止盈止损失败")
            }
            return first.algoId ?? algoClOrdId
        }
        return algoClOrdId
    }

    func fetchPendingOrders(
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> [OKXPendingOrder] {
        let resp = try await okxGET(
            OKXTradeEnvelope<OKXRawPendingOrder>.self,
            path: "/api/v5/trade/orders-pending",
            profile: profile,
            credentials: credentials
        )
        return resp.data.map { raw in
            let tsMs = Double(raw.cTime ?? "") ?? (Date().timeIntervalSince1970 * 1000)
            return OKXPendingOrder(
                id: "\(profile.id.uuidString)-\(raw.ordId)",
                ordId: raw.ordId,
                accountID: profile.id,
                accountName: profile.name,
                isSimulated: profile.isSimulated,
                instId: raw.instId,
                instType: raw.instType ?? "SWAP",
                side: raw.side ?? "buy",
                posSide: raw.posSide ?? "net",
                ordType: raw.ordType ?? "limit",
                tdMode: raw.tdMode ?? "cross",
                price: Double(raw.px ?? "") ?? 0,
                size: Double(raw.sz ?? "") ?? 0,
                filledSize: Double(raw.accFillSz ?? "") ?? 0,
                leverage: Double(raw.lever ?? "") ?? 1,
                state: raw.state ?? "live",
                createdAt: Date(timeIntervalSince1970: tsMs / 1000)
            )
        }
    }

    func fetchPendingAlgoOrders(
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> [OKXAlgoOrder] {
        async let condTask = try? okxGET(
            OKXTradeEnvelope<OKXRawAlgoOrder>.self,
            path: "/api/v5/trade/orders-algo-pending?ordType=conditional",
            profile: profile,
            credentials: credentials
        )
        async let ocoTask = try? okxGET(
            OKXTradeEnvelope<OKXRawAlgoOrder>.self,
            path: "/api/v5/trade/orders-algo-pending?ordType=oco",
            profile: profile,
            credentials: credentials
        )
        let combined = (await condTask?.data ?? []) + (await ocoTask?.data ?? [])
        var seen = Set<String>()
        var result: [OKXAlgoOrder] = []
        for raw in combined where seen.insert(raw.algoId).inserted {
            let tsMs = Double(raw.cTime ?? "") ?? (Date().timeIntervalSince1970 * 1000)
            let tp = Double(raw.tpTriggerPx ?? "").flatMap { $0 > 0 ? $0 : nil }
            let sl = Double(raw.slTriggerPx ?? "").flatMap { $0 > 0 ? $0 : nil }
            result.append(
                OKXAlgoOrder(
                    id: "\(profile.id.uuidString)-algo-\(raw.algoId)",
                    algoId: raw.algoId,
                    accountID: profile.id,
                    accountName: profile.name,
                    isSimulated: profile.isSimulated,
                    instId: raw.instId,
                    instType: raw.instType ?? "SWAP",
                    side: raw.side ?? "sell",
                    posSide: raw.posSide ?? "net",
                    ordType: raw.ordType ?? "conditional",
                    tdMode: raw.tdMode ?? "cross",
                    size: Double(raw.sz ?? "").flatMap { $0 > 0 ? $0 : nil },
                    closeFraction: raw.closeFraction,
                    tpTriggerPx: tp,
                    slTriggerPx: sl,
                    createdAt: Date(timeIntervalSince1970: tsMs / 1000)
                )
            )
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    func cancelOrder(
        order: OKXPendingOrder,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws {
        let resp = try await okxPOST(
            OKXTradeEnvelope<OKXOrderAck>.self,
            path: "/api/v5/trade/cancel-order",
            body: ["instId": order.instId, "ordId": order.ordId],
            profile: profile,
            credentials: credentials
        )
        if let first = resp.data.first, let sCode = first.sCode, sCode != "0" {
            throw OKXTradeError.okxRejected(code: sCode, message: first.sMsg ?? "撤单失败")
        }
    }

    func cancelBatchOrders(
        orders: [OKXPendingOrder],
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws {
        guard orders.isEmpty == false else { return }
        // OKX 单次批量撤单最多 20 条
        var index = 0
        while index < orders.count {
            let chunk = Array(orders[index..<min(index + 20, orders.count)])
            let payload: [[String: Any]] = chunk.map { ["instId": $0.instId, "ordId": $0.ordId] }
            _ = try await okxPOSTArray(
                OKXTradeEnvelope<OKXOrderAck>.self,
                path: "/api/v5/trade/cancel-batch-orders",
                bodyArray: payload,
                profile: profile,
                credentials: credentials
            )
            index += 20
        }
    }

    func cancelAlgoOrders(
        orders: [OKXAlgoOrder],
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws {
        guard orders.isEmpty == false else { return }
        var index = 0
        while index < orders.count {
            let chunk = Array(orders[index..<min(index + 10, orders.count)])
            let payload: [[String: Any]] = chunk.map { ["algoId": $0.algoId, "instId": $0.instId] }
            let resp = try await okxPOSTArray(
                OKXTradeEnvelope<OKXAlgoAck>.self,
                path: "/api/v5/trade/cancel-algos",
                bodyArray: payload,
                profile: profile,
                credentials: credentials
            )
            if let first = resp.data.first, let sCode = first.sCode, sCode != "0" {
                throw OKXTradeError.okxRejected(code: sCode, message: first.sMsg ?? "撤销止盈止损失败")
            }
            index += 10
        }
    }

    // MARK: 底层签名与 HTTP 请求

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
        applyOKXHeaders(&request, timestamp: timestamp, signature: signature, profile: profile, credentials: credentials)
        return try await sendAndDecode(type, request: request)
    }

    private func okxPOST<T: Decodable>(
        _ type: T.Type,
        path: String,
        body: [String: Any],
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> T {
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let bodyString = String(data: bodyData, encoding: .utf8) ?? "{}"
        return try await okxPOSTRaw(type, path: path, bodyData: bodyData, bodyString: bodyString, profile: profile, credentials: credentials)
    }

    private func okxPOSTArray<T: Decodable>(
        _ type: T.Type,
        path: String,
        bodyArray: [[String: Any]],
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> T {
        let bodyData = try JSONSerialization.data(withJSONObject: bodyArray, options: [.sortedKeys])
        let bodyString = String(data: bodyData, encoding: .utf8) ?? "[]"
        return try await okxPOSTRaw(type, path: path, bodyData: bodyData, bodyString: bodyString, profile: profile, credentials: credentials)
    }

    private func okxPOSTRaw<T: Decodable>(
        _ type: T.Type,
        path: String,
        bodyData: Data,
        bodyString: String,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) async throws -> T {
        guard let url = URL(string: "\(profile.resolvedBaseURL)\(path)") else {
            throw ExchangeAPIError.invalidBaseURL
        }
        let timestamp = Self.okxTimestamp()
        let prehash = "\(timestamp)POST\(path)\(bodyString)"
        let signature = Self.hmacSHA256Base64(message: prehash, secret: credentials.secretKey)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        applyOKXHeaders(&request, timestamp: timestamp, signature: signature, profile: profile, credentials: credentials)
        return try await sendAndDecode(type, request: request)
    }

    private func applyOKXHeaders(
        _ request: inout URLRequest,
        timestamp: String,
        signature: String,
        profile: ExchangeAccountProfile,
        credentials: ExchangeCredentials
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "OK-ACCESS-KEY")
        request.setValue(signature, forHTTPHeaderField: "OK-ACCESS-SIGN")
        request.setValue(timestamp, forHTTPHeaderField: "OK-ACCESS-TIMESTAMP")
        request.setValue(credentials.passphrase, forHTTPHeaderField: "OK-ACCESS-PASSPHRASE")
        if profile.isSimulated {
            request.setValue("1", forHTTPHeaderField: "x-simulated-trading")
        }
    }

    private func sendAndDecode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw ExchangeAPIError.badResponse
        }
        if let header = try? JSONDecoder().decode(OKXTradeStatusHeader.self, from: data),
           header.code != "0" {
            let detail = extractSubErrorMessage(from: data) ?? header.msg ?? "交易所返回错误"
            throw OKXTradeError.okxRejected(code: header.code, message: mapFriendlyOKXMessage(code: header.code, raw: detail))
        }
        guard (200...299).contains(http.statusCode) else {
            throw ExchangeAPIError.httpError(http.statusCode, "OKX 交易接口响应异常")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func extractSubErrorMessage(from data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(OKXTradeEnvelope<OKXGenericTradeAck>.self, from: data),
           let first = envelope.data.first,
           let sMsg = first.sMsg, sMsg.isEmpty == false {
            if let sCode = first.sCode, sCode != "0" {
                return "[\(sCode)] \(sMsg)"
            }
            return sMsg
        }
        return nil
    }

    private func mapFriendlyOKXMessage(code: String, raw: String) -> String {
        switch code {
        case "50119", "50120":
            return "API Key 缺少「交易」权限或模拟盘/实盘环境不匹配（请检查 API 权限）"
        case "50110":
            return "当前 IP 不在该 OKX API Key 白名单内"
        default:
            return raw
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw ExchangeAPIError.timeout
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                throw ExchangeAPIError.networkUnreachable
            default:
                throw ExchangeAPIError.requestFailed(error.localizedDescription)
            }
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
}

// MARK: - 全局交易状态管理器

@MainActor
@Observable
final class OKXTradingStore {
    private enum Keys {
        static let config = "OKXTradingStore.securityConfig"
    }

    var config: TradingSecurityConfig {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: Keys.config)
            }
        }
    }

    private(set) var pendingOrders: [OKXPendingOrder] = []
    private(set) var algoOrders: [OKXAlgoOrder] = []
    private(set) var isLoadingOrders = false
    private(set) var isSubmitting = false
    private(set) var lastOrdersError: String?

    @ObservationIgnored private let portfolio: PortfolioStore
    @ObservationIgnored private let service: OKXTradingService
    @ObservationIgnored private var specCache: [String: OKXInstrumentSpec] = [:]
    @ObservationIgnored private var posModeCache: [UUID: OKXPositionMode] = [:]
    @ObservationIgnored var onTradeExecuted: (() async -> Void)?

    init(portfolio: PortfolioStore, service: OKXTradingService = OKXTradingService()) {
        self.portfolio = portfolio
        self.service = service
        if let data = UserDefaults.standard.data(forKey: Keys.config),
           let decoded = try? JSONDecoder().decode(TradingSecurityConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = TradingSecurityConfig()
        }
    }

    /// 所有已启用的 OKX 账户（若开启“仅模拟盘锁”，优先筛选模拟盘账户）
    var availableOKXAccounts: [ExchangeAccountProfile] {
        let okx = portfolio.enabledAccounts.filter { $0.exchange == .okx }
        if config.preferSimulatedOnly {
            return okx.filter(\.isSimulated)
        }
        return okx
    }

    var allEnabledOKXAccounts: [ExchangeAccountProfile] {
        portfolio.enabledAccounts.filter { $0.exchange == .okx }
    }

    var totalOpenOrderCount: Int {
        pendingOrders.count + algoOrders.count
    }

    func pendingOrders(accountID: UUID?) -> [OKXPendingOrder] {
        guard let accountID else { return pendingOrders }
        return pendingOrders.filter { $0.accountID == accountID }
    }

    func algoOrders(accountID: UUID?) -> [OKXAlgoOrder] {
        guard let accountID else { return algoOrders }
        return algoOrders.filter { $0.accountID == accountID }
    }

    /// 获取指定账户在交易账户中的可用 USDT 余额
    func availableUSDT(for accountID: UUID) -> Double {
        portfolio.balances(accountID: accountID)
            .filter { $0.bucket == .trading && $0.currency.uppercased() == "USDT" }
            .reduce(0) { $0 + $1.available }
    }

    /// 获取合约/现货交易规格（带内存缓存）
    func instrumentSpec(for asset: CryptoAsset, accountID: UUID? = nil) async throws -> OKXInstrumentSpec {
        if let cached = specCache[asset.id] { return cached }
        let baseURL = accountID
            .flatMap { id in portfolio.accounts.first(where: { $0.id == id })?.resolvedBaseURL }
            ?? ExchangeKind.okx.defaultBaseURL
        let spec = try await service.fetchInstrumentSpec(
            instId: asset.id,
            instType: asset.instrumentKind.rawValue,
            baseURL: baseURL
        )
        specCache[asset.id] = spec
        return spec
    }

    /// 刷新全部已启用 OKX 账户的当前普通委托与止盈止损策略单
    func refreshOrders() async {
        let okxAccounts = allEnabledOKXAccounts
        guard okxAccounts.isEmpty == false else {
            pendingOrders = []
            algoOrders = []
            lastOrdersError = nil
            return
        }
        isLoadingOrders = true
        lastOrdersError = nil
        defer { isLoadingOrders = false }

        var allPending: [OKXPendingOrder] = []
        var allAlgos: [OKXAlgoOrder] = []
        var firstError: String?

        for profile in okxAccounts {
            let creds = portfolio.credentials(for: profile.id).trimmed
            guard creds.apiKey.isEmpty == false, creds.secretKey.isEmpty == false, creds.passphrase.isEmpty == false else {
                continue
            }
            do {
                async let pTask = service.fetchPendingOrders(profile: profile, credentials: creds)
                async let aTask = service.fetchPendingAlgoOrders(profile: profile, credentials: creds)
                let (p, a) = try await (pTask, aTask)
                allPending.append(contentsOf: p)
                allAlgos.append(contentsOf: a)
            } catch {
                if firstError == nil {
                    firstError = "\(profile.name)：\(error.localizedDescription)"
                }
            }
        }

        pendingOrders = allPending.sorted { $0.createdAt > $1.createdAt }
        algoOrders = allAlgos.sorted { $0.createdAt > $1.createdAt }
        lastOrdersError = firstError
    }

    // MARK: 核心交易动作（全部带安全护栏与生物识别）

    func placeOrder(_ req: PlaceOrderRequest) async throws -> String {
        let (profile, creds) = try validateAccountForTrade(accountID: req.accountID)
        guard req.notionalUSD > 0 else {
            throw OKXTradeError.invalidInput("请输入大于 0 的下单金额。")
        }
        if config.maxSingleOrderUSD > 0 && req.notionalUSD > config.maxSingleOrderUSD {
            throw OKXTradeError.exceedsMaxOrderLimit(actual: req.notionalUSD, limit: config.maxSingleOrderUSD)
        }
        if req.orderType == .limit && (req.limitPrice ?? 0) <= 0 {
            throw OKXTradeError.invalidInput("限价单必须输入大于 0 的委托价格。")
        }

        let spec = try await instrumentSpec(for: req.asset, accountID: profile.id)
        let refPrice = (req.orderType == .limit ? (req.limitPrice ?? req.referencePrice) : req.referencePrice)
        guard refPrice > 0 else {
            throw OKXTradeError.invalidInput("尚未获取到有效参考价格，请稍后重试。")
        }

        let isSpot = !spec.isDerivative
        let tdMode = isSpot ? "cash" : req.marginMode.rawValue
        let priceStr = req.orderType == .limit ? spec.alignedPrice(req.limitPrice ?? 0) : nil
        let tpStr = req.takeProfitPrice.flatMap { $0 > 0 ? spec.alignedPrice($0) : nil }
        let slStr = req.stopLossPrice.flatMap { $0 > 0 ? spec.alignedPrice($0) : nil }

        let sizeStr: String
        let tgtCcy: String?
        let finalNotional: Double

        if isSpot && req.orderType == .market && req.side == .buy {
            // 现货市价买单：直接按 USDT 金额下单
            sizeStr = String(format: "%.2f", req.notionalUSD)
            tgtCcy = "quote_ccy"
            finalNotional = req.notionalUSD
        } else {
            guard let aligned = spec.alignedOrderSize(fromNotionalUSD: req.notionalUSD, referencePrice: refPrice) else {
                let minNotional = NSDecimalNumber(decimal: spec.minSz).doubleValue * spec.unitNotionalUSD(referencePrice: refPrice)
                throw OKXTradeError.invalidInput("下单金额过小，该标的最小下单额约 \(MarketFormatter.price(minNotional))。")
            }
            sizeStr = aligned.sizeString
            tgtCcy = isSpot ? "base_ccy" : nil
            finalNotional = aligned.actualNotionalUSD
        }

        if config.maxSingleOrderUSD > 0 && finalNotional > config.maxSingleOrderUSD * 1.01 {
            throw OKXTradeError.exceedsMaxOrderLimit(actual: finalNotional, limit: config.maxSingleOrderUSD)
        }

        let envTag = profile.isSimulated ? "模拟盘" : "实盘"
        let reason = "确认在 OKX(\(envTag)) \(req.side.label(for: req.asset.instrumentKind)) \(req.asset.pairLabel)，金额约 \(MarketFormatter.price(finalNotional))"
        try await authorizeIfNeeded(reason: reason)

        isSubmitting = true
        defer { isSubmitting = false }

        var posSide: String?
        if isSpot == false {
            let posMode = try await resolvePositionMode(profile: profile, credentials: creds)
            if posMode == .longShort {
                posSide = req.side == .buy ? "long" : "short"
            } else {
                posSide = "net"
            }

            // 下单前同步杠杆（尽力设置，部分全仓同杠杆已生效无需阻断）
            if req.leverage > 0 {
                let targetLev = min(req.leverage, max(Int(spec.maxLeverage.rounded(.down)), 1))
                try? await service.setLeverage(
                    instId: req.asset.id,
                    leverage: targetLev,
                    marginMode: req.marginMode,
                    posSide: posSide,
                    profile: profile,
                    credentials: creds
                )
            }
        }

        let ordId = try await service.placeOrder(
            instId: req.asset.id,
            tdMode: tdMode,
            side: req.side.rawValue,
            posSide: posSide,
            ordType: req.orderType.rawValue,
            size: sizeStr,
            price: priceStr,
            tgtCcy: tgtCcy,
            reduceOnly: false,
            takeProfitPx: tpStr,
            stopLossPx: slStr,
            profile: profile,
            credentials: creds
        )

        await postTradeRefresh()
        return ordId
    }

    func closePosition(_ req: ClosePositionRequest) async throws {
        let (profile, creds) = try validateAccountForTrade(accountID: req.position.accountID)
        let ratio = min(max(req.ratio, 0.01), 1.0)
        if req.orderType == .limit && (req.limitPrice ?? 0) <= 0 {
            throw OKXTradeError.invalidInput("限价平仓必须填写有效委托价格。")
        }

        let envTag = profile.isSimulated ? "模拟盘" : "实盘"
        let pctLabel = "\(Int((ratio * 100).rounded()))%"
        let reason = "确认在 OKX(\(envTag)) \(req.orderType.label)平仓 \(req.position.displayPair) \(req.position.side.label)单 \(pctLabel)"
        try await authorizeIfNeeded(reason: reason)

        isSubmitting = true
        defer { isSubmitting = false }

        if req.orderType == .market && ratio >= 0.999 {
            try await service.closePositionMarketAll(position: req.position, profile: profile, credentials: creds)
        } else {
            let spec = try await instrumentSpec(for: req.position.marketAsset, accountID: profile.id)
            let rawQty = ratio >= 0.999 ? req.position.quantity : req.position.quantity * ratio
            guard let aligned = spec.alignedSize(rawQuantity: rawQty, allowMinFallback: ratio >= 0.999) else {
                throw OKXTradeError.invalidInput("按比例折算后的平仓数量小于最小下单量，请提高平仓比例或选择 100% 全平。")
            }
            let closeSide = req.position.side == .long ? "sell" : "buy"
            let posSide = (req.position.rawPosSide == "long" || req.position.rawPosSide == "short") ? req.position.rawPosSide : "net"
            let priceStr = req.orderType == .limit ? spec.alignedPrice(req.limitPrice ?? 0) : nil

            _ = try await service.placeOrder(
                instId: req.position.marketAsset.id,
                tdMode: req.position.rawMarginMode,
                side: closeSide,
                posSide: posSide,
                ordType: req.orderType.rawValue,
                size: aligned.sizeString,
                price: priceStr,
                tgtCcy: nil,
                reduceOnly: true,
                takeProfitPx: nil,
                stopLossPx: nil,
                profile: profile,
                credentials: creds
            )
        }

        await postTradeRefresh()
    }

    func placeTPSL(_ req: PlaceTPSLRequest) async throws -> String {
        let (profile, creds) = try validateAccountForTrade(accountID: req.position.accountID)
        let hasTP = (req.takeProfitPrice ?? 0) > 0
        let hasSL = (req.stopLossPrice ?? 0) > 0
        guard hasTP || hasSL else {
            throw OKXTradeError.invalidInput("请至少输入止盈价或止损价。")
        }

        let spec = try await instrumentSpec(for: req.position.marketAsset, accountID: profile.id)
        let tpStr = hasTP ? spec.alignedPrice(req.takeProfitPrice ?? 0) : nil
        let slStr = hasSL ? spec.alignedPrice(req.stopLossPrice ?? 0) : nil

        let envTag = profile.isSimulated ? "模拟盘" : "实盘"
        let reason = "确认在 OKX(\(envTag)) 为 \(req.position.displayPair) \(req.position.side.label)单设置止盈止损"
        try await authorizeIfNeeded(reason: reason)

        isSubmitting = true
        defer { isSubmitting = false }

        let algoId = try await service.placePositionTPSL(
            position: req.position,
            takeProfitPx: tpStr,
            stopLossPx: slStr,
            triggerType: req.triggerPriceType,
            profile: profile,
            credentials: creds
        )
        await postTradeRefresh()
        return algoId
    }

    func cancelOrder(_ order: OKXPendingOrder) async throws {
        let (profile, creds) = try validateAccountForTrade(accountID: order.accountID)
        try await authorizeIfNeeded(reason: "确认撤销 \(order.displayPair) 委托单")
        isSubmitting = true
        defer { isSubmitting = false }
        try await service.cancelOrder(order: order, profile: profile, credentials: creds)
        await postTradeRefresh()
    }

    func cancelAlgoOrder(_ order: OKXAlgoOrder) async throws {
        let (profile, creds) = try validateAccountForTrade(accountID: order.accountID)
        try await authorizeIfNeeded(reason: "确认撤销 \(order.displayPair) 止盈止损单")
        isSubmitting = true
        defer { isSubmitting = false }
        try await service.cancelAlgoOrders(orders: [order], profile: profile, credentials: creds)
        await postTradeRefresh()
    }

    func cancelAllOrders(accountID: UUID?) async throws {
        guard config.tradingEnabled else { throw OKXTradeError.tradingDisabled }
        let targetPending = pendingOrders(accountID: accountID)
        let targetAlgos = algoOrders(accountID: accountID)
        guard targetPending.isEmpty == false || targetAlgos.isEmpty == false else { return }

        try await authorizeIfNeeded(reason: "确认一键撤销全部 \(targetPending.count + targetAlgos.count) 笔未成交委托")
        isSubmitting = true
        defer { isSubmitting = false }

        let groupedPending = Dictionary(grouping: targetPending, by: \.accountID)
        for (accID, list) in groupedPending {
            let (profile, creds) = try validateAccountForTrade(accountID: accID)
            try await service.cancelBatchOrders(orders: list, profile: profile, credentials: creds)
        }

        let groupedAlgos = Dictionary(grouping: targetAlgos, by: \.accountID)
        for (accID, list) in groupedAlgos {
            let (profile, creds) = try validateAccountForTrade(accountID: accID)
            try await service.cancelAlgoOrders(orders: list, profile: profile, credentials: creds)
        }

        await postTradeRefresh()
    }

    // MARK: 内部辅助

    private func validateAccountForTrade(accountID: UUID) throws -> (ExchangeAccountProfile, ExchangeCredentials) {
        guard config.tradingEnabled else {
            throw OKXTradeError.tradingDisabled
        }
        guard let profile = portfolio.enabledAccounts.first(where: { $0.id == accountID }) else {
            throw OKXTradeError.accountNotFound
        }
        guard profile.exchange == .okx else {
            throw OKXTradeError.unsupportedExchange
        }
        if config.preferSimulatedOnly && profile.isSimulated == false {
            throw OKXTradeError.simulatedOnlyLock(profile.name)
        }
        let creds = portfolio.credentials(for: profile.id).trimmed
        guard creds.apiKey.isEmpty == false, creds.secretKey.isEmpty == false else {
            throw ExchangeAPIError.missingCredentials
        }
        guard creds.passphrase.isEmpty == false else {
            throw ExchangeAPIError.missingPassphrase
        }
        return (profile, creds)
    }

    private func authorizeIfNeeded(reason: String) async throws {
        guard config.requireBiometrics else { return }
        try await BiometricAuthorizer.authenticate(reason: reason)
    }

    private func resolvePositionMode(profile: ExchangeAccountProfile, credentials: ExchangeCredentials) async throws -> OKXPositionMode {
        if let cached = posModeCache[profile.id] { return cached }
        let mode = (try? await service.fetchAccountPositionMode(profile: profile, credentials: credentials)) ?? .longShort
        posModeCache[profile.id] = mode
        return mode
    }

    private func postTradeRefresh() async {
        // 稍作短暂缓冲，确保交易所撮合落账后再同步最新仓位与挂单
        try? await Task.sleep(for: .milliseconds(350))
        await portfolio.refreshAll()
        await refreshOrders()
        await onTradeExecuted?()
    }
}

// MARK: - OKX 交易 DTO

nonisolated private struct OKXTradeStatusHeader: Decodable {
    let code: String
    let msg: String?
}

nonisolated private struct OKXTradeEnvelope<Item: Decodable>: Decodable {
    let code: String
    let msg: String?
    let data: [Item]
}

nonisolated private struct OKXRawInstrument: Decodable {
    let instId: String
    let instType: String
    let baseCcy: String?
    let quoteCcy: String?
    let ctVal: String?
    let ctValCcy: String?
    let lotSz: String?
    let minSz: String?
    let tickSz: String?
    let lever: String?
}

nonisolated private struct OKXAccountConfigItem: Decodable {
    let posMode: String?
}

nonisolated private struct OKXOrderAck: Decodable {
    let ordId: String?
    let clOrdId: String?
    let sCode: String?
    let sMsg: String?
}

nonisolated private struct OKXAlgoAck: Decodable {
    let algoId: String?
    let sCode: String?
    let sMsg: String?
}

nonisolated private struct OKXGenericTradeAck: Decodable {
    let sCode: String?
    let sMsg: String?
}

nonisolated private struct OKXRawPendingOrder: Decodable {
    let ordId: String
    let instId: String
    let instType: String?
    let side: String?
    let posSide: String?
    let ordType: String?
    let tdMode: String?
    let px: String?
    let sz: String?
    let accFillSz: String?
    let lever: String?
    let state: String?
    let cTime: String?
}

nonisolated private struct OKXRawAlgoOrder: Decodable {
    let algoId: String
    let instId: String
    let instType: String?
    let side: String?
    let posSide: String?
    let ordType: String?
    let tdMode: String?
    let sz: String?
    let closeFraction: String?
    let tpTriggerPx: String?
    let slTriggerPx: String?
    let cTime: String?
}
