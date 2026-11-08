import Foundation
import AppKit
import CryptoKit

// Sequence and delayed-response checks use only temporary vaults and fake keys.
@MainActor enum DeepRetestChecks {
    static func run() async {
        runCheck("DeepRetest.catalog-address-edit-clears-only-the-old-discovered-models") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256)
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = catalogRecord(); record.manualModels = ["manual-spare"]
                record.modelCatalog = ModelCatalog(models: ["old-directory-model"])
                record.check = CheckResult(state: .valid, message: "old directory", models: ["old-directory-model"], requestMethod: "GET")
                expectTrue(store.save(record)); record = try unwrap(store.selected)
                record.verificationURL = "https://catalog.fixture.invalid/new"
                expectTrue(store.save(record, expectedUpdatedAt: record.updatedAt))
                let saved = try unwrap(store.selected)
                expectNil(saved.modelCatalog); expectTrue(saved.availableModels.isEmpty)
                expectEqual(Set(saved.modelOptions), Set(["manual-current", "manual-spare"]))
                expectNil(saved.searchMatch(for: "old-directory-model"))
            }
        }
        runCheck("DeepRetest.import-review-directory-edit-drops-old-catalog-but-description-edit-keeps-it") {
            var original = catalogRecord(); original.manualModels = ["manual-spare"]
            original.modelCatalog = ModelCatalog(models: ["old-directory-model"])
            original.check = CheckResult(state: .valid, message: "old directory", models: ["old-directory-model"], requestMethod: "GET")
            var edited = original; edited.verificationURL = "https://catalog.fixture.invalid/new"
            let changed = ImportView.mergingDraftEdit(edited, original: original, current: original)
            expectNil(changed.modelCatalog); expectNil(changed.check)
            expectEqual(Set(changed.modelOptions), Set(["manual-current", "manual-spare"]))
            edited = original; edited.notes = "仅补充用途"
            let described = ImportView.mergingDraftEdit(edited, original: original, current: original)
            expectEqual(described.modelCatalog, original.modelCatalog); expectEqual(described.check, original.check)
        }
        for status in [200, 403] { await lateCatalog(status: status) }
        await loaderAddressChange()
        await noteEditDuringCatalog()
        await clipboardDeadline()
        for seed in [UInt64(17), 391, 8923] { sequence(seed: seed) }
    }

    private static func catalogRecord() -> Credential {
        var record = DeepChecks.record(); record.model = "manual-current"
        record.baseURL = "https://gateway.fixture.invalid/v1"
        record.verificationURL = "https://catalog.fixture.invalid/old"
        return record
    }
    private static func withStore(_ work: (VaultStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Retest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
        try await work(store)
    }
    private static func lateCatalog(status: Int) async {
        do {
            let started = AuditCounter()
            let session = MockURLProtocol.session { _ in
                started.increment()
                let body = status == 200 ? #"{"data":[{"id":"obsolete-directory-model"}]}"# : #"{"error":{"message":"obsolete-directory-denied"}}"#
                return MockReply(status: status, body: Data(body.utf8), delay: 0.25)
            }
            defer { session.invalidateAndCancel() }
            try await withStore { store in
                expectTrue(store.save(catalogRecord())); let original = try unwrap(store.selected)
                let task = Task { await store.fetchModels(original, session: session) }
                await InteractionFlowChecks.wait { started.value == 1 }; expectEqual(started.value, 1)
                var changed = try unwrap(store.selected); changed.verificationURL = "https://catalog.fixture.invalid/new"
                expectTrue(store.save(changed, expectedUpdatedAt: changed.updatedAt))
                await task.value
                expectTrue(try unwrap(store.selected).availableModels.isEmpty)
                expectNil(store.error); expectTrue(store.modelsChecking.isEmpty)
            }
        } catch { checkFailures.append(error.localizedDescription) }
        checkpoint("DeepRetest.catalog-address-change-rejects-late-HTTP-\(status)-result-and-error")
    }
    private static func loaderAddressChange() async {
        let started = AuditCounter()
        let session = MockURLProtocol.session { request in
            started.increment()
            let old = request.url?.path == "/old"
            return MockReply(body: Data((old ? #"{"data":[{"id":"obsolete-directory-model"}]}"# : #"{"data":[{"id":"current-directory-model"}]}"#).utf8), delay: old ? 0.25 : 0.01)
        }
        defer { session.invalidateAndCancel() }
        let loader = ModelListLoader(); var record = catalogRecord()
        loader.select(record); loader.fetch(session: session)
        await InteractionFlowChecks.wait { started.value == 1 }; expectEqual(started.value, 1)
        record.verificationURL = "https://catalog.fixture.invalid/new"; loader.select(record)
        expectFalse(loader.loading)
        try? await Task.sleep(for: .milliseconds(300))
        expectTrue(loader.models.isEmpty); expectNil(loader.error)
        loader.fetch(session: session); await InteractionFlowChecks.wait { !loader.loading }
        expectEqual(loader.models, ["current-directory-model"]); loader.cancel()
        checkpoint("DeepRetest.model-selector-cancels-old-query-when-only-the-catalog-address-changes")
    }
    private static func noteEditDuringCatalog() async {
        do {
            let started = AuditCounter()
            let session = MockURLProtocol.session { _ in started.increment(); return MockReply(body: Data(#"{"data":[{"id":"current-directory-model"}]}"#.utf8), delay: 0.2) }
            defer { session.invalidateAndCancel() }
            try await withStore { store in
                expectTrue(store.save(catalogRecord())); let original = try unwrap(store.selected)
                let task = Task { await store.fetchModels(original, session: session) }
                await InteractionFlowChecks.wait { started.value == 1 }
                var edited = try unwrap(store.selected); edited.notes = "查询期间补充的备注"
                expectTrue(store.save(edited, expectedUpdatedAt: edited.updatedAt)); await task.value
                expectEqual(store.selected?.availableModels, ["current-directory-model"])
                expectEqual(store.selected?.notes, edited.notes)
            }
        } catch { checkFailures.append(error.localizedDescription) }
        checkpoint("DeepRetest.description-edit-keeps-the-current-catalog-query-and-the-new-description")
    }
    private static func clipboardDeadline() async {
        do {
            try await withStore { temporary in
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let store = VaultStore(disk: temporary.disk, automaticProxy: false, pasteboard: board, clipboardLifetime: .milliseconds(250))
                defer { store.clearSensitiveClipboard() }
                store.copy("fixture-only-delayed-clipboard", sensitive: true)
                func busyMainThread() { Thread.sleep(forTimeInterval: 0.4) }
                busyMainThread()
                try await Task.sleep(for: .milliseconds(50))
                expectNil(board.string(forType: .string))
            }
        } catch { checkFailures.append(error.localizedDescription) }
        checkpoint("DeepRetest.clipboard-expiration-starts-at-copy-time-even-when-the-main-actor-is-busy")
    }
    private static func sequence(seed: UInt64) {
        runCheck("DeepRetest.120-interleaved-edit-model-protocol-archive-dedup-reload-actions-seed-\(seed)") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let store = VaultStore(disk: disk, automaticProxy: false)
                let preset = ProviderPreset.all.first { $0.id == "bce-sg" }!
                var library: [UUID: Set<String>] = [:], aliases: [UUID: String] = [:], prefixes: [UUID: String] = [:]
                var ids: [UUID] = [], state = seed
                func next(_ limit: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 32) % UInt64(limit)) }
                for index in 0..<8 {
                    var record = preset.applying(to: Credential()); record.apiKey = "fixture-sequence-\(seed)-initial-\(index)"; record.model = "seed-model-\(index)"
                    expectTrue(store.save(record)); record = try unwrap(store.selected)
                    ids.append(record.id); library[record.id] = [record.model]; aliases[record.id] = record.localKey; prefixes[record.id] = record.envPrefix
                }
                for step in 0..<120 {
                    let id = ids[next(ids.count)], operation = next(9)
                    var record = try unwrap(store.credentials.first { $0.id == id })
                    switch operation {
                    case 0: store.toggleFavorite(record)
                    case 1: store.archive([id], archived: !record.archived)
                    case 2:
                        if record.archived { store.archive([id], archived: false); record = try unwrap(store.credentials.first { $0.id == id }) }
                        let model = "added-model-\(seed)-\(step)"
                        expectTrue(store.addModel(model, to: record)); library[id, default: []].insert(model)
                    case 3:
                        if record.archived { store.archive([id], archived: false); record = try unwrap(store.credentials.first { $0.id == id }) }
                        let kinds: [ServiceKind] = [.compatible, .anthropic, .responses, .gemini]
                        let index = (try unwrap(kinds.firstIndex(of: record.inferenceKind)) + 1) % kinds.count
                        store.selectProtocol(kinds[index], for: record)
                    case 4:
                        record.notes = "步骤 \(step) 的用途说明"; expectTrue(store.save(record, expectedUpdatedAt: record.updatedAt))
                    case 5:
                        let stale = record; record.notes = "较新的步骤 \(step)"
                        expectTrue(store.save(record, expectedUpdatedAt: record.updatedAt))
                        var older = stale; older.name = "不应覆盖较新内容"
                        expectFalse(store.save(older, expectedUpdatedAt: stale.updatedAt))
                        expectEqual(store.credentials.first { $0.id == id }?.notes, record.notes)
                    case 6:
                        record.id = UUID(); expectTrue(store.importRecords([record])); expectEqual(store.credentials.count, ids.count)
                    case 7:
                        let snapshot = store.credentials; store.load(); expectEqual(store.credentials, snapshot)
                    default:
                        record.apiKey = "fixture-sequence-\(seed)-rotated-\(step)"; expectTrue(store.save(record, expectedUpdatedAt: record.updatedAt))
                        library[id] = [record.model]
                    }
                    expectEqual(Set(store.credentials.map(\.id)), Set(ids))
                    expectEqual(Set(store.credentials.map(\.fingerprint)).count, ids.count)
                    expectEqual(try disk.load().credentials, store.credentials)
                    for item in store.credentials {
                        expectEqual(item.localKey, aliases[item.id]); expectEqual(item.envPrefix, prefixes[item.id])
                        expectEqual(Set(item.modelOptions), library[item.id] ?? [])
                        expectFalse(item.safeShareText.contains(item.apiKey))
                        for model in item.modelOptions { expectTrue(item.searchMatch(for: model) != nil) }
                    }
                }
            }
        }
    }
}
