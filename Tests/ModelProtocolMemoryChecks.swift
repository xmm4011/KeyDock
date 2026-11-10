import Foundation
import CryptoKit

@MainActor enum ModelProtocolMemoryChecks {
    static func run() async {
        runCheck("ModelProtocols.legacy-current-protocol-is-learned-and-new-model-defaults-to-Chat") {
            var original = DeepChecks.record(); original.kind = .anthropic; original.auth = .xAPIKey; original.model = "messages-model"
            expectNil(original.modelProtocols)
            let next = original.selectingModel("new-chat-model")
            expectEqual(next.inferenceKind, .compatible); expectEqual(next.auth, .bearer)
            expectEqual(next.modelProtocols?["messages-model"], .anthropic)
            expectEqual(next.selectingModel("messages-model").inferenceKind, .anthropic)
            expectEqual(original.selectingModel("messages-model").inferenceKind, .anthropic)
        }
        runCheck("ModelProtocols.last-explicit-choice-wins-and-each-model-is-independent") {
            var value = DeepChecks.record(); value.model = "model-a"
            value = value.selectingProtocol(.anthropic).selectingModel("model-b").selectingProtocol(.responses)
            expectEqual(value.selectingModel("model-a").inferenceKind, .anthropic)
            value = value.selectingModel("model-a").selectingProtocol(.compatible)
            expectEqual(value.selectingModel("model-b").inferenceKind, .responses)
            expectEqual(value.selectingModel("model-b").selectingModel("model-a").inferenceKind, .compatible)
        }
        runCheck("ModelProtocols.persistence-backup-and-independent-Keys-preserve-preferences") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let store = VaultStore(disk: disk, automaticProxy: false)
                var record = DeepChecks.record(); record.model = "model-a"; record.manualModels = ["model-a", "model-b"]
                expectTrue(store.save(record)); store.selectProtocol(.anthropic, for: try unwrap(store.selected))
                store.selectModel("model-b", for: try unwrap(store.selected)); store.selectProtocol(.responses, for: try unwrap(store.selected))
                let reopened = VaultStore(disk: disk, automaticProxy: false)
                reopened.selectModel("model-a", for: try unwrap(reopened.selected)); expectEqual(reopened.selected?.inferenceKind, .anthropic)
                let backup = try PortableBackup.create(reopened.data, password: "fixture-protocol-backup")
                let restored = try PortableBackup.restore(backup, password: "fixture-protocol-backup")
                expectEqual(restored.credentials.first?.modelProtocols?["model-b"], .responses)
                var other = record; other.id = UUID(); other.apiKey = "fixture-second-key"; other.modelProtocols = nil
                expectTrue(reopened.save(other)); expectEqual(reopened.selected?.inferenceKind, .compatible)
                expectNil(reopened.selected?.modelProtocols?["model-b"])
            }
        }
        runCheck("ModelProtocols.manual-add-defaults-to-Chat-and-preserves-directory-and-old-choice") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.kind = .anthropic; record.auth = .xAPIKey; record.model = "messages-model"
                record.modelCatalog = ModelCatalog(models: ["messages-model", "catalog-model", "third-model"])
                expectTrue(store.save(record)); expectTrue(store.addModel("added-model", to: try unwrap(store.selected)))
                expectEqual(store.selected?.inferenceKind, .compatible); expectEqual(store.selected?.availableModels.count, 3)
                store.selectModel("messages-model", for: try unwrap(store.selected)); expectEqual(store.selected?.inferenceKind, .anthropic)
                expectTrue(store.selected?.modelOptions.contains("added-model") == true)
            }
        }
        runCheck("ModelProtocols.switching-to-a-catalog-model-keeps-an-unlisted-original-model-available") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let store = VaultStore(disk: disk, automaticProxy: false)
                var record = DeepChecks.record(); record.kind = .anthropic; record.auth = .xAPIKey; record.model = "unlisted-messages-model"
                record.modelCatalog = ModelCatalog(models: ["catalog-chat-model", "another-model"])
                expectTrue(store.save(record)); store.selectModel("catalog-chat-model", for: try unwrap(store.selected))
                expectTrue(store.selected?.modelOptions.contains("unlisted-messages-model") == true)
                expectEqual(store.selected?.inferenceKind, .compatible)
                let reopened = VaultStore(disk: disk, automaticProxy: false)
                reopened.selectModel("unlisted-messages-model", for: try unwrap(reopened.selected))
                expectEqual(reopened.selected?.inferenceKind, .anthropic); expectEqual(reopened.selected?.availableModels.count, 2)
                expectTrue(reopened.selected?.modelOptions.contains("catalog-chat-model") == true)
            }
        }
        runCheck("ModelProtocols.protocol-and-model-change-clear-stale-proof-but-idempotent-choice-keeps-it") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = "model-a"; record.check = CheckResult(state: .valid, message: "passed", requestMethod: "POST")
                expectTrue(store.importRecords([record])); let initial = try unwrap(store.selected)
                store.selectProtocol(.compatible, for: initial); expectEqual(store.selected?.check?.state, .valid)
                store.selectModel("model-b", for: initial); expectNil(store.selected?.check)
                store.selectProtocol(.responses, for: try unwrap(store.selected)); let selected = try unwrap(store.selected)
                store.selectModel("model-a", for: initial); expectEqual(store.selected?.model, "model-b"); expectTrue(store.error?.contains("已更新") == true)
                store.selectModel("model-a", for: selected); expectEqual(store.selected?.inferenceKind, .compatible)
            }
        }
        runCheck("ModelProtocols.preset-switch-restores-the-matching-protocol-address-auth-and-new-service-resets-memory") {
            let preset = ProviderPreset.all.first { $0.id == "deepseek" }!
            var value = preset.applying(to: DeepChecks.record()); value.apiKey = "fixture-preset-key"; value.model = "messages-model"
            value = value.selectingProtocol(.anthropic).selectingModel("chat-model")
            expectEqual(value.baseURL, preset.connectionBase(.compatible))
            value = value.selectingModel("messages-model")
            expectEqual(value.baseURL, preset.connectionBase(.anthropic)); expectEqual(value.auth, preset.authentication(.anthropic))
            let changed = CredentialEditor.applyingPreset(to: value, name: "Other", kind: .compatible, url: "https://other.example/v1", docs: "")
            expectNil(changed.modelProtocols)
            let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DeepChecks.record())) as! [String: Any]
            expectNil(old["modelProtocols"])
            expectNil(try JSONDecoder().decode(Credential.self, from: JSONSerialization.data(withJSONObject: old)).modelProtocols)
        }
        for kind in [ServiceKind.compatible, .anthropic, .responses] {
            var record = DeepChecks.record(); record.model = "fixture-model"; record = record.selectingProtocol(kind)
            record = record.selectingModel("other-model").selectingModel("fixture-model")
            let expectedPath = kind == .anthropic ? "/v1/messages" : (kind == .responses ? "/v1/responses" : "/v1/chat/completions")
            let session = MockURLProtocol.session { request in
                expectEqual(request.url?.path, expectedPath)
                let body = try JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request)) as! [String: Any]
                expectEqual(body["model"] as? String, "fixture-model")
                let response = kind == .anthropic ? #"{"type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}]}"# : (kind == .responses ? #"{"object":"response","status":"completed","output":[]}"# : #"{"choices":[{"message":{"content":"Hi"}}]}"#)
                return MockReply(body: Data(response.utf8))
            }
            let result = await APIClient.verify(record, session: session, testModel: true); session.invalidateAndCancel()
            expectEqual(result.state, .valid); expectTrue(record.localCurl.contains(expectedPath.replacingOccurrences(of: "/v1/", with: "/")))
            checkpoint("ModelProtocols.restored-selection-generates-and-verifies-the-correct-wire-protocol-" + kind.rawValue)
        }
    }
}
