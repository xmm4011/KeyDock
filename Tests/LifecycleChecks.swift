import Foundation
import CryptoKit
import AppKit

@MainActor enum LifecycleChecks {
    static func run() async {
        runCheck("Lifecycle.deleting-an-unselected-record-keeps-the-current-detail") {
            try withStore { store, _ in
                var selected = DeepChecks.record(); selected.archived = true
                var other = selected; other.id = UUID(); other.apiKey = "fixture-other-archived-key"
                expectTrue(store.save(selected)); expectTrue(store.save(other)); store.selectedID = selected.id
                store.permanentlyDelete(other)
                expectEqual(store.selectedID, selected.id); expectEqual(store.selected?.id, selected.id)
                expectEqual(store.credentials.count, 1)
                store.permanentlyDelete(selected); expectNil(store.selectedID)
            }
        }
        runCheck("Lifecycle.delete-prunes-own-history-capture-environment-and-organizer") {
            try withStore { store, key in
                var a = DeepChecks.record(); a.variablePrefix = "AUDIT_A"
                var b = a; b.id = UUID(); b.apiKey = "fixture-other-account"; b.variablePrefix = "AUDIT_B"
                expectTrue(store.save(a)); expectTrue(store.save(b))
                expectTrue(store.commit { $0.organizerServiceID = a.id; $0.organizerModel = "old-service-model" })
                store.history.setCapture(true, for: a.id); store.history.setCapture(true, for: b.id)
                store.history.append(entry(a.id)); store.history.append(entry(b.id))
                store.toggleSystemEnvironment(a); expectTrue(store.userEnvironment.contains(a.id))
                store.archive([a.id]); store.permanentlyDelete(a)
                expectFalse(store.history.entries.contains { $0.credentialID == a.id })
                expectNil(store.history.totals[a.id]); expectFalse(store.history.captureBodies.contains(a.id))
                expectEqual(store.history.totals[b.id]?.calls, 1); expectTrue(store.history.captureBodies.contains(b.id))
                expectFalse(store.userEnvironment.contains(a.id)); expectNil(store.data.organizerServiceID); expectNil(store.data.organizerModel)
                let late = entry(a.id); store.history.append(late)
                expectFalse(store.history.entries.contains { $0.credentialID == a.id })
                store.history.flush()
                let reloaded = ProxyHistory(directory: store.disk.directory, keyProvider: { key })
                expectNil(reloaded.totals[a.id]); expectFalse(reloaded.captureBodies.contains(a.id))
                expectTrue(store.restore(VaultData(credentials: [a])))
                var oldRequest = entry(a.id); oldRequest.startedAt = Date().addingTimeInterval(-5)
                store.history.append(oldRequest); expectNil(store.history.totals[a.id])
                var newRequest = entry(a.id); newRequest.startedAt = Date().addingTimeInterval(1)
                store.history.append(newRequest); expectEqual(store.history.totals[a.id]?.calls, 1)
            }
        }
        runCheck("Lifecycle.clear-ignores-inflight-results-but-keeps-new-requests") {
            try withStore { store, _ in
                let record = DeepChecks.record(); expectTrue(store.save(record))
                store.history.setCapture(true, for: record.id)
                var pending = entry(record.id); pending.startedAt = Date().addingTimeInterval(-10)
                store.history.append(entry(record.id)); store.history.clear(record.id)
                store.history.append(pending)
                expectTrue(store.history.entries.isEmpty); expectNil(store.history.totals[record.id])
                var fresh = entry(record.id); fresh.startedAt = Date().addingTimeInterval(1)
                store.history.append(fresh)
                expectEqual(store.history.entries.count, 1); expectEqual(store.history.totals[record.id]?.calls, 1)
                expectTrue(store.history.captureBodies.contains(record.id)); store.history.flush()
            }
        }
        runCheck("Lifecycle.history-completion-is-idempotent-and-reloads") {
            try withStore { store, key in
                let record = DeepChecks.record(); expectTrue(store.save(record))
                let event = entry(record.id)
                store.history.append(event); store.history.append(event)
                expectEqual(store.history.entries.count, 1); expectEqual(store.history.totals[record.id]?.calls, 1)
                store.history.flush()
                // Avoid intentionally crashing the old implementation on duplicate IDs.
                if Set(store.history.entries.map(\.id)).count == store.history.entries.count {
                    let reloaded = ProxyHistory(directory: store.disk.directory, keyProvider: { key })
                    expectEqual(reloaded.entries.count, 1); expectNil(reloaded.error)
                }
            }
        }
        runCheck("Lifecycle.environment-uses-latest-record-instead-of-old-window") {
            try withStore { store, _ in
                var old = DeepChecks.record(); old.variablePrefix = "BEFORE_EDIT"; old.model = "before-model"
                expectTrue(store.save(old))
                var updated = store.credentials[0]; updated.variablePrefix = "AFTER_EDIT"; updated.model = "after-model"
                expectTrue(store.save(updated)); store.toggleSystemEnvironment(old)
                expectEqual(store.userEnvironment.entries.first?.prefix, "AFTER_EDIT")
                expectEqual(store.userEnvironment.entries.first?.values["AFTER_EDIT_MODEL"], "after-model")
                store.toggleSystemEnvironment(updated); expectTrue(store.userEnvironment.entries.isEmpty)
            }
        }
        runCheck("Lifecycle.old-window-cannot-install-deleted-or-archived-key") {
            try withStore { store, _ in
                let record = DeepChecks.record(); expectTrue(store.save(record))
                store.archive([record.id]); store.permanentlyDelete(record); store.toggleSystemEnvironment(record)
                expectTrue(store.userEnvironment.entries.isEmpty); expectTrue(store.error != nil)
                if store.userEnvironment.contains(record.id) { store.toggleSystemEnvironment(record) }
                expectTrue(store.save(record)); store.archive([record.id]); store.error = nil
                store.toggleSystemEnvironment(record)
                expectTrue(store.userEnvironment.entries.isEmpty); expectTrue(store.error != nil)
            }
        }
        runCheck("Lifecycle.backup-restores-mode-and-keeps-existing-explicit-choice") {
            try withStore { store, _ in
                let localBackup = VaultData(prefersLocalImport: true)
                expectTrue(store.restore(localBackup)); expectEqual(store.data.prefersLocalImport, true)
                expectTrue(store.commit { $0.prefersLocalImport = false })
                expectTrue(store.restore(localBackup)); expectEqual(store.data.prefersLocalImport, false)
            }
        }
        runCheck("Lifecycle.import-ID-collision-cannot-replace-an-existing-alias") {
            try withStore { store, _ in
                var a = DeepChecks.record(); a.provider = "FIRST_PROVIDER"; a.variablePrefix = "ORIGINAL_ROUTE"
                expectTrue(store.save(a))
                var collision = a; collision.provider = "SECOND_PROVIDER"; collision.apiKey = "fixture-second-account-key"
                expectTrue(store.importRecords([collision]))
                expectEqual(store.credentials.count, 2); expectEqual(Set(store.credentials.map(\.id)).count, 2)
                let request = LocalHTTPRequest(method: "GET", target: "/s/" + a.routeID + "/models", headers: ["authorization": "Bearer " + a.localKey], body: Data())
                let upstream = try request.upstream(records: store.credentials).0
                expectEqual(upstream.value(forHTTPHeaderField: "Authorization"), "Bearer " + a.apiKey)
            }
        }
        runCheck("Lifecycle.dedup-normalizes-host-and-default-port-but-keeps-path-case") {
            try withStore { store, _ in
                var a = DeepChecks.record(); a.baseURL = "https://API.EXAMPLE.COM:443/v1/"
                var same = a; same.id = UUID(); same.baseURL = "https://api.example.com/v1"
                expectTrue(store.importRecords([a, same])); expectEqual(store.credentials.count, 1)
                var different = same; different.id = UUID(); different.baseURL = "https://api.example.com/V1"
                expectTrue(store.importRecords([different])); expectEqual(store.credentials.count, 2)
            }
        }
        runCheck("Lifecycle.reload-prunes-legacy-orphan-history") {
            try withStore { store, key in
                let a = DeepChecks.record(); var b = a; b.id = UUID(); b.apiKey = "fixture-retained-key"
                expectTrue(store.save(a)); expectTrue(store.save(b))
                store.history.append(entry(a.id)); store.history.append(entry(b.id)); store.history.setCapture(true, for: a.id); store.history.flush()
                try store.disk.save(VaultData(credentials: [b]))
                let reloaded = VaultStore(disk: store.disk, automaticProxy: false)
                expectFalse(reloaded.history.entries.contains { $0.credentialID == a.id })
                expectNil(reloaded.history.totals[a.id]); expectFalse(reloaded.history.captureBodies.contains(a.id))
                expectEqual(reloaded.history.totals[b.id]?.calls, 1)
                reloaded.history.flush(); _ = key
            }
        }
        runCheck("Lifecycle.corrupt-history-does-not-crash-or-overwrite-original") {
            try withStore { store, key in
                let event = entry(UUID())
                let payload = ProxyHistory.Payload(entries: [event, event], captureBodies: [], totals: nil)
                let bytes = try AES.GCM.seal(JSONEncoder().encode(payload), using: key).combined!
                try bytes.write(to: store.history.fileURL)
                let loaded = ProxyHistory(directory: store.disk.directory, keyProvider: { key })
                expectFalse(loaded.isReadable); expectTrue(loaded.error != nil)
                loaded.setCapture(true, for: event.credentialID); loaded.flush()
                expectEqual(try Data(contentsOf: loaded.fileURL), bytes)
                expectTrue(loaded.captureBodies.isEmpty)
            }
        }
        runCheck("Lifecycle.history-read-and-write-recover-after-keychain-failure") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256); var locked = false
                let provider: () throws -> SymmetricKey = { if locked { throw KeyDockError.message("fixture locked") }; return key }
                let id = UUID(), writer = ProxyHistory(directory: root, keyProvider: provider)
                writer.setCapture(true, for: id); writer.append(entry(id)); writer.flush()
                locked = true
                let reader = ProxyHistory(directory: root, keyProvider: provider)
                expectFalse(reader.isReadable); expectTrue(reader.error != nil)
                locked = false; reader.retryLoading()
                expectTrue(reader.isReadable); expectNil(reader.error); expectEqual(reader.entries.count, 1)
                let original = try Data(contentsOf: reader.fileURL)
                reader.append(entry(id)); locked = true; reader.flush()
                expectTrue(reader.error != nil); expectEqual(try Data(contentsOf: reader.fileURL), original)
                locked = false; reader.retryLoading()
                expectNil(reader.error); expectEqual(ProxyHistory(directory: root, keyProvider: provider).entries.count, 2)
            }
        }
        runCheck("Lifecycle.vault-rejects-duplicate-IDs-without-overwriting") {
            try withStore { store, key in
                let record = DeepChecks.record(); expectTrue(store.save(record))
                let original = try Data(contentsOf: store.disk.fileURL)
                expectFalse(store.commit { $0.credentials.append(record) })
                expectEqual(try Data(contentsOf: store.disk.fileURL), original)
                let duplicate = VaultData(credentials: [record, record])
                let bytes = try AES.GCM.seal(JSONEncoder().encode(duplicate), using: key).combined!
                try bytes.write(to: store.disk.fileURL)
                expectThrows(try store.disk.load()); expectEqual(try Data(contentsOf: store.disk.fileURL), bytes)
            }
        }
        runCheck("Lifecycle.import-trims-fields-and-preserves-original-source") {
            try withStore { store, _ in
                var record = DeepChecks.record(); record.name = "  account  "; record.baseURL = "  https://example.com/v1  "
                record.apiKey = "  fixture-padded-key  "; record.source = "original source with spaces  "
                expectTrue(store.importRecords([record]))
                expectEqual(store.credentials.first?.name, "account"); expectEqual(store.credentials.first?.baseURL, "https://example.com/v1")
                expectEqual(store.credentials.first?.apiKey, "fixture-padded-key"); expectEqual(store.credentials.first?.source, record.source)
            }
        }
        runCheck("Lifecycle.proxy-preserves-encoded-path-query-and-strips-auth-query") {
            var record = DeepChecks.record(); record.baseURL = "https://example.com/tenant%2Fone/v1"
            let request = LocalHTTPRequest(method: "GET", target: "/s/" + record.routeID + "/file/a%2Fb?q=a%2Bb&space=a+b&nested=%252F&%6b%65%79=" + record.localKey, headers: ["authorization": "Bearer " + record.localKey], body: Data())
            let url = try unwrap(request.upstream(records: [record]).0.url)
            let parts = try unwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            expectEqual(parts.percentEncodedPath, "/tenant%2Fone/v1/file/a%2Fb")
            expectEqual(parts.percentEncodedQuery, "q=a%2Bb&space=a+b&nested=%252F")
            record.kind = .custom
            let business = LocalHTTPRequest(method: "GET", target: "/s/" + record.routeID + "/objects?key=business-id&api_key=" + record.localKey, headers: ["authorization": "Bearer " + record.localKey], body: Data())
            let customURL = try unwrap(business.upstream(records: [record]).0.url)
            expectEqual(URLComponents(url: customURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "key=business-id")
        }
        runCheck("Lifecycle.proxy-rejects-encoded-route-confusion-and-traversal") {
            let record = DeepChecks.record()
            for path in ["/s/" + record.routeID + "%2Fmodels/extra", "/s/" + record.routeID + "/%2e%2e/models", "/s/" + record.routeID + "/file%2F..%2Fsecret"] {
                let request = LocalHTTPRequest(method: "GET", target: path, headers: ["authorization": "Bearer " + record.localKey], body: Data())
                expectThrows(try request.upstream(records: [record]))
            }
        }
        runCheck("Lifecycle.log-redaction-hides-JSON-escaped-keys-even-when-truncated") {
            for secret in ["sk-fixture-encoded-secret-001", "fixture/base64+secret=77", "fixture-😀-secret"] {
                let escaped = secret.utf16.map { String(format: "\\u%04x", $0) }.joined()
                for padding in ["", String(repeating: "x", count: 200_000)] {
                    let raw = Data(("{\"echo\":\"" + escaped + padding + "\"}").utf8)
                    let body = LogRedaction.body(raw, secret: secret)
                    expectFalse(body.contains(secret)); expectFalse(body.contains(escaped)); expectTrue(body.utf8.count <= LogRedaction.bodyLimit)
                }
            }
        }
        runCheck("Lifecycle.log-redaction-hides-percent-encoded-other-keys") {
            let secret = "fixture+percent/key=88"
            let encoded = try unwrap(secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
            let doubled = try unwrap(encoded.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
            for text in ["https://example.com/file/" + encoded, "progress 50% done; key=" + doubled, #"{\"key\":\"fixture+percent\/key=88\"}"#] {
                let safe = LogRedaction.text(text, secret: "different-key", otherSecrets: [secret])
                expectFalse(safe.contains(secret)); expectFalse(safe.contains(encoded)); expectFalse(safe.contains(doubled))
            }
        }
        await staleRequestCheck()
        await liveClearAndDeleteCheck()
        await staleBalanceCheck()
        await continuousPersistenceCheck()
    }
    private static func staleRequestCheck() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            let counter = AuditCounter()
            let session = MockURLProtocol.session { _ in counter.increment(); return MockReply(body: Data(#"{"data":[{"id":"fixture-model"}]}"#.utf8)) }
            defer { session.invalidateAndCancel() }
            expectTrue(store.save(DeepChecks.record())); let old = store.credentials[0]
            var updated = old; updated.apiKey = "fixture-rotated-key"; expectTrue(store.save(updated))
            await store.verify(old, session: session)
            expectEqual(counter.value, 0); expectTrue(store.checking.isEmpty)
            let current = store.credentials[0]; store.archive([current.id]); store.permanentlyDelete(current)
            await store.verify(current, session: session)
            expectEqual(counter.value, 0)
        } catch { checkFailures.append("Lifecycle.stale-network: " + error.localizedDescription) }
        checkpoint("Lifecycle.stale-verify-cannot-send-edited-or-deleted-credentials")
    }
    private static func liveClearAndDeleteCheck() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            defer { store.history.flush() }
            let server = FixtureServer { _ in FixtureResponse(chunks: [Data("{\"usage\":".utf8), Data("{\"prompt_tokens\":2,\"completion_tokens\":3}}".utf8)], interval: 0.2) }
            let proxy = LocalProxy(port: 0), session = URLSession(configuration: .ephemeral)
            defer { proxy.stop(); server.stop(); session.invalidateAndCancel() }
            try server.start()
            for _ in 0..<200 { if server.port != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/tenant%2Fone/v1"
            expectTrue(store.save(record)); store.history.setCapture(true, for: record.id)
            proxy.update(store.credentials)
            proxy.recordHistory(captureBodies: [record.id]) { entry in Task { @MainActor in store.history.append(entry) } }
            proxy.start()
            for _ in 0..<200 { if proxy.running { break }; try await Task.sleep(for: .milliseconds(10)) }
            let port = try unwrap(proxy.listeningPort)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(record.routeID)/file/a%2Fb?q=a%2Bb")!)
            request.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization")
            let pending = Task { try await session.data(for: request) }
            for _ in 0..<200 { if server.received.count >= 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
            expectEqual(server.received.first?.target, "/tenant%2Fone/v1/file/a%2Fb?q=a%2Bb")
            store.history.clear(record.id)
            let pendingResult = try await pending.value
            expectEqual((pendingResult.1 as? HTTPURLResponse)?.statusCode, 200)
            try await Task.sleep(for: .milliseconds(80))
            expectTrue(store.history.entries.isEmpty); expectNil(store.history.totals[record.id])
            _ = try await session.data(for: request)
            for _ in 0..<200 { if store.history.totals[record.id]?.calls == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
            expectEqual(store.history.totals[record.id]?.calls, 1); expectEqual(store.history.totals[record.id]?.input, 2)
            let deletedPending = Task { try await session.data(for: request) }
            for _ in 0..<200 { if server.received.count >= 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
            store.archive([record.id]); store.permanentlyDelete(record); proxy.update(store.credentials)
            _ = try await deletedPending.value
            try await Task.sleep(for: .milliseconds(80))
            expectTrue(store.history.entries.isEmpty); expectNil(store.history.totals[record.id]); expectFalse(store.history.captureBodies.contains(record.id))
            store.history.flush()
            expectTrue(ProxyHistory(directory: root, keyProvider: { key }).entries.isEmpty)
        } catch { checkFailures.append("Lifecycle.live-clear-delete: " + error.localizedDescription) }
        checkpoint("Lifecycle.real-proxy-late-completion-cannot-undo-clear-or-delete")
    }
    private static func staleBalanceCheck() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let key = SymmetricKey(size: .bits256), server = FixtureServer { _ in FixtureResponse(chunks: [Data(#"{"balance":5}"#.utf8)]) }
            defer { server.stop() }
            try server.start()
            for _ in 0..<200 { if server.port != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            var record = DeepChecks.record(); record.balanceURL = "http://127.0.0.1:\(try unwrap(server.port))/balance"; record.balancePath = "balance"; record.balanceUnit = "CNY"
            expectTrue(store.save(record)); let old = store.credentials[0]
            var changed = old; changed.apiKey = "fixture-rotated-balance-key"; expectTrue(store.save(changed))
            await store.queryBalance(old); expectTrue(server.received.isEmpty)
            await store.queryBalance(store.credentials[0]); expectEqual(server.received.count, 1); expectEqual(store.credentials[0].balanceSummary, "5 CNY")
            let current = store.credentials[0]; store.archive([current.id]); store.permanentlyDelete(current)
            await store.queryBalance(current); expectEqual(server.received.count, 1)
        } catch { checkFailures.append("Lifecycle.stale-balance: " + error.localizedDescription) }
        checkpoint("Lifecycle.balance-rejects-stale-record-and-uses-current-credentials")
    }
    private static func continuousPersistenceCheck() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let key = SymmetricKey(size: .bits256), history = ProxyHistory(directory: root, keyProvider: { key }), id = UUID()
            defer { history.flush() }
            let producer = Task { @MainActor in
                for _ in 0..<16 { history.append(entry(id)); try? await Task.sleep(for: .milliseconds(50)) }
            }
            try await Task.sleep(for: .milliseconds(400))
            expectTrue(FileManager.default.fileExists(atPath: history.fileURL.path))
            let intermediate = ProxyHistory(directory: root, keyProvider: { key })
            expectTrue((intermediate.totals[id]?.calls ?? 0) > 0)
            await producer.value; history.flush()
            expectEqual(ProxyHistory(directory: root, keyProvider: { key }).totals[id]?.calls, 16)
        } catch { checkFailures.append("Lifecycle.continuous-persistence: " + error.localizedDescription) }
        checkpoint("Lifecycle.continuous-calls-flush-periodically-before-they-stop")
    }
    private static func entry(_ id: UUID) -> ProxyLogEntry { ProxyLogEntry(credentialID: id, method: "POST", status: 200, requestURL: "/v1/chat/completions") }
    private static func withStore(_ body: (VaultStore, SymmetricKey) throws -> Void) throws {
        try NewFeatureChecks.isolated { root in
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            defer { store.history.flush() }
            try body(store, key)
        }
    }
}

final class AuditCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
