import Foundation
import CryptoKit
import AppKit

@MainActor enum WorkflowChecks {
    static func run() async {
        await shellExamples()
        roundTrip()
        editor()
        draftEdits()
        await metadataDuringRequests()
        await batchUpdates()
        authenticationMaterial()
        await diagnosticEvidence()
    }
    struct ShellResult { var status:Int32; var data:Data }
    static func shell(_ script:String, root:URL, environment:[String:String]) async throws -> ShellResult {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath:"/bin/bash")
            process.arguments = ["--noprofile","--norc","-c",script]
            process.currentDirectoryURL = root; process.environment = environment
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return ShellResult(status:process.terminationStatus,data:data)
        }.value
    }
    static func shellExamples() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            let bin = root.appendingPathComponent("bin"); try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
            let fake = bin.appendingPathComponent("curl"), captured = root.appendingPathComponent("arguments.bin")
            try Data("#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$KEYDOCK_ARGS_FILE\"\n".utf8).write(to:fake)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:fake.path)
            var record = DeepChecks.record(); record.variablePrefix = "WORKFLOW_A"; record.model = "fixture-model"
            let environment = ["PATH":bin.path+":/usr/bin:/bin","KEYDOCK_ARGS_FILE":captured.path,"LANG":"C"]
            let result = try await shell(record.localCurl,root:root,environment:environment)
            expectEqual(result.status,0)
            let args = String(decoding:try Data(contentsOf:captured),as:UTF8.self).split(separator:"\0").map(String.init)
            expectTrue(args.contains(record.localBaseURL+"/chat/completions")); expectTrue(args.contains("Authorization: Bearer "+record.localKey))
            expectFalse(record.localCurl.contains(record.apiKey)); expectFalse(record.safeShareText.contains(record.apiKey))
            expectTrue(record.safeShareText.contains(":-"+record.localKey+"}"))
            expectFalse(ImportParser.keys(in:record.localCurl).contains("-"+record.localKey))
            checkpoint("Workflow.copied-curl-runs-without-setting-any-environment-variables")
            record.callTemplate = ModelCallTemplate(path:"responses/$(touch injected-marker)`touch injected-marker`",body:#"{"model":"fixture-model","input":"quote ' and $(touch injected-marker)","max_output_tokens":8}"#,model:"fixture-model")
            let safe = try await shell(record.localCurl,root:root,environment:environment)
            expectEqual(safe.status,0); expectFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("injected-marker").path))
            let safeArgs = String(decoding:try Data(contentsOf:captured),as:UTF8.self).split(separator:"\0").map(String.init)
            let url = try unwrap(safeArgs.first { $0.hasPrefix(record.localBaseURL) })
            expectTrue(url.contains("$(touch%20injected-marker)")); expectTrue(url.contains("%60touch%20injected-marker%60"))
            expectTrue(safeArgs.contains { $0.contains("quote ' and $(touch injected-marker)") })
            checkpoint("Workflow.curl-treats-document-paths-and-request-bodies-as-literal-data")
            await realCurl(root:root)
            await directUsage(root:root)
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Workflow.shell") }
    }
    static func realCurl(root:URL) async {
        let server = FixtureServer { _ in FixtureResponse(chunks:[Data(#"{"choices":[{"message":{"role":"assistant","content":"fixture-ok"}}],"echo":"fixture-extra-12345"}"#.utf8)]) }
        let proxy = LocalProxy(port:0)
        do {
            try server.start(); defer { server.stop() }; await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"; record.variablePrefix = "WORKFLOW_B"; record.model = "fixture-model"
            record.extraHeaders = "X-Project: fixture-project\nX-Token-Id: fixture-extra-12345"
            record.callTemplate = ModelCallTemplate(path:"responses",body:#"{"model":"fixture-model","input":"hello","max_output_tokens":8}"#,model:"fixture-model")
            var entries:[ProxyLogEntry] = []
            proxy.recordHistory(captureBodies:[record.id]) { entry in Task { @MainActor in entries.append(entry) } }
            proxy.update([record]); proxy.start(); defer { proxy.stop() }; await InteractionFlowChecks.wait { proxy.running }
            let environment = ["PATH":"/usr/bin:/bin","LANG":"C","WORKFLOW_B_BASE_URL":"http://127.0.0.1:\(try unwrap(proxy.listeningPort))/s/"+record.routeID,"WORKFLOW_B_API_KEY":record.localKey]
            // -q avoids user curl configuration; the test never contacts the production proxy.
            let script = "curl() { /usr/bin/curl -q --noproxy '*' --silent --show-error --max-time 3 \"$@\"; }\n"+record.localCurl
            let result = try await shell(script,root:root,environment:environment)
            expectEqual(result.status,0); expectTrue(String(decoding:result.data,as:UTF8.self).contains("fixture-ok"))
            let request = try unwrap(server.received.last)
            expectEqual(request.target,"/v1/responses"); expectEqual(request.method,"POST")
            expectEqual(request.headers["authorization"],"Bearer "+record.apiKey)
            expectEqual(request.headers["x-project"],"fixture-project"); expectEqual(request.headers["x-token-id"],"fixture-extra-12345")
            let body = try unwrap(try JSONSerialization.jsonObject(with:request.body) as? [String:Any]); expectEqual(body["model"] as? String,"fixture-model")
            expectEqual(body["input"] as? String,"hello"); expectNil(body["max_output_tokens"])
            checkpoint("Workflow.real-curl-honors-project-variables-and-forwards-the-saved-template-and-native-authentication")
            await InteractionFlowChecks.wait { !entries.isEmpty }
            expectTrue(entries.first?.requestHeaders.contains("fixture-extra-12345") == true)
            expectTrue(entries.first?.responseBody.contains("fixture-extra-12345") == true)
            expectFalse(entries.first?.responseBody.contains("已隐藏") == true)
            checkpoint("Workflow.real-proxy-retains-auxiliary-authentication-echoes-in-local-request-and-response-logs")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Workflow.real-curl") }
    }
    static func directUsage(root: URL) async {
        let server = FixtureServer { _ in FixtureResponse(chunks:[Data(#"{"result":"direct-fixture-ok"}"#.utf8)]) }
        do {
            try server.start(); defer { server.stop() }; await InteractionFlowChecks.wait { server.port != nil }
            let saved = root.appendingPathComponent("direct-environment.bin")
            let environment = ["PATH":"/usr/bin:/bin","LANG":"C","KEYDOCK_ENV_FILE":saved.path]
            let cases: [(ServiceKind, AuthKind)] = [(.compatible,.bearer),(.anthropic,.xAPIKey),(.gemini,.googleKey),(.compatible,.apiKey),(.compatible,.none)]
            for (kind, auth) in cases {
                var record = DeepChecks.record(); record.kind = kind; record.auth = auth
                record.name = "fixture\n$(touch injected-marker)"; record.variablePrefix = "WORKFLOW_REAL"; record.model = "fixture-model"
                record.apiKey = auth == .none ? "" : "fixture-'$(touch injected-marker)`touch injected-marker`-123456"
                record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/tenant/" + (kind == .gemini ? "v1beta" : "v1")
                record.extraHeaders = "X-Project: fixture-project\nX-Token-Id: fixture-extra-54321"
                if kind == .compatible {
                    record.callTemplate = ModelCallTemplate(path:"responses",body:#"{"model":"fixture-model","input":"quote ' and $(touch injected-marker)","max_output_tokens":8}"#,model:"fixture-model")
                }
                let expected = try APIClient.modelRequest(for:record), text = record.realUsageText
                expectTrue(record.canCopyUsage); expectFalse(text.contains(record.localKey)); expectFalse(text.contains(record.localBaseURL))
                let script = "curl() { /usr/bin/curl -q --noproxy '*' --silent --show-error --max-time 3 \"$@\"; }\n" + text + "\nprintf '%s\\0' \"${WORKFLOW_REAL_BASE_URL}\" \"${WORKFLOW_REAL_API_KEY}\" \"${WORKFLOW_REAL_MODEL}\" > \"$KEYDOCK_ENV_FILE\"\n"
                let result = try await shell(script,root:root,environment:environment)
                expectEqual(result.status,0); expectTrue(String(decoding:result.data,as:UTF8.self).contains("direct-fixture-ok"))
                let request = try unwrap(server.received.last)
                expectEqual(request.target,try unwrap(URLComponents(url:try unwrap(expected.url),resolvingAgainstBaseURL:false)).percentEncodedPath)
                expectEqual(request.method,"POST"); expectEqual(request.body,expected.httpBody ?? Data())
                for (name,value) in expected.allHTTPHeaderFields ?? [:] { expectEqual(request.headers[name.lowercased()],value) }
                let values = String(decoding:try Data(contentsOf:saved),as:UTF8.self).split(separator:"\0",omittingEmptySubsequences:false).map(String.init)
                expectEqual(Array(values.prefix(3)),[record.baseURL,record.apiKey,record.model])
                expectFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("injected-marker").path))
                checkpoint("Workflow.real-usage-exports-and-runs-directly-without-KeyDock-\(kind.rawValue)-\(auth.rawValue)")
            }
            var custom = DeepChecks.record(); custom.kind = .custom; custom.auth = .apiKey; custom.model = ""
            custom.extraHeaders = "X-Project: fixture-project"; custom.notes = "not-for-usage-copy"; custom.source = "not-for-usage-source"
            let text = custom.realUsageText
            expectTrue(text.contains(custom.apiKey)); expectTrue(text.contains("Api-Key: "+custom.apiKey) || text.contains("Api-key: "+custom.apiKey) || text.contains("api-key: "+custom.apiKey))
            expectTrue(text.contains("X-Project: fixture-project")); expectFalse(text.contains("curl --request POST"))
            expectFalse(text.contains(custom.notes)); expectFalse(text.contains(custom.source)); expectFalse(text.contains(custom.localKey))
            checkpoint("Workflow.real-usage-for-custom-services-keeps-authentication-without-inventing-a-model-call")
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            let key = SymmetricKey(size:.bits256)
            let store = VaultStore(disk:EncryptedVault(directory:root.appendingPathComponent("direct-copy-vault"),keyProvider:{key}),automaticProxy:false,pasteboard:board)
            var record = DeepChecks.record(); record.model = "fixture-model"; expectTrue(store.save(record)); record = try unwrap(store.selected)
            let realText = store.configuredForUse(record).realUsageText
            store.copy(realText,sensitive:true); expectEqual(board.string(forType:.string),realText); expectTrue(board.string(forType:.string)?.contains(record.apiKey) == true)
            store.clearSensitiveClipboard(); expectNil(board.string(forType:.string))
            store.copy(store.configuredForUse(record).safeShareText); expectFalse(board.string(forType:.string)?.contains(record.apiKey) == true)
            expectTrue(board.string(forType:.string)?.contains(record.localKey) == true)
            checkpoint("Workflow.real-usage-uses-sensitive-clipboard-while-normal-usage-keeps-local-aliases")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Workflow.real-usage") }
    }
    static func diagnosticEvidence() async {
        let server = FixtureServer { request in
            let json = request.target.hasSuffix("messages") ? #"{"type":"message","role":"assistant","content":[{"type":"text","text":"hello"}]}"# : #"{"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}"#
            return FixtureResponse(chunks:[Data(json.utf8)])
        }
        do {
            try server.start(); defer { server.stop() }; await InteractionFlowChecks.wait { server.port != nil }
            for kind in [ServiceKind.anthropic,.gemini] {
                var record = DeepChecks.record(); record.kind = kind; record.auth = kind == .gemini ? .googleKey : .xAPIKey
                record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))"; record.model = "fixture-model"
                let result = await APIClient.verify(record,testModel:true)
                expectEqual(result.state,.valid); expectEqual(result.requestMethod,"POST"); expectEqual(result.actionTitle,"调用验证")
                let request = try unwrap(server.received.last)
                expectEqual(request.target,kind == .gemini ? "/v1beta/models/fixture-model:generateContent" : "/v1/messages")
                expectEqual(request.headers[kind == .gemini ? "x-goog-api-key" : "x-api-key"],record.apiKey)
                let body = try unwrap(try JSONSerialization.jsonObject(with:request.body) as? [String:Any])
                let budget = kind == .gemini ? (body["generationConfig"] as? [String:Any])?["maxOutputTokens"] as? Int : body["max_tokens"] as? Int
                if kind == .anthropic { expectTrue((budget ?? 0) > 0 && (budget ?? 1000) <= 128) } else { expectNil(budget) }
                record.check = result; expectEqual(record.stateTitle,"调用通过")
                record.check = CheckResult(state:.valid,message:"catalog",requestMethod:"GET"); expectEqual(record.stateTitle,"连接正常")
                record.expiresAt = Date().addingTimeInterval(-5); expectEqual(record.stateTitle,"已到期")
                checkpoint("Workflow.native-call-verification-is-bounded-and-keeps-its-real-evidence-\(kind.rawValue)")
            }
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Workflow.native-diagnostics") }
        let session = MockURLProtocol.session { _ in MockReply(error:URLError(.timedOut)) }; defer { session.invalidateAndCancel() }
        var record = DeepChecks.record(); record.model = "fixture-model"
        let expected = try! APIClient.modelTestRequest(for:record)
        let result = await APIClient.verify(record,session:session,testModel:true)
        expectEqual(result.state,.uncertain); expectEqual(result.requestMethod,"POST"); expectEqual(result.endpoint,expected.url?.absoluteString)
        checkpoint("Workflow.failed-call-verification-keeps-the-attempted-method-and-address")
        runCheck("Workflow.document-based-POST-authentication-errors-use-call-evidence") {
            record.baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
            record.callTemplate = ModelCallTemplate(path:"chat/completions",body:#"{"model":"fixture-model","messages":[{"role":"user","content":"Hi"}],"max_tokens":8}"#,model:"fixture-model")
            let url = URL(string:record.baseURL+"/chat/completions")!
            let response = HTTPURLResponse(url:url,statusCode:401,httpVersion:nil,headerFields:nil)!
            let value = AgentVerification.classify(Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8),response:response,record:record,method:"POST",endpoint:url.absoluteString)
            expectEqual(value.state,.invalid); expectEqual(value.requestMethod,"POST"); expectEqual(value.endpoint,url.absoluteString)
        }
    }
    static func roundTrip() {
        runCheck("Workflow.known-share-format-keeps-incomplete-drafts-without-claiming-verification") {
            var record = DeepChecks.record(); record.apiKey = ""; record.model = ""; record.notes = "稍后补密钥"
            let restored = try unwrap(ImportParser.parse(record.shareText).first)
            expectEqual(restored.apiKey,""); expectEqual(restored.baseURL,record.baseURL); expectEqual(restored.notes,record.notes)
            expectNil(restored.check); expectFalse(restored.canCopyUsage); expectFalse(restored.canOrganize)
        }
        runCheck("Workflow.full-sharing-roundtrips-request-authentication-and-service-metadata-without-trusting-checks") {
            for kind in ServiceKind.allCases {
                var record = DeepChecks.record(); record.kind = kind; record.auth = kind == .gemini ? .googleKey : (kind == .anthropic ? .xAPIKey : .apiKey)
                record.provider = "自有网关"; record.baseURL = "https://example.com/platform/models"; record.model = "fixture-model"
                record.extraHeaders = "X-Project: private-project\nX-Token-Id: private-extra-12345"
                record.docsURL = "https://docs.example.com/api"; record.notes = "多行备注\n第二行 'quote'"; record.tags = "work,test"; record.purpose = "接口联调"
                record.verificationURL = "https://example.com/check"; record.balanceURL = "https://example.com/balance"; record.balancePath = "data.remaining"; record.balanceUnit = "CNY"
                record.expiresAt = Date(timeIntervalSince1970:1900000000)
                record.callTemplate = ModelCallTemplate(path:"responses",body:#"{"model":"fixture-model","input":"Hi","max_output_tokens":8}"#,model:"fixture-model")
                record.check = CheckResult(state:.valid,message:"must not travel"); record.modelCatalog = ModelCatalog(models:["private-cache"])
                record.source = "OTHER_KEY=sk-another-record-not-for-sharing-123456789"; record.balanceSummary = "private account data"
                let text = record.shareText, restored = try unwrap(ImportParser.parse(text).first)
                expectFalse(text.contains("sk-another-record")); expectFalse(text.contains("private-cache")); expectFalse(text.contains("private account data")); expectFalse(text.contains("must not travel"))
                expectEqual(restored.baseURL,record.baseURL); expectEqual(restored.apiKey,record.apiKey); expectEqual(restored.kind,record.kind); expectEqual(restored.auth,record.auth)
                expectEqual(restored.extraHeaders,record.extraHeaders); expectEqual(restored.callTemplate,record.callTemplate)
                expectEqual(restored.docsURL,record.docsURL); expectEqual(restored.notes,record.notes); expectEqual(restored.purpose,record.purpose); expectEqual(restored.tags,record.tags)
                expectEqual(restored.balanceURL,record.balanceURL); expectEqual(restored.balancePath,record.balancePath); expectEqual(restored.balanceUnit,record.balanceUnit); expectEqual(restored.expiresAt,record.expiresAt)
                expectNil(restored.check); expectNil(restored.modelCatalog); expectNotEqual(restored.id,record.id)
                if kind != .custom {
                    let before = try APIClient.modelRequest(for:record), after = try APIClient.modelRequest(for:restored)
                    expectEqual(before.url,after.url); expectEqual(before.allHTTPHeaderFields,after.allHTTPHeaderFields); expectEqual(before.httpBody,after.httpBody)
                }
                try NewFeatureChecks.isolated { folder in
                    let key = SymmetricKey(size:.bits256), disk = EncryptedVault(directory:folder,keyProvider:{key})
                    let store = VaultStore(disk:disk,automaticProxy:false)
                    expectTrue(store.importRecords([restored])); let saved = try unwrap(try disk.load().credentials.first)
                    expectEqual(saved.extraHeaders,record.extraHeaders); expectEqual(saved.callTemplate,record.callTemplate); expectNil(saved.check)
                }
            }
        }
        runCheck("Workflow.sharing-public-custom-service-does-not-invent-a-model-or-lose-no-authentication") {
            var record = DeepChecks.record(); record.kind = .custom; record.apiKey = ""; record.auth = .none; record.model = ""; record.verificationURL = "https://example.com/health"
            let text = record.shareText; expectFalse(text.contains("curl --request POST"))
            let restored = try unwrap(ImportParser.parse(text).first); expectEqual(restored.auth,.none); expectEqual(restored.apiKey,""); expectEqual(restored.kind,.custom)
            expectEqual(try APIClient.verificationRequest(for:restored).url?.absoluteString,record.verificationURL)
        }
    }
    static func editor() {
        runCheck("Workflow.organizer-service-requires-usable-connection-but-allows-a-separately-selected-model") {
            var record = DeepChecks.record(); record.model = ""
            expectTrue(record.canOrganize)
            record.apiKey = ""; expectFalse(record.canOrganize)
            record.auth = .none; expectTrue(record.canOrganize)
            record.archived = true; expectFalse(record.canOrganize)
            record.archived = false; record.expiresAt = Date().addingTimeInterval(-10); expectFalse(record.canOrganize)
            record.expiresAt = nil; record.kind = .custom; expectFalse(record.canOrganize)
        }
        runCheck("Workflow.editing-notes-never-changes-a-compatible-gateway-protocol-from-a-provider-label") {
            for provider in ["Google Gemini","Anthropic"] {
                var record = DeepChecks.record(); record.provider = provider; record.kind = .compatible; record.auth = .apiKey; record.model = "gemini-via-gateway"
                record.callTemplate = ModelCallTemplate(path:"chat/completions",body:#"{"model":"gemini-via-gateway","messages":[],"max_tokens":8}"#,model:record.model)
                record.notes = "仅修改备注"
                let saved = CredentialEditor.preparedForSave(record)
                expectEqual(saved.kind,.compatible); expectEqual(saved.auth,.apiKey); expectEqual(saved.callTemplate,record.callTemplate); expectEqual(saved.model,record.model)
                expectEqual(saved.notes,"仅修改备注")
            }
        }
        runCheck("Workflow.switching-provider-preset-removes-stale-service-settings-but-preserves-identity") {
            var record = DeepChecks.record(); record.model = "old-model"; record.extraHeaders = "X-Project: old-private-project"; record.auth = .apiKey
            record.verificationURL = "https://old.example/verify"; record.balanceURL = "https://old.example/balance"; record.balanceSummary = "old balance"
            record.callTemplate = ModelCallTemplate(path:"old/endpoint",body:"{}"); record.modelCatalog = ModelCatalog(models:["old-model"]); record.check = CheckResult(state:.valid,message:"old")
            record.variablePrefix = "PROJECT_KEEP"; record.notes = "用户备注"
            let changed = CredentialEditor.applyingPreset(to:record,name:"DeepSeek",kind:.compatible,url:"https://api.deepseek.com",docs:"https://api-docs.deepseek.com/")
            expectEqual(changed.id,record.id); expectEqual(changed.variablePrefix,"PROJECT_KEEP"); expectEqual(changed.notes,record.notes)
            expectEqual(changed.apiKey,""); expectEqual(changed.model,""); expectEqual(changed.extraHeaders,""); expectEqual(changed.auth,.bearer)
            expectEqual(changed.verificationURL,""); expectEqual(changed.balanceURL,""); expectEqual(changed.balanceSummary,""); expectNil(changed.callTemplate); expectNil(changed.modelCatalog); expectNil(changed.check)
            var entered = Credential(); entered.apiKey = "sk-fixture-pasted-before-preset-12345678"
            expectEqual(CredentialEditor.applyingPreset(to:entered,name:"DeepSeek",kind:.compatible,url:"https://api.deepseek.com",docs:"").apiKey,entered.apiKey)
        }
        runCheck("Workflow.incomplete-connection-has-an-actionable-copy-reason") {
            var record = DeepChecks.record(); record.model = "fixture"; record.baseURL = ""
            expectFalse(record.canCopyUsage); expectTrue(record.usageIssue?.contains("Base URL") == true)
            record.baseURL = "https://example.com/v1"; record.apiKey = ""; expectFalse(record.canCopyUsage); expectTrue(record.usageIssue?.contains("API Key") == true)
            record.apiKey = "sk-fixture-123456789"; record.extraHeaders = "Host: invalid.example"; expectFalse(record.canCopyUsage)
            record.extraHeaders = ""; expectTrue(record.canCopyUsage)
        }
    }

    static func draftEdits() {
        runCheck("Workflow.import-keeps-user-variable-prefixes-and-resolves-collisions-without-changing-route-identity") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size:.bits256), store = VaultStore(disk:EncryptedVault(directory:root,keyProvider:{key}),automaticProxy:false)
                var first = DeepChecks.record(); first.variablePrefix = " my_project "
                var second = first; second.id = UUID(); second.apiKey = "sk-fixture-second-123456789"
                expectTrue(store.importRecords([first,second]))
                expectEqual(store.credentials.first { $0.id == first.id }?.envPrefix,"MY_PROJECT")
                expectEqual(store.credentials.first { $0.id == second.id }?.envPrefix,"MY_PROJECT_2")
                expectEqual(Set(store.credentials.map(\.id)),[first.id,second.id])
                var third = first; third.id = UUID(); third.apiKey = "sk-fixture-third-123456789"; third.variablePrefix = "PATH"
                expectTrue(store.importRecords([third])); expectNotEqual(store.credentials.first { $0.id == third.id }?.envPrefix,"PATH")
                var longA = first; longA.id = UUID(); longA.apiKey = "sk-fixture-long-a-123456789"; longA.variablePrefix = String(repeating:"P",count:56)
                var longB = longA; longB.id = UUID(); longB.apiKey = "sk-fixture-long-b-123456789"
                expectTrue(store.importRecords([longA,longB]))
                let a = try unwrap(store.credentials.first { $0.id == longA.id }), b = try unwrap(store.credentials.first { $0.id == longB.id })
                expectNotEqual(a.envPrefix,b.envPrefix); expectTrue(a.envPrefix.count <= 56 && b.envPrefix.count <= 56)
                let saved = try store.disk.load(); expectEqual(saved.credentials.first { $0.id == second.id }?.envPrefix,"MY_PROJECT_2")
            }
        }
        runCheck("Workflow.incomplete-connection-cannot-install-a-dead-system-alias") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size:.bits256), store = VaultStore(disk:EncryptedVault(directory:root,keyProvider:{key}),automaticProxy:false)
                var record = DeepChecks.record(); record.apiKey = ""
                expectTrue(store.importRecords([record])); let invalid = try unwrap(store.selected)
                store.toggleSystemEnvironment(invalid)
                expectTrue(store.installedEnvironmentIDs.isEmpty); expectTrue(store.error?.contains("API Key") == true)
                expectFalse(FileManager.default.fileExists(atPath:store.userEnvironment.registry.path))
                var complete = invalid; complete.apiKey = "sk-fixture-valid-123456789"; complete.model = ""
                expectTrue(store.save(complete)); store.error = nil
                let current = try unwrap(store.selected); store.toggleSystemEnvironment(current)
                expectTrue(store.installedEnvironmentIDs.contains(current.id)); expectNil(store.error)
                store.toggleSystemEnvironment(current); expectTrue(store.installedEnvironmentIDs.isEmpty)
            }
        }
        runCheck("Workflow.note-only-draft-edit-preserves-a-newer-verification-and-generated-template") {
            var original = DeepChecks.record(); original.model = "fixture"
            var current = original
            current.check = CheckResult(state:.valid,message:"just verified",requestMethod:"POST")
            current.callTemplate = ModelCallTemplate(path:"chat/completions",body:#"{"model":"fixture","messages":[],"max_tokens":32}"#,model:"fixture")
            current.modelCatalog = ModelCatalog(models:["fixture"])
            var edited = original; edited.notes = "仅补充备注"
            let result = ImportView.mergingDraftEdit(edited,original:original,current:current)
            expectEqual(result.notes,edited.notes); expectEqual(result.check,current.check); expectEqual(result.callTemplate,current.callTemplate); expectEqual(result.modelCatalog,current.modelCatalog)
            expectTrue(original.hasSameVerificationConfiguration(as:edited))
        }
        runCheck("Workflow.draft-probe-address-edits-invalidate-old-verification") {
            var original = DeepChecks.record(); original.model = "fixture"; original.check = CheckResult(state:.valid,message:"old",requestMethod:"GET")
            var edited = original; edited.verificationURL = "https://example.com/new-check"
            let result = ImportView.mergingDraftEdit(edited,original:original,current:original)
            expectNil(result.check); expectEqual(result.verificationURL,edited.verificationURL)
            expectFalse(edited.hasSameVerificationConfiguration(as:original))
            edited = original; edited.apiKey = "sk-fixture-changed-123456789"
            expectNil(ImportView.mergingDraftEdit(edited,original:original,current:original).check)
        }
    }
    static func metadataDuringRequests() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        do {
            let key = SymmetricKey(size:.bits256), store = VaultStore(disk:EncryptedVault(directory:root,keyProvider:{key}),automaticProxy:false)
            var record = DeepChecks.record(); record.model = "fixture"; record.balanceURL = "https://example.com/balance"; record.balancePath = "data.remaining"; record.balanceUnit = "CNY"
            expectTrue(store.save(record)); record = try unwrap(store.selected)
            let session = MockURLProtocol.session { request in
                MockReply(body:Data((request.url?.path.contains("balance") == true ? #"{"data":{"remaining":12}}"# : #"{"data":[{"id":"fixture"}]}"#).utf8),delay:0.15)
            }
            defer { session.invalidateAndCancel() }
            let verification = Task { await store.verify(record,session:session) }
            let models = Task { await store.fetchModels(record,session:session) }
            let balance = Task { await store.queryBalance(record,session:session) }
            await InteractionFlowChecks.wait { store.checking.contains(record.id) && store.modelsChecking.contains(record.id) && store.balanceChecking.contains(record.id) }
            var edited = record; edited.notes = "请求进行中修改备注"; edited.name = "Updated fixture"
            expectTrue(store.save(edited))
            await verification.value; await models.value; await balance.value
            let current = try unwrap(store.selected)
            expectEqual(current.notes,edited.notes); expectEqual(current.name,edited.name)
            expectEqual(current.check?.state,.valid); expectEqual(current.availableModels,["fixture"]); expectEqual(current.balanceSummary,"12 CNY")
            checkpoint("Workflow.verification-catalog-and-balance-results-survive-unrelated-metadata-edits")
            let failure = MockURLProtocol.session { _ in MockReply(status:404,body:Data("{}".utf8),delay:0.15) }
            defer { failure.invalidateAndCancel() }
            let pending = Task { await store.queryBalance(current,session:failure) }
            await InteractionFlowChecks.wait { store.balanceChecking.contains(current.id) }
            var reconfigured = current; reconfigured.balancePath = "data.changed"
            expectTrue(store.save(reconfigured)); store.error = nil
            await pending.value
            expectNil(store.error); expectEqual(store.selected?.balanceSummary,"")
            checkpoint("Workflow.old-balance-failure-cannot-report-an-error-for-a-new-configuration")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Workflow.metadata-requests") }
    }

    static func batchUpdates() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        do {
            let key = SymmetricKey(size:.bits256), store = VaultStore(disk:EncryptedVault(directory:root,keyProvider:{key}),automaticProxy:false)
            var first = DeepChecks.record(), second = DeepChecks.record(); first.name = "First"; second.name = "Second"; second.apiKey = "sk-fixture-old-batch-key-123456789"
            expectTrue(store.importRecords([first,second])); let order = store.active
            let firstID = try unwrap(order.first?.id), later = try unwrap(order.last)
            var sent:[String] = []
            let session = MockURLProtocol.session { request in
                MockURLProtocol.lock.lock(); sent.append(request.value(forHTTPHeaderField:"Authorization") ?? ""); MockURLProtocol.lock.unlock()
                return MockReply(body:Data(#"{"data":[{"id":"fixture"}]}"#.utf8),delay:0.15)
            }
            defer { session.invalidateAndCancel() }
            store.verifyAll(session:session)
            await InteractionFlowChecks.wait { store.checking.contains(firstID) }
            var updated = later; updated.apiKey = "sk-fixture-new-batch-key-987654321"; expectTrue(store.save(updated))
            for _ in 0..<100 { if !store.batchRunning { break }; try await Task.sleep(for:.milliseconds(15)) }
            expectFalse(store.batchRunning); expectEqual(sent.count,2)
            expectFalse(sent.contains("Bearer "+later.apiKey)); expectTrue(sent.contains("Bearer "+updated.apiKey))
            expectEqual(store.credentials.first { $0.id == later.id }?.check?.state,.valid)
            checkpoint("Workflow.batch-verification-uses-current-credentials-for-keys-edited-while-waiting")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Workflow.batch-updates") }
    }

    static func authenticationMaterial() {
        runCheck("Workflow.startup-refreshes-only-managed-environment-and-removes-legacy-authentication-values") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size:.bits256), disk = EncryptedVault(directory:root,keyProvider:{key})
                let token = "LEGACY_AUXILIARY_SECRET_123456789"
                var record = DeepChecks.record(); record.extraHeaders = "X-Session-Token: " + token; record.model = token; record.variablePrefix = "LEGACY_PROJECT"
                try disk.save(VaultData(credentials:[record]))
                let before = try Data(contentsOf:disk.fileURL)
                let oldEnvironment = UserEnvironment(home:root.appendingPathComponent("environment-test-home"),command:{_ in ""})
                var legacy = EnvironmentEntry(record); legacy.values[legacy.prefix+"_MODEL"] = token
                try FileManager.default.createDirectory(at:oldEnvironment.directory,withIntermediateDirectories:true)
                try JSONEncoder().encode([legacy]).write(to:oldEnvironment.registry)
                let store = VaultStore(disk:disk,automaticProxy:false)
                expectTrue(store.installedEnvironmentIDs.contains(record.id)); expectNil(store.error)
                expectFalse(try String(contentsOf:store.userEnvironment.registry,encoding:.utf8).contains(token))
                expectFalse(try String(contentsOf:store.userEnvironment.shellFile,encoding:.utf8).contains(token))
                expectEqual(try Data(contentsOf:disk.fileURL),before)
            }
        }
        runCheck("Workflow.auxiliary-authentication-stays-out-of-alias-config-and-AI-but-local-copy-is-original") {
            try NewFeatureChecks.isolated { root in
                var record = DeepChecks.record(); let token = "AUXILIARY_PRIVATE_123456789"
                record.extraHeaders = "X-Access-Token: Bearer "+token+"\nX-Project: public-project"
                record.provider = token; record.variablePrefix = token; record.model = token
                expectTrue(record.secretValues.contains(token)); expectFalse(record.secretValues.contains("public-project"))
                expectTrue(record.modelIssue(token) != nil); expectFalse(record.canCopyUsage); expectFalse(record.safeModel.contains(token))
                expectFalse(record.safeShareText.contains(token)); expectFalse(record.environmentText.contains(token)); expectFalse(EnvironmentEntry(record).values.values.joined().contains(token))
                let key = SymmetricKey(size:.bits256), board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let store = VaultStore(disk:EncryptedVault(directory:root,keyProvider:{key}),automaticProxy:false,pasteboard:board)
                expectTrue(store.importRecords([record]))
                var otherService = DeepChecks.record(); otherService.model = "fixture-model"
                expectTrue(store.modelIssue(token, for:otherService) != nil); expectNil(store.modelIssue("fixture-model",for:otherService))
                otherService.model = token; expectTrue(store.usageIssue(otherService) != nil)
                store.copy("debug echo "+token); expectFalse(board.string(forType:.string)?.contains(token) == true)
                expectTrue(store.setShowFullContent(true)); store.copy("debug echo "+token); expectEqual(board.string(forType:.string),"debug echo "+token)
                let host = ImportAgentHost(original:"API Key: sk-fixture-target-123456789\nBase URL: https://example.com/v1",imageText:"",images:[],workspace:root,session:APIClient.session)
                host.organizerOtherSecrets = record.secretValues
                expectFalse(host.safe("service error echoed "+token).contains(token))
                var identifiers = DeepChecks.record(); identifiers.extraHeaders = "X-Token-Id: 1\nCookie: sid=session-private-123456; locale=en"; identifiers.model = "qwen-1"
                expectFalse(identifiers.secretValues.contains("1")); expectFalse(identifiers.secretValues.contains("en")); expectTrue(identifiers.secretValues.contains("session-private-123456"))
                expectTrue(identifiers.canCopyUsage); expectTrue(identifiers.safeShareText.contains(identifiers.localBaseURL)); expectTrue(identifiers.safeShareText.contains("qwen-1"))
            }
        }
        runCheck("Workflow.same-provider-distinct-authentication-configurations-remain-distinct-and-route-correctly") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size:.bits256), store = VaultStore(disk:EncryptedVault(directory:root,keyProvider:{key}),automaticProxy:false)
                var first = DeepChecks.record(); first.kind = .custom; first.auth = .none; first.apiKey = ""; first.extraHeaders = "X-Client-Token: fixture-auth-first-123456789"
                var second = first; second.id = UUID(); second.extraHeaders = "X-Client-Token: fixture-auth-second-987654321"
                expectNotEqual(first.fingerprint,second.fingerprint)
                expectTrue(store.importRecords([first,second])); expectEqual(store.credentials.count,2)
                for expected in [first,second] {
                    let local = LocalHTTPRequest(method:"GET",target:"/s/"+expected.routeID+"/health",headers:["authorization":"Bearer "+expected.localKey],body:Data())
                    let upstream = try local.upstream(records:store.credentials).0
                    expectEqual(upstream.value(forHTTPHeaderField:"X-Client-Token"),expected.extraHeaders.components(separatedBy:": ").last)
                }
                var duplicate = first; duplicate.id = UUID(); duplicate.extraHeaders = "x-client-token:   fixture-auth-first-123456789  "
                expectEqual(duplicate.fingerprint,first.fingerprint); expectTrue(store.importRecords([duplicate])); expectEqual(store.credentials.count,2)
                let host = ImportAgentHost(original:"API Key: sk-fixture-shared-main-123456789\nBase URL: https://example.com/v1",imageText:"",images:[],workspace:root,session:APIClient.session)
                _ = try host.propose(["api_key":"KEYDOCK_SECRET_1","base_url":"https://example.com/v1","kind":"compatible","extra_headers":"X-Project: first"])
                _ = try host.propose(["api_key":"KEYDOCK_SECRET_1","base_url":"https://example.com/v1","kind":"compatible","extra_headers":"X-Project: second"])
                expectEqual(host.candidates.count,2)
            }
        }
    }

}
