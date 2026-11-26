import Foundation

// MARK: - AI 模型配置

nonisolated struct AIProviderConfiguration: Equatable, Sendable {
    var provider: AIProvider = .openAI
    var apiKey = ""
    var baseURL = AIProvider.openAI.defaultBaseURL
    var model = AIProvider.openAI.defaultModel

    var resolvedBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return URL(string: trimmed)
    }

    var isReady: Bool {
        guard resolvedBaseURL != nil,
              model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        if provider.requiresAPIKey {
            return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return true
    }
}

nonisolated enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case deepSeek
    case qwen
    case moonshot
    case local
    case compatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .qwen: return "通义千问"
        case .moonshot: return "Kimi (Moonshot)"
        case .local: return "本地模型 (Ollama)"
        case .compatible: return "自定义 OpenAI 兼容"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .local: return "http://127.0.0.1:11434/v1"
        case .compatible: return "https://api.example.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .moonshot: return "moonshot-v1-8k"
        case .local: return "qwen2.5:7b"
        case .compatible: return "gpt-4o-mini"
        }
    }

    var requiresAPIKey: Bool {
        self != .local
    }

    var hint: String {
        switch self {
        case .openAI: return "使用官方 OpenAI 接口，推荐 gpt-4o-mini 兼顾速度与成本。"
        case .deepSeek: return "支持 deepseek-chat / deepseek-reasoner，响应快、中文表达自然。"
        case .qwen: return "阿里云百炼 OpenAI 兼容端点，支持 qwen-plus / qwen-max。"
        case .moonshot: return "Moonshot OpenAI 兼容端点，需填写平台 API Key。"
        case .local: return "连接本机 Ollama / LM Studio，无需 API Key，数据不出本机。"
        case .compatible: return "填写任意支持 /chat/completions 协议的服务地址与模型名称。"
        }
    }
}

nonisolated struct MarketAnalysisContext: Sendable {
    let asset: CryptoAsset
    let interval: KlineInterval
    let quote: CryptoQuote?
    let klines: [KlinePoint]
}

nonisolated struct AIAnalysisReport: Equatable, Sendable {
    let content: String
    let generatedAt: Date
    let modelName: String
}

// MARK: - AI 分析结果缓存

@MainActor
@Observable
final class AIAnalysisCache {
    private var storage: [String: AIAnalysisReport] = [:]

    func report(for asset: CryptoAsset, interval: KlineInterval) -> AIAnalysisReport? {
        storage[cacheKey(asset: asset, interval: interval)]
    }

    func store(_ report: AIAnalysisReport, for asset: CryptoAsset, interval: KlineInterval) {
        storage[cacheKey(asset: asset, interval: interval)] = report
    }

    private func cacheKey(asset: CryptoAsset, interval: KlineInterval) -> String {
        "\(asset.id)|\(interval.rawValue)"
    }
}

// MARK: - AI 分析服务

nonisolated struct AIAnalysisService: Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    func analyze(context: MarketAnalysisContext, configuration: AIProviderConfiguration) async throws -> AIAnalysisReport {
        let content = try await sendCompletion(
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt(for: context))
            ],
            temperature: 0.25,
            maxTokens: nil,
            configuration: configuration
        )

        return AIAnalysisReport(
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            generatedAt: Date(),
            modelName: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 轻量级连通性测试，用于设置页一键验证 API Key 与端点
    func testConnection(configuration: AIProviderConfiguration) async throws -> String {
        let reply = try await sendCompletion(
            messages: [
                ChatMessage(role: "user", content: "请仅回复“连接成功”四个字。")
            ],
            temperature: 0,
            maxTokens: 20,
            configuration: configuration
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendCompletion(
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int?,
        configuration: AIProviderConfiguration
    ) async throws -> String {
        guard let baseURL = configuration.resolvedBaseURL else {
            throw AIAnalysisError.invalidBaseURL
        }

        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty == false else {
            throw AIAnalysisError.missingModel
        }

        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.provider.requiresAPIKey && apiKey.isEmpty {
            throw AIAnalysisError.missingAPIKey
        }

        let endpoint = resolveEndpoint(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if apiKey.isEmpty == false {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw AIAnalysisError.timeout
        } catch {
            throw AIAnalysisError.requestFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAnalysisError.badResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AIAnalysisError.emptyResponse
        }

        return content
    }

    private func resolveEndpoint(baseURL: URL) -> URL {
        if baseURL.path.hasSuffix("chat/completions") {
            return baseURL
        }
        return baseURL.appending(path: "chat/completions")
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> AIAnalysisError {
        if statusCode == 401 || statusCode == 403 {
            return .unauthorized
        }
        if statusCode == 429 {
            return .rateLimited
        }
        if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data),
           let message = apiError.error?.message,
           message.isEmpty == false {
            return .requestFailed("HTTP \(statusCode)：\(message)")
        }
        return .requestFailed("HTTP \(statusCode)")
    }

    private var systemPrompt: String {
        """
        你是一位专业、克制、重数据的加密货币行情分析助手。
        规则：
        1. 严格基于用户提供的行情和 K 线数据分析，严禁编造链上数据、宏观新闻或未提供的指标。
        2. 使用中文输出，结构清晰、分析充分、重点突出，不做字数截断限制。
        3. 所有判断使用概率和条件表达，禁止直接发出“买入/卖出/做多/做空”指令。
        4. 末尾附一句清晰的风险提示（非投资建议）。
        """
    }

    private func userPrompt(for context: MarketAnalysisContext) -> String {
        let quoteText: String
        if let quote = context.quote {
            quoteText = """
            最新价: \(quote.price)
            24h涨跌幅: \(String(format: "%.2f", quote.changePercentage24h))%
            24h最高: \(quote.high24h)
            24h最低: \(quote.low24h)
            24h成交额(USDT): \(String(format: "%.0f", quote.volumeCurrency24h))
            """
        } else {
            quoteText = "暂无实时报价"
        }

        let recent = Array(context.klines.suffix(60))
        let indicatorSummary = computeIndicatorSummary(from: recent)
        let klineRows = recent.map { point in
            "\(Int(point.openTime.timeIntervalSince1970)),O=\(point.open),H=\(point.high),L=\(point.low),C=\(point.close),V=\(String(format: "%.2f", point.volume))"
        }.joined(separator: "\n")

        return """
        标的：\(context.asset.pairLabel)（\(context.asset.instrumentKind.label)）
        周期：\(context.interval.label)

        【24小时行情】
        \(quoteText)

        【技术摘要】
        \(indicatorSummary)

        【最近 K 线（时间,开,高,低,收,量）】
        \(klineRows)

        请按以下结构输出详尽、客观的分析：
        1. 市场状态（趋势 / 震荡 / 量价与波动特征）
        2. 多头因素（结合上述 K 线结构、均线与量能说明依据）
        3. 空头因素（结合上述 K 线结构、均线与量能说明依据）
        4. 关键价位（支撑位与压力位，说明从哪些高低点或均线推导）
        5. 短线情景推演（分突破、回踩、跌破三种触发条件与观察信号）
        6. 风险提示、综合置信度（0-100）与非投资建议声明
        """
    }

    private func computeIndicatorSummary(from klines: [KlinePoint]) -> String {
        guard klines.isEmpty == false else { return "暂无 K 线数据" }
        let closes = klines.map(\.close)
        let ma7 = movingAverage(closes, period: 7)
        let ma25 = movingAverage(closes, period: 25)
        let periodHigh = klines.map(\.high).max() ?? 0
        let periodLow = klines.map(\.low).min() ?? 0
        let avgVol = klines.map(\.volume).reduce(0, +) / Double(klines.count)
        let lastVol = klines.last?.volume ?? 0
        let volRatio = avgVol > 0 ? lastVol / avgVol : 1

        var lines: [String] = [
            "区间最高: \(periodHigh) / 区间最低: \(periodLow)",
            "最新量能/区间均量: \(String(format: "%.2f", volRatio))x"
        ]
        if let ma7 { lines.append("MA7: \(String(format: "%.4f", ma7))") }
        if let ma25 { lines.append("MA25: \(String(format: "%.4f", ma25))") }
        return lines.joined(separator: "\n")
    }

    private func movingAverage(_ values: [Double], period: Int) -> Double? {
        guard values.count >= period else { return nil }
        let slice = values.suffix(period)
        return slice.reduce(0, +) / Double(period)
    }
}

// MARK: - OpenAI 兼容协议 DTO

nonisolated private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

nonisolated private struct ChatMessage: Codable {
    let role: String
    let content: String
}

nonisolated private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

nonisolated private struct OpenAIErrorEnvelope: Decodable {
    let error: Inner?
    struct Inner: Decodable {
        let message: String?
    }
}

nonisolated enum AIAnalysisError: LocalizedError {
    case invalidBaseURL
    case missingModel
    case missingAPIKey
    case unauthorized
    case rateLimited
    case timeout
    case badResponse
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "模型服务地址格式无效，请在设置中检查 Base URL。"
        case .missingModel:
            return "请先在设置中填写模型名称。"
        case .missingAPIKey:
            return "尚未配置 API Key，请前往“设置 → AI 助手”完成配置。"
        case .unauthorized:
            return "API Key 无效或无权访问该模型，请检查后重试。"
        case .rateLimited:
            return "请求过于频繁或账号额度不足，请稍后再试。"
        case .timeout:
            return "模型响应超时，请检查网络或切换更快的模型。"
        case .badResponse:
            return "模型服务响应异常。"
        case .requestFailed(let message):
            return "请求失败：\(message)"
        case .emptyResponse:
            return "模型未返回有效分析内容。"
        }
    }
}
