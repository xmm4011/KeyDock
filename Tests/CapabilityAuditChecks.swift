import Foundation
import CryptoKit

@MainActor enum CapabilityAuditChecks {
    static func run() async {
        runCheck("CapabilityAudit.manual-provider-change-replaces-only-old-preset-defaults") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                let deepseek = ProviderPreset.all.first { $0.id == "deepseek" }!, kimi = ProviderPreset.all.first { $0.id == "kimi" }!
                var old = deepseek.applying(to: Credential()); old.apiKey = "fixture-old-provider-key"; old.model = "fixture-a"; old.notes = "用户自己的备注"
                expectTrue(store.save(old)); var edited = try unwrap(store.selected)
                edited.baseURL = kimi.baseURL; edited.apiKey = "fixture-new-provider-key"; edited.model = "fixture-b"
                expectTrue(store.save(edited)); let saved = try unwrap(store.selected)
                expectEqual(try APIClient.verificationRequest(for: saved).url?.host, "api.moonshot.cn")
                expectEqual(saved.verificationURL, kimi.catalogURL); expectEqual(saved.balanceURL, kimi.balanceURL)
                expectEqual(saved.balancePath, kimi.balancePath); expectEqual(saved.docsURL, kimi.docs[0])
                expectEqual(saved.notes, old.notes)
                var custom = saved; custom.verificationURL = "https://custom.fixture.invalid/check"; custom.balanceURL = "https://custom.fixture.invalid/balance"
                custom.balancePath = "remaining"; custom.docsURL = "https://docs.fixture.invalid/custom"
                expectTrue(store.save(custom)); custom = try unwrap(store.selected); custom.baseURL = deepseek.baseURL
                expectTrue(store.save(custom)); let kept = try unwrap(store.selected)
                expectEqual(kept.verificationURL, "https://custom.fixture.invalid/check"); expectEqual(kept.balanceURL, custom.balanceURL)
                expectEqual(kept.balancePath, "remaining"); expectEqual(kept.docsURL, custom.docsURL)
            }
        }
        runCheck("CapabilityAudit.legacy-duplicate-keys-remain-editable-without-allowing-new-duplicates") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                var first = ProviderPreset.all.first { $0.id == "deepseek" }!.applying(to: Credential()); first.apiKey = "fixture-legacy-duplicate-key"
                var second = first; second.id = UUID(); second.kind = .anthropic; second.baseURL = "https://api.deepseek.com/anthropic/v1"
                try disk.save(VaultData(credentials: [first, second]))
                let store = VaultStore(disk: disk, automaticProxy: false)
                var edited = first; edited.notes = "补充备注不会新建一条 Key"
                expectTrue(store.save(edited, expectedUpdatedAt: first.updatedAt))
                expectEqual(store.credentials.count, 2); expectEqual(store.credentials.first { $0.id == first.id }?.notes, edited.notes)
                var third = first; third.id = UUID(); expectFalse(store.save(third)); expectEqual(store.credentials.count, 2)
            }
        }
        runCheck("CapabilityAudit.duplicate-only-import-reveals-the-existing-key-instead-of-an-unrelated-row") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var target = DeepChecks.record(); target.apiKey = "fixture-import-existing-target"; target.name = "Existing target"
                var unrelated = target; unrelated.id = UUID(); unrelated.apiKey = "fixture-import-unrelated-key"; unrelated.name = "Unrelated row"
                expectTrue(store.importRecords([target, unrelated])); expectEqual(store.selectedID, unrelated.id)
                var duplicate = target; duplicate.id = UUID()
                expectTrue(store.importRecords([duplicate])); expectEqual(store.credentials.count, 2); expectEqual(store.selectedID, target.id)
                expectTrue(store.toast?.contains("已存在") == true)
                store.archive([target.id]); store.selectedID = unrelated.id
                expectTrue(store.importRecords([duplicate])); expectEqual(store.selectedID, target.id)
                expectTrue(store.credentials.first { $0.id == target.id }?.archived == true)
            }
        }
        runCheck("CapabilityAudit.explicit-EOS-region-is-usable-evidence-without-guessing-an-ambiguous-region") {
            expectEqual(ProviderPreset.matches(in: "百度 EOS 新加坡 API Key: fixture-only").map(\.id), ["bce-sg"])
            expectEqual(ProviderPreset.matches(in: "BCEVOD Germany API Key: fixture-only").map(\.id), ["bce-de"])
            expectEqual(ProviderPreset.matches(in: "百度 EOS 新加坡或德国，还不确定").filter(\.isBCE).count, 4)
            expectEqual(ProviderPreset.matches(in: "百度 EOS API Key: sk-fixture-de-region-123456789").filter(\.isBCE).count, 4)
            expectEqual(ProviderPreset.matches(in: "百度 EOS 新加坡 API Key: sk-fixture-de-region-123456789").map(\.id), ["bce-sg"])
        }
        runCheck("CapabilityAudit.provider-verification-error-preserves-original-values") {
            var record = DeepChecks.record(); record.apiKey = "fixture-echoed-verification-secret"
            let data = try JSONSerialization.data(withJSONObject: ["error": ["code": "DeploymentNotFound", "message": "fixture-deployment is disabled; credential " + record.apiKey]])
            let check = APIClient.classify(status: 400, data: data, record: record, testModel: true)
            expectEqual(check.state, .uncertain); expectTrue(check.message.contains("fixture-deployment")); expectTrue(check.message.contains(record.apiKey))
        }
        runCheck("CapabilityAudit.note-edit-preserves-legacy-implicit-query-defaults-and-successful-proof") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var original = DeepChecks.record(); original.baseURL = "https://api.deepseek.com"; original.model = "fixture-model"
                original.check = CheckResult(state: .valid, message: "passed", requestMethod: "POST")
                expectTrue(store.importRecords([original])); original = try unwrap(store.selected)
                var edited = original; edited.notes = "修改备注"
                let prepared = CredentialEditor.preparedForSave(edited, previous: original)
                expectTrue(prepared.verificationURL.isEmpty); expectTrue(prepared.balanceURL.isEmpty)
                expectTrue(store.save(prepared, expectedUpdatedAt: original.updatedAt)); expectEqual(store.selected?.check, original.check)
            }
        }
        runCheck("CapabilityAudit.editor-protocol-reflects-and-switches-legacy-templates-without-resetting-a-checked-template") {
            var record = DeepChecks.record(); record.model = "fixture-model"
            record.callTemplate = ModelCallTemplate(path: "responses", body: #"{"model":"fixture-model","input":"Hi"}"#, model: record.model)
            expectEqual(record.inferenceKind, .responses)
            expectEqual(CredentialEditor.changingProtocol(record, to: .responses), record)
            let request = try APIClient.modelTestRequest(for: record)
            let body = try unwrap(try JSONSerialization.jsonObject(with: try unwrap(request.httpBody)) as? [String: Any])
            expectNil(body["max_output_tokens"]); expectNil(body["max_tokens"])
            let chat = CredentialEditor.changingProtocol(record, to: .compatible)
            expectNil(chat.callTemplate); expectEqual(chat.inferenceKind, .compatible)
            expectTrue(try APIClient.modelRequest(for: chat).url?.path.hasSuffix("/chat/completions") == true)
        }
        runCheck("CapabilityAudit.permanent-delete-rechecks-the-reviewed-record-and-its-latest-archive-state") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); expectTrue(store.save(record)); record = try unwrap(store.selected)
                store.permanentlyDelete(record); expectEqual(store.credentials.count, 1)
                store.archive([record.id]); let snapshot = try unwrap(store.selected)
                store.archive([record.id], archived: false); store.permanentlyDelete(snapshot, expectedUpdatedAt: snapshot.updatedAt)
                expectEqual(store.credentials.count, 1); expectTrue(store.selected?.archived == false)
                store.archive([record.id]); var edited = try unwrap(store.selected); edited.notes = "确认框打开后条目有变动"
                expectTrue(store.save(edited)); store.permanentlyDelete(snapshot, expectedUpdatedAt: snapshot.updatedAt)
                expectEqual(store.credentials.count, 1)
                let current = try unwrap(store.selected); store.permanentlyDelete(current, expectedUpdatedAt: current.updatedAt)
                expectTrue(store.credentials.isEmpty)
            }
        }
        await responses()
        await organizerTemplate()
    }
    static func responses() async {
        for (kind, body) in [(ServiceKind.compatible, #"{"choices":[{"message":{"content":"Hi"}}]}"#), (.anthropic, #"{"type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}]}"#), (.responses, #"{"object":"response","status":"completed","output":[]}"#), (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#)] {
            var record = DeepChecks.record(); record.model = "fixture-model"; record.kind = kind
            let session = MockURLProtocol.session { _ in MockReply(headers: ["X-Request-ID": "fixture-trace-id", "Set-Cookie": "fixture-private-session"], body: Data(body.utf8)) }
            let result = await APIClient.verify(record, session: session, testModel: true); session.invalidateAndCancel()
            expectEqual(result.state, .valid); expectTrue(result.response?.headers.contains("fixture-trace-id") == true)
            expectTrue(result.response?.headers.contains("fixture-private-session") == true); expectFalse(result.response?.body.isEmpty == true)
            checkpoint("CapabilityAudit.verified-response-is-retained-for-" + kind.rawValue)
        }
        runCheck("CapabilityAudit.response-evidence-is-bounded-original-encrypted-and-backward-compatible") {
            try NewFeatureChecks.isolated { root in
                var record = DeepChecks.record(); record.apiKey = "fixture-response-secret-123456789"
                let full = Data((String(repeating: "x", count: LogRedaction.bodyLimit - 7) + record.apiKey + String(repeating: "z", count: 1000)).utf8)
                let response = CheckedResponse(full, record: record)
                expectTrue(response.truncated); expectTrue(response.body.contains(String(record.apiKey.prefix(7)))); expectTrue(response.body.utf8.count <= RecordedContent.bodyLimit)
                var result = CheckResult(state: .uncertain, message: "fixture-error", response: response)
                record.check = result
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                try disk.save(VaultData(credentials: [record])); expectEqual(try disk.load().credentials.first?.check?.response, response)
                expectFalse(String(decoding: try Data(contentsOf: root.appendingPathComponent("vault.kdv")), as: UTF8.self).contains(record.apiKey))
                result.response = nil; let data = try JSONEncoder().encode(result)
                expectNil(try JSONDecoder().decode(CheckResult.self, from: data).response)
            }
        }
        var record = DeepChecks.record(); record.balanceURL = "https://fixture.invalid/balance"
        let session = MockURLProtocol.session { _ in MockReply(status: 403, body: Data(#"{"error":{"message":"fixture-billing-scope is missing"}}"#.utf8)) }
        do { _ = try await APIClient.balance(record, session: session); checkFailures.append("balance failure was hidden") }
        catch { expectTrue(error.localizedDescription.contains("fixture-billing-scope")) }
        session.invalidateAndCancel(); checkpoint("CapabilityAudit.balance-errors-preserve-actionable-service-reasons")
    }
    static func organizerTemplate() async {
        func event(_ value: [String: Any]) -> String { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n\n" }
        let item: [String: Any] = ["id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "需要确认部署 ID。", "annotations": []]]]
        let final: [String: Any] = ["id": "resp_fixture", "object": "response", "status": "completed", "created_at": 1, "model": "fixture-model", "output": [item], "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2]]
        let stream = event(["type": "response.created", "response": ["id": "resp_fixture", "status": "in_progress", "output": []]]) + event(["type": "response.output_item.added", "output_index": 0, "item": item]) + event(["type": "response.output_item.done", "output_index": 0, "item": item]) + event(["type": "response.completed", "response": final])
        let server = FixtureServer { request in
            guard request.target == "/organizer/v1/responses" else { return FixtureResponse(status: 400, chunks: [Data(#"{"error":{"message":"expected Responses protocol"}}"#.utf8)]) }
            return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [Data(stream.utf8)])
        }
        do {
            try server.start(); defer { server.stop() }
            for _ in 0..<150 { if server.port != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            var service = DeepChecks.record(); service.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/organizer/v1"; service.model = "fixture-model"
            service.callTemplate = ModelCallTemplate(path: "responses", body: #"{"model":"fixture-model","input":"Hi"}"#, model: service.model)
            let interaction = AgentInteraction()
            let task = Task { try await ImportAgent.run(raw: "资料中的模型部署 ID 需要确认。", service: service, model: service.model, images: [], interaction: interaction, progress: { _ in }) }
            for _ in 0..<400 {
                if interaction.question != nil || interaction.failure != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            task.cancel(); _ = try? await task.value
            expectEqual(server.received.first?.target, "/organizer/v1/responses")
            expectTrue(interaction.lastReply?.question.contains("部署 ID") == true)
            checkpoint("CapabilityAudit.official-Agent-uses-the-actual-protocol-of-a-legacy-saved-template")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("CapabilityAudit.legacy-Agent-protocol") }
    }
}
