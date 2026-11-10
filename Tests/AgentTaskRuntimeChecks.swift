import Foundation
import CryptoKit

private final class TaskRuntimeFixture: @unchecked Sendable {
    let lock=NSLock(); var base="",phase=0; var observedSupplement=false; var observedContext=false
    let key="fixture-task-target-key-123456789"
    func response(_ request:LocalHTTPRequest)->FixtureResponse {
        lock.lock(); defer { lock.unlock() }
        if request.target=="/gateway/v1/models" { return FixtureResponse(chunks:[Data(#"{"data":[{"id":"fixture-chat"},{"id":"fixture-other"}]}"#.utf8)]) }
        if request.target=="/gateway/v1/chat/completions" {
            let json=(try? JSONSerialization.jsonObject(with:request.body)) as? [String:Any] ?? [:]
            if json["model"] as? String=="fixture-wrong" { return FixtureResponse(status:404,chunks:[Data(#"{"error":{"code":"model_not_found","message":"Use the actual deployment ID"}}"#.utf8)]) }
            return FixtureResponse(chunks:[Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)])
        }
        let body=String(decoding:request.body,as:UTF8.self)
        if body.contains("请使用实际部署") { observedSupplement=true }
        if body.contains("上一轮建议部署") { observedContext=true }
        let json=(try? JSONSerialization.jsonObject(with:request.body)) as? [String:Any] ?? [:]
        let messages=json["messages"] as? [[String:Any]] ?? []
        let last=messages.last { $0["role"] as? String=="tool" }?["content"] as? String ?? ""
        let result=(try? JSONSerialization.jsonObject(with:Data(last.utf8))) as? [String:Any] ?? [:]
        let id=result["id"] as? String ?? ""
        let name:String,args:[String:Any]
        switch phase {
        case 0: name="bash"; args=["command":"node -e \"console.log('first-output');setTimeout(()=>console.log('second-output'),1500)\"","timeout":10]
        case 1: name="propose_credential"; args=["api_key":"KEYDOCK_SECRET_1","base_url":base+"/gateway/v1","model":"fixture-wrong","kind":"compatible"]
        case 2: name="verify_credential"; args=["id":id]
        case 3: name="propose_credential"; args=["id":id,"api_key":"KEYDOCK_SECRET_1","base_url":base+"/gateway/v1","model":"fixture-chat","kind":"compatible"]
        case 4: name="verify_credential"; args=["id":id]
        case 5: name="finish_import"; args=["ids":[id],"summary":"已修正部署并验证，保留完整图片。"]
        default: name=""; args=[:]
        }
        phase+=1
        let delta:[String:Any]=name.isEmpty ? ["role":"assistant","content":"已经验证通过，请确认导入。"] : ["role":"assistant","tool_calls":[["index":0,"id":"task-\(phase)","type":"function","function":["name":name,"arguments":String(decoding:try! JSONSerialization.data(withJSONObject:args),as:UTF8.self)]]]]
        let chunks:[[String:Any]]=[["index":0,"delta":delta,"finish_reason":NSNull()],["index":0,"delta":[:],"finish_reason":name.isEmpty ? "stop":"tool_calls"]]
        let stream=chunks.map { "data: "+String(decoding:try! JSONSerialization.data(withJSONObject:["id":"fixture","object":"chat.completion.chunk","created":1,"model":"fixture","choices":[$0]]),as:UTF8.self)+"\n\n" }.joined()+"data: [DONE]\n\n"
        return FixtureResponse(headers:["Content-Type":"text/event-stream"],chunks:[Data(stream.utf8)])
    }
}

@MainActor enum AgentTaskRuntimeChecks {
    static func run() async {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-TaskRuntime-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let fixture=TaskRuntimeFixture(),server=FixtureServer(response:fixture.response)
        do {
            try server.start(); defer { server.stop() }; await InteractionFlowChecks.wait { server.port != nil }
            fixture.base="http://127.0.0.1:\(try unwrap(server.port))"
            let interaction=AgentInteraction(); interaction.activity.directory=root
            interaction.postReply("上一轮建议部署 fixture-chat，等待核验。")
            var service=DeepChecks.record(); service.baseURL=fixture.base+"/organizer/v1"; service.apiKey="fixture-task-organizer-secret"
            var supplements:[ImportPaste]=[]
            let task=Task { try await ImportAgent.run(raw:"API Key: "+fixture.key+"\nBase URL: "+fixture.base+"/gateway/v1",service:service,model:"fixture",images:[],promptConfiguration:.init(directory:root.appendingPathComponent("prompts")),interaction:interaction,onSupplement:{supplements.append($0)},progress:{_ in}) }
            defer { task.cancel() }
            for _ in 0..<300 { if interaction.activity.text.contains("输出：\nfirst-output") { break }; try await Task.sleep(for: .milliseconds(20)) }
            expectTrue(interaction.activity.active); expectTrue(interaction.activity.text.contains("输出：\nfirst-output"))
            expectFalse(interaction.activity.text.contains("second-output\n"))
            interaction.activity.flush()
            let logFile=root.appendingPathComponent(interaction.activity.record.id.uuidString.lowercased()+".json")
            expectTrue(try String(contentsOf:logFile,encoding:.utf8).contains("first-output"))
            checkpoint("AgentTask.official-SDK-streams-real-command-output-and-persists-it-before-completion")
            try await interaction.supplement?(ImportPaste(text:"请使用实际部署 fixture-chat，并保留其他可用模型。"))
            let result=try await task.value
            expectTrue(fixture.observedSupplement); expectTrue(fixture.observedContext); expectEqual(supplements.count,1)
            expectEqual(result.records.first?.check?.state,.valid); expectEqual(result.records.first?.model,"fixture-chat")
            expectEqual(interaction.activity.record.status,"completed")
            expectTrue(interaction.activity.text.contains("model_not_found")); expectTrue(interaction.activity.text.contains("HTTP 404"))
            expectTrue(interaction.activity.text.contains("second-output")); expectTrue(interaction.activity.entries.contains { $0.state=="failed" })
            expectEqual(interaction.messages.last?.text, result.summary)
            checkpoint("AgentTask.chat-supplement-uses-official-steering-and-errors-are-repaired-within-the-same-run")
            await interaction.activity.waitForPersistence()
            let persisted=try String(contentsOf:logFile,encoding:.utf8)
            expectFalse(persisted.contains(fixture.key)); expectFalse(persisted.contains(service.apiKey))
            expectTrue(persisted.contains("HTTP 404")); expectTrue(persisted.contains("completed"))
            checkpoint("AgentTask.completed-diagnostic-file-preserves-observed-failures-and-never-writes-real-authentication")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("AgentTask.official-chat-runtime-completes") }
    }
}
