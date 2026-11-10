import Foundation
import AppKit
import CryptoKit

@MainActor enum NewFeatureChecks {
    static func run() async {
        instanceChecks(); simpleFlowChecks(); environmentChecks(); historyChecks(); curlChecks()
        await organizerChecks(); await proxyChecks()
    }
    static func instanceChecks() {
        runCheck("Feature.single-instance-lock-allows-one-process-and-releases-on-exit") {
            try isolated { root in
                let file = root.appendingPathComponent("instance.lock")
                var lock = try FileInstanceLock(file: file); expectTrue(lock != nil)
                expectNil(try FileInstanceLock(file: file)); lock = nil
                let reclaimed = try FileInstanceLock(file: file); expectTrue(reclaimed != nil)
                withExtendedLifetime(reclaimed) {}
            }
        }
        runCheck("Feature.concurrent-process-starts-only-one-instance") {
            try isolated { root in
                var processes: [Process] = []
                for _ in 0..<6 {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                    process.arguments = ["--instance-lock-hold", root.appendingPathComponent("instance.lock").path]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); processes.append(process)
                }
                let deadline = Date().addingTimeInterval(10)
                while ((try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.contains(".ready-") }.count < 6) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                try Data().write(to: root.appendingPathComponent("instance.lock.release"))
                processes.forEach { $0.waitUntilExit() }
                expectEqual(processes.filter { $0.terminationStatus == 0 }.count, 1)
                expectEqual(processes.filter { $0.terminationStatus == 42 }.count, 5)
            }
        }
    }
    static func isolated(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    static func simpleFlowChecks() {
        runCheck("Simple.explicit-local-choice-persists-and-old-vault-keeps-smart-default") {
            let legacy = try JSONDecoder().decode(VaultData.self, from: Data(#"{"version":1,"credentials":[]}"#.utf8))
            expectNil(legacy.prefersLocalImport)
            try isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let store = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(store.commit { $0.prefersLocalImport = true })
                let reloaded = VaultStore(disk: disk, automaticProxy: false)
                expectEqual(reloaded.data.prefersLocalImport, true)
                expectTrue(reloaded.commit { $0.prefersLocalImport = false })
                expectEqual(try disk.load().prefersLocalImport, false)
            }
        }
        runCheck("Simple.same-key-remembers-model-without-changing-saved-record") {
            try isolated { root in
                let key = SymmetricKey(size: .bits256)
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = ""
                expectTrue(store.save(record))
                expectTrue(store.commit { $0.organizerServiceID = record.id; $0.organizerModel = "fixture-chat" })
                let ready = store.configuredForUse(record)
                expectEqual(ready.model, "fixture-chat")
                expectTrue(ready.safeShareText.contains("fixture-chat")); expectTrue(ready.localCurl.contains("--request POST"))
                expectFalse(ready.safeShareText.contains(record.apiKey)); expectTrue(ready.safeShareText.contains(record.localKey))
                expectEqual(try store.disk.load().credentials.first?.model, "")
                record.model = "explicit-choice"; expectEqual(store.configuredForUse(record).model, "explicit-choice")
                record.model = ""; record.id = UUID(); expectEqual(store.configuredForUse(record).model, "")
                record.id = ready.id; record.kind = .custom; expectEqual(store.configuredForUse(record).model, "")
            }
        }
        runCheck("Simple.environment-uses-remembered-model-and-updates-once-configured") {
            try isolated { root in
                let key = SymmetricKey(size: .bits256)
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = ""; record.variablePrefix = "SIMPLE_WORK"
                expectTrue(store.save(record))
                expectTrue(store.commit { $0.organizerServiceID = record.id; $0.organizerModel = "fixture-chat" })
                store.toggleSystemEnvironment(record)
                expectEqual(store.userEnvironment.entries.first?.values["SIMPLE_WORK_MODEL"], "fixture-chat")
                store.toggleFavorite(record)
                expectEqual(store.userEnvironment.entries.first?.values["SIMPLE_WORK_MODEL"], "fixture-chat")
                expectTrue(store.commit { $0.organizerModel = "fixture-chat-new" })
                expectEqual(store.userEnvironment.entries.first?.values["SIMPLE_WORK_MODEL"], "fixture-chat-new")
                expectFalse(try String(contentsOf: store.userEnvironment.shellFile, encoding: .utf8).contains(record.apiKey))
                store.toggleSystemEnvironment(record); expectTrue(store.userEnvironment.entries.isEmpty)
            }
        }
        runCheck("Simple.reimporting-copied-alias-skips-existing-and-keeps-distinct-key") {
            try isolated { root in
                let key = SymmetricKey(size: .bits256)
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = "fixture-chat"
                expectTrue(store.save(record))
                let copied = ImportParser.parse(record.safeShareText)
                expectFalse(copied.isEmpty)
                expectTrue(store.importRecords(copied)); expectEqual(store.credentials.count, 1)
                var alias = record; alias.id = UUID(); alias.baseURL = " " + record.localBaseURL + "/ "; alias.apiKey = record.localKey
                var another = record; another.id = UUID(); another.apiKey = "fixture-distinct-key"
                expectTrue(store.importRecords([alias, another])); expectEqual(store.credentials.count, 2)
                expectEqual(Set(store.credentials.map(\.apiKey)), Set([record.apiKey, another.apiKey]))
            }
        }
        runCheck("Simple.self-proxy-address-rejected-with-original-record-preserved") {
            try isolated { root in
                let key = SymmetricKey(size: .bits256)
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); expectTrue(store.save(record))
                let original = record.baseURL
                record.baseURL = " " + record.localBaseURL + "/ "
                expectFalse(store.save(record)); expectEqual(store.credentials.first?.baseURL, original)
                expectEqual(try store.disk.load().credentials.first?.baseURL, original)
            }
        }
    }
    static func environmentChecks() {
        runCheck("Feature.environment-install-remove-keeps-user-profiles-and-other-keys") {
            try isolated { root in
                let profile = root.appendingPathComponent(".zshrc"), original = "export USER_SETTING='keep-me'\n"
                try original.write(to: profile, atomically: true, encoding: .utf8)
                var variables: [String: String] = [:]
                let manager = UserEnvironment(home: root) { args in
                    if args[0] == "getenv" { return variables[args[1]] ?? "" }
                    if args[0] == "setenv" { variables[args[1]] = args[2] } else { variables.removeValue(forKey: args[1]) }; return ""
                }
                var a = DeepChecks.record(); a.variablePrefix = "KEY_A"; a.model = "fixture-model"
                var b = a; b.id = UUID(); b.variablePrefix = "KEY_B"; b.apiKey = "another-fake-secret"
                try manager.install(a); try manager.install(a); try manager.install(b)
                expectEqual(manager.entries.count, 2); expectEqual(variables["KEY_A_API_KEY"], a.localKey)
                let source = try String(contentsOf: manager.shellFile, encoding: .utf8)
                expectFalse(source.contains(a.apiKey)); expectFalse(source.contains(b.apiKey))
                expectEqual(try String(contentsOf: profile, encoding: .utf8).components(separatedBy: manager.profileLine).count, 2)
                expectEqual(try FileManager.default.attributesOfItem(atPath: manager.registry.path)[.posixPermissions] as? Int, 0o600)
                try manager.remove(a.id); expectNil(variables["KEY_A_API_KEY"]); expectEqual(variables["KEY_B_API_KEY"], b.localKey)
                variables["KEY_B_API_KEY"] = "user-changed-value"
                try manager.remove(b.id); expectEqual(variables["KEY_B_API_KEY"], "user-changed-value")
                expectEqual(try String(contentsOf: profile, encoding: .utf8), original)
                expectFalse(FileManager.default.fileExists(atPath: manager.agent.path)); expectFalse(FileManager.default.fileExists(atPath: manager.shellFile.path))
            }
        }
        runCheck("Feature.environment-conflicts-and-command-failures-roll-back") {
            try isolated { root in
                let profile = root.appendingPathComponent(".zshrc"); try "# user config\n".write(to: profile, atomically: true, encoding: .utf8)
                var record = DeepChecks.record(); record.variablePrefix = "KEY_WORK"
                let collision = UserEnvironment(home: root) { args in args[0] == "getenv" && args[1].hasSuffix("API_KEY") ? "user-existing-key" : "" }
                expectThrows(try collision.install(record)); expectFalse(FileManager.default.fileExists(atPath: collision.registry.path))
                var vars: [String: String] = [:], fail = true
                let failure = UserEnvironment(home: root) { args in
                    if args[0] == "getenv" { return vars[args[1]] ?? "" }
                    if args[0] == "setenv" && fail { fail = false; throw KeyDockError.message("fixture failure") }
                    if args[0] == "setenv" { vars[args[1]] = args[2] } else { vars.removeValue(forKey: args[1]) }; return ""
                }
                expectThrows(try failure.install(record)); expectTrue(failure.entries.isEmpty); expectTrue(vars.isEmpty)
                expectEqual(try String(contentsOf: profile, encoding: .utf8), "# user config\n"); expectFalse(FileManager.default.fileExists(atPath: failure.registry.path))
            }
        }
        runCheck("Feature.environment-survives-reload-and-tracks-renamed-prefix-model") {
            try isolated { root in
                var vars: [String: String] = [:]
                let command: UserEnvironment.Command = { args in
                    if args[0] == "getenv" { return vars[args[1]] ?? "" }
                    if args[0] == "setenv" { vars[args[1]] = args[2] } else { vars.removeValue(forKey: args[1]) }; return ""
                }
                var record = DeepChecks.record(); record.variablePrefix = "OLD_PREFIX"
                try UserEnvironment(home: root, command: command).install(record)
                let reloaded = UserEnvironment(home: root, command: command); expectTrue(reloaded.contains(record.id))
                record.variablePrefix = "NEW_PREFIX"; record.model = record.apiKey
                try reloaded.synchronize([record]); expectNil(vars["OLD_PREFIX_API_KEY"]); expectEqual(vars["NEW_PREFIX_API_KEY"], record.localKey)
                expectFalse(try String(contentsOf: reloaded.shellFile, encoding: .utf8).contains(record.apiKey))
                try reloaded.synchronize([]); expectTrue(reloaded.entries.isEmpty)
            }
        }
        runCheck("Feature.environment-shell-quotes-values-without-executing-them") {
            try isolated { root in
                var record = DeepChecks.record(); record.variablePrefix = "SHELL_TEST"
                let marker = root.appendingPathComponent("must-not-exist")
                record.model = "model' $(touch \(marker.path))\nnext"
                let manager = UserEnvironment(home: root, command: { _ in "" }); try manager.install(record)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.environment = [:]
                process.arguments = ["-dfc", "source \"$1\"; print -r -- \"$SHELL_TEST_MODEL\"", "test", manager.shellFile.path]
                let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                expectEqual(process.terminationStatus, 0); expectEqual(String(decoding: data, as: UTF8.self), record.model + "\n")
                expectFalse(FileManager.default.fileExists(atPath: marker.path))
            }
        }
        runCheck("Feature.environment-keeps-existing-bash-login-fallback-and-restores-created-files") {
            try isolated { root in
                let profile = root.appendingPathComponent(".profile"), original = "export EXISTING_LOGIN_CONFIG=yes\n"
                try original.write(to: profile, atomically: true, encoding: .utf8)
                let manager = UserEnvironment(home: root, command: { _ in "" }), record = DeepChecks.record()
                try manager.install(record)
                expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bash_profile").path))
                expectTrue(try String(contentsOf: profile, encoding: .utf8).contains(original))
                try UserEnvironment(home: root, command: { _ in "" }).remove(record.id)
                expectEqual(try String(contentsOf: profile, encoding: .utf8), original)
                expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".zshrc").path))
                expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bashrc").path))
            }
        }
    }
    static func historyChecks() {
        runCheck("Feature.tokens-JSON-and-three-SSE-protocols") {
            let cases: [(String, Int, Int, Int)] = [
                (#"{"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#, 10, 4, 14),
                ("data: {\"message\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":0}}}\n\ndata: {\"usage\":{\"output_tokens\":8}}\n\n", 12, 8, 20),
                ("data: {\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":4,\"thoughtsTokenCount\":2,\"totalTokenCount\":9}}\n\n", 3, 6, 9),
                ("data: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":5}}\n\ndata: [DONE]\n\n", 2, 5, 7)
            ]
            for (raw, input, output, total) in cases {
                var usage = TokenUsage(); let data = Data(raw.utf8)
                for chunk in stride(from: 0, to: data.count, by: 7) { usage.receive(data.subdata(in: chunk..<min(chunk + 7, data.count))) }
                usage.finish(); expectEqual(usage.input, input); expectEqual(usage.output, output); expectEqual(usage.total, total)
            }
            var invalid = TokenUsage(); invalid.receive(Data(#"{"usage":{"prompt_tokens":true,"completion_tokens":-3}}"#.utf8)); invalid.finish()
            expectNil(invalid.input); expectNil(invalid.output)
        }
        runCheck("Feature.long-SSE-retains-early-input-usage-with-bounded-buffers") {
            var usage = TokenUsage()
            usage.receive(Data("data: {\"message\":{\"usage\":{\"input_tokens\":99}}}\n\n".utf8))
            for _ in 0..<5000 { usage.receive(Data("data: {\"delta\":{\"text\":\"a sufficiently long streaming fixture token segment\"}}\n\n".utf8)) }
            usage.receive(Data("data: {\"usage\":{\"output_tokens\":5000}}\n\n".utf8)); usage.finish()
            expectEqual(usage.input, 99); expectEqual(usage.output, 5000); expectEqual(usage.total, 5099)
        }
        runCheck("Feature.environment-never-leaks-secret-mistaken-for-provider-or-prefix") {
            var record = DeepChecks.record(); record.apiKey = "ABCDEF1234567890ABCDEFGH"; record.provider = record.apiKey; record.variablePrefix = record.apiKey
            expectFalse(record.environmentText.contains(record.apiKey)); expectFalse(EnvironmentEntry(record).prefix.contains(record.apiKey))
        }
        runCheck("Feature.normal-copy-hides-all-known-keys-and-keeps-public-local-aliases") {
            try isolated { root in
                let key = SymmetricKey(size: .bits256), board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false, pasteboard: board)
                var a = DeepChecks.record(), b = DeepChecks.record(); b.apiKey = "unformatted-custom-secret-42"
                a.name = a.apiKey; expectTrue(a.title.contains(a.apiKey)); expectFalse(store.displayText(a.title, additionalSecrets: a.secretValues).contains(a.apiKey))
                expectTrue(store.save(a)); expectTrue(store.save(b))
                store.copy("nested note " + b.apiKey + " " + a.localKey)
                expectFalse(board.string(forType: .string)?.contains(b.apiKey) == true)
                expectTrue(board.string(forType: .string)?.contains(a.localKey) == true)
            }
        }
        runCheck("Feature.structured-short-key-is-still-redacted-before-AI") {
            let prepared = RedactedImport(#"{"key":"vKey42","base_url":"https://example.com/v1"}"#)
            expectFalse(prepared.text.contains("vKey42")); expectTrue(prepared.keys.values.contains("vKey42"))
        }
        runCheck("Feature.history-encrypted-retention-and-cumulative-statistics") {
            try isolated { root in
                let key = SymmetricKey(size: .bits256), id = UUID()
                let history = ProxyHistory(directory: root, keyProvider: { key })
                history.flush(); expectFalse(FileManager.default.fileExists(atPath: history.fileURL.path))
                history.setCapture(true, for: id)
                for _ in 0..<105 {
                    var entry = ProxyLogEntry(credentialID: id, method: "POST", requestURL: "/v1/chat/completions")
                    entry.status = 200; entry.inputTokens = 2; entry.outputTokens = 3; entry.requestBody = "private business fixture"
                    history.append(entry)
                }
                history.flush(); expectEqual(history.entries.count, 105); expectEqual(history.totals[id]?.calls, 105); expectEqual(history.totals[id]?.input, 210)
                let bytes = try Data(contentsOf: history.fileURL); expectFalse(String(decoding: bytes, as: UTF8.self).contains("private business fixture"))
                expectEqual(try FileManager.default.attributesOfItem(atPath: history.fileURL.path)[.posixPermissions] as? Int, 0o600)
                let restored = ProxyHistory(directory: root, keyProvider: { key }); expectEqual(restored.entries.count, 105); expectEqual(restored.totals[id]?.calls, 105); expectTrue(restored.captureBodies.contains(id))
                restored.clear(id); restored.flush(); expectTrue(restored.entries.isEmpty); expectNil(restored.totals[id])
            }
        }
        runCheck("Feature.log-redaction-hides-authentication-and-bounds-body") {
            let secret = "fixture-sensitive-value"
            let headers = LogRedaction.headers(["Authorization": "Bearer " + secret, "X-Access-Token": "another-private-token", "X-Request-ID": "keep-me"], secret: secret)
            expectFalse(headers.contains(secret)); expectFalse(headers.contains("another-private-token")); expectTrue(headers.contains("keep-me"))
            let body = Data((String(repeating: "A", count: LogRedaction.bodyLimit - 5) + secret + "end").utf8)
            let text = LogRedaction.body(body, secret: secret)
            expectFalse(text.contains(secret)); expectTrue(text.utf8.count <= LogRedaction.bodyLimit)
            var errorUsage = TokenUsage(); errorUsage.receive(Data(#"{"error":{"message":"fail"}}"#.utf8)); errorUsage.finish(); expectTrue(errorUsage.hasAPIError)
        }
    }
    static func curlChecks() {
        runCheck("Feature.curl-calls-real-selected-model-and-never-falls-back-to-model-list") {
            var record = DeepChecks.record()
            expectFalse(record.localCurl.contains("/models")); expectTrue(record.localCurl.contains("选择"))
            for kind in [ServiceKind.compatible, .anthropic, .gemini] {
                record.kind = kind; record.model = "fixture-model"
                let request = try APIClient.modelRequest(for: record)
                expectEqual(request.httpMethod, "POST"); expectTrue(record.localCurl.contains("--data")); expectTrue(record.localCurl.contains("--request POST"))
                expectFalse(record.localCurl.contains(record.apiKey)); expectTrue(record.realModelCurl.contains(record.apiKey))
                expectFalse(record.shareText.contains("验证 curl"))
                let shared = try unwrap(try JSONSerialization.jsonObject(with:Data(record.shareText.utf8)) as? [String:Any])
                expectEqual(shared["curl"] as? String,record.realModelCurl)
            }
        }
    }
    static func image() throws -> ImportImage {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        return try ImportImage(data: bitmap.representation(using: .png, properties: [:])!, name: "fixture.png")
    }
    static func organizerChecks() async {
        let cases = ["tokenId apikey\nqa1fixture99 alpha42BETA77unknownkey9911\n这是 Gemini 的，文档稍后补", "朋友发来的，先收着\nalpha42BETA77unknownkey9911\n用来写代码，不知道地址", "访问口令用 vKey42，备注：研发测试"]
        for (index, raw) in cases.enumerated() {
            do {
                let prepared = RedactedImport(raw), key = index == 2 ? "vKey42" : "alpha42BETA77unknownkey9911"
                let candidate = prepared.keys.first { $0.value == key }?.key ?? key
                expectFalse(ImportParser.parse(raw).contains { $0.apiKey == key })
                let session = MockURLProtocol.session { request in
                    let bytes = DeepNetworkChecks.bodyData(request), body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    expectTrue(body?["messages"] != nil)
                    if index != 2 { expectFalse(String(decoding: bytes, as: UTF8.self).contains(key)) }
                    let content = String(data: try JSONSerialization.data(withJSONObject: [["name": "Gemini 零散资料", "api_key": candidate, "base_url": "", "kind": "compatible", "notes": "地址待补"]]), encoding: .utf8)!
                    return MockReply(body: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]))
                }
                let result = try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: DeepChecks.record(), model: "fixture", original: raw, session: session)
                expectEqual(result.first?.apiKey, key); expectEqual(result.first?.baseURL, ""); session.invalidateAndCancel()
            } catch { checkFailures.append("messy AI case \(index): " + error.localizedDescription) }
            checkpoint("Feature.AI-understands-messy-text-without-local-parser-\(index)")
        }
        for kind in [ServiceKind.compatible, .anthropic, .gemini] {
            do {
                let image = try image(), raw = "这是文档截图，帮我提取服务资料", prepared = RedactedImport(raw)
                var service = DeepChecks.record(); service.kind = kind
                let session = MockURLProtocol.session { request in
                    let body = try JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request)) as! [String: Any]
                    let dataURL = "data:image/jpeg;base64," + image.data.base64EncodedString()
                    let bytes = String(decoding: DeepNetworkChecks.bodyData(request), as: UTF8.self)
                    expectTrue(bytes.contains(image.data.base64EncodedString()))
                    if kind == .compatible { let messages = body["messages"] as! [[String: Any]]; let content = messages.last?["content"] as! [[String: Any]]; expectEqual((content.last?["image_url"] as? [String: Any])?["url"] as? String, dataURL) }
                    if kind == .anthropic { expectTrue(bytes.contains("media_type")); expectTrue(bytes.contains("base64")) }
                    if kind == .gemini { expectTrue(bytes.contains("inlineData")) }
                    let content = String(data: try JSONSerialization.data(withJSONObject: [["name": "截图提取待核对", "api_key": "fixture-image-key", "base_url": "https://not-in-source.invalid", "kind": "compatible"]]), encoding: .utf8)!
                    let response: [String: Any] = kind == .anthropic ? ["content": [["text": content]]] : (kind == .gemini ? ["candidates": [["content": ["parts": [["text": content]]]]]] : ["choices": [["message": ["content": content]]]])
                    return MockReply(body: try JSONSerialization.data(withJSONObject: response))
                }
                let records = try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: service, model: "fixture", original: raw, images: [image], session: session)
                expectEqual(records.first?.baseURL, ""); expectTrue(records.first?.notes.contains("核对") == true); session.invalidateAndCancel()
            } catch { checkFailures.append("image protocol: " + error.localizedDescription) }
            checkpoint("Feature.AI-real-image-bytes-" + kind.rawValue)
        }
        runCheck("Feature.image-paths-become-attachments-and-clipboard-data-is-preserved") {
            try isolated { root in
                let image = try image(), file = root.appendingPathComponent("sample.jpg"); try image.data.write(to: file)
                var paste = ImportPaste(text: "零散说明\n" + file.path + "\n" + file.path); paste.absorbPaths()
                expectEqual(paste.images.count, 1); expectEqual(paste.text, "零散说明"); expectTrue(paste.errors.isEmpty)
                expectThrows(try ImportImage(data: Data("not an image".utf8)))
                expectThrows(try ImportImage.validate(Array(repeating: image, count: 7)))
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                board.setData(image.data, forType: .png)
                expectEqual(ImportPaste.from(board).images.count, 1)
            }
        }
    }
    static func proxyChecks() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), history = ProxyHistory(directory: root, keyProvider: { key })
        var record = DeepChecks.record(); record.apiKey = "fixture-log-secret"
        let secret = record.apiKey
        let provider = FixtureServer { _ in FixtureResponse(headers: ["Content-Type": "application/json", "Authorization": "Bearer " + secret], chunks: [Data(("{\"choices\":[{\"message\":{\"content\":\"" + secret + "\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3,\"total_tokens\":13}}").utf8)]) }
        let proxy = LocalProxy(port: 0), session = URLSession(configuration: .ephemeral)
        defer { proxy.stop(); provider.stop(); session.invalidateAndCancel(); history.flush() }
        do {
            try provider.start()
            for _ in 0..<200 { if provider.port != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            record.baseURL = "http://127.0.0.1:\(try unwrap(provider.port))/v1"
            proxy.recordHistory(captureBodies: [record.id]) { entry in Task { @MainActor in history.append(entry) } }
            proxy.update([record]); proxy.start()
            for _ in 0..<200 { if proxy.running { break }; try await Task.sleep(for: .milliseconds(10)) }
            let port = try unwrap(proxy.listeningPort)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(record.routeID)/chat/completions")!)
            request.httpMethod = "POST"; request.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization")
            request.httpBody = Data(("{\"model\":\"fixture-chat\",\"prompt\":\"" + secret + "\"}").utf8)
            let response = try await session.data(for: request)
            expectEqual((response.1 as? HTTPURLResponse)?.statusCode, 200); expectTrue(String(decoding: response.0, as: UTF8.self).contains(secret))
            for _ in 0..<100 { if history.entries.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let entry = try history.detail(for: unwrap(history.entries.first))
            expectEqual(entry.inputTokens, 10); expectEqual(entry.outputTokens, 3); expectEqual(entry.totalTokens, 13)
            expectTrue(entry.bodiesCaptured); expectTrue(entry.requestBody.contains(secret)); expectTrue(entry.responseBody.contains(secret)); expectTrue(entry.requestHeaders.contains(secret)); expectTrue(entry.responseHeaders.contains(secret))
            expectEqual(provider.received.first?.body, request.httpBody); checkpoint("Feature.real-proxy-history-captures-original-values-and-tokens-without-changing-wire-data")
            proxy.recordHistory(captureBodies: []) { entry in Task { @MainActor in history.append(entry) } }
            _ = try await session.data(for: request)
            for _ in 0..<100 { if history.entries.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let metadata = try unwrap(history.entries.first); expectFalse(metadata.bodiesCaptured); expectTrue(metadata.requestBody.isEmpty); expectTrue(metadata.responseBody.isEmpty)
            expectEqual(history.totals[record.id]?.calls, 2); expectEqual(history.totals[record.id]?.input, 20)
            checkpoint("Feature.proxy-body-recording-is-opt-in-and-cumulative-counts-persist")
        } catch { checkFailures.append("history proxy: " + error.localizedDescription); checkpoint("Feature.history-proxy-completion") }
    }
}
