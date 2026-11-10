import Foundation

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Verification, catalog, balance and agent checks share one session per
// configured timeout. Only the fixed choices are cached, so sessions stay bounded.
final class VerificationSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NetworkTimeouts.defaultVerification
    private var sessions: [TimeInterval: URLSession] = [:]
    var timeout: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    var current: URLSession {
        lock.lock(); defer { lock.unlock() }
        return make(value)
    }
    // Slow calls such as image generation wait at least `minimum`, or longer when the setting is longer.
    func session(atLeast minimum: TimeInterval) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        return make(max(value, minimum))
    }
    private func make(_ value: TimeInterval) -> URLSession {
        if let session = sessions[value] { return session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = value
        config.timeoutIntervalForResource = value
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: APIClient.delegate, delegateQueue: nil)
        sessions[value] = session; return session
    }
}

enum NetworkTimeouts {
    static let defaultVerification: TimeInterval = 60
    static let verificationChoices: [TimeInterval] = [30, 60, 120, 300, 600]
    static let defaultProxy: TimeInterval = 3600
    static let proxyChoices: [TimeInterval] = [1800, 3600, 7200, 21600, 43200, 86400]
    static func title(_ value: TimeInterval) -> String {
        let seconds = Int(value)
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        return "\(seconds / 3600) 小时"
    }
}

struct APIClient {
    static let delegate = NoRedirectDelegate()
    static let verificationSessions = VerificationSessions()
    static var verificationTimeout: TimeInterval {
        get { verificationSessions.timeout }
        set { verificationSessions.timeout = newValue }
    }
    static var session: URLSession { verificationSessions.current }

    static func failureMessage(_ error: Error) -> String {
        if let error = error as? KeyDockError { return error.localizedDescription }
        let ns = error as NSError
        if error is CancellationError || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) { return "请求已取消。" }
        let reason: String
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                reason = "macOS App Transport Security 阻止了 HTTP 请求。这是应用网络配置问题，请更新 KeyDock；无需更换密钥、模型或改成 HTTPS。"
            case NSURLErrorTimedOut: reason = "请求超时（等待上限 \(NetworkTimeouts.title(verificationTimeout))），请检查服务响应与网络连接；模型响应较慢时可在系统设置中调大验证超时。"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: reason = "无法解析服务地址，请检查域名与 DNS。"
            case NSURLErrorCannotConnectToHost: reason = "无法连接服务，请检查地址、端口与网络。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: reason = "网络连接不可用或已中断。"
            default: reason = ns.localizedDescription
            }
        } else { reason = ns.localizedDescription }
        return reason + "（\(ns.domain) \(ns.code)）"
    }

    static func safeURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmed), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else {
            throw KeyDockError.message("请填写完整地址，例如 https://api.example.com/v1。")
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            throw KeyDockError.message("接口地址只支持 HTTP 或 HTTPS。")
        }
        return url
    }

    static func endpoint(base: String, suffix: String, defaultVersion: String) throws -> URL {
        let url = try safeURL(base)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.query == nil else {
            throw KeyDockError.message("Base URL 请只填基础地址；带查询参数的接口请放在自定义验证地址中。")
        }
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { path = url.host == "api.deepseek.com" ? "" : defaultVersion }
        if path != suffix && !path.hasSuffix("/" + suffix) { path += (path.isEmpty ? "" : "/") + suffix }
        parts.path = "/" + path
        guard let result = parts.url else { throw KeyDockError.message("无法生成接口地址。") }
        return result
    }

    static func authenticatedRequest(url: URL, record: Credential) throws -> URLRequest {
        guard !record.apiKey.trimmed.isEmpty || record.auth == .none else { throw KeyDockError.message("请先填写 API Key。") }
        guard record.apiKey.rangeOfCharacter(from: .controlCharacters) == nil else { throw KeyDockError.message("API Key 不能包含换行或控制字符。") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for line in record.extraHeaders.components(separatedBy: .newlines) where !line.trimmed.isEmpty {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, !pair[0].trimmed.isEmpty,
                  pair[0].trimmed.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                  pair[1].unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else { throw KeyDockError.message("附加 Header 格式应为每行 名称: 值，不能包含控制字符。") }
            guard !["host", "content-length", "transfer-encoding", "connection", "authorization", "x-api-key", "api-key", "x-goog-api-key"].contains(pair[0].trimmed.lowercased()) else {
                throw KeyDockError.message("鉴权 Header 请通过鉴权方式设置；不能覆盖 Host 等连接 Header。")
            }
            request.setValue(pair[1].trimmed, forHTTPHeaderField: pair[0].trimmed)
        }
        switch record.auth {
        case .bearer: request.setValue("Bearer " + record.apiKey, forHTTPHeaderField: "Authorization")
        case .xAPIKey: request.setValue(record.apiKey, forHTTPHeaderField: "x-api-key")
        case .apiKey: request.setValue(record.apiKey, forHTTPHeaderField: "api-key")
        case .googleKey: request.setValue(record.apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .none: break
        }
        if record.kind == .anthropic && request.value(forHTTPHeaderField: "anthropic-version") == nil {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    static func verificationRequest(for record: Credential) throws -> URLRequest {
        let record = ProviderPreset.configuration(record)
        let url: URL
        if !record.verificationURL.trimmed.isEmpty {
            url = try safeURL(record.verificationURL)
            if ProviderPreset.matching(record.baseURL)?.catalogURL == url.absoluteString {
                var catalogRecord = record; catalogRecord.auth = .bearer
                return try authenticatedRequest(url: url, record: catalogRecord)
            }
        }
        else {
            guard !requiresModelTest(record) else { throw KeyDockError.message("此服务不支持通用模型列表检查。请选择模型后点击“验证调用”，会产生少量用量；批量连接检查不会自动调用模型。") }
            if let preset = ProviderPreset.matching(record.baseURL), let catalog = preset.catalogURL {
                var catalogRecord = record; catalogRecord.auth = .bearer
                return try authenticatedRequest(url: safeURL(catalog), record: catalogRecord)
            }
            switch record.kind {
            case .compatible, .anthropic, .responses: url = try endpoint(base: record.baseURL, suffix: "models", defaultVersion: "v1")
            case .gemini: url = try endpoint(base: record.baseURL, suffix: "models", defaultVersion: "v1beta")
            case .custom: throw KeyDockError.message("请在编辑 → 高级选项中填写此服务的 GET 验证地址。")
            }
        }
        return try authenticatedRequest(url: url, record: record)
    }

    static func requiresModelTest(_ record: Credential) -> Bool {
        if record.callTemplate != nil && record.verificationURL.trimmed.isEmpty { return true }
        if record.verificationURL.trimmed.isEmpty, let preset = ProviderPreset.matching(record.baseURL) { return preset.catalogURL == nil }
        guard record.verificationURL.trimmed.isEmpty, record.kind == .compatible else { return false }
        let host = URL(string: record.baseURL)?.host?.lowercased() ?? ""
        return host == "dashscope.aliyuncs.com" || host.hasSuffix(".dashscope.aliyuncs.com") || host.hasSuffix(".maas.aliyuncs.com") || host == "api.baichuan-ai.com"
    }

    // Catalog discovery is independent of inference verification and its saved template.
    static func fetchModels(_ record: Credential, session: URLSession = APIClient.session) async -> CheckResult {
        var attempted: URLRequest?
        do {
            var record = ProviderPreset.configuration(record)
            guard record.kind != .custom else { throw KeyDockError.message("此服务没有通用模型列表。") }
            let url: URL
            if !record.verificationURL.trimmed.isEmpty {
                url = try safeURL(record.verificationURL)
                if ProviderPreset.matching(record.baseURL)?.catalogURL == url.absoluteString { record.auth = .bearer }
            } else if let preset = ProviderPreset.matching(record.baseURL), let catalog = preset.catalogURL {
                url = try safeURL(catalog); record.auth = .bearer
            } else { url = try endpoint(base: record.baseURL, suffix: "models", defaultVersion: record.kind == .gemini ? "v1beta" : "v1") }
            let request = try authenticatedRequest(url: url, record: record)
            attempted = request
            let (data, response) = try await AgentVerification.boundedData(for: request, session: session, limit: 1_048_576)
            var catalogRecord = record; catalogRecord.verificationURL = ""; catalogRecord.callTemplate = nil
            var result = classify(status: response.statusCode, data: data, record: catalogRecord, endpoint: url.absoluteString)
            result.requestMethod = "GET"
            result.request = CheckedRequest(request); result.response = CheckedResponse(data, response: response, record: record)
            if [404, 405].contains(response.statusCode), let preset = ProviderPreset.matching(record.baseURL) {
                result.message = "当前接口未提供模型目录。" + preset.catalogNote + " 可在模型下拉框中添加模型。"
                result = includingServiceError(result, data: data, record: record)
            }
            if ProviderPreset.matching(record.baseURL)?.id == "qwen", result.state == .valid,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let output = json["output"] as? [String: Any],
               let total = output["total"] as? Int, let size = output["page_size"] as? Int, size > 0 {
                var page = (output["page_no"] as? Int ?? 1) + 1
                while result.models.count < min(total, 1000), page <= 50 {
                    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    parts.queryItems = [URLQueryItem(name: "page_no", value: String(page)), URLQueryItem(name: "page_size", value: String(size))]
                    let nextRequest = try authenticatedRequest(url: parts.url!, record: record)
                    let (nextData, nextResponse) = try await AgentVerification.boundedData(for: nextRequest, session: session, limit: 1_048_576)
                    let next = classify(status: nextResponse.statusCode, data: nextData, record: catalogRecord, endpoint: url.absoluteString)
                    guard next.state == .valid, !next.models.isEmpty else { break }
                    let count = Set(result.models).count
                    result.models = Array(Set(result.models + next.models))
                    guard result.models.count > count else { break }
                    page += 1
                }
                result.message = result.models.count >= total ? "模型目录读取完成（\(result.models.count) 个），具体调用权限需验证。" : "已获取 \(result.models.count) / \(total) 个模型；目录尚未完整读取，可稍后刷新。"
            }
            result.models = Array(Set(result.models.filter { name in !name.trimmed.isEmpty && !record.secretValues.contains(where: { name.contains($0) }) })).sorted()
            return result
        } catch {
            return CheckResult(state: .uncertain, message: LogRedaction.text(failureMessage(error), secret: record.apiKey, otherSecrets: record.secretValues), endpoint: attempted?.url?.absoluteString ?? "", requestMethod: attempted?.httpMethod, request: attempted.map(CheckedRequest.init))
        }
    }

    static func modelTestRequest(for record: Credential) throws -> URLRequest {
        let record = ProviderPreset.configuration(record)
        if record.callTemplate != nil { return try AgentVerification.request(record, arguments: [:]).0 }
        if record.kind != .compatible { return try AgentVerification.request(record, arguments: [:]).0 }
        guard !record.model.trimmed.isEmpty else { throw KeyDockError.message("请先在编辑中填写默认模型，例如从该服务控制台复制模型名称或推理接入点 ID。") }
        let url = try endpoint(base: record.baseURL, suffix: "chat/completions", defaultVersion: "v1")
        var request = try authenticatedRequest(url: url, record: record)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No automatic retries or fallback generation. Let the provider apply its thinking defaults.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": record.model.trimmed, "messages": [["role": "user", "content": "Hi"]], "stream": false])
        return request
    }

    static func modelPayload(for record: Credential) throws -> (path: String, body: [String: Any]) {
        guard !record.model.trimmed.isEmpty else { throw KeyDockError.message("请先选择或填写实际调用的模型，再生成请求示例。") }
        if let template = record.callTemplate {
            guard !template.path.hasPrefix("/"), !template.path.contains("://"), !template.path.contains(".."),
                  let data = template.body.data(using: .utf8), let original = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw KeyDockError.message("保存的调用示例格式不正确，请重新验证。") }
            func replacingModel(_ value: Any) -> Any {
                if let value = value as? String, value == template.model { return record.model }
                if let value = value as? [String: Any] { return value.mapValues(replacingModel) }
                if let value = value as? [Any] { return value.map(replacingModel) }
                return value
            }
            var body = original.mapValues(replacingModel)
            if body["model"] != nil { body["model"] = record.model }
            let path = template.path.replacingOccurrences(of: "{model}", with: record.model.replacingOccurrences(of: "models/", with: ""))
            return (path, body)
        }
        switch record.kind {
        case .compatible: return ("chat/completions", ["model": record.model.trimmed, "messages": [["role": "user", "content": "你好"]], "stream": false])
        case .anthropic: return ("messages", ["model": record.model.trimmed, "max_tokens": 128, "messages": [["role": "user", "content": "你好"]]])
        case .responses: return ("responses", ["model": record.model.trimmed, "input": "你好", "stream": false])
        case .gemini:
            let model = record.model.trimmed.replacingOccurrences(of: "models/", with: "")
            guard model.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { throw KeyDockError.message("请填写合法的 Gemini 模型名称。") }
            return ("models/" + model + ":generateContent", ["contents": [["parts": [["text": "你好"]]]]])
        case .custom: throw KeyDockError.message("此服务请按接口文档填写具体调用路径和参数。")
        }
    }
    static func modelRequest(for record: Credential) throws -> URLRequest {
        let record = ProviderPreset.configuration(record)
        let payload = try modelPayload(for: record)
        let url = try endpoint(base: record.baseURL, suffix: payload.path, defaultVersion: record.kind == .gemini ? "v1beta" : "v1")
        var request = try authenticatedRequest(url: url, record: record)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: inferenceBody(payload.body, path: payload.path, record: record), options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }
    static func requiresOutputLimit(_ record: Credential, path: String) -> Bool {
        let messages = record.inferenceKind == .anthropic || path.split(separator: "/").last == "messages"
        return messages && !["deepseek", "volcengine"].contains(ProviderPreset.matching(record.baseURL)?.id ?? "")
    }
    // One policy for app-built requests, copied examples and legacy templates.
    // Observed request snapshots and caller-supplied proxy traffic stay unchanged.
    static func inferenceBody(_ body: [String: Any], path: String, record: Credential) -> [String: Any] {
        var body = body
        if requiresOutputLimit(record, path: path) { body["max_tokens"] = body["max_tokens"] ?? 128 }
        else { body.removeValue(forKey: "max_tokens") }
        body.removeValue(forKey: "max_completion_tokens"); body.removeValue(forKey: "max_output_tokens")
        if var configuration = body["generationConfig"] as? [String: Any] {
            configuration.removeValue(forKey: "maxOutputTokens")
            if configuration.isEmpty { body.removeValue(forKey: "generationConfig") } else { body["generationConfig"] = configuration }
        }
        return body
    }

    static func verify(_ record: Credential, session: URLSession = APIClient.session, testModel: Bool = false) async -> CheckResult {
        var attempted: URLRequest?
        let clock = ContinuousClock(), started = clock.now
        do {
            let request = try testModel ? modelTestRequest(for: record) : verificationRequest(for: record)
            attempted = request
            let (data, http) = try await AgentVerification.boundedData(for: request, session: session, limit: 1_048_576)
            let elapsed = Latency.seconds(clock.now - started)
            var result = classify(status: http.statusCode, data: data, record: record, endpoint: request.url!.absoluteString, testModel: testModel)
            result.response = CheckedResponse(data, response: http, record: record)
            result.requestMethod = request.httpMethod; result.request = CheckedRequest(request); result.duration = elapsed; return result
        } catch {
            let message = LogRedaction.text(failureMessage(error), secret: record.apiKey, otherSecrets: record.secretValues)
            var result = CheckResult(state: .uncertain, message: message, endpoint: attempted?.url?.absoluteString ?? "", requestMethod: attempted?.httpMethod, request: attempted.map(CheckedRequest.init))
            if attempted != nil { result.duration = Latency.seconds(clock.now - started) }
            return result
        }
    }

    static func classify(status: Int, data: Data, record: Credential, endpoint: String = "", testModel: Bool = false) -> CheckResult {
        var result = CheckResult(state: .uncertain, message: "", httpStatus: status, endpoint: endpoint, response: CheckedResponse(data, record: record))
        switch status {
        case 200..<300:
            if testModel, record.callTemplate != nil || record.kind != .compatible, let url = URL(string: endpoint.isEmpty ? record.baseURL : endpoint), let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) {
                return AgentVerification.classify(data, response: response, record: record, method: "POST", endpoint: endpoint)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !hasAPIError(json) else {
                result.message = "接口返回成功状态，但内容不是预期 JSON 或包含错误，请检查验证地址。"; return includingServiceError(result, data: data, record: record)
            }
            if testModel {
                guard let choices = json["choices"] as? [[String: Any]], let first = choices.first, first["message"] is [String: Any] else {
                    result.message = "接口未返回预期的模型响应，请核对模型名称与协议。"; return includingServiceError(result, data: data, record: record)
                }
                result.message = "当前模型调用验证通过，已产生少量用量。"
            } else if (record.verificationURL.isEmpty || record.verificationURL == ProviderPreset.matching(record.baseURL)?.catalogURL) && record.kind != .custom {
                let field = record.kind == .gemini ? "models" : "data"
                let qwenCatalog = ProviderPreset.matching(record.baseURL)?.id == "qwen" ? (json["output"] as? [String: Any])?["models"] as? [[String: Any]] : nil
                guard let models = qwenCatalog ?? json[field] as? [[String: Any]] else {
                    result.message = "返回内容中没有模型列表，请核对服务类型或设置自定义验证地址。"; return includingServiceError(result, data: data, record: record)
                }
                result.models = models.compactMap { ($0["model"] ?? $0["id"] ?? $0["name"]) as? String }
                result.message = "模型列表查询成功（本页 \(result.models.count) 个）。具体模型的调用权限及可用额度需另行确认。"
            } else { result.message = "自定义 GET 接口返回 JSON 且未包含 error 字段。业务可用性请结合该服务文档判断。" }
            result.state = .valid
        case 401:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = json?["error"] as? [String: Any] ?? json ?? [:]
            let codes = [detail["code"], detail["type"]].compactMap { $0 as? String }.map { $0.lowercased() }
            let known = Set(["invalid_api_key", "invalidapikey", "authenticationerror", "authentication_error", "invalid_authentication", "unauthorized", "unauthenticated", "invalid_token", "token_expired"])
            if (!requiresModelTest(record) || testModel), !known.isDisjoint(with: codes) {
                result.state = .invalid; result.message = "HTTP 401：服务明确返回鉴权错误。请检查密钥、鉴权方式、地域和接入地址后重试。"
            } else {
                result.message = "HTTP 401：此检查接口未通过，可能是中转登录、接口不支持、地址或鉴权配置问题，暂不判定 Key 失效。可核对配置后验证模型调用。"
            }
        case 403:
            result.state = .restricted; result.message = "HTTP 403：权限、地区或访问策略受限，不能据此认定密钥过期。"
        case 402, 429:
            result.state = .quota; result.message = "HTTP \(status)：可能余额不足、额度耗尽或触发限流，不能据此认定密钥失效。"
        case 300..<400:
            result.message = "接口要求重定向。为避免密钥被转发，请手动填写最终接口地址。"
        case 404, 405:
            result.message = testModel ? "HTTP \(status)：模型 ID、调用协议或请求路径未匹配，请核对当前模型和接口文档。" : "HTTP \(status)：此地址可能不支持模型列表 / GET 查询。请设置自定义验证地址。"
        default:
            result.message = "HTTP \(status)：服务异常或请求不匹配，请稍后重试并核对文档。"
        }
        return includingServiceError(result, data: data, record: record)
    }

    static func includingServiceError(_ original: CheckResult, data: Data, record: Credential) -> CheckResult {
        guard original.state != .valid, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return original }
        let fields = json["error"] as? [String: Any] ?? json
        let detail = ["message", "error_msg", "error_description", "msg"].compactMap { fields[$0] as? String }.first ?? json["error"] as? String ?? ""
        let message = String(detail.trimmed.prefix(500))
        guard !message.isEmpty, !original.message.contains(message) else { return original }
        var result = original; result.message += "\n服务返回：" + message; return result
    }

    static func balanceRequest(for record: Credential) throws -> URLRequest {
        var record = record
        if let preset = ProviderPreset.matching(record.baseURL), record.balanceURL.isEmpty || record.balanceURL == preset.balanceURL { record.auth = .bearer }
        let url: URL
        if !record.balanceURL.trimmed.isEmpty { url = try safeURL(record.balanceURL) }
        else if let preset = ProviderPreset.matching(record.baseURL) {
            guard let address = preset.balanceURL else { throw KeyDockError.message(preset.balanceNote) }
            url = try safeURL(address); record.auth = .bearer
        }
        else if URL(string: record.baseURL)?.host == "api.deepseek.com" {
            url = URL(string: "https://api.deepseek.com/user/balance")!
        } else { throw KeyDockError.message("此服务尚未配置余额接口。可在高级选项中填写 GET 查询地址和 JSON 字段路径。") }
        return try authenticatedRequest(url: url, record: record)
    }

    static func balance(_ record: Credential, session: URLSession = APIClient.session) async throws -> String {
        let request = try balanceRequest(for: record)
        let (data, http) = try await AgentVerification.boundedData(for: request, session: session, limit: 1_048_576)
        guard (200..<300).contains(http.statusCode) else {
            let result = includingServiceError(CheckResult(state: .uncertain, message: "余额查询未完成（HTTP \(http.statusCode)），请核对接口权限与配置。"), data: data, record: record)
            throw KeyDockError.message(result.message)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !hasAPIError(json) else {
            throw KeyDockError.message(includingServiceError(CheckResult(state: .uncertain, message: "余额接口返回格式不正确。"), data: data, record: record).message)
        }
        if record.balanceURL.isEmpty || record.balanceURL == ProviderPreset.matching(record.baseURL)?.balanceURL, let infos = json["balance_infos"] as? [[String: Any]] {
            let values = infos.compactMap { info -> String? in
                guard let value = info["total_balance"] as? String, let currency = info["currency"] as? String else { return nil }
                return "\(currency) \(value)"
            }
            guard !values.isEmpty else { throw KeyDockError.message("未找到余额数据。") }
            return values.joined(separator: " · ")
        }
        let preset = ProviderPreset.matching(record.baseURL)
        let path = record.balancePath.trimmed.isEmpty ? (preset?.balancePath ?? "") : record.balancePath
        guard !path.isEmpty else { throw KeyDockError.message("请填写余额 JSON 字段路径，例如 data.balance 或 balance_infos.0.total_balance。") }
        var current: Any = json
        for component in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any], let value = dict[component] { current = value }
            else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) { current = array[index] }
            else { throw KeyDockError.message("返回 JSON 中找不到配置的余额字段。") }
        }
        guard (current is String || current is NSNumber), CFGetTypeID(current as CFTypeRef) != CFBooleanGetTypeID() else { throw KeyDockError.message("余额字段必须是数字或字符串。") }
        return "\(current) \(record.balanceUnit.isEmpty ? (preset?.balanceUnit ?? "") : record.balanceUnit)".trimmed
    }
    static func hasAPIError(_ json: [String: Any]) -> Bool {
        guard let error = json["error"], !(error is NSNull) else { return false }
        if let boolean = error as? Bool, !boolean { return false }
        return true
    }
}
