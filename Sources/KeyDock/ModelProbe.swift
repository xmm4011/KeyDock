import Foundation

// One lightweight result per model in a Key's list: enough to rank latency and
// to recognise a model the service no longer serves, without storing bodies.
// The current model keeps its full evidence in `Credential.check`.
struct ModelProbe: Codable, Equatable {
    var state: CheckState
    var message: String
    var checkedAt: Date
    var duration: TimeInterval?
    var httpStatus: Int?
    var protocolKind: ServiceKind
    var endpoint: String
    // The service said this model does not exist, was retired or has no route.
    var unavailable: Bool

    init(_ result: CheckResult, model: String, protocolKind: ServiceKind) {
        state = result.state
        message = String(result.displayMessage.prefix(600))
        checkedAt = result.checkedAt
        duration = result.duration
        httpStatus = result.httpStatus
        self.protocolKind = protocolKind
        endpoint = result.endpoint
        unavailable = result.state != .valid && Self.reportsMissingModel(result, model: model)
    }

    var passed: Bool { state == .valid }
    // Derived from the saved message, so results stored by earlier builds work too.
    var timedOut: Bool { httpStatus == nil && message.contains("NSURLErrorDomain \(NSURLErrorTimedOut)") }
    // A failed call that may be offered for cleanup. Quota and rate limits pass.
    var cleanable: Bool { !passed && state != .quota }
    var title: String {
        if unavailable { return "已下线" }
        if timedOut { return "超时" }
        switch state {
        case .valid: return "通过"
        case .uncertain: return "未通过"
        default: return state.title
        }
    }
    // One short line: the HTTP status and what the service said, or the local failure.
    var reason: String {
        guard !passed else { return "" }
        if timedOut { return "请求超时，服务在验证超时时间内没有返回完整响应" }
        let lines = message.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }
        let status = httpStatus.map { "HTTP \($0)" }
        if let service = lines.first(where: { $0.hasPrefix("服务返回：") }) {
            return ([status] + [service]).compactMap { $0 }.joined(separator: " · ")
        }
        guard var first = lines.first else { return status ?? "调用未通过" }
        if let status, first.hasPrefix(status) { first = String(first.dropFirst(status.count)).trimmingCharacters(in: CharacterSet(charactersIn: "：: ")) }
        return ([status] + [first.isEmpty ? nil : first]).compactMap { $0 }.joined(separator: " · ")
    }
    // Restores the last call result after switching to this model. The probe
    // keeps no request / response, so the detail rebuilds or omits them.
    var check: CheckResult {
        CheckResult(state: state, message: message, checkedAt: checkedAt, httpStatus: httpStatus, endpoint: endpoint, requestMethod: "POST", duration: duration)
    }

    private static let missingPhrases = [
        "model_not_found", "model not found", "modelnotfound", "model_not_exist", "model not exist", "model does not exist", "model_does_not_exist",
        "unknown model", "invalid model", "invalid_model", "model_decommissioned", "has been decommissioned", "model has been deprecated", "model is deprecated",
        "model is no longer", "model_not_supported", "model not supported", "model is not supported", "unsupported model", "not supported model",
        "model_not_available", "model not available", "model is not available", "no available channel", "no endpoints found", "invalidendpointormodel",
        "模型不存在", "不存在该模型", "该模型不存在", "模型已下线", "模型已停用", "模型已停止服务", "无可用渠道", "不支持该模型", "不支持的模型", "模型不可用", "模型未找到", "找不到模型", "未找到模型"
    ]
    // Only an explicit statement about the model counts. Authentication, quota,
    // permission, network and protocol-path failures never mark a model offline.
    static func reportsMissingModel(_ result: CheckResult, model: String) -> Bool {
        guard let status = result.httpStatus, ![401, 402, 403, 429].contains(status), let body = result.response?.body, !body.isEmpty else { return false }
        let text = body.lowercased()
        if missingPhrases.contains(where: text.contains) { return true }
        if text.contains("model"), text.contains("does not exist") || text.contains("no longer available") { return true }
        let name = model.trimmed.lowercased()
        return [404, 410].contains(status) && name.count >= 3 && text.contains(name)
    }
}

enum Latency {
    static func text(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(max(1, Int((seconds * 1000).rounded()))) ms" }
        if seconds < 10 { return String(format: "%.2f s", seconds) }
        if seconds < 100 { return String(format: "%.1f s", seconds) }
        return "\(Int(seconds.rounded())) s"
    }
    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension Credential {
    // Another model is called exactly as selecting it would: its remembered
    // protocol, otherwise Chat Completions. The Key's current protocol never
    // spreads to other models.
    func probing(_ name: String) -> Credential {
        name.trimmed == model.trimmed ? self : selectingModel(name)
    }
    // Fastest conversation model; embedding and image calls are not comparable.
    func fastestProbe(in models: [String]) -> (model: String, probe: ModelProbe)? {
        guard let probes = modelProbes, !probes.isEmpty else { return nil }
        let listed = Set(models)
        return probes.compactMap { name, probe -> (String, ModelProbe, TimeInterval)? in
            guard probe.passed, listed.contains(name), ModelEndpoint.of(name) == .chat, let duration = probe.duration else { return nil }
            return (name, probe, duration)
        }.min { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }
    // At least one model answered on this Key, so another model's explicit
    // "not found" reflects that model rather than the Key, address or protocol.
    var servesSomeModel: Bool {
        (check?.state == .valid && check?.requestMethod == "POST") || modelProbes?.values.contains(where: \.passed) == true
    }
    // Removes models from every list source. The selected model always stays.
    mutating func removeModels(_ names: Set<String>) {
        let targets = names.subtracting([model.trimmed])
        guard !targets.isEmpty else { return }
        if let manual = manualModels {
            let kept = manual.filter { !targets.contains($0.trimmed) }
            manualModels = kept.isEmpty ? nil : kept
        }
        if var catalog = modelCatalog { catalog.models.removeAll { targets.contains($0.trimmed) }; modelCatalog = catalog }
        else if let listed = check?.models, !listed.isEmpty { modelCatalog = ModelCatalog(models: listed.filter { !targets.contains($0.trimmed) }) }
        for name in targets { modelProtocols?[name] = nil; modelProbes?[name] = nil }
        if modelProtocols?.isEmpty == true { modelProtocols = nil }
        if modelProbes?.isEmpty == true { modelProbes = nil }
    }
    // After switching model or protocol, show that model's last probe when no
    // fuller verification was kept for it.
    mutating func adoptProbedCheck() {
        guard check == nil, let probe = modelProbes?[model.trimmed], probe.protocolKind == inferenceKind else { return }
        check = probe.check
    }
}

extension Credential {
    mutating func recordProbe(_ result: CheckResult, model name: String, protocolKind: ServiceKind) {
        let target = name.trimmed
        guard !target.isEmpty else { return }
        if modelProbes == nil { modelProbes = [:] }
        modelProbes?[target] = ModelProbe(result, model: target, protocolKind: protocolKind)
    }
}

struct ProbeProgress: Equatable {
    var done: Int
    var total: Int
}

struct BatchCounts {
    var keys = 0, keysDone = 0, models = 0, modelsDone = 0
}

struct ModelCleanupItem: Identifiable, Hashable {
    let credentialID: UUID
    let model: String
    // The selected model is shown but must be switched away from first.
    var inUse = false
    // false: the call failed without the service saying the model is gone,
    // e.g. an image or embedding model on the chat endpoint, or a timeout.
    var offline = true
    var id: String { credentialID.uuidString + "/" + model }
}

// Which OpenAI-style endpoint can actually call a model. Embedding and image
// models reject chat requests, so checking them through chat proves nothing.
enum ModelEndpoint: Equatable {
    case chat, embedding, image
    private static let imageMarkers = ["gpt-image", "dall-e", "seedream", "seededit", "flux", "stable-diffusion", "sdxl", "imagen", "cogview", "wanx", "kolors", "midjourney", "recraft", "ideogram", "qwen-image", "hunyuan-image", "jimeng"]
    static func of(_ model: String) -> ModelEndpoint {
        let name = model.trimmed.lowercased()
        let last = name.split(separator: "/").last.map(String.init) ?? name
        if name.contains("embed") || last.hasPrefix("bge-") { return .embedding }
        // Chat models that can also draw (e.g. gemini-*-image-preview) stay on chat.
        if imageMarkers.contains(where: name.contains) { return .image }
        return .chat
    }
    var label: String? {
        switch self {
        case .chat: return nil
        case .embedding: return "向量"
        case .image: return "图片"
        }
    }
}

extension APIClient {
    static let imageProbeTimeout: TimeInterval = 180
    // Only OpenAI-style services share /embeddings and /images/generations.
    static func probeEndpoint(_ record: Credential) -> ModelEndpoint {
        guard [.compatible, .responses].contains(ProviderPreset.configuration(record).kind) else { return .chat }
        return ModelEndpoint.of(record.model)
    }
    static func capabilityRequest(for record: Credential, endpoint kind: ModelEndpoint) throws -> URLRequest {
        let record = ProviderPreset.configuration(record), model = record.model.trimmed
        guard !model.isEmpty else { throw KeyDockError.message("请先选择或填写需要验证的模型。") }
        let url = try endpoint(base: record.baseURL, suffix: kind == .embedding ? "embeddings" : "images/generations", defaultVersion: "v1")
        var request = try authenticatedRequest(url: url, record: record)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model]
        if kind == .embedding { body["input"] = "Hi" }
        else {
            body["prompt"] = "A small red circle on a plain white background"; body["n"] = 1
            // The lowest-cost option for this family; others keep their defaults.
            if model.lowercased().hasPrefix("gpt-image") { body["quality"] = "low"; body["size"] = "1024x1024" }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }
    // Calls a model through the endpoint that fits it: chat for conversation
    // models, /embeddings for embedding models, /images/generations for image models.
    static func probe(_ record: Credential, session: URLSession? = nil) async -> CheckResult {
        let kind = probeEndpoint(record)
        guard kind != .chat else { return await verify(record, session: session ?? APIClient.session, testModel: true) }
        let session = session ?? (kind == .image ? verificationSessions.session(atLeast: imageProbeTimeout) : APIClient.session)
        var attempted: URLRequest?
        let clock = ContinuousClock(), started = clock.now
        do {
            let request = try capabilityRequest(for: record, endpoint: kind)
            attempted = request
            // Images often arrive inline as base64, so allow a larger body.
            let (data, http) = try await AgentVerification.boundedData(for: request, session: session, limit: kind == .image ? 33_554_432 : 4_194_304)
            let elapsed = Latency.seconds(clock.now - started), address = request.url!.absoluteString
            var result: CheckResult
            if (200..<300).contains(http.statusCode) {
                if recognizes(data, kind) {
                    result = CheckResult(state: .valid, message: kind == .image ? "图片模型调用验证通过，已生成 1 张图片。" : "向量模型调用验证通过，已产生少量用量。", httpStatus: http.statusCode, endpoint: address)
                } else {
                    result = includingServiceError(CheckResult(state: .uncertain, message: kind == .image ? "返回成功状态，但未识别到图片结果，请按服务文档核对图片接口。" : "返回成功状态，但未识别到向量结果，请按服务文档核对向量接口。", httpStatus: http.statusCode, endpoint: address), data: data, record: record)
                }
            } else { result = classify(status: http.statusCode, data: data, record: record, endpoint: address, testModel: true) }
            result.response = CheckedResponse(data, response: http, record: record)
            result.requestMethod = "POST"; result.request = CheckedRequest(request); result.duration = elapsed
            return result
        } catch {
            let message = LogRedaction.text(failureMessage(error), secret: record.apiKey, otherSecrets: record.secretValues)
            var result = CheckResult(state: .uncertain, message: message, endpoint: attempted?.url?.absoluteString ?? "", requestMethod: attempted?.httpMethod, request: attempted.map(CheckedRequest.init))
            if attempted != nil { result.duration = Latency.seconds(clock.now - started) }
            return result
        }
    }
    static func recognizes(_ data: Data, _ kind: ModelEndpoint) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !hasAPIError(json) else { return false }
        let items = json["data"] as? [[String: Any]] ?? (json["data"] as? [String: Any]).map { [$0] } ?? []
        if kind == .embedding { return items.contains { ($0["embedding"] as? [Any])?.isEmpty == false || ($0["embedding"] as? String)?.isEmpty == false } }
        return items.contains { ($0["url"] as? String)?.isEmpty == false || ($0["b64_json"] as? String)?.isEmpty == false }
    }
}

// What a check is about to call, for the confirmation before it starts.
struct BatchPlan: Equatable {
    var keys = 0, models = 0, images = 0
    mutating func add(_ record: Credential, targets: [String]) {
        keys += 1; models += targets.count
        images += targets.filter { APIClient.probeEndpoint(record.probing($0)) == .image }.count
    }
    var imageNote: String { images > 0 ? "其中 \(images) 个图片模型各生成 1 张图片，费用和耗时会更高。" : "" }
}
