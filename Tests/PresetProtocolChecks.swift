import Foundation
import CryptoKit

@MainActor enum PresetProtocolChecks {
    static func run() async {
        runCheck("Presets.domestic-defaults-fill-docs-catalog-and-safe-balance-settings") {
            expectEqual(ProviderPreset.all.count, 10)
            expectFalse(ProviderPreset.all.contains { ["api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com"].contains(URL(string: $0.baseURL)?.host ?? "") })
            for preset in ProviderPreset.all {
                let record = preset.applying(to: Credential())
                expectEqual(record.kind, .compatible); expectEqual(record.baseURL, preset.baseURL)
                expectEqual(record.docsURL, preset.docs[0]); expectEqual(record.verificationURL, preset.catalogURL ?? "")
                expectEqual(record.balanceURL, preset.balanceURL ?? ""); expectFalse(preset.balanceNote.isEmpty)
                expectFalse(record.docsURL.contains("login.bce")); expectTrue(try JSONSerialization.data(withJSONObject: preset.reference).count > 100)
                var previous = record; previous.apiKey = "fixture-only-preset-key"; previous.notes = "用户备注"
                let changed = ProviderPreset.all.first { $0.id != preset.id && URL(string: $0.baseURL)?.host != URL(string: preset.baseURL)?.host }!.applying(to: previous)
                expectTrue(changed.apiKey.isEmpty); expectEqual(changed.notes, "用户备注")
            }
        }
        runCheck("Presets.every-EOS-region-and-protocol-keeps-Bearer-and-correct-version") {
            for preset in ProviderPreset.all.filter(\.isBCE) {
                for kind in preset.protocols {
                    var record = preset.applying(to: Credential()); record.kind = kind
                    record.apiKey = "fixture-bce-only-key"; record.model = "fixture-model"
                    let request = try APIClient.modelRequest(for: record)
                    expectEqual(request.url?.host, URL(string: preset.baseURL)?.host)
                    let path: String = [.compatible: "/v1/chat/completions", .anthropic: "/v1/messages", .responses: "/v1/responses", .gemini: "/v1beta/models/fixture-model:generateContent"][kind]!
                    expectEqual(request.url?.path, path)
                    expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + record.apiKey)
                    expectNil(request.value(forHTTPHeaderField: "x-goog-api-key")); expectNil(request.value(forHTTPHeaderField: "x-api-key"))
                    expectTrue(APIClient.requiresModelTest(record)); expectThrows(try APIClient.verificationRequest(for: record))
                    let configured = ProviderPreset.configuration(record)
                    expectEqual(ProviderPreset.configuration(configured).baseURL, configured.baseURL)
                }
            }
        }
        runCheck("Presets.native-protocol-prefixes-do-not-mix-with-chat-prefixes") {
            let expected = ["deepseek": "/anthropic/v1/messages", "kimi": "/anthropic/v1/messages", "qwen": "/apps/anthropic/v1/messages", "volcengine": "/api/compatible/v1/messages", "qianfan": "/anthropic/v1/messages"]
            for preset in ProviderPreset.all.filter({ expected[$0.id] != nil }) {
                var record = preset.applying(to: Credential()); record.kind = .anthropic
                record.apiKey = "fixture-prefix-only"; record.model = "fixture-model"
                expectEqual(try APIClient.modelRequest(for: record).url?.path, expected[preset.id])
                if let catalog = preset.catalogURL { expectEqual(try APIClient.verificationRequest(for: record).url?.absoluteString, catalog) }
                record.kind = .responses
                let request = try APIClient.modelRequest(for: record)
                expectTrue(request.url?.path.hasSuffix("/responses") == true)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
                expectEqual(body?["input"] as? String, "你好"); expectNil(body?["messages"]); expectNil(body?["max_tokens"]); expectNil(body?["max_output_tokens"])
            }
        }
        runCheck("Presets.proxy-alias-routes-by-incoming-protocol-after-selection-changes") {
            for preset in ProviderPreset.all.filter({ $0.protocols.contains(.anthropic) }) {
                var record = preset.applying(to: Credential()); record.kind = .responses
                record.apiKey = "fixture-only-alias-key"; record.model = "fixture-model"
                for (kind, suffix) in [(ServiceKind.compatible, "v1/chat/completions"), (.anthropic, "v1/messages"), (.responses, "v1/responses")] {
                    let local = LocalHTTPRequest(method: "POST", target: "/s/" + record.routeID + "/" + suffix, headers: ["x-api-key": record.localKey], body: Data("{}".utf8))
                    let result = try local.upstream(records: [record]).0
                    let configured = ProviderPreset.configuration(record, kind: kind)
                    let payload = try APIClient.modelPayload(for: configured)
                    let expected = try APIClient.endpoint(base: configured.baseURL, suffix: payload.path, defaultVersion: "v1")
                    expectEqual(result.url?.absoluteString, expected.absoluteString)
                    expectFalse(result.allHTTPHeaderFields?.values.contains(record.localKey) == true)
                }
                if let catalog = preset.catalogURL {
                    let local = LocalHTTPRequest(method: "GET", target: "/s/" + record.routeID + "/v1/models", headers: ["authorization": "Bearer " + record.localKey], body: Data())
                    expectEqual(try local.upstream(records: [record]).0.url?.absoluteString, catalog)
                }
            }
        }
        runCheck("Presets.lookalike-hosts-and-plan-gateway-prefixes-are-never-rewritten") {
            for raw in ["https://api.deepseek.com.evil.invalid/v1", "https://ark.cn-beijing.volces.com/api/plan/v3", "https://relay.invalid/team/openai/v1", "https://api.moonshot.cn/custom/v1", "https://api.deepseek.com/v1?key=fixture", "https://api.deepseek.com:8443/v1"] {
                expectNil(ProviderPreset.matching(raw))
                var record = DeepChecks.record(); record.baseURL = raw; record.kind = .responses
                expectEqual(ProviderPreset.configuration(record).baseURL, raw)
            }
            let workspace = "https://fixture-workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
            expectEqual(ProviderPreset.matching(workspace)?.catalogURL, "https://fixture-workspace.cn-beijing.maas.aliyuncs.com/api/v1/models")
        }
        runCheck("Presets.protocol-switch-preserves-models-alias-and-key-but-clears-call-proof") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = "fixture-a"; record.manualModels = ["fixture-b"]
                record.modelCatalog = ModelCatalog(models: ["fixture-c"])
                record.check = CheckResult(state: .valid, message: "fixture passed", requestMethod: "POST")
                expectTrue(store.importRecords([record])); record = try unwrap(store.selected)
                store.selectProtocol(.responses, for: record)
                let selected = try unwrap(store.selected)
                expectEqual(selected.kind, .responses); expectEqual(selected.apiKey, record.apiKey)
                expectEqual(selected.localBaseURL, record.localBaseURL); expectEqual(Set(selected.modelOptions), Set(record.modelOptions))
                expectNil(selected.check); expectEqual(selected.modelCatalog, record.modelCatalog)
                store.load(); expectEqual(store.selected?.kind, .responses)
                store.selectProtocol(.anthropic, for: record); expectTrue(store.error?.contains("已更新") == true)
            }
        }
        runCheck("Presets.examples-and-real-probes-omit-optional-output-limits") {
            for kind in [ServiceKind.compatible, .responses, .gemini, .anthropic] {
                var record = DeepChecks.record(); record.kind = kind; record.model = "fixture-model"
                let example = try APIClient.modelRequest(for: record), probe = try AgentVerification.request(record, arguments: [:]).0
                let text = String(decoding: example.httpBody!, as: UTF8.self)
                expectEqual(text.contains("max_tokens"), kind == .anthropic)
                expectFalse(text.contains("max_output_tokens")); expectFalse(text.contains("maxOutputTokens"))
                expectEqual(CheckedRequest(probe).body?.contains("max_tokens"), kind == .anthropic)
                expectFalse(CheckedRequest(probe).body?.contains("max_output_tokens") == true)
                expectFalse(CheckedRequest(probe).body?.contains("maxOutputTokens") == true)
            }
            var deepseek = DeepChecks.record(); deepseek.baseURL = "https://api.deepseek.com"; deepseek.kind = .anthropic; deepseek.model = "fixture-model"
            expectFalse(String(decoding: try APIClient.modelRequest(for: deepseek).httpBody!, as: UTF8.self).contains("max_tokens"))
            deepseek.baseURL = "https://ark.cn-beijing.volces.com/api/compatible/v1"
            expectFalse(String(decoding: try APIClient.modelRequest(for: deepseek).httpBody!, as: UTF8.self).contains("max_tokens"))
        }
        runCheck("Presets.agent-references-follow-provider-not-the-model-name-or-guessed-region") {
            expectTrue(ProviderPreset.matches(in: "中转 https://relay.invalid/v1 模型 gemini、deepseek").isEmpty)
            let matches = ProviderPreset.matches(in: "https://eos-de.aigc.exp.bcevod.com/v1 模型gemini")
            expectEqual(matches.map(\.id), ["bce-de"])
            expectEqual(ProviderPreset.matches(in: "DeepSeek API Key 需要导入").map(\.id), ["deepseek"])
            expectEqual(ProviderPreset.matches(in: "百度 EOS API Key").count, 4)
            try NewFeatureChecks.isolated { root in
                let session = MockURLProtocol.session { _ in MockReply() }; defer { session.invalidateAndCancel() }
                let host = ImportAgentHost(original: "DeepSeek API Key: sk-fixture-reference-only-123456", imageText: "", images: [], workspace: root, session: session)
                let id = try unwrap(host.redacted.keys.keys.first)
                _ = try host.propose(["base_url": "https://api.deepseek.com", "api_key": id, "kind": "compatible"])
                expectEqual(host.candidates.first?.verificationURL, "https://api.deepseek.com/models")
                expectEqual(host.candidates.first?.balanceURL, "https://api.deepseek.com/user/balance")
                expectFalse(host.candidates.first?.source.contains("厂商参考") == true)
                let bce = ImportAgentHost(original: "百度 EOS API Key: sk-fixture-reference-only-123456", imageText: "", images: [], workspace: root, session: session)
                _ = try bce.propose(["base_url": "https://eos-sg.aigc.exp.bcevod.com/v1", "api_key": bce.redacted.keys.keys.first!, "kind": "compatible"])
                expectTrue(bce.candidates.first?.baseURL.isEmpty == true)
            }
        }
        runCheck("Presets.agent-notes-are-structured-deduplicated-and-separate-from-original") {
            let notes = ImportAgentHost.structuredNotes(["access": ["使用区域专属 Key。", "使用区域专属 Key。", ""], "limits": ["仅供开发环境使用。"], "pending": ["请确认部署 ID。"]])
            expectEqual(notes, "使用区域专属 Key。\n仅供开发环境使用。\n待确认：请确认部署 ID。")
            try NewFeatureChecks.isolated { root in
                let raw = "DeepSeek API Key: sk-fixture-notes-secret-123456\n原始聊天很零散，这些全部只留在导入原文。"
                let session = MockURLProtocol.session { _ in MockReply() }; defer { session.invalidateAndCancel() }
                let host = ImportAgentHost(original: raw, imageText: "", images: [], workspace: root, session: session)
                _ = try host.propose(["api_key": host.redacted.keys.keys.first!, "base_url": "https://api.deepseek.com", "kind": "compatible", "notes": raw,
                                      "notes_sections": ["access": ["用于开发环境联调。"], "pending": ["核对部署 ID。"]]])
                let record = try unwrap(host.reviewResult().records.first)
                expectEqual(record.source, raw); expectFalse(record.notes.contains("原始聊天")); expectFalse(record.notes.contains(record.apiKey))
                expectEqual(record.notes, "用于开发环境联调。\n待确认：核对部署 ID。")
            }
        }
        runCheck("Presets.same-provider-key-does-not-import-twice-for-different-protocols") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var chat = ProviderPreset.all.first { $0.id == "deepseek" }!.applying(to: Credential())
                chat.apiKey = "fixture-dedup-protocol-only"; chat.model = "fixture-model"
                var messages = chat; messages.id = UUID(); messages.baseURL = "https://api.deepseek.com/anthropic/v1"; messages.kind = .anthropic; messages.auth = .xAPIKey
                messages.extraHeaders = "anthropic-version: 2023-06-01"
                expectEqual(chat.fingerprint, messages.fingerprint)
                expectTrue(store.importRecords([chat, messages])); expectEqual(store.credentials.count, 1)
                messages.variablePrefix = "FIXTURE_DEDUP_NATIVE"; expectFalse(store.save(messages)); expectEqual(store.credentials.count, 1)
                messages.apiKey = "fixture-another-protocol-key"; expectTrue(store.save(messages)); expectEqual(store.credentials.count, 2)
            }
        }
        runCheck("Presets.saved-Responses-template-can-switch-back-to-Chat-without-a-stale-label") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = "fixture-model"
                record.callTemplate = ModelCallTemplate(path: "responses", body: #"{"model":"fixture-model","input":"你好"}"#, model: record.model)
                expectTrue(store.importRecords([record])); let saved = try unwrap(store.selected)
                expectEqual(store.configuredForUse(saved).kind, .responses)
                store.selectProtocol(.compatible, for: saved)
                let changed = try unwrap(store.selected); expectNil(changed.callTemplate)
                expectEqual(changed.inferenceKind, .compatible)
                expectTrue(try APIClient.modelRequest(for: changed).url?.path.hasSuffix("/chat/completions") == true)
            }
        }
        await qwenCatalog()
        await balance()
    }
    static func qwenCatalog() async {
        var record = DeepChecks.record(); record.baseURL = "https://fixture-workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        let session = MockURLProtocol.session { request in
            expectEqual(request.url?.path, "/api/v1/models"); expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + record.apiKey)
            let second = request.url?.query?.contains("page_no=2") == true
            return MockReply(body: Data((second ? #"{"success":true,"output":{"total":3,"page_no":2,"page_size":2,"models":[{"model":"fixture-c","name":"名称不能冒充 ID"}]}}"# : #"{"success":true,"output":{"total":3,"page_no":1,"page_size":2,"models":[{"model":"fixture-a"},{"model":"fixture-b"}]}}"#).utf8))
        }
        let result = await APIClient.fetchModels(record, session: session); session.invalidateAndCancel()
        expectEqual(result.state, .valid); expectEqual(result.models, ["fixture-a", "fixture-b", "fixture-c"])
        expectTrue(result.message.contains("读取完成")); checkpoint("Presets.Qwen-model-catalog-reads-real-IDs-and-all-documented-pages")
        var eos = ProviderPreset.all.first { $0.id == "bce-sg" }!.applying(to: Credential()); eos.apiKey = "fixture-eos-catalog-only"
        let eosSession = MockURLProtocol.session { request in
            expectEqual(request.url?.path, "/v1/models"); expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + eos.apiKey)
            return MockReply(body: Data(#"{"data":[{"id":"fixture-new-provider-catalog"}]}"#.utf8))
        }
        let observed = await APIClient.fetchModels(eos, session: eosSession); eosSession.invalidateAndCancel()
        expectEqual(observed.state, .valid); expectEqual(observed.models, ["fixture-new-provider-catalog"])
        checkpoint("Presets.unknown-catalog-reference-does-not-block-explicit-Agent-or-user-discovery")
    }
    static func balance() async {
        var record = ProviderPreset.all.first { $0.id == "kimi" }!.applying(to: Credential()); record.apiKey = "fixture-kimi-balance-only"
        let session = MockURLProtocol.session { request in
            expectEqual(request.url?.absoluteString, "https://api.moonshot.cn/v1/users/me/balance")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + record.apiKey)
            return MockReply(body: Data(#"{"code":0,"status":true,"data":{"available_balance":12.5}}"#.utf8))
        }
        do { let value = try await APIClient.balance(record, session: session); expectEqual(value, "12.5 CNY") } catch { checkFailures.append(error.localizedDescription) }
        session.invalidateAndCancel()
        var deepseek = ProviderPreset.all.first { $0.id == "deepseek" }!.applying(to: Credential())
        deepseek.kind = .anthropic; deepseek.auth = .xAPIKey; deepseek.apiKey = "fixture-deepseek-balance-only"
        let deepseekSession = MockURLProtocol.session { request in
            expectEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + deepseek.apiKey)
            return MockReply(body: Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"8.25"}]}"#.utf8))
        }
        do { let value = try await APIClient.balance(deepseek, session: deepseekSession); expectEqual(value, "CNY 8.25") } catch { checkFailures.append(error.localizedDescription) }
        deepseekSession.invalidateAndCancel()
        for preset in ProviderPreset.all where preset.balanceURL == nil { expectThrows(try APIClient.balanceRequest(for: preset.applying(to: Credential()))) }
        checkpoint("Presets.Kimi-balance-fills-JSON-path-and-other-account-APIs-never-receive-model-keys")
    }
}
