import Foundation

enum SDKFixture {
    static let domesticPaths = ["qwen": "gateway/qwen/compatible-mode/v1", "doubao": "gateway/doubao/api/v3", "kimi": "gateway/kimi/v1", "deepseek": "gateway/deepseek", "baichuan": "gateway/baichuan/v1", "relay": "tenant/team/relay/openai/v1"]
    @MainActor static func run() async {
        func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) ?? Data() }
        func event(_ value: Any, name: String? = nil) -> Data {
            Data(((name.map { "event: \($0)\n" } ?? "") + "data: " + String(data: json(value), encoding: .utf8)! + "\n\n").utf8)
        }
        let server = FixtureServer { request in
            let path = request.target.components(separatedBy: "?")[0]
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let streaming = body["stream"] as? Bool == true || path.contains(":streamGenerateContent")
            let nativeAnthropic = path.hasPrefix("/anthropic/")
            let nativeGemini = path.hasPrefix("/gemini/")
            let domestic = domesticPaths.first { path.hasPrefix("/" + $0.value + "/") }
            let auth = nativeAnthropic ? request.headers["x-api-key"] : (nativeGemini ? request.headers["x-goog-api-key"] : request.headers["authorization"])
            let expected = nativeAnthropic ? "fake-sdk-upstream-anthropic" : (nativeGemini ? "fake-sdk-upstream-gemini" : "Bearer fake-sdk-upstream-" + (domestic?.key ?? "compatible"))
            guard auth == expected else { return FixtureResponse(status: 401, chunks: [json(["error": ["type": "authentication_error", "message": "fixture authentication mismatch"]])]) }
            let valid = ["/oai/v1/chat/completions", "/oai/v1/models", "/oai/v1/responses", "/anthropic/v1/messages", "/anthropic/v1/models", "/gemini/v1beta/models", "/gemini/v1beta/models/fixture-model:generateContent", "/gemini/v1beta/models/fixture-model:streamGenerateContent"]
            let domesticPath = domestic.map { path == "/" + $0.value + "/chat/completions" } ?? false
            guard valid.contains(path) || domesticPath else { return FixtureResponse(status: 404, chunks: [json(["error": ["type": "not_found_error", "message": "unexpected fixture route", "path": path]])]) }
            if let domestic {
                guard body["model"] as? String == "fixture-" + domestic.key, request.headers["x-workspace"] == "fixture-team" else { return FixtureResponse(status: 400) }
            }
            if path.hasSuffix("/models") {
                let model: [String: Any] = nativeAnthropic ? ["id": "fixture-model", "type": "model", "display_name": "Fixture", "created_at": "2025-01-01T00:00:00Z"] : ["id": "fixture-model", "object": "model", "created": 0, "owned_by": "fixture"]
                if nativeGemini { return FixtureResponse(chunks: [json(["models": [["name": "models/fixture-model", "displayName": "Fixture", "supportedGenerationMethods": ["generateContent"]]]])]) }
                return FixtureResponse(chunks: [json(["data": [model], "has_more": false, "first_id": "fixture-model", "last_id": "fixture-model"])])
            }
            if nativeAnthropic {
                let message: [String: Any] = ["id": "msg_fixture", "type": "message", "role": "assistant", "model": "fixture-model", "content": [["type": "text", "text": "ACK"]], "stop_reason": "end_turn", "stop_sequence": NSNull(), "usage": ["input_tokens": 2, "output_tokens": 1]]
                if !streaming { return FixtureResponse(chunks: [json(message)]) }
                var start = message; start["content"] = []; start["stop_reason"] = NSNull()
                let frames: [(String, [String: Any])] = [
                    ("message_start", ["type": "message_start", "message": start]),
                    ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]),
                    ("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "ACK"]]),
                    ("content_block_stop", ["type": "content_block_stop", "index": 0]),
                    ("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()], "usage": ["output_tokens": 1]]),
                    ("message_stop", ["type": "message_stop"])
                ]
                return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: frames.map { event($0.1, name: $0.0) }, interval: 0.01)
            }
            if nativeGemini {
                let response: [String: Any] = ["candidates": [["index": 0, "content": ["role": "model", "parts": [["text": "ACK"]]], "finishReason": "STOP"]], "usageMetadata": ["promptTokenCount": 2, "candidatesTokenCount": 1, "totalTokenCount": 3], "modelVersion": "fixture-model"]
                return FixtureResponse(headers: ["Content-Type": streaming ? "text/event-stream" : "application/json"], chunks: [streaming ? event(response) : json(response)])
            }
            if path.hasSuffix("/responses") {
                let part: [String: Any] = ["type": "output_text", "annotations": [], "text": "ACK"]
                let message: [String: Any] = ["id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed", "content": [part]]
                let response: [String: Any] = ["id": "resp_fixture", "object": "response", "created_at": 0, "status": "completed", "model": "fixture-model", "output": [message]]
                if !streaming { return FixtureResponse(chunks: [json(response)]) }
                var start = response; start["output"] = []; start["status"] = "in_progress"
                var initialMessage = message; initialMessage["content"] = []; initialMessage["status"] = "in_progress"
                let frames: [[String: Any]] = [
                    ["type": "response.created", "sequence_number": 0, "response": start],
                    ["type": "response.output_item.added", "sequence_number": 1, "output_index": 0, "item": initialMessage],
                    ["type": "response.content_part.added", "sequence_number": 2, "item_id": "msg_fixture", "output_index": 0, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]],
                    ["type": "response.output_text.delta", "sequence_number": 3, "item_id": "msg_fixture", "output_index": 0, "content_index": 0, "delta": "ACK"],
                    ["type": "response.output_text.done", "sequence_number": 4, "item_id": "msg_fixture", "output_index": 0, "content_index": 0, "text": "ACK"],
                    ["type": "response.content_part.done", "sequence_number": 5, "item_id": "msg_fixture", "output_index": 0, "content_index": 0, "part": part],
                    ["type": "response.output_item.done", "sequence_number": 6, "output_index": 0, "item": message],
                    ["type": "response.completed", "sequence_number": 7, "response": response]
                ]
                return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: frames.map { event($0, name: $0["type"] as? String) }, interval: 0.01)
            }
            if streaming {
                let chunk: [String: Any] = ["id": "chatcmpl_fixture", "object": "chat.completion.chunk", "created": 0, "model": "fixture-model", "choices": [["index": 0, "delta": ["role": "assistant", "content": "ACK"], "finish_reason": NSNull()]]]
                return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [event(chunk), Data("data: [DONE]\n\n".utf8)], interval: 0.01)
            }
            return FixtureResponse(chunks: [json(["id": "chatcmpl_fixture", "object": "chat.completion", "created": 0, "model": "fixture-model", "choices": [["index": 0, "message": ["role": "assistant", "content": "ACK"], "finish_reason": "stop"]]])])
        }
        let proxy = LocalProxy(port: 0)
        do {
            try server.start()
            for _ in 0..<200 { if server.port != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard let port = server.port else { throw KeyDockError.message("SDK fixture server failed") }
            var records: [Credential] = []
            var named: [String: Credential] = [:]
            for kind in [ServiceKind.compatible, .anthropic, .gemini] {
                var record = Credential(); record.name = "SDK fixture"; record.kind = kind
                let prefix = kind == .compatible ? "oai/v1" : (kind == .anthropic ? "anthropic/v1" : "gemini/v1beta")
                record.baseURL = "http://127.0.0.1:\(port)/" + prefix
                record.apiKey = "fake-sdk-upstream-" + kind.rawValue
                record.auth = kind == .anthropic ? .xAPIKey : (kind == .gemini ? .googleKey : .bearer)
                records.append(record)
                named[kind.rawValue] = record
            }
            for (name, path) in domesticPaths {
                var record = Credential(); record.name = name; record.baseURL = "http://127.0.0.1:\(port)/" + path
                record.apiKey = "fake-sdk-upstream-" + name; record.extraHeaders = "X-Workspace: fixture-team"
                records.append(record); named[name] = record
            }
            proxy.update(records); proxy.start()
            for _ in 0..<200 { if proxy.running { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard let proxyPort = proxy.listeningPort else { throw KeyDockError.message("SDK fixture proxy failed") }
            let accounts = named.mapValues { ["base_url": "http://127.0.0.1:\(proxyPort)/s/" + $0.routeID, "api_key": $0.localKey] }
            print(String(data: json(["accounts": accounts]), encoding: .utf8)!); fflush(stdout)
            while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
        } catch { fputs("SDK fixture startup failed\n", stderr); exit(1) }
    }
}
