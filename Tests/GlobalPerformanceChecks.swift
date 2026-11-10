import Foundation
import AppKit
import CryptoKit

@MainActor enum GlobalPerformanceChecks {
    static func run() async {
        search()
        replacements()
        images()
        editor()
        await panels()
        await files()
        await logging()
        await LayoutChecks.commonPreparedPanels()
    }
    static func search() {
        runCheck("GlobalPerformance.library-search-ranking-hints-and-display-policy-are-reused-until-data-changes") {
            let cache = CredentialRenderCache()
            let models = (0..<240).map { "fixture-model-\($0)" }
            var records = (0..<600).map { index -> Credential in
                var value = DeepChecks.record(); value.name = "Service \(index)"; value.apiKey = "fixture-library-key-\(index)-123456789"; value.updatedAt = Date(timeIntervalSince1970: Double(index)); value.modelCatalog = ModelCatalog(models: models); return value
            }
            records[0].name = "fixture-model-239"; records[1].favorite = true; records[2].archived = true
            cache.reset(records)
            let started = Date(), first = cache.list(records, shelf: .all, query: "fixture-model-239"), cold = Date().timeIntervalSince(started)
            expectEqual(first.records.first?.id, records[0].id); expectEqual(first.records.dropFirst().first?.id, records[1].id)
            expectEqual(first.hints[records[1].id], "模型：fixture-model-239"); expectFalse(first.records.contains { $0.id == records[2].id })
            let builds = cache.queryBuilds, modelBuilds = cache.modelBuilds, warmStart = Date()
            for _ in 0..<100 { expectEqual(cache.list(records, shelf: .all, query: "fixture-model-239").records.count, 599); _ = cache.displayPolicy(records, full: false) }
            let warm = Date().timeIntervalSince(warmStart)
            expectEqual(cache.queryBuilds, builds); expectEqual(cache.modelBuilds, modelBuilds); expectEqual(cache.policyBuilds, 1)
            records[0].name = "renamed"; records[0].modelCatalog?.models = ["new-model"]
            records[1].favorite = false; records[1].archived = true; records[3].apiKey = "rotated-library-secret"; records.remove(at: 4)
            cache.reset(records)
            let changed = cache.list(records, shelf: .all, query: "fixture-model-239")
            expectFalse(changed.records.contains { $0.id == records[0].id || $0.id == records[1].id })
            expectEqual(cache.list(records, shelf: .all, query: "new-model").records.first?.id, records[0].id)
            expectTrue(cache.displayPolicy(records, full: false).secrets.contains("rotated-library-secret"))
            expectTrue(cache.displayPolicy(records, full: true).fullContent)
            print("GLOBAL SEARCH METRICS records=600 catalog_each=240 cold_ms=\(Int(cold * 1000)) cached_100_ms=\(Int(warm * 1000)) query_builds_for_100=1")
        }
    }
    static func replacements() {
        runCheck("GlobalPerformance.shared-secret-replacement-is-linear-noncascading-and-preserves-overlap-and-Unicode") {
            let raw = String(repeating: "prefix-key-long🙂|prefix-key|", count: 70000)
            let start = Date(), actual = raw.replacingSecrets(["prefix-key-long":"KEYDOCK_SECRET_1", "prefix-key":"短", "KEYDOCK_SECRET_1":"must-not-cascade"])
            expectEqual(actual, String(repeating: "KEYDOCK_SECRET_1🙂|短|", count: 70000))
            expectEqual("a🙂a".replacingSecrets(["a":"", "🙂":"$1\\literal"]), "$1\\literal")
            expectEqual("small".replacingSecrets([String(repeating: "a", count: 10000):"hidden"]), "small")
            let activity = AgentActivity(), fields = String(repeating: "api_key: field-value🙂\n", count: 20000), started = Date()
            expectEqual(activity.safe(fields), String(repeating: "api_key: [已隐藏]\n", count: 20000))
            expectEqual(activity.safe("api_key: KEYDOCK_SECRET_1\nauthorization: keydock-local-fixture\nsecret: actual-value"), "api_key: KEYDOCK_SECRET_1\nauthorization: keydock-local-fixture\nsecret: [已隐藏]")
            print("GLOBAL FIELD METRICS fields=20000 elapsed_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            print("GLOBAL REDACTION METRICS literal_matches=140000 fields=20000 utf8=\(raw.utf8.count) combined_elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        }
    }
    static func images() {
        runCheck("GlobalPerformance.image-thumbnails-reuse-immutable-pixels-without-resizing-original-preview") {
            let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 900, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let image = try ImportImage(data: unwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])))
            let thumbnail = try unwrap(image.thumbnail); expectEqual(thumbnail.size.width, 640)
            thumbnail.size = NSSize(width: 10, height: 10)
            expectEqual(try unwrap(image.thumbnail).size.width, 640)
            expectEqual(try unwrap(image.preview).size.width, 1600)
            let first = try unwrap(image.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let second = try unwrap(image.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)); expectTrue(first === second)
        }
    }
    static func panels() async {
        let model = CodePresentation(), key = "fixture'large-key-123456789", policy = HTTPLogDisplayPolicy(fullContent: false, secrets: ["fixture'large-key-123456789"])
        var raw = URLRequest(url: URL(string: "https://fixture.invalid/chat")!); raw.httpMethod = "POST"; raw.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        raw.httpBody = Data(("{\"key\":\"" + key + "\",\"input\":\"" + String(repeating: "说明文字", count: 10000) + "\"}").utf8)
        let request = CheckedRequest(raw)
        let response = CheckedResponse(Data(("{\"key\":\"" + key + "\",\"output\":\"" + String(repeating: "返回文字", count: 10000) + "\"}").utf8), record: DeepChecks.record())
        let scope = CodeScope(contents: [.request(request), .response(response, request)], policy: policy)
        await model.prepare(scope)
        expectEqual(model.documents.count, 2)
        for doc in model.documents.values { expectFalse(doc.text.contains(key)); expectTrue(doc.initialLayout != nil) }
        for _ in 0..<20 { await model.prepare(scope) }; expectEqual(model.preparations, 2)
        let original = Task { await model.prepare(.init(contents: [.source(LargeBodyChecks.source())], policy: .init(fullContent: true, secrets: []))) }
        await Task.yield(); original.cancel(); await model.prepare(scope); await original.value
        expectEqual(model.scope, scope); for doc in model.documents.values { expectFalse(doc.text.contains(key)) }
        checkpoint("GlobalPerformance.verification-and-source-use-background-documents-and-ignore-obsolete-visible-content")
    }
    static func editor() {
        runCheck("GlobalPerformance.rich-import-document-reuses-derived-text-images-and-paste-until-an-edit") {
            let image = try NewFeatureChecks.image()
            var document = ImportDocument(ImportPaste(text: String(repeating: "用户资料🙂\n", count: 18000), images: [image]))
            let identity = document.identity, text = document.text, paste = document.paste.text
            expectEqual(document.images.count, 1)
            expectFalse(paste.contains("[图片 1]"))
            let start = Date()
            for _ in 0..<1000 { expectEqual(document.text, text); expectEqual(document.images.count, 1); expectEqual(document.paste.text, paste) }
            expectEqual(document.derivationCount, 1)
            try document.append(ImportPaste(text: "补充", images: [image]))
            expectNotEqual(document.identity, identity); expectTrue(document.text.contains("补充")); expectEqual(document.images.count, 1)
            expectEqual(document.derivationCount, 1)
            print("GLOBAL EDITOR METRICS cached_accesses=3000 derivations=1 elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        }
    }
    private static func wait(_ gate: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in DispatchQueue.global().async { gate.wait(); continuation.resume() } }
    }
    static func files() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-FilePerformance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = try NewFeatureChecks.image(), photo = root.appendingPathComponent("fixture.jpg"), text = root.appendingPathComponent("fixture.txt")
            try image.data.write(to: photo)
            try ("API Key: fixture-file-secret\n" + photo.path).write(to: text, atomically: true, encoding: .utf8)
            let paste = try await ImportFileLoader.load([text], images: false)
            expectTrue(paste.text.contains("fixture-file-secret")); expectEqual(paste.images.count, 1)
            let images = try await ImportFileLoader.load([photo, root.appendingPathComponent("missing.jpg")], images: true)
            expectEqual(images.images.count, 1); expectEqual(images.errors.count, 1)
            let canceled = Task { try await ImportFileLoader.load([text], images: false) }; canceled.cancel()
            do { _ = try await canceled.value; checkFailures.append("canceled file import returned data") } catch is CancellationError { }
            let large = root.appendingPathComponent("large.txt"); try Data(repeating: 65, count: 1_000_001).write(to: large)
            do { _ = try await ImportFileLoader.load([large], images: false); checkFailures.append("oversized text file accepted") } catch { }
            checkpoint("GlobalPerformance.file-selection-reads-and-normalizes-in-background-and-honors-cancellation-and-size-limits")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("GlobalPerformance.file-input") }
    }
    static func logging() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-LoggingPerformance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0), lock = NSLock()
        var first = true
        let writer = AgentLogWriter { record, directory in
            lock.lock(); let block = first; first = false; lock.unlock()
            if block { entered.signal(); gate.wait(); throw KeyDockError.message("old-run fixture failure") }
            try AgentLogWriter.persist(record, directory)
        }
        defer { gate.signal() }
        let activity = AgentActivity(writer: writer); activity.directory = root
        activity.begin(raw: "fixture", service: DeepChecks.record(), model: "fixture")
        let start = Date(); activity.finish("completed", detail: "old completed"); let duration = Date().timeIntervalSince(start)
        await wait(entered)
        expectTrue(duration < 0.05)
        activity.prepareForRun(); activity.begin(raw: "second", service: DeepChecks.record(), model: "fixture"); activity.finish("completed", detail: "new completed")
        try? await Task.sleep(for: .milliseconds(40)); expectNil(activity.saveError)
        gate.signal(); await activity.waitForPersistence(); try? await Task.sleep(for: .milliseconds(30))
        expectNil(activity.saveError)
        do {
            let text = try String(contentsOf: root.appendingPathComponent(activity.record.id.uuidString.lowercased() + ".json"), encoding: .utf8)
            expectTrue(text.contains("new completed")); expectTrue(text.contains("completed"))
        } catch { checkFailures.append(error.localizedDescription) }
        checkpoint("GlobalPerformance.agent-finish-does-not-wait-for-slow-disk-and-old-save-errors-cannot-affect-next-run")
        let blocking = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        var once = true
        let bounded = AgentLogWriter { record, directory in
            if once { once = false; started.signal(); blocking.wait() }
            try AgentLogWriter.persist(record, directory)
        }
        defer { blocking.signal() }
        var record = AgentRunRecord(); record.status = "running"
        bounded.submit(.init(record: record, directory: root, ticket: 0, completion: { _ in }))
        await wait(started)
        for index in 1...100 { record.status = "latest-\(index)"; bounded.submit(.init(record: record, directory: root, ticket: index, completion: { _ in })) }
        expectEqual(bounded.pendingCount, 1)
        let id = record.id
        blocking.signal(); _ = await Task.detached { bounded.flush(id) }.value
        expectTrue(try String(contentsOf: root.appendingPathComponent(id.uuidString.lowercased() + ".json"), encoding: .utf8).contains("latest-100"))
        checkpoint("GlobalPerformance.slow-log-storage-coalesces-repeated-run-snapshots-and-persists-the-latest-state")
        print("GLOBAL LOG METRICS blocked_disk_finish_ms=\(Int(duration * 1000)) coalesced_updates=100 pending=1")

        let held = DispatchSemaphore(value: 0), writing = DispatchSemaphore(value: 0)
        var initial = true
        let retained = AgentLogWriter { record, directory in
            if initial { initial = false; writing.signal(); held.wait() }
            try AgentLogWriter.persist(record, directory)
        }
        defer { held.signal() }
        let boundedRoot = root.appendingPathComponent("bounded")
        retained.submit(.init(record: AgentRunRecord(), directory: boundedRoot, ticket: 0, completion: { _ in }))
        await wait(writing)
        var last = AgentRunRecord()
        for ticket in 1...35 { last = AgentRunRecord(); retained.submit(.init(record: last, directory: boundedRoot, ticket: ticket, completion: { _ in })) }
        expectEqual(retained.pendingCount, 20)
        let lastID = last.id
        held.signal(); _ = await Task.detached { retained.flush(lastID) }.value
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: boundedRoot.path).filter { $0.hasSuffix(".json") }.count, 20)
        expectTrue(FileManager.default.fileExists(atPath: boundedRoot.appendingPathComponent(lastID.uuidString.lowercased() + ".json").path))

        var fail = true
        let retryWriter = AgentLogWriter { record, directory in
            if fail { fail = false; throw KeyDockError.message("fixture write failure") }
            try AgentLogWriter.persist(record, directory)
        }
        var owner: AgentActivity? = AgentActivity(writer: retryWriter)
        owner?.directory = root.appendingPathComponent("retry")
        owner?.begin(raw: "fixture", service: DeepChecks.record(), model: "fixture"); owner?.finish("completed", detail: "terminal snapshot")
        await owner?.waitForPersistence(); expectTrue(owner?.saveError != nil)
        owner?.flush(); expectNil(owner?.saveError)
        let released = { [weak owner] in owner == nil }
        let terminalID = owner!.record.id
        owner = nil; expectTrue(released())
        _ = await Task.detached { retryWriter.flush(terminalID) }.value
        expectTrue(try String(contentsOf: root.appendingPathComponent("retry").appendingPathComponent(terminalID.uuidString.lowercased() + ".json"), encoding: .utf8).contains("terminal snapshot"))
        checkpoint("GlobalPerformance.log-backlog-is-bounded-write-failures-recover-and-terminal-snapshots-survive-owner-release")
    }
}
