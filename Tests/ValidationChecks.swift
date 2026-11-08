import Foundation
import CryptoKit

@MainActor enum ValidationChecks {
    static func run() async {
        do {
            var template = record()
            template.callTemplate = ModelCallTemplate(path: "chat/completions", body: #"{"model":"fixture-model","messages":[{"role":"user","content":"Hi"}],"max_tokens":8}"#, model: "fixture-model")
            try await withStore(template) { store in
                let session = MockURLProtocol.session { request in
                    expectEqual(request.httpMethod, "POST")
                    return callReply()
                }; defer { session.invalidateAndCancel() }
                await store.verify(try unwrap(store.selected), session: session, testModel: true)
                let passed = try unwrap(store.selected?.check); expectEqual(passed.state, .valid)
                store.verifyAll(session: session); await waitForBatch(store)
                expectEqual(store.selected?.check, passed); expectEqual(store.selected?.stateTitle, "调用通过")
                expectEqual(store.selected?.connectionCheck?.state, .uncertain)
                expectEqual(try store.disk.load().credentials.first?.check, passed)
                expectTrue(store.selected?.connectionCheck?.request == nil)
                checkpoint("Validation.batch-skips-paid-template-calls-without-erasing-passed-inference-and-persists-evidence")
            }
            for (label, reply) in [
                ("unsupported", MockReply(status: 404)),
                ("catalog-success", MockReply(body: Data(#"{"data":[{"id":"fixture-model"},{"id":"fixture-other"}]}"#.utf8))),
                ("timeout", MockReply(error: URLError(.timedOut))),
                ("directory-forbidden", MockReply(status: 403))
            ] {
                try await withStore(record()) { store in
                    let session = MockURLProtocol.session { request in request.httpMethod == "POST" ? callReply() : reply }
                    defer { session.invalidateAndCancel() }
                    await store.verify(try unwrap(store.selected), session: session, testModel: true)
                    let passed = try unwrap(store.selected?.check)
                    store.verifyAll(session: session); await waitForBatch(store)
                    expectEqual(store.selected?.check, passed); expectEqual(store.selected?.stateTitle, "调用通过")
                    expectEqual(store.selected?.connectionCheck?.requestMethod, "GET")
                    if label == "catalog-success" { expectTrue(store.selected?.availableModels.contains("fixture-other") == true) }
                    checkpoint("Validation.batch-connection-\(label)-preserves-actual-passed-call-with-separate-diagnostic")
                }
            }
            try await withStore(record()) { store in
                let session = MockURLProtocol.session { request in
                    request.httpMethod == "POST" ? callReply() : MockReply(status: 401, body: Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8))
                }; defer { session.invalidateAndCancel() }
                await store.verify(try unwrap(store.selected), session: session, testModel: true)
                expectEqual(store.selected?.stateTitle, "调用通过")
                store.verifyAll(session: session); await waitForBatch(store)
                expectEqual(store.selected?.check?.state, .invalid); expectTrue(store.selected?.cleanupCandidate == true)
                var rotated = try unwrap(store.selected); rotated.apiKey = "fixture-new-validation-key"
                expectTrue(store.save(rotated)); expectNil(store.selected?.check); expectNil(store.selected?.connectionCheck)
                checkpoint("Validation.real-authentication-failure-remains-visible-and-key-rotation-clears-old-diagnostics")
            }
            try await withStore(record()) { store in
                let session = MockURLProtocol.session { request in request.httpMethod == "POST" ? callReply() : MockReply(status: 404) }
                defer { session.invalidateAndCancel() }
                await store.verify(try unwrap(store.selected), session: session, testModel: true)
                var changed = try unwrap(store.selected); changed.model = "fixture-different-model"
                expectTrue(store.save(changed)); expectNil(store.selected?.check)
                store.verifyAll(session: session); await waitForBatch(store)
                expectEqual(store.selected?.check?.state, .uncertain); expectNotEqual(store.selected?.stateTitle, "调用通过")
                checkpoint("Validation.model-change-does-not-inherit-passed-inference-from-a-different-model")
            }
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Validation.batch-evidence") }
        runCheck("Validation.current-model-remains-selectable-and-copyable-without-a-catalog") {
            expectEqual(Credential.modelChoices(current: "gemini-2.5-flash", available: []), ["gemini-2.5-flash"])
            expectEqual(Credential.modelChoices(current: " gemini-2.5-flash ", available: ["gemini-2.5-flash", "qwen", "qwen", ""]), ["gemini-2.5-flash", "qwen"])
            expectEqual(Credential.modelChoices(current: "", available: ["only-model"]), ["only-model"])
            expectEqual(Credential.modelChoices(current: " ", available: []), [])
        }
    }
    private static func record() -> Credential {
        var record = DeepChecks.record(); record.name = "Validation fixture"; record.baseURL = "https://example.com/v1"; record.model = "fixture-model"; return record
    }
    private static func callReply() -> MockReply { MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)) }
    private static func withStore(_ record: Credential, _ work: (VaultStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
        expectTrue(store.save(record)); try await work(store)
    }
    private static func waitForBatch(_ store: VaultStore) async {
        for _ in 0..<100 { if !store.batchRunning { return }; try? await Task.sleep(for: .milliseconds(15)) }
        expectFalse(store.batchRunning)
    }
}
