import Foundation
import CryptoKit
import Darwin

private final class AgentFixture: @unchecked Sendable {
    let lock = NSLock()
    var base = "", outside = ""
    let key = "sk-fixture-agent-only-0123456789"
    var phase = 0, failures: [String] = [], wrongAttempts = 0, goodAttempts = 0
    func response(_ request: LocalHTTPRequest) -> FixtureResponse {
        lock.lock(); defer { lock.unlock() }
        if request.target == "/guide" {
            if request.headers["authorization"] != nil { failures.append("document received credentials") }
            return FixtureResponse(headers: ["Content-Type":"text/html"], chunks:[Data("<html><body>API Base: \(base)/v1<br>Use model: fixture-good<br>POST chat/completions with Bearer authentication.</body></html>".utf8)])
        }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String:Any] ?? [:]
        if request.target == "/v1/chat/completions" {
            if request.headers["authorization"] != "Bearer " + key { failures.append("wrong candidate authentication") }
            if json["model"] as? String == "fixture-wrong" { wrongAttempts += 1; return FixtureResponse(status:404,chunks:[Data(("{\"error\":{\"code\":\"model_not_found\",\"message\":\"fix model \(key)\"}}").utf8)]) }
            goodAttempts += 1
            return FixtureResponse(chunks:[Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#.utf8)])
        }
        if request.target == "/v1/models" {
            if request.headers["authorization"] != "Bearer " + key { failures.append("wrong catalog authentication") }
            return FixtureResponse(chunks:[Data(#"{"data":[{"id":"fixture-good"},{"id":"fixture-wrong"}]}"#.utf8)])
        }
        guard request.target == "/organizer/v1/chat/completions" else { failures.append("unexpected endpoint"); return FixtureResponse(status:404) }
        if request.headers["authorization"] != "Bearer fixture-organizer-secret" { failures.append("wrong organizer authentication") }
        let raw = String(decoding:request.body,as:UTF8.self)
        if raw.contains(key) { failures.append("candidate key leaked into model context") }
        let messages = json["messages"] as? [[String:Any]] ?? []
        let last = messages.last { $0["role"] as? String == "tool" }?["content"] as? String ?? ""
        let observed = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String:Any] ?? [:]
        let id = observed["id"] as? String ?? ""
        var name = "", args: [String:Any] = [:]
        switch phase {
        case 0: name = "fetch_document"; args = ["url":base+"/guide"]
        case 1:
            if observed["ok"] as? Bool != true { failures.append("document fetch failed") }
            name = "read"; args = ["path":"document-1.txt"]
        case 2:
            if !last.contains("fixture-good") { failures.append("document was not actually read") }
            name = "write"; args = ["path":"extract.mjs","content":"import fs from 'node:fs'; const text=fs.readFileSync('document-1.txt','utf8'); console.log('EXTRACTED_MODEL:'+text.match(/model: ([a-z-]+)/)[1]); try { fs.readFileSync(" + String(data:try! JSONSerialization.data(withJSONObject: outside,options:[.fragmentsAllowed]),encoding:.utf8)! + "); console.log('ISOLATION_FAILED'); } catch(e) { console.log('ISOLATION_BLOCKED:'+e.code); }"]
        case 3: name = "bash"; args = ["command":"node extract.mjs","timeout":10]
        case 4:
            if !last.contains("EXTRACTED_MODEL:fixture-good") || !last.contains("ISOLATION_BLOCKED") || last.contains("ISOLATION_FAILED") { failures.append("code execution or filesystem isolation failed: "+String(last.prefix(300))) }
            name = "propose_credential"; args = ["base_url":base+"/v1","api_key":"KEYDOCK_SECRET_1","model":"fixture-wrong","kind":"compatible","name":"Agent fixture","docs_url":base+"/guide"]
        case 5: name = "verify_credential"; args = ["id":id]
        case 6:
            if observed["status"] as? Int != 404 || !last.contains("model_not_found") { failures.append("failed verification was not observed") }
            name = "propose_credential"; args = ["id":id,"base_url":base+"/v1","api_key":"KEYDOCK_SECRET_1","model":"fixture-good","kind":"compatible","name":"Agent fixture"]
        case 7: name = "verify_credential"; args = ["id":id]
        case 8:
            if observed["ok"] as? Bool != true { failures.append("corrected candidate did not verify") }
            name = "finish_import"; args = ["ids":[id],"summary":"已读取文档、执行提取脚本，修正模型并完成实际验证。"]
        default: break
        }
        phase += 1
        let delta: [String:Any] = name.isEmpty ? ["role":"assistant","content":"已完成。"] : ["role":"assistant","tool_calls":[["index":0,"id":"fixture-call-\(phase)","type":"function","function":["name":name,"arguments":String(decoding:try! JSONSerialization.data(withJSONObject:args),as:UTF8.self)]]]]
        let chunks: [[String:Any]] = [["index":0,"delta":delta,"finish_reason":NSNull()],["index":0,"delta":[:],"finish_reason":name.isEmpty ? "stop" : "tool_calls"]]
        let stream = chunks.map { choice in "data: "+String(decoding:try! JSONSerialization.data(withJSONObject:["id":"fixture-response","object":"chat.completion.chunk","created":1,"model":"fixture-organizer","choices":[choice]]),as:UTF8.self)+"\n\n" }.joined()+"data: [DONE]\n\n"
        return FixtureResponse(headers:["Content-Type":"text/event-stream"],chunks:[Data(stream.utf8)])
    }
}

@MainActor enum AgentChecks {
    static func run() async {
        runCheck("Agent.templates-keep-verified-request-in-real-and-safe-curl") {
            var record = DeepChecks.record(); record.model = "documented-model"
            record.callTemplate = ModelCallTemplate(path:"responses",body:#"{"model":"old-model","input":"Hi","max_output_tokens":16}"#)
            let request = try APIClient.modelRequest(for:record)
            expectTrue(request.url?.path.hasSuffix("/responses") == true)
            expectTrue(String(decoding:request.httpBody!,as:UTF8.self).contains("documented-model"))
            expectTrue(record.localCurl.contains("/responses")); expectFalse(record.safeShareText.contains(record.apiKey))
            expectTrue(APIClient.requiresModelTest(record)); expectTrue(try APIClient.modelTestRequest(for:record).url?.path.hasSuffix("/responses") == true)
        }
        runCheck("Agent.probes-validate-protocol-not-only-HTTP-200") {
            var record = DeepChecks.record(); record.model = "fixture"
            let response = HTTPURLResponse(url:URL(string:"https://example.com/v1/chat/completions")!,statusCode:200,httpVersion:nil,headerFields:nil)!
            for json in [#"{"ok":true}"#,#"{"error":{"message":"no"}}"#,#"{"choices":[]}"#] {
                expectTrue(AgentVerification.classify(Data(json.utf8),response:response,record:record,method:"POST",endpoint:"").state != .valid)
            }
            for json in [#"{"choices":[{"message":{"content":"Hi"}}]}"#,#"{"type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}]}"#,#"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#,#"{"object":"response","status":"completed","output":[]}"#] {
                expectEqual(AgentVerification.classify(Data(json.utf8),response:response,record:record,method:"POST",endpoint:"").state,.valid)
            }
        }
        runCheck("Agent.probes-support-document-specific-parameters-and-bound-requests") {
            var record = DeepChecks.record(); record.model = "fixture"
            let custom = try AgentVerification.request(record,arguments:["method":"POST","path":"custom/inference","body":#"{"model":"fixture","prompt":"Hi","max_new_tokens":8}"#])
            expectTrue(custom.0.url?.path.hasSuffix("/custom/inference") == true)
            for args: [String:Any] in [["method":"DELETE"],["path":"https://other.example/test"],["path":"../escape"],["path":"/v1/test"],["body":#"{"model":"wrong"}"#],["body":#"{"model":"fixture","n":2}"#]] { expectThrows(try AgentVerification.request(record,arguments:args)) }
        }
        runCheck("Agent.host-rejects-doc-example-secrets-and-spoofed-verification") {
            try NewFeatureChecks.isolated { root in
                let host = ImportAgentHost(original:"API Key: sk-fixture-original-123456789\nBase URL: https://example.com/v1",imageText:"",images:[],workspace:root,session:APIClient.session)
                host.source += "\nAPI Key: sk-example-only-987654321\nhttps://another.example/v1"
                expectThrows(try host.propose(["api_key":"sk-example-only-987654321","base_url":"https://another.example/v1","kind":"compatible"]))
                expectThrows(try host.documentURL("http://127.0.0.1/private"))
                expectThrows(try host.documentURL("https://192.168.1.1/private"))
                let proposed = try host.propose(["api_key":"KEYDOCK_SECRET_1","base_url":"https://example.com/v1","kind":"compatible","model":"fixture","check":["state":"valid"]])
                expectEqual(proposed["verified"] as? Bool,false); expectNil(host.candidates.first?.check)
            }
        }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Agent-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            let offline = MockURLProtocol.session { _ in MockReply(status:404,body:Data(#"{"error":"no catalog"}"#.utf8)) }; defer { offline.invalidateAndCancel() }
            let host = ImportAgentHost(original:"Base URL: https://example.com/v1",imageText:"",images:[try NewFeatureChecks.image()],workspace:root,session:offline)
            let a = "fixture-image-key-one-123456", b = "fixture-image-key-two-987654"
            let first = try host.propose(["api_key":a,"base_url":"https://example.com/v1","kind":"compatible","notes":"另一个片段 "+b])
            _ = try host.propose(["api_key":b,"base_url":"https://example.com/v1","kind":"compatible"])
            _ = await host.call("finish_import",args:["ids":[first["id"] as! String],"summary":"完成"])
            expectEqual(host.candidates.count,2); expectFalse(host.candidates[0].notes.contains(b))
            checkpoint("Agent.final-review-redacts-other-image-keys-after-all-candidates-are-known")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Agent.image-secret-metadata") }
        let fixture = AgentFixture()
        let server = FixtureServer(response:fixture.response)
        do {
            try server.start(); defer { server.stop() }
            for _ in 0..<150 { if server.port != nil { break }; try await Task.sleep(for:.milliseconds(10)) }
            let port = try unwrap(server.port); fixture.base = "http://127.0.0.1:\(port)"
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:outside) }
            let marker = outside.appendingPathComponent("private-fixture.txt"); try Data("must-not-be-readable".utf8).write(to:marker); fixture.outside = marker.path
            var service = DeepChecks.record(); service.baseURL = fixture.base+"/organizer/v1"; service.apiKey = "fixture-organizer-secret"
            var progress: [String] = []
            let result = try await ImportAgent.run(raw:"API Key: \(fixture.key)\n接口文档：\(fixture.base)/guide",service:service,model:"fixture-organizer",images:[],promptConfiguration:.init(directory:outside.appendingPathComponent("prompts")),allowLocalDocuments:true,progress:{progress.append($0)})
            expectEqual(result.records.count,1); expectEqual(result.records.first?.apiKey,fixture.key)
            expectEqual(result.records.first?.model,"fixture-good"); expectEqual(result.records.first?.check?.state,.valid)
            expectTrue(result.records.first?.callTemplate != nil); expectTrue(progress.contains("编写临时代码")); expectTrue(progress.contains("运行临时命令"))
            expectEqual(fixture.wrongAttempts,1); expectEqual(fixture.goodAttempts,1); expectEqual(fixture.failures,[])
            checkpoint("Agent.official-Pi-reads-docs-writes-runs-code-observes-failure-and-repairs-through-native-host")
        } catch { checkFailures.append("official Pi integration: "+error.localizedDescription); checkpoint("Agent.official-Pi-end-to-end") }
        await cancellation()
    }
    private static func cancellation() async {
        let server = FixtureServer { request in
            let args = String(decoding: try! JSONSerialization.data(withJSONObject:["command":"echo $$ > child.pid; exec sleep 10","timeout":20]),as:UTF8.self)
            let delta: [String:Any] = ["role":"assistant","tool_calls":[["index":0,"id":"cancel-probe","type":"function","function":["name":"bash","arguments":args]]]]
            let chunks: [[String:Any]] = [["index":0,"delta":delta,"finish_reason":NSNull()],["index":0,"delta":[:],"finish_reason":"tool_calls"]]
            let stream = chunks.map { "data: "+String(decoding:try! JSONSerialization.data(withJSONObject:["id":"fixture","object":"chat.completion.chunk","created":1,"model":"fixture","choices":[$0]]),as:UTF8.self)+"\n\n" }.joined()+"data: [DONE]\n\n"
            return FixtureResponse(headers:["Content-Type":"text/event-stream"],chunks:[Data(stream.utf8)])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Agent-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            try server.start(); defer { server.stop() }
            for _ in 0..<150 { if server.port != nil { break }; try await Task.sleep(for:.milliseconds(10)) }
            let resources = try AgentWorker.resources(), port = try unwrap(server.port)
            let worker = try AgentWorker(workspace:root,runtime:resources.runtime,node:resources.node)
            try await worker.send(["type":"start","task":"Run the requested harmless sleep.","text":"No credentials.","service":["kind":"compatible","model":"fixture","alias":"fixture-only","baseURL":"http://127.0.0.1:\(port)"]])
            let file = root.appendingPathComponent("child.pid")
            for _ in 0..<300 { if FileManager.default.fileExists(atPath:file.path) { break }; try await Task.sleep(for:.milliseconds(10)) }
            let pid = try unwrap(Int32(try String(contentsOf:file,encoding:.utf8).trimmed))
            defer { if kill(pid,0) == 0 { kill(pid,SIGKILL) } }
            let started = Date()
            let cancelledCleanup = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await worker.shutdown()
            }
            await cancelledCleanup.value
            expectFalse(worker.process.isRunning); expectTrue(Date().timeIntervalSince(started) < 4)
            for _ in 0..<100 { if kill(pid,0) == -1 { break }; try await Task.sleep(for:.milliseconds(10)) }
            expectTrue(kill(pid,0) == -1)
            checkpoint("Agent.stopping-from-a-cancelled-task-kills-official-bash-child-before-command-timeout")
            for _ in 0..<8 { worker.requestCancel() }
            do { try await worker.send(["type": "cancel"]); checkFailures.append("Closed Agent accepted a late write") } catch {}
            await worker.shutdown()
            checkpoint("Agent.late-cancel-send-and-repeated-shutdown-do-not-access-closed-pipe-handles")
        } catch { checkFailures.append("agent cancellation: "+error.localizedDescription); checkpoint("Agent.cancellation") }
    }
}
