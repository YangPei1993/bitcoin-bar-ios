import AudioToolbox
import AVFoundation
import Foundation
import UIKit
import UserNotifications

// MARK: - 告警级别与消息体

nonisolated enum AlertSeverity: String, CaseIterable, Identifiable, Codable, Sendable, Comparable {
    case info
    case warning
    case critical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .info: return "常规提醒"
        case .warning: return "风险预警"
        case .critical: return "极危告警"
        }
    }

    var badge: String {
        switch self {
        case .info: return "P2"
        case .warning: return "P1"
        case .critical: return "P0"
        }
    }

    var emoji: String {
        switch self {
        case .info: return "🔔"
        case .warning: return "⚠️"
        case .critical: return "🚨"
        }
    }

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated struct AlertPayload: Identifiable, Sendable {
    let id: UUID
    let severity: AlertSeverity
    let category: String
    let title: String
    let body: String
    let assetID: String?
    let openPortfolio: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        severity: AlertSeverity,
        category: String,
        title: String,
        body: String,
        assetID: String? = nil,
        openPortfolio: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.body = body
        self.assetID = assetID
        self.openPortfolio = openPortfolio
        self.timestamp = timestamp
    }
}

// MARK: - 推送通道模型

nonisolated enum NotificationChannelKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case wecom
    case serverChan
    case pushPlus
    case bark
    case feishu
    case dingtalk
    case telegram
    case twilioSMS
    case customWebhook

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wecom: return "企业微信机器人"
        case .serverChan: return "微信 · Server酱"
        case .pushPlus: return "微信 · PushPlus"
        case .bark: return "Bark（iOS 强提醒）"
        case .feishu: return "飞书机器人"
        case .dingtalk: return "钉钉机器人"
        case .telegram: return "Telegram Bot"
        case .twilioSMS: return "Twilio 短信"
        case .customWebhook: return "自定义 Webhook / 短信网关"
        }
    }

    var shortLabel: String {
        switch self {
        case .wecom: return "企微"
        case .serverChan: return "微信"
        case .pushPlus: return "微信"
        case .bark: return "Bark"
        case .feishu: return "飞书"
        case .dingtalk: return "钉钉"
        case .telegram: return "TG"
        case .twilioSMS: return "短信"
        case .customWebhook: return "Hook"
        }
    }

    var hint: String {
        switch self {
        case .wecom: return "在企业微信群添加群机器人，复制 Webhook 地址即可免费推送到微信，无条数限制。"
        case .serverChan: return "填入 Server酱 SendKey（支持 Turbo 与 Server3），消息直推个人微信。"
        case .pushPlus: return "填入 PushPlus Token，消息直接推送至个人微信。"
        case .bark: return "填入 iPhone Bark App 推送地址，P0 极危告警自动触发紧急响铃突破静音！"
        case .feishu: return "在飞书群添加自定义机器人，粘贴 Webhook 地址即可推送。"
        case .dingtalk: return "在钉钉群添加自定义机器人（建议关键词“告警”或“提醒”），粘贴 Webhook 地址。"
        case .telegram: return "通过 @BotFather 获取 Bot Token 并填写 Chat ID，直连 Telegram 秒达。"
        case .twilioSMS: return "填入 Twilio Account SID、Auth Token、发送号码与接收手机号（含区号如 +86...）。"
        case .customWebhook: return "POST JSON（severity/category/title/body/timestamp），自由对接短信/电话网关。"
        }
    }

    var primarySecretLabel: String {
        switch self {
        case .wecom, .feishu, .dingtalk, .customWebhook: return "Webhook URL"
        case .serverChan: return "SendKey"
        case .pushPlus: return "Token"
        case .bark: return "Bark 推送地址"
        case .telegram: return "Bot Token"
        case .twilioSMS: return "Auth Token"
        }
    }

    var primarySecretPlaceholder: String {
        switch self {
        case .wecom: return "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=..."
        case .serverChan: return "SCT... 或 sctp..."
        case .pushPlus: return "输入 PushPlus Token"
        case .bark: return "https://api.day.app/你的设备Key"
        case .feishu: return "https://open.feishu.cn/open-apis/bot/v2/hook/..."
        case .dingtalk: return "https://oapi.dingtalk.com/robot/send?access_token=..."
        case .telegram: return "123456:ABC-DEF..."
        case .twilioSMS: return "输入 Twilio Auth Token"
        case .customWebhook: return "https://your-gateway.example.com/alert"
        }
    }
}

nonisolated enum ChannelRoutingRule: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case riskOnly
    case criticalOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部提醒（P0/P1/P2）"
        case .riskOnly: return "仅风控预警（P0/P1）"
        case .criticalOnly: return "仅极危告警（P0）"
        }
    }

    var shortLabel: String {
        switch self {
        case .all: return "全部"
        case .riskOnly: return "风控"
        case .criticalOnly: return "极危"
        }
    }

    func accepts(_ severity: AlertSeverity) -> Bool {
        switch self {
        case .all: return true
        case .riskOnly: return severity >= .warning
        case .criticalOnly: return severity >= .critical
        }
    }
}

nonisolated enum VoiceAlertMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case criticalOnly
    case riskAndCritical
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭语音播报"
        case .criticalOnly: return "仅极危告警（P0）朗读"
        case .riskAndCritical: return "风险与极危（P0/P1）朗读"
        case .all: return "全部提醒朗读"
        }
    }

    func accepts(_ severity: AlertSeverity) -> Bool {
        switch self {
        case .off: return false
        case .criticalOnly: return severity >= .critical
        case .riskAndCritical: return severity >= .warning
        case .all: return true
        }
    }
}

nonisolated struct NotificationChannelConfig: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: NotificationChannelKind
    var name: String
    var routingRule: ChannelRoutingRule
    var isEnabled: Bool
    var extraField1: String
    var extraField2: String
    var extraField3: String
    var maskedSecret: String

    init(
        id: UUID = UUID(),
        kind: NotificationChannelKind,
        name: String,
        routingRule: ChannelRoutingRule = .all,
        isEnabled: Bool = true,
        extraField1: String = "",
        extraField2: String = "",
        extraField3: String = "",
        maskedSecret: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.routingRule = routingRule
        self.isEnabled = isEnabled
        self.extraField1 = extraField1
        self.extraField2 = extraField2
        self.extraField3 = extraField3
        self.maskedSecret = maskedSecret
    }
}

nonisolated struct AlertEventRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let severity: AlertSeverity
    let category: String
    let title: String
    let body: String
    let timestamp: Date
    var deliverySummary: String
}

// MARK: - 通道 HTTP 发送器

nonisolated struct ChannelDeliveryClient: Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    func send(payload: AlertPayload, channel: NotificationChannelConfig, secret: String) async throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ChannelDeliveryError.missingSecret(channel.kind.primarySecretLabel)
        }

        switch channel.kind {
        case .wecom: try await sendWeCom(payload: payload, webhookURL: trimmed)
        case .serverChan: try await sendServerChan(payload: payload, sendKey: trimmed)
        case .pushPlus: try await sendPushPlus(payload: payload, token: trimmed)
        case .bark: try await sendBark(payload: payload, baseURL: trimmed)
        case .feishu: try await sendFeishu(payload: payload, webhookURL: trimmed)
        case .dingtalk: try await sendDingTalk(payload: payload, webhookURL: trimmed)
        case .telegram: try await sendTelegram(payload: payload, botToken: trimmed, chatID: channel.extraField1)
        case .twilioSMS:
            try await sendTwilioSMS(
                payload: payload,
                accountSID: channel.extraField1,
                authToken: trimmed,
                fromNumber: channel.extraField2,
                toNumber: channel.extraField3
            )
        case .customWebhook: try await sendCustomWebhook(payload: payload, urlString: trimmed, bearerToken: channel.extraField1)
        }
    }

    private func sendWeCom(payload: AlertPayload, webhookURL: String) async throws {
        guard let url = URL(string: webhookURL) else { throw ChannelDeliveryError.invalidURL }
        let colorTag = payload.severity >= .warning ? "warning" : "info"
        let markdown = """
        \(payload.severity.emoji) **[\(payload.severity.label)] \(payload.title)**
        > 类别：\(payload.category)
        > 详情：<font color="\(colorTag)">\(payload.body)</font>
        > 时间：\(MarketFormatter.clockTime(payload.timestamp))
        """
        try await postJSON(url: url, object: ["msgtype": "markdown", "markdown": ["content": markdown]])
    }

    private func sendServerChan(payload: AlertPayload, sendKey: String) async throws {
        let urlString: String
        if sendKey.hasPrefix("sctp"), let range = sendKey.range(of: "t") {
            let uid = sendKey[sendKey.index(sendKey.startIndex, offsetBy: 4)..<range.lowerBound]
            urlString = "https://\(uid).push.ft07.com/send/\(sendKey).send"
        } else {
            urlString = "https://sctapi.ftqq.com/\(sendKey).send"
        }
        guard let url = URL(string: urlString) else { throw ChannelDeliveryError.invalidURL }
        let body: [String: Any] = [
            "title": "\(payload.severity.emoji) \(payload.title)",
            "desp": "**[\(payload.severity.label) · \(payload.category)]**\n\n\(payload.body)\n\n时间：\(MarketFormatter.clockTime(payload.timestamp))"
        ]
        try await postJSON(url: url, object: body)
    }

    private func sendPushPlus(payload: AlertPayload, token: String) async throws {
        guard let url = URL(string: "https://www.pushplus.plus/send") else { throw ChannelDeliveryError.invalidURL }
        let body: [String: Any] = [
            "token": token,
            "title": "\(payload.severity.emoji) \(payload.title)",
            "content": "[\(payload.severity.label) · \(payload.category)]<br/>\(payload.body)<br/>时间：\(MarketFormatter.clockTime(payload.timestamp))",
            "template": "html"
        ]
        try await postJSON(url: url, object: body)
    }

    private func sendBark(payload: AlertPayload, baseURL: String) async throws {
        let clean = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: clean) else { throw ChannelDeliveryError.invalidURL }
        var body: [String: Any] = [
            "title": "\(payload.severity.emoji) \(payload.title)",
            "body": "[\(payload.category)] \(payload.body)",
            "group": "bitcoin-bar"
        ]
        switch payload.severity {
        case .critical:
            body["level"] = "critical"
            body["volume"] = 10
            body["sound"] = "alarm"
            body["call"] = "1"
        case .warning:
            body["level"] = "timeSensitive"
            body["sound"] = "anticipate"
        case .info:
            body["level"] = "active"
        }
        try await postJSON(url: url, object: body)
    }

    private func sendFeishu(payload: AlertPayload, webhookURL: String) async throws {
        guard let url = URL(string: webhookURL) else { throw ChannelDeliveryError.invalidURL }
        let text = "\(payload.severity.emoji) [\(payload.severity.label) · \(payload.category)]\n\(payload.title)\n\(payload.body)\n时间：\(MarketFormatter.clockTime(payload.timestamp))"
        try await postJSON(url: url, object: ["msg_type": "text", "content": ["text": text]])
    }

    private func sendDingTalk(payload: AlertPayload, webhookURL: String) async throws {
        guard let url = URL(string: webhookURL) else { throw ChannelDeliveryError.invalidURL }
        let content = "\(payload.severity.emoji) 告警提醒 · [\(payload.severity.label)]\n\(payload.title)\n\(payload.body)\n时间：\(MarketFormatter.clockTime(payload.timestamp))"
        try await postJSON(url: url, object: ["msgtype": "text", "text": ["content": content]])
    }

    private func sendTelegram(payload: AlertPayload, botToken: String, chatID: String) async throws {
        let cleanChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanChatID.isEmpty == false else { throw ChannelDeliveryError.missingSecret("Chat ID") }
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else { throw ChannelDeliveryError.invalidURL }
        let text = "\(payload.severity.emoji) [\(payload.severity.label) · \(payload.category)]\n\(payload.title)\n\(payload.body)\n时间：\(MarketFormatter.clockTime(payload.timestamp))"
        try await postJSON(url: url, object: ["chat_id": cleanChatID, "text": text])
    }

    private func sendTwilioSMS(payload: AlertPayload, accountSID: String, authToken: String, fromNumber: String, toNumber: String) async throws {
        let sid = accountSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = fromNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = toNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sid.isEmpty == false, from.isEmpty == false, to.isEmpty == false else {
            throw ChannelDeliveryError.missingSecret("Account SID / 发送号码 / 接收手机号")
        }
        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(sid)/Messages.json") else {
            throw ChannelDeliveryError.invalidURL
        }

        let smsText = "[bitcoin-bar \(payload.severity.badge)] \(payload.title) - \(payload.body)"
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "From", value: from),
            URLQueryItem(name: "To", value: to),
            URLQueryItem(name: "Body", value: smsText)
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Data("\(sid):\(authToken)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "短信发送失败"
            throw ChannelDeliveryError.serverRejected(String(text.prefix(160)))
        }
    }

    private func sendCustomWebhook(payload: AlertPayload, urlString: String, bearerToken: String) async throws {
        guard let url = URL(string: urlString) else { throw ChannelDeliveryError.invalidURL }
        let body: [String: Any] = [
            "app": "bitcoin-bar-ios",
            "severity": payload.severity.rawValue,
            "level": payload.severity.badge,
            "category": payload.category,
            "title": payload.title,
            "body": payload.body,
            "assetId": payload.assetID ?? "",
            "timestamp": Int(payload.timestamp.timeIntervalSince1970)
        ]
        var headers: [String: String] = [:]
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty == false {
            headers["Authorization"] = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        }
        try await postJSON(url: url, object: body, extraHeaders: headers)
    }

    private func postJSON(url: URL, object: [String: Any], extraHeaders: [String: String] = [:]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChannelDeliveryError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ChannelDeliveryError.serverRejected("HTTP \(http.statusCode)：\(String(detail.prefix(140)))")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errcode = json["errcode"] as? Int, errcode != 0 {
                throw ChannelDeliveryError.serverRejected((json["errmsg"] as? String) ?? "errcode=\(errcode)")
            }
            if let code = json["code"] as? Int, code != 0 && code != 200 {
                throw ChannelDeliveryError.serverRejected((json["msg"] as? String) ?? (json["message"] as? String) ?? "code=\(code)")
            }
            if let ok = json["ok"] as? Bool, ok == false {
                throw ChannelDeliveryError.serverRejected((json["description"] as? String) ?? "发送失败")
            }
        }
    }
}

nonisolated enum ChannelDeliveryError: LocalizedError {
    case missingSecret(String)
    case invalidURL
    case badResponse
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingSecret(let field): return "请先填写 \(field)。"
        case .invalidURL: return "推送地址格式无效，请确认以 https:// 或 http:// 开头。"
        case .badResponse: return "推送服务响应异常。"
        case .serverRejected(let msg): return "推送被拒绝：\(msg)"
        }
    }
}

// MARK: - iOS 统一通知分发中心

@MainActor
@Observable
final class NotificationDispatcher {
    private enum Keys {
        static let channels = "NotificationDispatcher.channels"
        static let voiceMode = "NotificationDispatcher.voiceMode"
        static let isMuted = "NotificationDispatcher.isMuted"
    }

    private(set) var channels: [NotificationChannelConfig] = []
    private(set) var recentEvents: [AlertEventRecord] = []

    var voiceMode: VoiceAlertMode {
        didSet { UserDefaults.standard.set(voiceMode.rawValue, forKey: Keys.voiceMode) }
    }

    var isMuted: Bool {
        didSet { UserDefaults.standard.set(isMuted, forKey: Keys.isMuted) }
    }

    @ObservationIgnored private let client = ChannelDeliveryClient()
    @ObservationIgnored private let speechSynthesizer = AVSpeechSynthesizer()
    @ObservationIgnored var onDisplayToast: ((AlertPayload) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        self.voiceMode = VoiceAlertMode(rawValue: defaults.string(forKey: Keys.voiceMode) ?? "") ?? .criticalOnly
        self.isMuted = defaults.bool(forKey: Keys.isMuted)

        if let data = defaults.data(forKey: Keys.channels),
           let decoded = try? JSONDecoder().decode([NotificationChannelConfig].self, from: data) {
            self.channels = decoded
        }
    }

    var enabledChannelCount: Int {
        channels.filter(\.isEnabled).count
    }

    func dispatch(_ payload: AlertPayload) {
        onDisplayToast?(payload)

        if isMuted {
            insertRecord(payload: payload, summary: "已静音跳过推送")
            return
        }

        triggerHapticAndSound(for: payload.severity)

        if voiceMode.accepts(payload.severity) {
            speakAlert("\(payload.severity.label)。\(payload.title)。\(payload.body)")
        }

        postSystemNotification(payload)

        let matched = channels.filter { $0.isEnabled && $0.routingRule.accepts(payload.severity) }
        insertRecord(payload: payload, summary: matched.isEmpty ? "已发送本机通知" : "正在推送至 \(matched.count) 个外部通道...")

        guard matched.isEmpty == false else { return }

        let client = client
        let pairs = matched.map { ($0, secret(for: $0.id)) }
        let eventID = payload.id

        Task { [weak self] in
            var okNames: [String] = []
            var failNames: [String] = []

            await withTaskGroup(of: (String, Bool).self) { group in
                for (ch, sec) in pairs {
                    group.addTask {
                        do {
                            try await client.send(payload: payload, channel: ch, secret: sec)
                            return (ch.name, true)
                        } catch {
                            return (ch.name, false)
                        }
                    }
                }
                for await (name, ok) in group {
                    if ok { okNames.append(name) } else { failNames.append(name) }
                }
            }

            guard let self, let idx = self.recentEvents.firstIndex(where: { $0.id == eventID }) else { return }
            if failNames.isEmpty {
                self.recentEvents[idx].deliverySummary = "本机 + \(okNames.joined(separator: "、")) 已送达"
            } else if okNames.isEmpty {
                self.recentEvents[idx].deliverySummary = "本机已达；外部失败：\(failNames.joined(separator: "、"))"
            } else {
                self.recentEvents[idx].deliverySummary = "成功：\(okNames.joined(separator: "、"))；失败：\(failNames.joined(separator: "、"))"
            }
        }
    }

    func speakAlert(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    func secret(for channelID: UUID) -> String {
        KeychainStore.load(account: keychainAccount(for: channelID))
    }

    @discardableResult
    func saveChannel(
        editingID: UUID?,
        kind: NotificationChannelKind,
        name: String,
        routingRule: ChannelRoutingRule,
        secret: String,
        extraField1: String,
        extraField2: String,
        extraField3: String
    ) -> NotificationChannelConfig {
        let id = editingID ?? UUID()
        let existingSecret = editingID.map { self.secret(for: $0) } ?? ""
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSecret = trimmedSecret.isEmpty ? existingSecret : trimmedSecret

        KeychainStore.save(finalSecret, account: keychainAccount(for: id))

        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? kind.label
            : name.trimmingCharacters(in: .whitespacesAndNewlines)

        let config = NotificationChannelConfig(
            id: id,
            kind: kind,
            name: resolvedName,
            routingRule: routingRule,
            isEnabled: true,
            extraField1: extraField1.trimmingCharacters(in: .whitespacesAndNewlines),
            extraField2: extraField2.trimmingCharacters(in: .whitespacesAndNewlines),
            extraField3: extraField3.trimmingCharacters(in: .whitespacesAndNewlines),
            maskedSecret: ExchangeAccountProfile.maskAPIKey(finalSecret)
        )

        if let idx = channels.firstIndex(where: { $0.id == id }) {
            channels[idx] = config
        } else {
            channels.append(config)
        }
        persistChannels()
        return config
    }

    func toggleChannel(id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[idx].isEnabled.toggle()
        persistChannels()
    }

    func deleteChannel(id: UUID) {
        channels.removeAll { $0.id == id }
        KeychainStore.save("", account: keychainAccount(for: id))
        persistChannels()
    }

    func testChannel(config: NotificationChannelConfig, secret: String) async throws {
        let testPayload = AlertPayload(
            severity: .warning,
            category: "通道连通性测试",
            title: "bitcoin-bar iOS 推送通道测试成功",
            body: "来自「\(config.name)」的测试消息，后续价格、余额与强平风控告警将通过此通道送达。"
        )
        try await client.send(payload: testPayload, channel: config, secret: secret)
    }

    func clearHistory() {
        recentEvents.removeAll()
    }

    private func insertRecord(payload: AlertPayload, summary: String) {
        let record = AlertEventRecord(
            id: payload.id,
            severity: payload.severity,
            category: payload.category,
            title: payload.title,
            body: payload.body,
            timestamp: payload.timestamp,
            deliverySummary: summary
        )
        recentEvents.insert(record, at: 0)
        if recentEvents.count > 50 { recentEvents.removeLast(recentEvents.count - 50) }
    }

    private func triggerHapticAndSound(for severity: AlertSeverity) {
        let generator = UINotificationFeedbackGenerator()
        switch severity {
        case .critical:
            generator.notificationOccurred(.error)
            AudioServicesPlaySystemSound(1005)
        case .warning:
            generator.notificationOccurred(.warning)
            AudioServicesPlaySystemSound(1007)
        case .info:
            generator.notificationOccurred(.success)
            AudioServicesPlaySystemSound(1007)
        }
    }

    private func postSystemNotification(_ payload: AlertPayload) {
        let content = UNMutableNotificationContent()
        content.title = "\(payload.severity.emoji) \(payload.title)"
        content.body = payload.body
        content.sound = .default
        if payload.severity == .critical {
            content.interruptionLevel = .timeSensitive
        }

        var userInfo: [AnyHashable: Any] = [:]
        if payload.openPortfolio { userInfo["openTab"] = "portfolio" }
        if let assetID = payload.assetID { userInfo["assetID"] = assetID }
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: "alert-\(payload.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func keychainAccount(for id: UUID) -> String {
        "notify.channel.\(id.uuidString).secret"
    }

    private func persistChannels() {
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: Keys.channels)
        }
    }
}
