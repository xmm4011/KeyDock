import Foundation

struct AgentVerification {
    static func request(_ record: Credential, arguments: [String: Any]) throws -> (URLRequest, ModelCallTemplate?) {
        let record = ProviderPreset.configuration(record)
        let method = (arguments["method"] as? String ?? (record.model.isEmpty ? "GET" : "POST")).uppercased()
        guard ["GET", "POST"].contains(method) else { throw KeyDockError.message("验证只支持 GET 或小用量 POST 请求。") }
        if method == "GET", (arguments["path"] as? String ?? "").isEmpty { return (try APIClient.verificationRequest(for: record), nil) }
        var path = arguments["path"] as? String ?? ""
        var body: [String: Any] = [:]
        if path.isEmpty {
            let payload = try APIClient.modelPayload(for: record); path = payload.path; body = payload.body
            if record.kind != .gemini { body["stream"] = false }
        }
        // A conventional endpoint such as /chat/completions is still
        // relative to the configured Base URL, including its gateway prefix.
        if path.hasPrefix("/"), !path.hasPrefix("//") { path.removeFirst() }
        guard !path.isEmpty, path.utf8.count < 2048, !path.hasPrefix("/"), !path.contains("://"), !path.contains(".."), !path.contains("?"), !path.contains("#"), !path.contains("\\") else {
            throw KeyDockError.message("接口路径请填 chat/completions 或 /chat/completions，不填完整地址、查询参数或路径穿越。")
        }
        guard path.range(of: #"^v[0-9]+(?:beta[0-9]*)?/"#, options: .regularExpression) == nil else { throw KeyDockError.message("路径不需要重复版本；例如 Base URL 已含 /v1 时，请填 chat/completions。") }
        if let provided = arguments["body"] as? String, !provided.isEmpty {
            guard provided.utf8.count <= 16_384, let data = provided.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw KeyDockError.message("验证正文必须是小于 16 KB 的 JSON 对象。") }
            body = json
        }
        body = APIClient.inferenceBody(body, path: path, record: record)
        if let model = body["model"] as? String, model != record.model { throw KeyDockError.message("请求模型与候选配置不同，请先修正候选模型后验证。") }
        for name in ["max_tokens", "n"] {
            if let value = body[name] as? NSNumber, value.intValue > (name == "n" ? 1 : 128) { throw KeyDockError.message("请使用低用量验证参数，输出预算不超过 128，且只生成一份响应。") }
        }
        var configured = record
        if let headers = arguments["headers"] as? String, !headers.isEmpty { configured.extraHeaders += (configured.extraHeaders.isEmpty ? "" : "\n") + headers }
        let url = try APIClient.endpoint(base: record.baseURL, suffix: path, defaultVersion: record.kind == .gemini ? "v1beta" : "v1")
        var request = try APIClient.authenticatedRequest(url: url, record: configured); request.httpMethod = method
        guard method == "POST" else { return (request, nil) }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if record.kind == .gemini { path = path.replacingOccurrences(of: record.model.replacingOccurrences(of: "models/", with: ""), with: "{model}") }
        return (request, ModelCallTemplate(path: path, body: String(decoding: data, as: UTF8.self), model: record.model))
    }
    static func boundedData(for request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw KeyDockError.message("未收到 HTTP 响应。") }
        guard response.expectedContentLength <= Int64(limit) else { throw KeyDockError.message("返回内容过大，已停止读取。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw KeyDockError.message("返回内容过大，已停止读取。") }
            data.append(byte)
        }
        return (data, response)
    }
    static func classify(_ data: Data, response: HTTPURLResponse, record: Credential, method: String, endpoint: String) -> CheckResult {
        guard method == "POST", (200..<300).contains(response.statusCode) else {
            var result = APIClient.classify(status: response.statusCode, data: data, record: record, endpoint: endpoint, testModel: method == "POST")
            result.requestMethod = method; result.response = CheckedResponse(data, response: response, record: record); return result
        }
        var result = CheckResult(state: .uncertain, message: "返回成功状态，但未识别到真实模型响应，请按文档核对协议。", httpStatus: response.statusCode, endpoint: endpoint, requestMethod: method, response: CheckedResponse(data, response: response, record: record))
        var objects: [[String: Any]] = []
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { objects = [json] }
        else {
            objects = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter { $0.hasPrefix("data:") }.compactMap {
                try? JSONSerialization.jsonObject(with: Data(String($0.dropFirst(5)).trimmed.utf8)) as? [String: Any]
            }
        }
        objects += objects.compactMap { $0["response"] as? [String: Any] }
        guard !objects.isEmpty, !objects.contains(where: APIClient.hasAPIError) else { return APIClient.includingServiceError(result, data: data, record: record) }
        func hasGeneratedContent(_ json: [String: Any]) -> Bool {
            (json["output"] as? [[String: Any]] ?? []).contains { item in
                let type = item["type"] as? String
                guard type == "message" && item["role"] as? String == "assistant" || type == "reasoning" else { return false }
                return ((item["content"] as? [[String: Any]] ?? []) + (item["summary"] as? [[String: Any]] ?? [])).contains { part in
                    !(part["text"] as? String ?? "").trimmed.isEmpty
                } || (type == "reasoning" && !(item["encrypted_content"] as? String ?? "").isEmpty && ((json["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0) > 0)
            }
        }
        let success = objects.contains { json in
            if let choices = json["choices"] as? [[String: Any]], let first = choices.first { return first["message"] is [String: Any] || first["delta"] is [String: Any] }
            if let candidates = json["candidates"] as? [[String: Any]], let content = candidates.first?["content"] as? [String: Any] { return content["parts"] is [[String: Any]] }
            if json["type"] as? String == "message", json["role"] as? String == "assistant" { return json["content"] is [[String: Any]] }
            if let message = json["message"] as? [String: Any], message["type"] as? String == "message" { return true }
            if json["object"] as? String == "response" {
                if json["status"] as? String == "completed" { return json["output"] is [[String: Any]] }
                if json["status"] as? String == "incomplete" { return hasGeneratedContent(json) }
            }
            return false
        }
        if success { result.state = .valid; result.message = "当前模型调用验证通过，已产生少量用量。" }
        if success, let partial = objects.first(where: { $0["object"] as? String == "response" && $0["status"] as? String == "incomplete" && hasGeneratedContent($0) }) {
            let visible = (partial["output"] as? [[String: Any]] ?? []).contains { item in
                item["type"] as? String == "message" && (item["content"] as? [[String: Any]] ?? []).contains { !(($0["text"] as? String) ?? "").trimmed.isEmpty }
            }
            result.message = visible ? "当前模型调用验证通过，服务输出未完整结束。" : "当前模型调用验证通过，服务已返回推理内容，尚无最终回答。"
        }
        return result
    }
}
