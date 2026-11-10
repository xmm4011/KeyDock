import Foundation
import CryptoKit
import AppKit

@MainActor enum GlobalSettingsChecks {
    static func run() async {
        await networkTimeoutSettings()
        await proxyTimeoutChangesApplyToNewRequests()
        runCheck("Settings.defaults-hide-sensitive-values-without-recording-bodies-and-full-toggle-is-reversible") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false, pasteboard: board)
                var record = DeepChecks.record(); record.model = "fixture-model"; expectTrue(store.save(record))
                expectFalse(store.showFullContent); expectFalse(store.recordAllBodies); expectTrue(store.capturedCredentialIDs.isEmpty)
                let headers = "Authorization: Bearer " + record.apiKey + "\nSet-Cookie: sid=fixture-private-cookie\naccess-control-allow-credentials: true"
                let data = Data(("{\"echo\":\"" + record.apiKey + "\",\"cookie\":\"fixture-private-cookie\"}").utf8)
                var response = CheckedResponse(data, record: record); response.headers = headers
                let hidden = store.displayResponse(response, request: nil)
                expectFalse(hidden.contains(record.apiKey)); expectFalse(hidden.contains("fixture-private-cookie")); expectTrue(hidden.contains("access-control-allow-credentials: true"))
                store.copy("echo " + record.apiKey); expectFalse(board.string(forType: .string)?.contains(record.apiKey) == true)
                expectTrue(store.setShowFullContent(true)); expectEqual(store.displayResponse(response, request: nil), response.text)
                store.copy("echo " + record.apiKey); expectEqual(board.string(forType: .string), "echo " + record.apiKey)
                expectTrue(store.setShowFullContent(false)); expectEqual(store.displayResponse(response, request: nil), hidden)
                expectTrue(response.text.contains(record.apiKey))
            }
        }
        runCheck("Settings.saved-preferences-survive-reload-and-backup-without-overriding-explicit-local-choice") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let store = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(store.setShowFullContent(true)); expectTrue(store.setRecordAllBodies(true))
                let reopened = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(reopened.showFullContent); expectTrue(reopened.recordAllBodies)
                let bytes = try PortableBackup.create(store.data, password: "fixture-settings-backup")
                let restored = try PortableBackup.restore(bytes, password: "fixture-settings-backup")
                expectEqual(restored.showFullContent, true); expectEqual(restored.recordAllBodies, true)
                expectTrue(reopened.setShowFullContent(false)); expectTrue(reopened.setRecordAllBodies(false)); expectTrue(reopened.restore(restored))
                expectFalse(reopened.showFullContent); expectFalse(reopened.recordAllBodies)
                let old = try JSONDecoder().decode(VaultData.self, from: Data(#"{"version":1,"credentials":[]}"#.utf8))
                expectNil(old.showFullContent); expectNil(old.recordAllBodies)
            }
        }
        runCheck("Settings.global-capture-includes-future-Keys-and-preserves-explicit-per-Key-choice") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var first = DeepChecks.record(); first.model = "fixture-model"; expectTrue(store.save(first))
                expectTrue(store.setRecordAllBodies(true)); expectEqual(store.capturedCredentialIDs, [first.id])
                var second = first; second.id = UUID(); second.apiKey = "fixture-another-key"; second.variablePrefix = ""; expectTrue(store.save(second))
                expectEqual(store.capturedCredentialIDs, [first.id, second.id])
                store.history.setCapture(true, for: first.id)
                expectTrue(store.setRecordAllBodies(false)); expectEqual(store.capturedCredentialIDs, [first.id])
                expectFalse(store.showFullContent)
            }
        }
        runCheck("Settings.failed-write-does-not-turn-on-global-visibility-or-capture") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let first = VaultStore(disk: disk, automaticProxy: false), stale = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(first.commit { $0.organizerModel = "changed-revision" })
                expectFalse(stale.setShowFullContent(true)); expectFalse(stale.showFullContent); expectFalse(stale.recordAllBodies)
            }
        }
        await proxyCapture()
    }
    static func proxyCapture() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false, proxyPort: 0)
        let server = FixtureServer { _ in FixtureResponse(headers: ["Authorization": "Bearer fixture-response-auth"], chunks: [Data(#"{"choices":[{"message":{"content":"fixture-reply"}}],"usage":{"prompt_tokens":1,"completion_tokens":2}}"#.utf8)]) }
        let session = URLSession(configuration: .ephemeral)
        defer { store.proxy.stop(); server.stop(); session.invalidateAndCancel(); store.history.flush() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"; record.model = "fixture-model"
            expectTrue(store.save(record)); store.proxy.start(); await InteractionFlowChecks.wait { store.proxy.running }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(try unwrap(store.proxy.listeningPort))/s/\(record.routeID)/chat/completions")!)
            request.httpMethod = "POST"; request.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization")
            request.httpBody = Data(#"{"model":"fixture-model","messages":[{"role":"user","content":"fixture-request"}]}"#.utf8)
            _ = try await session.data(for: request); await InteractionFlowChecks.wait { store.history.entries.count == 1 }
            let initial = try unwrap(store.history.entries.first)
            expectFalse(initial.bodiesCaptured); expectTrue(initial.requestHeaders.isEmpty); expectTrue(initial.responseBody.isEmpty)
            expectTrue(store.setRecordAllBodies(true))
            _ = try await session.data(for: request); await InteractionFlowChecks.wait { store.history.entries.count == 2 }
            let captured = try store.history.detail(for: unwrap(store.history.entries.first))
            expectTrue(captured.bodiesCaptured); expectTrue(captured.requestHeaders.contains(record.apiKey)); expectTrue(captured.requestBody.contains("fixture-request"))
            expectTrue(captured.responseHeaders.contains("fixture-response-auth")); expectTrue(captured.responseBody.contains("fixture-reply"))
            expectFalse(store.displayHeaders(captured.requestHeaders).contains(record.apiKey))
            expectTrue(store.setShowFullContent(true)); expectEqual(store.displayHeaders(captured.requestHeaders), captured.requestHeaders)
            expectTrue(store.setRecordAllBodies(false))
            _ = try await session.data(for: request); await InteractionFlowChecks.wait { store.history.entries.count == 3 }
            expectFalse(try unwrap(store.history.entries.first).bodiesCaptured); expectEqual(store.history.totals[record.id]?.calls, 3)
            expectEqual(store.history.totals[record.id]?.input, 3); expectEqual(store.history.totals[record.id]?.output, 6)
            expectTrue(store.history.entries[1].bodiesCaptured)
            checkpoint("Settings.real-proxy-switches-off-on-off-for-subsequent-requests-and-keeps-existing-evidence-and-usage")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Settings.real-proxy-capture-completes") }
    }
    private static func networkTimeoutSettings() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Timeouts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); APIClient.verificationTimeout = NetworkTimeouts.defaultVerification }
        do {
            let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
            let store = VaultStore(disk: disk, automaticProxy: false)
            expectEqual(store.verificationTimeout, 60); expectEqual(store.proxyTimeout, 3600)
            expectEqual(APIClient.verificationTimeout, 60); expectEqual(APIClient.session.configuration.timeoutIntervalForResource, 60)
            expectTrue(NetworkTimeouts.proxyChoices.allSatisfy { $0 >= 1800 && $0 <= ProxyTransportPolicy().resourceTimeout })
            expectTrue(store.setVerificationTimeout(120)); expectTrue(store.setProxyTimeout(7200))
            expectEqual(APIClient.verificationTimeout, 120)
            expectEqual(APIClient.session.configuration.timeoutIntervalForRequest, 120); expectEqual(APIClient.session.configuration.timeoutIntervalForResource, 120)
            expectTrue(APIClient.session === APIClient.session)
            let storeIdle = await store.proxy.currentUpstreamIdleTimeout(); expectEqual(storeIdle, 7200)
            expectFalse(store.setVerificationTimeout(5)); expectTrue(store.error != nil); store.error = nil
            expectFalse(store.setProxyTimeout(60)); expectTrue(store.error != nil); store.error = nil
            expectEqual(store.verificationTimeout, 120); expectEqual(store.proxyTimeout, 7200)
            let reopened = VaultStore(disk: disk, automaticProxy: false)
            expectEqual(reopened.verificationTimeout, 120); expectEqual(reopened.proxyTimeout, 7200)
            let reopenedIdle = await reopened.proxy.currentUpstreamIdleTimeout(); expectEqual(reopenedIdle, 7200)
            expectTrue(APIClient.failureMessage(URLError(.timedOut)).contains("2 分钟"))
            expectTrue(APIClient.failureMessage(URLError(.timedOut)).contains("系统设置"))
            var tampered = reopened.data; tampered.verificationTimeout = 1; tampered.proxyTimeout = 1
            _ = try disk.save(tampered, replacing: try disk.revision())
            let fallback = VaultStore(disk: disk, automaticProxy: false)
            expectEqual(fallback.verificationTimeout, 60); expectEqual(fallback.proxyTimeout, 3600); expectEqual(APIClient.verificationTimeout, 60)
            let old = try JSONDecoder().decode(VaultData.self, from: Data(#"{"version":1,"credentials":[]}"#.utf8))
            expectNil(old.verificationTimeout); expectNil(old.proxyTimeout)
            checkpoint("Settings.network-timeouts-default-persist-reject-unknown-values-and-drive-verification-and-proxy")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Settings.network-timeouts") }
    }
    private static func proxyTimeoutChangesApplyToNewRequests() async {
        let server = FixtureServer { _ in FixtureResponse(chunks: [Data("slow".utf8)], headerDelay: 1.5) }
        let proxy = LocalProxy(port: 0, policy: .init(idleTimeout: 30, resourceTimeout: 60))
        let session = URLSession(configuration: .ephemeral)
        defer { proxy.stop(); server.stop(); session.invalidateAndCancel() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            func request() throws -> URLRequest {
                var r = URLRequest(url: URL(string: "http://127.0.0.1:\(try unwrap(proxy.listeningPort))/s/\(record.routeID)/slow")!)
                r.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); r.httpMethod = "POST"; r.httpBody = Data("{}".utf8); return r
            }
            let patient = try await session.data(for: request())
            expectEqual((patient.1 as? HTTPURLResponse)?.statusCode, 200); expectEqual(patient.0, Data("slow".utf8))
            proxy.setUpstreamIdleTimeout(0.4)
            let shortIdle = await proxy.currentUpstreamIdleTimeout(); expectEqual(shortIdle, 0.4)
            let short = try await session.data(for: request())
            expectEqual((short.1 as? HTTPURLResponse)?.statusCode, 504)
            proxy.setUpstreamIdleTimeout(30)
            let restored = try await session.data(for: request())
            expectEqual((restored.1 as? HTTPURLResponse)?.statusCode, 200)
            checkpoint("Settings.proxy-timeout-change-applies-to-new-requests-without-restarting-the-proxy")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Settings.proxy-timeout-runtime") }
    }
}
