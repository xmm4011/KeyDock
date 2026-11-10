import Foundation

@MainActor enum AgentPromptChecks {
    static func run() async {
        runCheck("AgentPrompt.external-file-is-seeded-once-and-preserved-across-default-updates") {
            try NewFeatureChecks.isolated { root in
                let runtime = root.appendingPathComponent("runtime")
                try FileManager.default.createDirectory(at: runtime.appendingPathComponent("prompts"), withIntermediateDirectories: true)
                let bundled = runtime.appendingPathComponent("prompts/credential-import.md")
                try Data("original default\n".utf8).write(to: bundled)
                let configuration = AgentPromptConfiguration(directory: root.appendingPathComponent("external"))
                expectEqual(try configuration.load(runtime: runtime), "original default\n")
                try configuration.save("用户打磨后的提示词\n", runtime: runtime)
                try Data("updated default\n".utf8).write(to: bundled)
                expectEqual(try configuration.load(runtime: runtime), "用户打磨后的提示词\n")
                expectEqual(try configuration.defaultText(runtime: runtime), "updated default\n")
                expectEqual((try FileManager.default.attributesOfItem(atPath: configuration.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                // Existing external configuration remains usable without rereading defaults.
                try FileManager.default.removeItem(at: runtime)
                expectEqual(try configuration.load(runtime: runtime), "用户打磨后的提示词\n")
            }
        }
        runCheck("AgentPrompt.invalid-or-unreadable-config-is-actionable-and-never-silently-replaced") {
            try NewFeatureChecks.isolated { root in
                let runtime = try AgentWorker.resources().runtime
                let configuration = AgentPromptConfiguration(directory: root)
                _ = try configuration.prepare(runtime: runtime)
                try Data("\n  \n".utf8).write(to: configuration.file)
                expectThrows(try configuration.load(runtime: runtime))
                expectEqual(try configuration.readForEditing(runtime: runtime), "\n  \n")
                expectThrows(try configuration.save("", runtime: runtime))
                expectEqual(try Data(contentsOf: configuration.file), Data("\n  \n".utf8))
                try Data([0xff, 0xfe, 0xff]).write(to: configuration.file)
                expectThrows(try configuration.load(runtime: runtime))
                expectEqual(try Data(contentsOf: configuration.file), Data([0xff, 0xfe, 0xff]))
            }
        }
        runCheck("AgentPrompt.editor-save-detects-external-edits-and-restoring-default-requires-saving") {
            try NewFeatureChecks.isolated { root in
                let runtime = try AgentWorker.resources().runtime
                let configuration = AgentPromptConfiguration(directory: root)
                let initial = try configuration.readForEditing(runtime: runtime)
                try Data("edited in external editor".utf8).write(to: configuration.file, options: .atomic)
                expectThrows(try configuration.save("stale settings edit", runtime: runtime, replacing: initial))
                expectEqual(try configuration.load(runtime: runtime), "edited in external editor")
                _ = try configuration.defaultText(runtime: runtime)
                expectEqual(try configuration.load(runtime: runtime), "edited in external editor")
                try configuration.save("saved in settings", runtime: runtime, replacing: "edited in external editor")
                expectEqual(try configuration.load(runtime: runtime), "saved in settings")
            }
        }
        await officialRuntime()
    }
    static func officialRuntime() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-PromptChecks-" + UUID().uuidString)
        let configuration = AgentPromptConfiguration(directory: root)
        let fixture = PromptRuntimeFixture(configuration: configuration)
        let server = FixtureServer(response: fixture.response)
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        do {
            try configuration.save("prompt-version-one", runtime: AgentWorker.resources().runtime)
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            fixture.base = "http://127.0.0.1:\(try unwrap(server.port))"
            var service = DeepChecks.record(); service.baseURL = fixture.base + "/organizer/v1"
            for _ in 0..<2 {
                let result = try await ImportAgent.run(raw: "Base URL: \(fixture.base)/target/v1\napi-key: fixture-prompt-target-key-123456\nmodel: fixture-chat", service: service, model: "fixture", images: [], promptConfiguration: configuration, progress: { _ in })
                expectEqual(result.records.first?.check?.state, .valid)
            }
            expectEqual(fixture.failures, [])
            expectEqual(fixture.observedPrompts.count, 8)
            expectTrue(fixture.observedPrompts.prefix(4).allSatisfy { $0.contains("prompt-version-one") && !$0.contains("prompt-version-two") })
            expectTrue(fixture.observedPrompts.suffix(4).allSatisfy { $0.contains("prompt-version-two") && !$0.contains("prompt-version-one") })
            expectFalse(fixture.observedPrompts.contains { $0.contains("你是 KeyDock 中的凭据导入") })
            checkpoint("AgentPrompt.official-SDK-uses-task-snapshot-and-rereads-edited-file-for-next-task-without-restart")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("AgentPrompt.official-runtime-completes") }
    }
}

private final class PromptRuntimeFixture: @unchecked Sendable {
    let configuration: AgentPromptConfiguration
    let lock = NSLock()
    var base = "", observedPrompts: [String] = [], failures: [String] = []
    init(configuration: AgentPromptConfiguration) { self.configuration = configuration }
    func response(_ request: LocalHTTPRequest) -> FixtureResponse {
        lock.lock(); defer { lock.unlock() }
        if request.target == "/target/v1/models" { return FixtureResponse(chunks: [Data(#"{"data":[{"id":"fixture-chat"}]}"#.utf8)]) }
        if request.target == "/target/v1/chat/completions" { return FixtureResponse(chunks: [Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8)]) }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []
        observedPrompts.append(messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? "")
        if observedPrompts.count == 1 {
            do { try Data("prompt-version-two".utf8).write(to: configuration.file, options: .atomic) }
            catch { failures.append(error.localizedDescription) }
        }
        let tools = messages.filter { $0["role"] as? String == "tool" }
        let text = tools.last?["content"] as? String ?? ""
        let result = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        if result["ok"] as? Bool == false { failures.append(text) }
        let id = result["id"] as? String ?? ""
        let name: String, args: [String: Any]
        switch tools.count {
        case 0: name = "propose_credential"; args = ["api_key": "KEYDOCK_SECRET_1", "base_url": base + "/target/v1", "model": "fixture-chat", "kind": "compatible"]
        case 1: name = "verify_credential"; args = ["id": id]
        case 2: name = "finish_import"; args = ["ids": [id], "summary": "已验证，请确认。"]
        default: name = ""; args = [:]
        }
        let delta: [String: Any] = name.isEmpty ? ["role": "assistant", "content": "已验证，请确认。"] : ["role": "assistant", "tool_calls": [["index": 0, "id": "prompt-\(tools.count)", "type": "function", "function": ["name": name, "arguments": String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]]]
        let choices: [[String: Any]] = [["index": 0, "delta": delta, "finish_reason": NSNull()], ["index": 0, "delta": [:], "finish_reason": name.isEmpty ? "stop" : "tool_calls"]]
        let stream = choices.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: ["id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture", "choices": [$0]]), as: UTF8.self) + "\n\n" }.joined() + "data: [DONE]\n\n"
        return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [Data(stream.utf8)])
    }
}
