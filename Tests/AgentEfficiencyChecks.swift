import Foundation

@MainActor enum AgentEfficiencyChecks {
    static func run() async {
        logContent()
        await catalogAndEdits()
        await officialRuntime()
    }
    static func logContent() {
        runCheck("AgentEfficiency.diagnostics-exclude-reasoning-and-avoid-repeating-the-entire-conversation") {
            let raw: [String: Any] = ["model": "fixture", "messages": [
                ["role": "system", "content": "initial-instructions"],
                ["role": "user", "content": "API Key: KEYDOCK_SECRET_1"],
                ["role": "assistant", "reasoning_content": "private-reasoning", "reasoning": "private-details", "content": [["type": "thinking", "thinking": "private-block"], ["type": "text", "text": "public-text"]]],
                ["role": "tool", "content": "observed-models"]
            ], "tools": [["type": "function", "function": ["name": "list_models", "description": "large-schema"]]]]
            let input = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
            let first = AgentLogContent.modelRequest(input, includeHistory: true)
            let later = AgentLogContent.modelRequest(input, includeHistory: false)
            for value in [first, later] {
                expectFalse(value.contains("private-reasoning")); expectFalse(value.contains("private-details")); expectFalse(value.contains("private-block"))
                expectTrue(value.contains("public-text")); expectTrue(value.contains("observed-models"))
            }
            expectTrue(first.contains("KEYDOCK_SECRET_1")); expectTrue(first.contains("initial-instructions"))
            expectFalse(later.contains("initial-instructions")); expectFalse(later.contains("large-schema")); expectTrue(later.contains("earlier_messages_omitted"))
            let gemini = AgentLogContent.modelRequest(#"{"contents":[{"parts":[{"thought":true,"text":"private-gemini"},{"text":"public-gemini","thoughtSignature":"private-signature"}]}]}"#, includeHistory: true)
            expectFalse(gemini.contains("private-gemini")); expectFalse(gemini.contains("private-signature")); expectTrue(gemini.contains("public-gemini"))
            let original = try unwrap(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            expectEqual((original["messages"] as? [[String: Any]])?[2]["reasoning_content"] as? String, "private-reasoning")
        }
        runCheck("AgentEfficiency.compact-process-shows-key-events-and-keeps-details-and-wire-placeholders-available") {
            let activity = AgentActivity(), key = "fixture-visible-credential-12345"
            activity.begin(raw: "api-key: " + key, service: DeepChecks.record(), model: "fixture")
            activity.note("request", detail: "repeated-context KEYDOCK_SECRET_1", diagnosticOnly: true)
            activity.update(id: "catalog", title: "获取模型列表", detail: "full-catalog-json", state: "completed", summary: "已获取 2 个模型")
            activity.note("native request", detail: "Authorization: Bearer " + key)
            let compact = activity.displayText(showFullContent: false, detailed: false)
            expectTrue(compact.contains("已获取 2 个模型")); expectFalse(compact.contains("repeated-context")); expectFalse(compact.contains("full-catalog-json")); expectFalse(compact.contains(key))
            let full = activity.displayText(showFullContent: true)
            expectTrue(full.contains("KEYDOCK_SECRET_1")); expectTrue(full.contains("full-catalog-json")); expectTrue(full.contains(key))
            let diagnostic = activity.diagnosticText(showFullContent: false)
            expectTrue(diagnostic.contains("repeated-context")); expectTrue(diagnostic.contains("full-catalog-json")); expectTrue(diagnostic.contains("任务 ")); expectFalse(diagnostic.contains(key))
            expectTrue(activity.diagnosticText(showFullContent: true).contains(key))
            expectEqual(activity.safe(#"{"api_key":{"description":"schema"}}"#), #"{"api_key":{"description":"schema"}}"#)
            let oldEntry = Data(#"{"id":"legacy","time":0,"title":"old","detail":"old detail","state":"completed"}"#.utf8)
            expectNil(try JSONDecoder().decode(AgentActivityEntry.self, from: oldEntry).diagnosticOnly)
            activity.finish("completed", detail: "done")
        }
        runCheck("AgentEfficiency.final-chat-replaces-the-final-narration-with-one-canonical-result") {
            let interaction = AgentInteraction()
            interaction.postUser(ImportPaste(text: "fixture materials"))
            interaction.postReply("模型给出的最终说明")
            interaction.postCompletion(summary: "1 条验证通过；目录暂不可用。", reply: "模型给出的最终说明")
            expectEqual(interaction.messages.count, 2)
            expectEqual(interaction.messages.last?.text, "1 条验证通过；目录暂不可用。")
        }
    }
    static func catalogAndEdits() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Efficiency-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MockURLProtocol.session { request in
            if request.httpMethod == "GET" { return MockReply(body: Data(#"{"data":[{"id":"fixture-chat"},{"id":"fixture-other"}]}"#.utf8)) }
            return MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        do {
            let base = "https://fixture.invalid/gateway/v1", other = "https://fixture.invalid/other/v1"
            let host = ImportAgentHost(original: "Base URL: \(base)\nAlternate: \(other)\napi-key: fixture-source-key-123456", imageText: "", images: [], workspace: root, session: session)
            var args: [String: Any] = ["base_url": base, "api_key": "KEYDOCK_SECRET_1", "kind": "compatible", "auth": "bearer"]
            let draft = try host.propose(args); args["id"] = draft["id"]
            let catalog = await host.call("list_models", args: ["id": draft["id"]!])
            args["models"] = catalog["models"]; args["model"] = "fixture-chat"
            _ = try host.propose(args)
            expectEqual(host.candidates.first?.modelCatalog?.models, ["fixture-chat", "fixture-other"])
            expectNil(host.candidates.first?.modelCatalog?.source)
            checkpoint("AgentEfficiency.actual-catalog-is-valid-model-evidence-for-its-own-draft")
            let result = await host.call("verify_credential", args: ["id": draft["id"]!, "method": "POST", "path": "/chat/completions"])
            expectEqual(result["ok"] as? Bool, true)
            let verified = try unwrap(host.candidates.first), proof = try unwrap(verified.check)
            expectTrue(proof.endpoint.hasSuffix("/gateway/v1/chat/completions"))
            args["notes_sections"] = ["access": ["使用 Bearer 鉴权"]]; args["name"] = "Updated title"
            let revised = try host.propose(args)
            expectEqual(revised["verified"] as? Bool, true)
            expectEqual(host.candidates.first?.check, proof); expectEqual(host.candidates.first?.callTemplate, verified.callTemplate)
            expectEqual(host.verificationCalls, 2)
            checkpoint("AgentEfficiency.notes-and-title-edits-preserve-proof-time-template-and-catalog-without-new-requests")
            var bad = args; bad["models"] = ["invented-model"]
            expectThrows(try host.propose(bad))
            bad = args; bad["base_url"] = other
            expectThrows(try host.propose(bad))
            bad = args; bad["auth"] = "xAPIKey"
            expectThrows(try host.propose(bad))
            bad = args; bad["extra_headers"] = "X-Workspace: another-account"
            expectThrows(try host.propose(bad))
            checkpoint("AgentEfficiency.catalog-evidence-does-not-authorize-invented-models-or-cross-connection-auth-and-workspace-reuse")
            for field in ["base_url", "auth", "extra_headers", "kind", "model"] {
                host.candidates = [verified]
                var changed = args; changed.removeValue(forKey: "models")
                changed[field] = ["base_url": other, "auth": "xAPIKey", "extra_headers": "X-Workspace: another", "kind": "responses", "model": "fixture-other"][field]!
                let value = try host.propose(changed)
                expectEqual(value["verified"] as? Bool, false); expectNil(host.candidates.first?.check); expectNil(host.candidates.first?.callTemplate)
            }
            checkpoint("AgentEfficiency.request-affecting-edits-still-clear-old-proof-and-template")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("AgentEfficiency.catalog-and-edit-regressions-complete") }
    }
    static func officialRuntime() async {
        let fixture = EfficientRuntimeFixture(), server = FixtureServer(response: fixture.response)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-EfficientRuntime-" + UUID().uuidString)
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            fixture.base = "http://127.0.0.1:\(try unwrap(server.port))"
            let disk = DispatchSemaphore(value: 0)
            var firstWrite = true
            let writer = AgentLogWriter { record, directory in
                if firstWrite { firstWrite = false; disk.wait() }
                try AgentLogWriter.persist(record, directory)
            }
            defer { disk.signal() }
            let interaction = AgentInteraction(activity: AgentActivity(writer: writer)); interaction.activity.directory = root
            var service = DeepChecks.record(); service.baseURL = fixture.base + "/organizer/v1"; service.apiKey = "fixture-organizer-secret"
            var returned = false
            let task = Task {
                let result = try await ImportAgent.run(raw: "Base URL: \(fixture.base)/gateway/v1\napi-key: fixture-target-secret", service: service, model: "fixture", images: [], promptConfiguration: .init(directory: root.appendingPathComponent("prompts")), interaction: interaction, progress: { _ in })
                returned = true; return result
            }
            defer { task.cancel() }
            for _ in 0..<400 { if returned { break }; try await Task.sleep(for: .milliseconds(25)) }
            expectTrue(returned)
            disk.signal()
            let result = try await task.value
            await interaction.activity.waitForPersistence()
            checkpoint("GlobalPerformance.official-Agent-returns-reviewable-results-before-blocked-diagnostic-storage-is-released")
            expectEqual(result.records.first?.check?.state, .valid)
            expectEqual(result.records.first?.availableModels, ["fixture-chat", "fixture-other"])
            expectEqual(fixture.catalogCalls, 1); expectEqual(fixture.inferenceCalls, 1); expectTrue(fixture.failures.isEmpty)
            expectTrue(fixture.retainedVerification); expectFalse(fixture.receivedRealKey)
            expectFalse(interaction.activity.displayText(showFullContent: false, detailed: false).contains("整理模型请求"))
            checkpoint("AgentEfficiency.official-SDK-completes-catalog-revision-leading-slash-probe-and-notes-with-one-inference")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("AgentEfficiency.official-runtime-completes") }
    }
}

private final class EfficientRuntimeFixture: @unchecked Sendable {
    let lock = NSLock()
    var base = "", phase = 0, id = "", catalogCalls = 0, inferenceCalls = 0
    var failures: [String] = [], retainedVerification = false, receivedRealKey = false
    func response(_ request: LocalHTTPRequest) -> FixtureResponse {
        lock.lock(); defer { lock.unlock() }
        if request.target == "/gateway/v1/models" {
            catalogCalls += 1
            return FixtureResponse(chunks: [Data(#"{"data":[{"id":"fixture-chat"},{"id":"fixture-other"}]}"#.utf8)])
        }
        if request.target == "/gateway/v1/chat/completions" {
            inferenceCalls += 1
            return FixtureResponse(chunks: [Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8)])
        }
        if String(decoding: request.body, as: UTF8.self).contains("fixture-target-secret") { receivedRealKey = true }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []
        let text = messages.last { $0["role"] as? String == "tool" }?["content"] as? String ?? ""
        let result = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        if result["ok"] as? Bool == false { failures.append(text) }
        if let value = result["id"] as? String { id = value }
        if phase == 5 { retainedVerification = result["verified"] as? Bool == true }
        var args: [String: Any] = ["base_url": base + "/gateway/v1", "api_key": "KEYDOCK_SECRET_1", "kind": "compatible", "auth": "bearer"]
        let name: String
        switch phase {
        case 0: name = "propose_credential"
        case 1: name = "list_models"; args = ["id": id]
        case 2: name = "propose_credential"; args["id"] = id; args["model"] = "fixture-chat"; args["models"] = ["fixture-chat", "fixture-other"]
        case 3: name = "verify_credential"; args = ["id": id, "method": "POST", "path": "/chat/completions"]
        case 4: name = "propose_credential"; args["id"] = id; args["model"] = "fixture-chat"; args["notes_sections"] = ["access": ["已核对接入"]]
        case 5: name = "finish_import"; args = ["ids": [id], "summary": "1 条凭据已验证，请确认保存。"]
        default: name = ""; args = [:]
        }
        phase += 1
        let delta: [String: Any] = name.isEmpty ? ["role": "assistant", "content": "1 条凭据已验证，请确认保存。"] : ["role": "assistant", "tool_calls": [["index": 0, "id": "efficient-\(phase)", "type": "function", "function": ["name": name, "arguments": String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]]]
        let chunks: [[String: Any]] = [["index": 0, "delta": delta, "finish_reason": NSNull()], ["index": 0, "delta": [:], "finish_reason": name.isEmpty ? "stop" : "tool_calls"]]
        let stream = chunks.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: ["id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture", "choices": [$0]]), as: UTF8.self) + "\n\n" }.joined() + "data: [DONE]\n\n"
        return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [Data(stream.utf8)])
    }
}
