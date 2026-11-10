import Foundation
import CryptoKit
import AppKit

@MainActor enum AgentTaskChecks {
    static func run() async {
        await AgentPromptChecks.run()
        await AgentEfficiencyChecks.run()
        await CapabilityAvailabilityChecks.run()
        await TaskLifecycleChecks.run()
        await transportFailures()
        runCheck("AgentTask.process-visibility-switch-restores-exact-values-without-changing-agent-or-persisted-redaction") {
            try NewFeatureChecks.isolated { root in
                let activity = AgentActivity(); activity.directory = root
                let secret = "2583abcd0123456789abcdef01234567"
                activity.begin(raw: "api-key: " + secret, service: DeepChecks.record(), model: "fixture")
                activity.note("request", detail: "Authorization: Bearer " + secret + "\napi_key: KEYDOCK_SECRET_1")
                expectFalse(activity.text.contains(secret))
                expectTrue(activity.displayText(showFullContent: true).contains("Authorization: Bearer " + secret))
                expectTrue(activity.displayText(showFullContent: true).contains("api_key: KEYDOCK_SECRET_1"))
                expectFalse(activity.displayText(showFullContent: false).contains(secret))
                activity.note("new sensitive value", detail: "fixture-discovered-secret")
                activity.addSecrets(["fixture-discovered-secret"])
                expectFalse(activity.text.contains("fixture-discovered-secret"))
                expectTrue(activity.displayText(showFullContent: true).contains("fixture-discovered-secret"))
                activity.finish("completed", detail: "done")
                activity.flush()
                let file = try unwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
                let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
                expectFalse(saved.contains(secret)); expectFalse(saved.contains("fixture-discovered-secret"))
            }
        }
        runCheck("AgentTask.explicit-HTTP-gateway-is-retained-by-parser-Agent-and-authenticated-probes") {
            let source = "直接用 CPA 集群\nhttp://198.51.100.12:8319\napi-key: fixture-http-key-123456\n模型：fixture-chat"
            let records = ImportParser.parse(source)
            expectTrue(records.first?.baseURL.hasPrefix("http://198.51.100.12:8319") == true)
            try NewFeatureChecks.isolated { root in
                let host = ImportAgentHost(original: source, imageText: "", images: [], workspace: root, session: APIClient.session)
                let result = try host.propose(["base_url":"http://198.51.100.12:8319/v1","api_key":"KEYDOCK_SECRET_1","model":"fixture-chat","kind":"compatible"])
                expectEqual(result["base_url"] as? String,"http://198.51.100.12:8319/v1")
                let request = try AgentVerification.request(try unwrap(host.candidates.first), arguments: [:]).0
                expectEqual(request.url?.scheme,"http"); expectEqual(request.url?.path,"/v1/chat/completions")
                expectEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer fixture-http-key-123456")
            }
            expectThrows(try APIClient.safeURL("file:///etc/passwd")); expectThrows(try APIClient.safeURL("ftp://example.com"))
        }
        runCheck("AgentTask.diagnostic-log-persists-real-events-without-credentials-or-image-bytes") {
            try NewFeatureChecks.isolated { root in
                let activity = AgentActivity(); activity.directory = root
                var service = DeepChecks.record(); service.model = "fixture-model"
                activity.begin(raw:"Base URL: https://example.com/v1\nAPI Key: fixture-import-key-778899",service:service,model:service.model)
                activity.update(id:"tool-1",title:"bash",detail:"node extract.mjs\nfixture-import-key-778899\n"+service.apiKey,state:"running")
                activity.update(id:"tool-1",title:"bash",detail:"node extract.mjs\nEXTRACTED_MODEL: fixture-model",state:"completed")
                let picture = try NewFeatureChecks.image().data.base64EncodedString()
                activity.note("附件回显", detail: "data:image/jpeg;base64," + picture)
                activity.note("HTTP 404",detail:"model_not_found"); activity.finish("failed",detail:"请使用实际部署 ID")
                activity.flush()
                let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
                let file = try unwrap(files.first); let bytes = try Data(contentsOf:file), text = String(decoding:bytes,as:UTF8.self)
                expectFalse(text.contains(service.apiKey)); expectFalse(text.contains("fixture-import-key-778899"))
                expectTrue(text.contains("model_not_found")); expectTrue(text.contains("EXTRACTED_MODEL")); expectFalse(text.contains(picture))
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                expectEqual(try decoder.decode(AgentRunRecord.self,from:bytes).status,"failed")
                expectEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
                expectEqual(activity.entries.filter { $0.id=="tool-1" }.count,1)
            }
        }
        runCheck("AgentTask.log-retention-is-bounded-and-stopping-freezes-the-current-run") {
            let activity = AgentActivity(), record = DeepChecks.record()
            expectFalse(activity.active); activity.finish("stopped", detail: "未开始的界面关闭"); expectTrue(activity.entries.isEmpty)
            activity.begin(raw:"API Key: fixture-log-key-1234",service:record,model:"fixture-model")
            for index in 0..<400 { activity.note("step \(index)", detail:String(repeating:"诊断文本。",count:800)) }
            expectTrue(activity.entries.count <= 250); expectTrue(activity.entries.reduce(0) { $0+$1.detail.utf8.count+$1.title.utf8.count } <= 524_288)
            activity.finish("stopped",detail:"已停止"); let count=activity.entries.count
            activity.note("late-event"); expectEqual(activity.entries.count,count); expectEqual(activity.record.status,"stopped")
        }
        runCheck("AgentTask.original-images-survive-host-review-encrypted-vault-and-portable-backup") {
            try NewFeatureChecks.isolated { root in
                let image=try NewFeatureChecks.image(), source="API Key: sk-fixture-picture-123456789\nBase URL: https://example.com/v1\n[图片 1]"
                let host=ImportAgentHost(original:source,imageText:"image OCR",images:[image],workspace:root,session:APIClient.session)
                _ = try host.propose(["api_key":"KEYDOCK_SECRET_1","base_url":"https://example.com/v1","kind":"compatible","model":"fixture-model"])
                let record=try unwrap(host.reviewResult().records.first)
                expectEqual(record.source,source); expectEqual(record.sourceImages?.first?.data,image.data)
                let key=SymmetricKey(size:.bits256),disk=EncryptedVault(directory:root,keyProvider:{key})
                try disk.save(VaultData(credentials:[record])); expectEqual(try disk.load().credentials.first?.sourceImages,[image])
                let bytes=try PortableBackup.create(VaultData(credentials:[record]),password:"fixture-image-backup")
                expectEqual(try PortableBackup.restore(bytes,password:"fixture-image-backup").credentials.first?.sourceImages,[image])
                expectFalse(record.shareText.contains(image.data.base64EncodedString()))
                let legacy=try JSONDecoder().decode(Credential.self,from:JSONEncoder().encode(DeepChecks.record()))
                expectNil(legacy.sourceImages)
            }
        }
        runCheck("AgentTask.reimport-and-backup-can-fill-missing-original-images-without-duplicating-or-overwriting-a-Key") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var original = DeepChecks.record(); original.source = "original source"; original.check = CheckResult(state: .valid, message: "existing proof", requestMethod: "POST")
                expectTrue(store.importRecords([original]))
                var incoming = original; incoming.id = UUID(); incoming.source = "new source"; incoming.sourceImages = [try NewFeatureChecks.image()]; incoming.check = nil
                expectTrue(store.importRecords([incoming])); expectEqual(store.credentials.count, 1)
                expectEqual(store.selected?.sourceImages, incoming.sourceImages); expectEqual(store.selected?.source, "original source")
                expectEqual(store.selected?.check, original.check)
                var missing = original; missing.id = UUID(); missing.apiKey = "fixture-other-picture-key"; expectTrue(store.importRecords([missing]))
                var backedUp = missing; backedUp.sourceImages = incoming.sourceImages
                expectTrue(store.restore(VaultData(credentials: [backedUp])))
                expectEqual(store.credentials.first { $0.id == missing.id }?.sourceImages, incoming.sourceImages)
            }
        }
        runCheck("AgentTask.organizer-uses-its-models-remembered-protocol-without-changing-the-project-choice") {
            var service = DeepChecks.record(); service.model = "project-model"; service.kind = .anthropic; service.auth = .xAPIKey
            service.modelProtocols = ["project-model": .anthropic, "organizer-model": .responses]
            let selected = service.usingModel("organizer-model")
            expectEqual(selected.model, "organizer-model"); expectEqual(selected.inferenceKind, .responses)
            expectEqual(try APIClient.modelRequest(for: selected).url?.path, "/v1/responses")
            expectEqual(service.model, "project-model"); expectEqual(service.inferenceKind, .anthropic)
            var legacy = service; legacy.modelProtocols = nil
            expectEqual(legacy.usingModel("legacy-model").inferenceKind, .anthropic)
        }
        await verificationMemory()
    }
    static func transportFailures() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Transport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = MockURLProtocol.session { _ in MockReply(error: URLError(.appTransportSecurityRequiresSecureConnection)) }
            defer { session.invalidateAndCancel() }
            let source = "http://198.51.100.12:8319\napi-key: fixture-http-key-123456"
            let host = ImportAgentHost(original: source, imageText: "", images: [], workspace: root, session: session)
            let draft = try host.propose(["base_url": "http://198.51.100.12:8319/v1", "api_key": "KEYDOCK_SECRET_1", "kind": "compatible", "model": "fixture-chat"])
            let catalog = await host.call("list_models", args: ["id": draft["id"]!])
            expectTrue((catalog["message"] as? String ?? "").contains("-1022"))
            expectTrue((catalog["endpoint"] as? String ?? "").hasSuffix("/v1/models"))
            let result = await host.call("verify_credential", args: ["id": draft["id"]!])
            expectEqual(result["error_code"] as? Int, NSURLErrorAppTransportSecurityRequiresSecureConnection)
            expectTrue((result["error"] as? String ?? "").contains("应用网络配置"))
            expectEqual(host.candidates.first?.check?.requestMethod, "POST")
            expectTrue(host.candidates.first?.check?.endpoint.hasSuffix("/v1/chat/completions") == true)
            checkpoint("AgentTask.transport-errors-preserve-ATS-cause-and-attempted-request-for-models-and-verification")
            let docs = MockURLProtocol.session { _ in MockReply(body: Data("Public gateway documentation".utf8)) }
            defer { docs.invalidateAndCancel() }
            let docHost = ImportAgentHost(original: source, imageText: "", images: [], workspace: root, session: docs)
            docHost.allowLocalDocuments = true
            let document = await docHost.call("fetch_document", args: ["url": "http://198.51.100.12:8319/"])
            expectEqual(document["ok"] as? Bool, true)
            let unknown = await docHost.call("fetch_document", args: ["url": "http://198.51.100.12:8319/private"])
            expectEqual(unknown["ok"] as? Bool, false)
            checkpoint("AgentTask.provided-origin-with-or-without-root-slash-is-readable-without-authorizing-other-paths")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("AgentTask.transport-regressions-complete") }
    }
    static func verificationMemory() async {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Task-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        do {
            let key=SymmetricKey(size:.bits256),disk=EncryptedVault(directory:root,keyProvider:{key}),store=VaultStore(disk:disk,automaticProxy:false)
            var record=DeepChecks.record(); record.model="fixture-a"; expectTrue(store.save(record))
            let session=MockURLProtocol.session { _ in MockReply(body:Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)) }; defer { session.invalidateAndCancel() }
            await store.verify(try unwrap(store.selected),session:session,testModel:true)
            let first=try unwrap(store.selected?.check)
            store.selectModel("fixture-b",for:try unwrap(store.selected)); expectNil(store.selected?.check)
            await store.verify(try unwrap(store.selected),session:session,testModel:true)
            let second=try unwrap(store.selected?.check)
            store.selectModel("fixture-a",for:try unwrap(store.selected)); expectEqual(store.selected?.check,first)
            store.selectModel("fixture-b",for:try unwrap(store.selected)); expectEqual(store.selected?.check,second)
            checkpoint("AgentTask.switching-models-restores-their-last-request-response-status-and-date")
            store.selectProtocol(.responses,for:try unwrap(store.selected)); expectNil(store.selected?.check)
            store.selectProtocol(.compatible,for:try unwrap(store.selected)); expectEqual(store.selected?.check,second)
            let reopened=VaultStore(disk:disk,automaticProxy:false)
            reopened.selectModel("fixture-a",for:try unwrap(reopened.selected)); expectEqual(reopened.selected?.check,first)
            checkpoint("AgentTask.verification-history-survives-protocol-switches-and-reload")
            reopened.selectModel("fixture-b",for:try unwrap(reopened.selected))
            let limited=MockURLProtocol.session { _ in MockReply(status:429,body:Data(#"{"error":{"message":"fixture rate limited"}}"#.utf8)) }
            await reopened.verify(try unwrap(reopened.selected),session:limited,testModel:true); limited.invalidateAndCancel()
            let failure=try unwrap(reopened.selected?.check); expectEqual(failure.state,.quota)
            reopened.selectModel("fixture-a",for:try unwrap(reopened.selected)); expectEqual(reopened.selected?.check,first)
            reopened.selectModel("fixture-b",for:try unwrap(reopened.selected)); expectEqual(reopened.selected?.check,failure)
            checkpoint("AgentTask.failed-verification-is-also-restored-without-erasing-another-models-result")
            var changed=try unwrap(reopened.selected); changed.apiKey="fixture-replaced-credential"; expectTrue(reopened.save(changed))
            expectNil(reopened.selected?.check); expectNil(reopened.selected?.verificationHistory)
            reopened.selectModel("fixture-b",for:try unwrap(reopened.selected)); expectNil(reopened.selected?.check)
            checkpoint("AgentTask.changing-authentication-does-not-restore-an-obsolete-passed-result")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("AgentTask.verification-memory-completes") }
    }
}
