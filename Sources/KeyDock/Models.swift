import Foundation

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case compatible, anthropic, responses, gemini, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compatible: return "兼容 Chat Completions"
        case .anthropic: return "Anthropic / Claude"
        case .responses: return "兼容 Responses"
        case .gemini: return "Google Gemini"
        case .custom: return "其他第三方服务"
        }
    }
    var symbol: String { self == .custom ? "square.stack.3d.up" : "sparkles" }
    var protocolTitle: String {
        switch self {
        case .compatible: return "/v1/chat/completions"
        case .anthropic: return "/v1/messages"
        case .responses: return "/v1/responses"
        case .gemini: return "Gemini 原生"
        case .custom: return "自定义接口"
        }
    }
}

enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case bearer, xAPIKey, apiKey, googleKey, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bearer: return "Authorization: Bearer"
        case .xAPIKey: return "x-api-key"
        case .apiKey: return "api-key（如 Azure）"
        case .googleKey: return "x-goog-api-key"
        case .none: return "不附加鉴权"
        }
    }
}

enum CheckState: String, Codable {
    case unchecked, valid, invalid, restricted, quota, uncertain
    var title: String {
        switch self {
        case .unchecked: return "待验证"
        case .valid: return "验证通过"
        case .invalid: return "鉴权失败"
        case .restricted: return "权限受限"
        case .quota: return "额度 / 限流"
        case .uncertain: return "需要检查"
        }
    }
}

struct CheckedRequest: Codable, Equatable {
    var method: String
    var address: String
    var headers: [String: String]
    var body: String?
    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"; address = request.url?.absoluteString ?? ""
        headers = request.allHTTPHeaderFields ?? [:]
        body = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
    }
    var curl: String { curl(redacting: nil) }
    func curl(redacting secrets: [String]?) -> String {
        func safe(_ text: String) -> String { secrets.map { LogRedaction.text(text, secret: "", otherSecrets: $0) } ?? text }
        var value = "curl --request " + method + " " + Credential.shellQuote(safe(address))
        for (name, raw) in headers.sorted(by: { $0.key < $1.key }) {
            let header = secrets != nil && LogRedaction.isSensitiveHeader(name) ? "[已隐藏]" : safe(raw)
            value += " \\\n  --header " + Credential.shellQuote(name + ": " + header)
        }
        if let body { value += " \\\n  --data " + Credential.shellQuote(safe(body)) }
        return value
    }
}

struct CheckedResponse: Codable, Equatable {
    var headers: String
    var body: String
    var truncated: Bool
    init(_ data: Data, response: HTTPURLResponse? = nil, record: Credential) {
        let fields = Dictionary((response?.allHeaderFields ?? [:]).map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { first, _ in first })
        headers = RecordedContent.headers(fields)
        body = RecordedContent.body(data)
        truncated = data.count > RecordedContent.bodyLimit
    }
    var text: String { (headers.isEmpty ? "" : headers + "\n\n") + (body.isEmpty ? "（空正文）" : body) }
}

struct CheckResult: Codable, Equatable {
    var state: CheckState
    var message: String
    var checkedAt: Date = Date()
    var httpStatus: Int?
    var models: [String] = []
    var endpoint: String = ""
    var requestMethod: String?
    var request: CheckedRequest?
    var response: CheckedResponse?
    var displayMessage: String {
        state == .valid && requestMethod == "POST" && message == "当前模型调用验证通过，已产生少量用量。" ? "当前模型调用验证通过。" : message
    }
    var actionTitle: String {
        switch requestMethod?.uppercased() {
        case "POST": return "调用验证"
        case "GET": return "连接检查"
        default: return "检查"
        }
    }
}

struct ModelCallTemplate: Codable, Equatable {
    var path: String
    var body: String
    var model: String? = nil
}

struct ModelCatalog: Codable, Equatable {
    var models: [String]
    var fetchedAt = Date()
    var source: String? = nil
}

struct CredentialSearchMatch {
    var rank: Int
    var detail: String? = nil
}

struct Credential: Identifiable, Codable, Equatable {
    static let reservedVariablePrefixes = Set(["HOME", "PATH", "USER", "SHELL", "TMPDIR", "CODEX_HOME"])
    var id = UUID()
    var name = ""
    var provider = ""
    var variablePrefix = ""
    var kind: ServiceKind = .compatible
    var baseURL = ""
    var apiKey = ""
    var auth: AuthKind = .bearer
    var model = ""
    var callTemplate: ModelCallTemplate?
    var modelCatalog: ModelCatalog?
    var manualModels: [String]?
    var modelProtocols: [String: ServiceKind]?
    var docsURL = ""
    var purpose = ""
    var notes = ""
    var tags = ""
    var curl = ""
    var source = ""
    var verificationURL = ""
    var balanceURL = ""
    var balancePath = ""
    var balanceUnit = ""
    var balanceSummary = ""
    var balanceCheckedAt: Date?
    var extraHeaders = ""
    var expiresAt: Date?
    var favorite = false
    var archived = false
    var createdAt = Date()
    var updatedAt = Date()
    var check: CheckResult?
    var connectionCheck: CheckResult?

    var title: String { name.isEmpty ? (provider.isEmpty ? "未命名服务" : provider) : name }
    var inferenceKind: ServiceKind {
        switch callTemplate?.path {
        case "chat/completions": return .compatible
        case "messages": return .anthropic
        case "responses": return .responses
        case "models/{model}:generateContent": return .gemini
        default: return kind
        }
    }
    var availableModels: [String] { modelCatalog?.models ?? check?.models ?? [] }
    var modelOptions: [String] { Self.modelChoices(current: model, available: (manualModels ?? []) + availableModels) }
    mutating func rememberModel(_ value: String) {
        let name = value.trimmed
        guard modelIssue(name) == nil, name.rangeOfCharacter(from: .controlCharacters) == nil else { return }
        manualModels = Self.modelChoices(current: "", available: (manualModels ?? []) + [name])
    }
    mutating func preserveManualModels(from previous: Credential) {
        let sameProviderKey = ProviderPreset.matching(baseURL) != nil && fingerprint == previous.fingerprint
        guard (baseURL == previous.baseURL || sameProviderKey), apiKey == previous.apiKey, extraHeaders == previous.extraHeaders else { manualModels = nil; return }
        let editedList = manualModels != nil && manualModels != previous.manualModels
        manualModels = manualModels ?? previous.manualModels
        if model != previous.model && !editedList {
            if !previous.availableModels.contains(previous.model) { rememberModel(previous.model) }
            if !previous.availableModels.contains(model) { rememberModel(model) }
        }
    }
    static func modelChoices(current: String, available: [String]) -> [String] {
        var seen = Set<String>()
        return ([current] + available).map(\.trimmed).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    var host: String { URL(string: baseURL)?.host ?? "尚未填写地址" }
    var maskedKey: String {
        guard !apiKey.isEmpty else { return "未填写密钥" }
        return apiKey.count > 12 ? String(apiKey.prefix(5)) + "••••••••" + String(apiKey.suffix(4)) : String(repeating: "•", count: 12)
    }
    var expired: Bool { expiresAt.map { $0 < Date() } ?? false }
    var cleanupCandidate: Bool { !archived && (expired || check?.state == .invalid) }
    var stateTitle: String {
        if archived { return "已归档" }
        if expired { return "已到期" }
        if let check, check.state == .valid {
            if check.requestMethod == "POST" { return "调用通过" }
            if check.requestMethod == "GET" { return "连接正常" }
        }
        return check?.state.title ?? "待验证"
    }
    var connectionIssue: String? {
        if baseURL.trimmed.isEmpty { return "请先补充 Base URL。" }
        if apiKey.trimmed.isEmpty && auth != .none { return "请先补充 API Key。" }
        do {
            let url = try APIClient.safeURL(baseURL)
            guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil else { return "Base URL 请只填基础地址。" }
            _ = try APIClient.authenticatedRequest(url: url, record: self)
        } catch { return error.localizedDescription }
        return nil
    }
    var usageIssue: String? {
        if archived { return "此 Key 已归档，恢复后可继续使用。" }
        if expired { return "此 Key 已到期，请编辑到期时间或更换密钥。" }
        if let issue = connectionIssue { return issue }
        if kind != .custom {
            if let issue = modelIssue(model) { return issue }
            do { _ = try APIClient.modelRequest(for: self) } catch { return error.localizedDescription }
        }
        return nil
    }
    var canCopyUsage: Bool { usageIssue == nil }
    var verificationActionTitle: String {
        kind == .custom ? "检查连接" : "验证调用"
    }
    func modelIssue(_ value: String) -> String? {
        if value.trimmed.isEmpty { return "请选择或填写调用模型。" }
        if secretValues.contains(where: { value == $0 || ($0.count >= 8 && value.contains($0)) }) { return "模型名称中包含鉴权信息，请填写实际的模型 ID。" }
        return nil
    }
    var canOrganize: Bool { kind != .custom && !archived && !expired && connectionIssue == nil }
    var safeModel: String { safeMetadata(model) }
    mutating func rememberProtocol() {
        let name = model.trimmed, protocolKind = inferenceKind
        guard !name.isEmpty, protocolKind != .custom else { return }
        if modelProtocols == nil { modelProtocols = [:] }
        modelProtocols?[name] = protocolKind
    }
    func selectingProtocol(_ kind: ServiceKind) -> Credential {
        var value = self
        value.rememberProtocol()
        value = value.configuringProtocol(kind)
        value.rememberProtocol()
        return value
    }
    private func configuringProtocol(_ kind: ServiceKind) -> Credential {
        var value = self
        if kind != inferenceKind {
            value.kind = kind; value.callTemplate = nil
            if let preset = ProviderPreset.matching(baseURL), preset.protocols.contains(kind) {
                value.baseURL = preset.connectionBase(kind); value.auth = preset.authentication(kind)
            } else {
                switch kind { case .anthropic: value.auth = .xAPIKey; case .gemini: value.auth = .googleKey; default: value.auth = .bearer }
            }
        }
        return value
    }
    func selectingModel(_ name: String) -> Credential {
        guard name.trimmed != model.trimmed else { var value = self; value.rememberProtocol(); return value }
        var value = self
        value.rememberProtocol()
        let remembered = value.modelProtocols?[name.trimmed] ?? .compatible
        value.model = name.trimmed
        value = value.configuringProtocol(remembered == .custom ? .compatible : remembered)
        value.rememberProtocol()
        return value
    }
    var secretValues: [String] {
        var values = apiKey.isEmpty ? [] : [apiKey]
        for line in extraHeaders.components(separatedBy: .newlines) {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, LogRedaction.isSensitiveHeader(pair[0].trimmed) else { continue }
            let value = pair[1].trimmed
            let name = pair[0].trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
            // Short lookup IDs are not standalone credentials. Mask their header
            // fields, but do not corrupt unrelated model IDs or loopback URLs.
            if (name.hasSuffix("-id") || ["tokenid", "keyid"].contains(name)) && value.count < 8 { continue }
            if !value.isEmpty { values.append(value) }
            let authorization = value.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if authorization.count == 2, ["bearer", "basic"].contains(authorization[0].lowercased()) { values.append(String(authorization[1]).trimmed) }
            if pair[0].trimmed.lowercased() == "cookie" {
                for part in value.split(separator: ";") {
                    let cookie = part.split(separator: "=", maxSplits: 1)
                    guard cookie.count == 2 else { continue }
                    let name = String(cookie[0]).trimmed.lowercased()
                    if LogRedaction.isSensitiveHeader(name) || name.contains("sess") || name.hasSuffix("sid") || ["skey", "jwt", "cf_clearance"].contains(name) { values.append(String(cookie[1]).trimmed) }
                }
            }
        }
        return Set(values.filter { !$0.isEmpty }).sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    }
    func hasSameConnection(as other: Credential) -> Bool {
        id == other.id && baseURL == other.baseURL && apiKey == other.apiKey && kind == other.kind && auth == other.auth && extraHeaders == other.extraHeaders
    }
    func hasSameModelCatalogConfiguration(as other: Credential) -> Bool {
        hasSameConnection(as: other) && verificationURL == other.verificationURL && inferenceKind == other.inferenceKind
    }
    func hasSameVerificationConfiguration(as other: Credential) -> Bool {
        hasSameConnection(as: other) && model == other.model && verificationURL == other.verificationURL && callTemplate == other.callTemplate
    }
    func hasSameBalanceConfiguration(as other: Credential) -> Bool {
        hasSameConnection(as: other) && balanceURL == other.balanceURL && balancePath == other.balancePath && balanceUnit == other.balanceUnit
    }
    var searchText: String { ([name, provider, baseURL, purpose, notes, tags] + modelOptions).joined(separator: " ") }
    func searchMatch(for text: String) -> CredentialSearchMatch? {
        let query = text.trimmed
        guard !query.isEmpty else { return CredentialSearchMatch(rank: 0) }
        for (value, baseRank) in [(name, 0), (provider, 3)] where value.localizedCaseInsensitiveContains(query) {
            if value.localizedCaseInsensitiveCompare(query) == .orderedSame { return CredentialSearchMatch(rank: baseRank) }
            return CredentialSearchMatch(rank: baseRank + (value.range(of: query, options: [.anchored, .caseInsensitive]) != nil ? 1 : 2))
        }
        if let matched = modelOptions.first(where: { $0.localizedCaseInsensitiveContains(query) }) {
            return CredentialSearchMatch(rank: 6, detail: "模型：" + matched)
        }
        for (value, rank, label) in [(purpose, 7, "用途"), (tags, 8, "标签"), (baseURL, 9, "地址")] where value.localizedCaseInsensitiveContains(query) {
            return CredentialSearchMatch(rank: rank, detail: label + "：" + value)
        }
        if notes.localizedCaseInsensitiveContains(query) { return CredentialSearchMatch(rank: 10, detail: "备注匹配") }
        return nil
    }
    var fingerprint: String {
        var url = baseURL.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if var parts = URLComponents(string: url), let scheme = parts.scheme, let host = parts.host {
            parts.scheme = scheme.lowercased(); parts.host = host.lowercased()
            if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
            url = parts.string ?? url
        }
        let key = apiKey.trimmed
        let preset = kind == .custom ? nil : ProviderPreset.matching(baseURL)
        var headers: [String: String] = [:]
        for line in extraHeaders.components(separatedBy: .newlines) where !line.trimmed.isEmpty {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                let name = pair[0].trimmed.lowercased()
                if preset != nil && ["anthropic-version", "content-type", "accept"].contains(name) { continue }
                headers[name] = pair[1].trimmed
            }
        }
        if let preset { url = "https://" + (URL(string: preset.baseURL)?.host ?? "") + "/keydock-provider/" + preset.id }
        let configuration = (preset == nil ? [kind.rawValue, auth.rawValue] : ["provider-key"]) + headers.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        return ([url, key] + configuration).map { "\($0.utf8.count):\($0)" }.joined()
    }
    var routeID: String { id.uuidString.lowercased() }
    var localBaseURL: String { "http://127.0.0.1:47831/s/" + routeID }
    var localKey: String { "keydock-local-" + routeID }
    var suggestedPrefix: String {
        let safeProvider = secretValues.reduce(provider) { $0.replacingOccurrences(of: $1, with: "SERVICE", options: .caseInsensitive) }
        let stem = safeProvider.uppercased().replacingOccurrences(of: "[^A-Z0-9]", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((stem.isEmpty || stem.first?.isNumber == true ? "SERVICE" : stem).prefix(40)) + "_" + String(id.uuidString.prefix(6))
    }
    var envPrefix: String {
        if variablePrefix.range(of: #"^[A-Z][A-Z0-9_]{1,55}$"#, options: .regularExpression) == nil || Self.reservedVariablePrefixes.contains(variablePrefix) || secretValues.contains(where: { variablePrefix.range(of: $0, options: .caseInsensitive) != nil }) { return suggestedPrefix }
        return variablePrefix
    }
    var environmentText: String {
        environmentText(base: localBaseURL, key: localKey)
    }
    private func environmentText(base: String, key: String) -> String {
        var value = "export \(envPrefix)_BASE_URL=" + Self.shellQuote(base) + "\nexport \(envPrefix)_API_KEY=" + Self.shellQuote(key)
        if !model.isEmpty { value += "\nexport \(envPrefix)_MODEL=" + Self.shellQuote(safeMetadata(model)) }
        return value
    }
    var localCurl: String {
        var record = self; record.model = safeMetadata(self.model)
        let payload: (path: String, body: [String: Any])
        do { payload = try APIClient.modelPayload(for: record) } catch { return "# " + error.localizedDescription }
        // Fallbacks make a separately copied curl runnable while still honoring
        // project environment variables. Quote the path as data, never shell code.
        var path = URLComponents(); path.path = "/" + payload.path
        let target = "\"${\(envPrefix)_BASE_URL:-\(localBaseURL)}\"" + Self.shellQuote(path.percentEncodedPath)
        let auth = "  --header \"Authorization: Bearer ${\(envPrefix)_API_KEY:-\(localKey)}\""
        let json = String(data: (try? JSONSerialization.data(withJSONObject: APIClient.inferenceBody(payload.body, path: payload.path, record: record), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), encoding: .utf8) ?? "{}"
        return "curl --request POST " + target + " \\\n" + auth + " \\\n  --header 'Content-Type: application/json' \\\n  --data " + Self.shellQuote(json)
    }
    var safeShareText: String {
        let content = "# KeyDock · \(title.replacingOccurrences(of: "\n", with: " "))\n# 仅在运行 KeyDock 的这台 Mac 上生效，不含真实 API Key。\n\n" + environmentText + (kind == .custom ? "\n\n# 按服务文档，在本机地址后添加所需接口路径。鉴权由 KeyDock 注入。" : "\n\n" + localCurl)
        return safeMetadata(content)
    }
    var realUsageText: String {
        var content = "# KeyDock · \(title.replacingOccurrences(of: "\n", with: " "))\n# 包含真实凭据。接口调用可能产生正常用量。\n# 直接请求服务，不经过 KeyDock，也不计入本机调用记录。\n\n" + environmentText(base: baseURL.trimmed, key: apiKey)
        if kind == .custom {
            content += "\n\n# 按服务文档添加具体接口路径和请求参数。"
            if let url = try? APIClient.safeURL(baseURL), let request = try? APIClient.authenticatedRequest(url: url, record: self) {
                for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
                    content += "\n# \(name): \(value)"
                }
            }
        } else { content += "\n\n" + realModelCurl }
        return content
    }
    private func safeMetadata(_ text: String) -> String {
        let secrets = Set(ImportParser.keys(in: text).filter { $0 != localKey } + secretValues)
        return text.replacingSecrets(Dictionary(uniqueKeysWithValues: secrets.map { ($0, "[已隐藏]") }))
    }
    var shareText: String {
        CredentialTransfer.text(self)
    }
    var generatedCurl: String {
        var request: URLRequest
        do { request = try APIClient.requiresModelTest(self) ? APIClient.modelTestRequest(for: self) : APIClient.verificationRequest(for: self) }
        catch { return "# " + error.localizedDescription }
        if let data = request.httpBody, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            request.httpBody = try? JSONSerialization.data(withJSONObject: APIClient.inferenceBody(body, path: request.url?.path ?? "", record: self), options: [.sortedKeys, .withoutEscapingSlashes])
        }
        return (request.httpMethod == "POST" ? "# 模型调用示例，会产生正常用量。\n" : "") + CheckedRequest(request).curl
    }
    var realModelCurl: String {
        do {
            return CheckedRequest(try APIClient.modelRequest(for: self)).curl
        } catch { return "# " + error.localizedDescription }
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func shellQuote(_ text: String) -> String { Self.shellQuote(text) }
}

struct VaultData: Codable {
    var version = 1
    var credentials: [Credential] = []
    var organizerServiceID: UUID?
    var organizerModel: String?
    var prefersLocalImport: Bool?
    var showFullContent: Bool?
    var recordAllBodies: Bool?
}

enum KeyDockError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func matches(_ pattern: String, group: Int = 0) -> [String] {
        guard let re = RegexCache.expression(pattern) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard group < $0.numberOfRanges, $0.range(at: group).location != NSNotFound else { return nil }
            return ns.substring(with: $0.range(at: group))
        }
    }
    func replacingSecrets(_ replacements: [String: String]) -> String {
        let keys = replacements.keys.filter { !$0.isEmpty }.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        guard !keys.isEmpty, let expression = try? NSRegularExpression(pattern: keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")) else { return self }
        let original = self as NSString
        let matches = expression.matches(in: self, range: NSRange(location: 0, length: original.length))
        let result = NSMutableString(string: self)
        for match in matches.reversed() {
            if let replacement = replacements[original.substring(with: match.range)] { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}

enum RegexCache {
    static let cache: NSCache<NSString, NSRegularExpression> = { let cache = NSCache<NSString, NSRegularExpression>(); cache.countLimit = 96; return cache }()
    static func expression(_ pattern: String) -> NSRegularExpression? {
        if let cached = cache.object(forKey: pattern as NSString) { return cached }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache.setObject(expression, forKey: pattern as NSString); return expression
    }
}
