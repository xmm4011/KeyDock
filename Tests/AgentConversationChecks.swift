import Foundation

private final class ConversationFixture: @unchecked Sendable {
    let mode: String
    let lock = NSLock()
    var base = "", phase = 0, candidateID = "", failures: [String] = []
    let key = "sk-fixture-conversation-first-123456789"
    let addedKey = "sk-fixture-conversation-added-much-longer-987654321"
    init(_ mode:String) { self.mode = mode }
    func response(_ request: LocalHTTPRequest) -> FixtureResponse {
        lock.lock(); defer { lock.unlock() }
        if request.target == "/v1/chat/completions" {
            if request.headers["authorization"] != "Bearer " + key { failures.append("candidate auth mismatch") }
            if mode == "partial" { return FixtureResponse(status:404,chunks:[Data(#"{"error":{"code":"model_not_found","message":"unknown model"}}"#.utf8)]) }
            return FixtureResponse(chunks:[Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)])
        }
        if request.target == "/v1/models" { return FixtureResponse(chunks:[Data(#"{"data":[{"id":"fixture-good"}]}"#.utf8)]) }
        let raw = String(decoding:request.body,as:UTF8.self)
        if raw.contains(key) || raw.contains(addedKey) { failures.append("real candidate key leaked into organizer context") }
        let json = (try? JSONSerialization.jsonObject(with:request.body)) as? [String:Any] ?? [:]
        let messages = json["messages"] as? [[String:Any]] ?? []
        let last = messages.last { $0["role"] as? String == "tool" }?["content"] as? String ?? ""
        let observed = (try? JSONSerialization.jsonObject(with:Data(last.utf8))) as? [String:Any] ?? [:]
        if let id = observed["id"] as? String { candidateID = id }
        let step = phase; phase += 1
        if mode == "error" && step == 0 {
            return FixtureResponse(status:429,chunks:[Data(#"{"error":{"message":"fixture service is temporarily rate limited, echoed fixture-organizer-only","code":"rate_limit_exceeded"}}"#.utf8)])
        }
        var tool = "", args:[String:Any] = [:], text = ""
        if step == 0 && mode == "ask" {
            tool = "ask_user"; args = ["question":"请补充接入配置截图中的 tokenId","reason":"文字未包含辅助鉴权值","items":["tokenId"],"example":"粘贴配置文字或截图"]
        } else if step == 0 && mode == "reply" {
            text = "已核对资料，当前网关返回了未记录的协议错误，我暂时无法完成验证。"
        } else {
            let offset = ["ask","reply","error"].contains(mode) ? 1 : 0
            switch step - offset {
            case 0:
                if offset == 1 {
                    if !raw.contains("新增接入配置") { failures.append("user reply absent from resumed SDK context") }
                    if !raw.contains("KEYDOCK_SECRET_1") || !raw.contains("KEYDOCK_SECRET_2") { failures.append("stable original/new secret IDs absent") }
                    if mode == "ask" && !raw.contains("image_url") { failures.append("supplement image not passed as image content") }
                    if mode == "reply" && !raw.contains("暂时无法完成验证") { failures.append("previous assistant reply lost") }
                }
                tool = "propose_credential"; args = ["api_key":"KEYDOCK_SECRET_1","base_url":base+"/v1","kind":"compatible","model":"fixture-good","name":"Conversation fixture"]
            case 1: tool = "list_models"; args = ["id":candidateID]
            case 2: tool = "verify_credential"; args = ["id":candidateID]
            case 3:
                if mode == "crash" { tool = "bash"; args = ["command":"kill -KILL \"$PPID\"","timeout":5] }
                else { tool = "finish_import"; args = ["ids":[candidateID],"summary":mode == "partial" ? "模型不存在，未验证通过。" : "已完成实际调用验证。"] }
            default: text = mode == "partial" ? "已获取模型列表，但指定模型返回 model_not_found；保留了草稿供你核对。" : "已根据你的回复修正配置，真实请求验证通过。"
            }
        }
        let delta:[String:Any] = tool.isEmpty ? ["role":"assistant","content":text] : ["role":"assistant","tool_calls":[["index":0,"id":"conversation-\(step)","type":"function","function":["name":tool,"arguments":String(decoding:try! JSONSerialization.data(withJSONObject:args),as:UTF8.self)]]]]
        let chunks:[[String:Any]] = [["index":0,"delta":delta,"finish_reason":NSNull()],["index":0,"delta":[:],"finish_reason":tool.isEmpty ? "stop" : "tool_calls"]]
        let stream = chunks.map { "data: "+String(decoding:try! JSONSerialization.data(withJSONObject:["id":"fixture","object":"chat.completion.chunk","created":1,"model":"fixture","choices":[$0]]),as:UTF8.self)+"\n\n" }.joined()+"data: [DONE]\n\n"
        return FixtureResponse(headers:["Content-Type":"text/event-stream"],chunks:[Data(stream.utf8)])
    }
}

@MainActor enum AgentConversationChecks {
    static func run() async {
        for mode in ["ask","reply","error","partial","cancel","crash"] { await scenario(mode) }
    }
    static func scenario(_ mode:String) async {
        let fixture = ConversationFixture(mode == "cancel" ? "ask" : mode)
        let server = FixtureServer(response:fixture.response)
        do {
            try server.start(); defer { server.stop() }
            await InteractionFlowChecks.wait { server.port != nil }
            fixture.base = "http://127.0.0.1:\(try unwrap(server.port))"
            var service = DeepChecks.record(); service.baseURL = fixture.base+"/organizer/v1"; service.apiKey = "fixture-organizer-only"
            let interaction = AgentInteraction(); var saved: [ImportPaste] = []
            let task = Task { try await ImportAgent.run(raw:"API Key: \(fixture.key)\nBase URL: \(fixture.base)/v1",service:service,model:"fixture",images:[],interaction:interaction,onSupplement:{saved.append($0)},progress:{_ in}) }
            if mode == "crash" {
                do { _ = try await task.value; checkFailures.append("killed worker returned success") } catch {
                    expectTrue(interaction.failure != nil)
                    expectEqual(interaction.recovery?.records.count,1)
                    expectEqual(interaction.recovery?.records.first?.check?.state,.valid)
                    expectEqual(interaction.recovery?.records.first?.apiKey,fixture.key)
                    expectFalse(interaction.failure?.question.contains(fixture.key) == true)
                    expectFalse(interaction.isWaiting)
                }
                expectEqual(fixture.failures,[])
                checkpoint("AgentConversation.crash-retains-host-verified-candidates-and-an-actionable-error"); return
            }
            for _ in 0..<1500 { if interaction.isWaiting { break }; try await Task.sleep(for:.milliseconds(10)) }
            expectTrue(interaction.isWaiting)
            let reply = interaction.question?.question ?? ""
            expectFalse(reply.contains("fixture-organizer-only"))
            switch mode {
            case "ask", "cancel": expectTrue(reply.contains("tokenId")); expectEqual(interaction.question?.items,["tokenId"])
            case "reply": expectTrue(reply.contains("暂时无法完成验证")); expectFalse(reply.contains("请补充资料"))
            case "error": expectTrue(reply.contains("rate") || reply.contains("429")); expectFalse(reply.contains("请补充资料"))
            case "partial": expectTrue(reply.contains("model_not_found")); expectTrue(interaction.question?.canReview == true)
            default: break
            }
            if mode == "cancel" {
                task.cancel()
                do { _ = try await task.value; checkFailures.append("cancelled Agent returned a result") } catch { expectTrue(error is CancellationError) }
                expectFalse(interaction.isWaiting); expectEqual(saved.count,0)
            } else {
                if mode == "partial" { interaction.review() }
                else {
                    interaction.document = ImportDocument(ImportPaste(text:"新增接入配置 \(fixture.addedKey)",images:mode == "ask" ? [try NewFeatureChecks.image()] : []))
                    interaction.submit()
                }
                let result = try await task.value
                expectEqual(result.records.count,1); expectEqual(result.records.first?.apiKey,fixture.key)
                expectEqual(result.records.first?.check?.state,mode == "partial" ? .uncertain : .valid)
                expectEqual(result.records.first?.availableModels,["fixture-good"])
                expectTrue(!result.reply.isEmpty)
                expectEqual(saved.count,mode == "partial" ? 0 : 1)
            }
            expectEqual(fixture.failures,[])
            checkpoint("AgentConversation.\(mode)-preserves-actual-reply-context-and-secret-mapping")
        } catch { checkFailures.append(mode+": "+error.localizedDescription); checkpoint("AgentConversation.\(mode)") }
    }
}
