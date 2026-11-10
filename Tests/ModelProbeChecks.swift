import Foundation
import AppKit
import SwiftUI
import CryptoKit
import Vision

// Checking every model of every Key: per-call durations, the fastest model,
// one Key's models in order while Keys run in parallel, and one-click cleanup
// of models a service reports as gone. Only mock services and fixture keys.
@MainActor enum ModelProbeChecks {
    private struct Call { let key: String; let model: String; let start: Date; let delay: TimeInterval }
    static func run() async {
        classification()
        await endpoints()
        await batch()
        await cleanup()
        await cancellation()
        layout()
    }

    static func classification() {
        runCheck("ModelProbe.only-explicit-model-statements-mark-a-model-offline") {
            func probe(_ status: Int, _ body: String, model: String = "fixture-gone") -> ModelProbe {
                var result = APIClient.classify(status: status, data: Data(body.utf8), record: record(), endpoint: "https://example.com/v1/chat/completions", testModel: true)
                result.response = CheckedResponse(Data(body.utf8), record: record())
                return ModelProbe(result, model: model, protocolKind: .compatible)
            }
            expectTrue(probe(404, #"{"error":{"message":"The model `fixture-gone` does not exist","code":"model_not_found"}}"#).unavailable)
            expectTrue(probe(400, #"{"error":{"message":"Model Not Exist"}}"#).unavailable)
            expectTrue(probe(503, #"{"error":{"message":"当前分组 default 下对于模型 fixture-gone 无可用渠道"}}"#).unavailable)
            expectTrue(probe(400, #"{"error":{"code":"model_decommissioned","message":"retired"}}"#).unavailable)
            expectTrue(probe(404, #"{"type":"error","error":{"type":"not_found_error","message":"model: fixture-gone"}}"#).unavailable)
            expectTrue(probe(404, #"{"error":{"code":"InvalidEndpointOrModel.NotFound"}}"#).unavailable)
            // Missing route, other parameters, auth, quota, permission and network say nothing about the model.
            expectFalse(probe(404, #"{"error":{"message":"Invalid URL (POST /v1/chat/completions)"}}"#).unavailable)
            expectFalse(probe(400, #"{"error":{"message":"max_tokens is deprecated, use max_completion_tokens"}}"#).unavailable)
            expectFalse(probe(401, #"{"error":{"code":"model_not_found"}}"#).unavailable)
            expectFalse(probe(403, #"{"error":{"message":"model not available in your region"}}"#).unavailable)
            expectFalse(probe(429, #"{"error":{"message":"model not available, retry later"}}"#).unavailable)
            expectFalse(ModelProbe(CheckResult(state: .uncertain, message: "请求超时"), model: "fixture-gone", protocolKind: .compatible).unavailable)
            let passed = probe(200, #"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#)
            expectTrue(passed.passed); expectFalse(passed.unavailable); expectEqual(passed.title, "通过")
            expectEqual(Latency.text(0.0824), "82 ms"); expectEqual(Latency.text(1.234), "1.23 s"); expectEqual(Latency.text(42.42), "42.4 s")
            // Failures say why on one line; timeouts are named as such.
            let rejected = probe(400, #"{"error":{"message":"This model is only supported in v1/images/generations"}}"#, model: "fixture-image")
            expectFalse(rejected.unavailable); expectEqual(rejected.title, "未通过"); expectTrue(rejected.cleanable)
            expectEqual(rejected.reason, "HTTP 400 · 服务返回：This model is only supported in v1/images/generations")
            let timeout = ModelProbe(CheckResult(state: .uncertain, message: APIClient.failureMessage(URLError(.timedOut))), model: "fixture-slow", protocolKind: .compatible)
            expectTrue(timeout.timedOut); expectEqual(timeout.title, "超时"); expectTrue(timeout.reason.contains("请求超时"))
            expectFalse(probe(429, #"{"error":{"message":"slow down"}}"#).cleanable)
            expectEqual(ModelProbe(CheckResult(state: .uncertain, message: "HTTP 404", httpStatus: 404), model: "x", protocolKind: .compatible).reason, "HTTP 404")
            expectEqual(probe(404, "{}").reason, "HTTP 404 · 模型 ID、调用协议或请求路径未匹配，请核对当前模型和接口文档。")
            expectEqual(ModelEndpoint.of("doubao-embedding-vision"), .embedding); expectEqual(ModelEndpoint.of("BAAI/bge-m3"), .embedding)
            expectEqual(ModelEndpoint.of("gpt-image-2.5-flare"), .image); expectEqual(ModelEndpoint.of("doubao-seedream-5.0-flash"), .image)
            expectEqual(ModelEndpoint.of("gemini-3.1-flash-image-preview"), .chat); expectEqual(ModelEndpoint.of("deepseek-v4-pro"), .chat)
        }
    }

    static func endpoints() async {
        do {
            try await withStore { store in
                var value = record(); value.name = "Mixed relay"; value.model = "chat-model"
                value.manualModels = ["doubao-embedding-vision", "gpt-image-2.5", "doubao-seedream-5.0-flash"]
                expectTrue(store.save(value))
                var bodies: [String: [String: Any]] = [:]
                let session = MockURLProtocol.session { request in
                    let body = (try? JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request))) as? [String: Any] ?? [:]
                    let path = request.url?.path ?? ""
                    MockURLProtocol.lock.lock(); bodies[(body["model"] as? String ?? "") + " " + path] = body; MockURLProtocol.lock.unlock()
                    switch path {
                    case "/v1/embeddings": return MockReply(body: Data(#"{"object":"list","data":[{"object":"embedding","embedding":[0.01,0.02]}]}"#.utf8), delay: 0.005)
                    case "/v1/images/generations": return MockReply(body: Data(#"{"created":1,"data":[{"url":"https://example.com/fixture.png"}]}"#.utf8), delay: 0.05)
                    default: return MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8), delay: 0.03)
                    }
                }; defer { session.invalidateAndCancel() }
                let current = try unwrap(store.selected)
                expectEqual(store.probePlan(current).images, 2)
                await store.probeModels(current, session: session)
                expectEqual(Set(bodies.keys), ["chat-model /v1/chat/completions", "doubao-embedding-vision /v1/embeddings", "gpt-image-2.5 /v1/images/generations", "doubao-seedream-5.0-flash /v1/images/generations"])
                expectEqual(bodies["doubao-embedding-vision /v1/embeddings"]?["input"] as? String, "Hi")
                expectEqual(bodies["gpt-image-2.5 /v1/images/generations"]?["quality"] as? String, "low")
                expectEqual(bodies["gpt-image-2.5 /v1/images/generations"]?["n"] as? Int, 1)
                expectNil(bodies["doubao-seedream-5.0-flash /v1/images/generations"]?["quality"])
                let probes = try unwrap(store.selected?.modelProbes)
                expectTrue(probes.count == 4 && probes.values.allSatisfy(\.passed))
                expectTrue(probes["gpt-image-2.5"]?.message.contains("图片") == true); expectTrue(probes["doubao-embedding-vision"]?.message.contains("向量") == true)
                // The embedding call is quickest, but the fastest model shown is a chat model.
                let stored = try unwrap(store.selected)
                expectEqual(stored.fastestProbe(in: store.rendering.models(stored))?.model, "chat-model")
                expectTrue(store.modelCleanup.isEmpty)
                // A 2xx without vectors / images is not a pass.
                let empty = MockURLProtocol.session { _ in MockReply(body: Data(#"{"data":[]}"#.utf8)) }; defer { empty.invalidateAndCancel() }
                var embedding = stored; embedding.model = "doubao-embedding-vision"
                let result = await APIClient.probe(embedding, session: empty)
                expectEqual(result.state, .uncertain); expectEqual(result.requestMethod, "POST"); expectTrue(result.endpoint.hasSuffix("/v1/embeddings"))
                // A model explicitly set to a native protocol keeps it, so no images endpoint is guessed.
                var native = stored; native.kind = .anthropic; native.auth = .xAPIKey; native.model = "doubao-embedding-vision"
                expectEqual(APIClient.probeEndpoint(native), .chat)
                checkpoint("ModelProbe.embedding-and-image-models-are-checked-through-their-own-endpoints")
            }
            // A relay Key currently on Gemini native: the current model keeps it,
            // other models without a choice use Chat Completions like selecting them would.
            try await withStore { store in
                var value = record(); value.name = "Gemini current"; value.kind = .gemini; value.auth = .googleKey
                value.model = "gemini-fixture"; value.manualModels = ["gpt-fixture", "gpt-image-2.5"]
                expectTrue(store.save(value))
                var paths: [String: String] = [:]
                let session = MockURLProtocol.session { request in
                    let path = request.url?.path ?? ""
                    let model = ((try? JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request))) as? [String: Any])?["model"] as? String ?? path
                    MockURLProtocol.lock.lock(); paths[model] = path; MockURLProtocol.lock.unlock()
                    if path.hasSuffix(":generateContent") { return MockReply(body: Data(#"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#.utf8)) }
                    if path.hasSuffix("/images/generations") { return MockReply(body: Data(#"{"data":[{"b64_json":"aGk="}]}"#.utf8)) }
                    return MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8))
                }; defer { session.invalidateAndCancel() }
                let before = try unwrap(store.selected)
                await store.probeModels(before, session: session)
                expectEqual(paths["gpt-fixture"], "/v1/chat/completions"); expectEqual(paths["gpt-image-2.5"], "/v1/images/generations")
                expectTrue(paths.values.contains("/v1/models/gemini-fixture:generateContent"))
                let after = try unwrap(store.selected)
                expectEqual(after.modelProtocols, before.modelProtocols); expectNil(after.modelProtocols?["gpt-image-2.5"])
                expectTrue(after.modelProbes?.values.allSatisfy(\.passed) == true)
                store.selectModel("gpt-image-2.5", for: after)
                expectEqual(store.selected?.inferenceKind, .compatible); expectEqual(store.selected?.check?.state, .valid)
                checkpoint("ModelProbe.current-native-protocol-does-not-spread-to-other-models")
            }
        } catch { checkFailures.append("ModelProbe.endpoints: " + error.localizedDescription); checkpoint("ModelProbe.endpoints") }
    }

    static func batch() async {
        do {
            try await withStore { store in
                var first = record(); first.name = "Probe A"; first.apiKey = "fixture-probe-key-a-123456789"; first.variablePrefix = "PROBE_A"
                first.model = "a-medium"; first.manualModels = ["a-fast", "a-slow"]
                var second = record(); second.name = "Probe B"; second.apiKey = "fixture-probe-key-b-123456789"; second.variablePrefix = "PROBE_B"
                second.model = "b-one"; second.manualModels = ["b-two"]
                expectTrue(store.save(first)); expectTrue(store.save(second))
                let delays = ["a-fast": 0.03, "a-medium": 0.12, "a-slow": 0.2, "b-one": 0.1, "b-two": 0.1]
                var calls: [Call] = []
                let session = MockURLProtocol.session { request in
                    let model = ((try? JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request))) as? [String: Any])?["model"] as? String ?? ""
                    let delay = delays[model] ?? 0
                    MockURLProtocol.lock.lock(); calls.append(Call(key: request.value(forHTTPHeaderField: "Authorization") ?? "", model: model, start: Date(), delay: delay)); MockURLProtocol.lock.unlock()
                    return MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8), delay: delay)
                }; defer { session.invalidateAndCancel() }
                expectEqual(store.batchPlan.models, 5)
                store.verifyAll(session: session); await waitForBatch(store)
                expectEqual(calls.count, 5)
                // Each Key sends its next model only after the previous answer arrived.
                for key in Set(calls.map(\.key)) {
                    let own = calls.filter { $0.key == key }.sorted { $0.start < $1.start }
                    for (previous, next) in zip(own, own.dropFirst()) { expectTrue(next.start.timeIntervalSince(previous.start) >= previous.delay * 0.9) }
                }
                // Different Keys overlap.
                let a = calls.filter { $0.key.hasSuffix("key-a-123456789") }.map(\.start), b = calls.filter { $0.key.hasSuffix("key-b-123456789") }.map(\.start)
                expectTrue(abs((a.min() ?? .distantPast).timeIntervalSince(b.min() ?? .distantFuture)) < 0.08)
                let stored = try unwrap(store.credentials.first { $0.name == "Probe A" })
                expectEqual(Set(try unwrap(stored.modelProbes).keys), ["a-fast", "a-medium", "a-slow"])
                expectTrue(stored.modelProbes?.values.allSatisfy { $0.passed && ($0.duration ?? 0) > 0 } == true)
                expectTrue((stored.modelProbes?["a-slow"]?.duration ?? 0) > (stored.modelProbes?["a-fast"]?.duration ?? 1))
                expectEqual(stored.fastestProbe(in: store.rendering.models(stored))?.model, "a-fast")
                expectEqual(stored.check?.state, .valid); expectTrue(stored.check?.duration != nil); expectEqual(stored.model, "a-medium")
                // Checking changes no protocol choice; switching restores the model's last call and time.
                expectNil(stored.modelProtocols?["a-fast"])
                store.selectModel("a-fast", for: stored)
                let switched = try unwrap(store.credentials.first { $0.id == stored.id })
                expectEqual(switched.check?.state, .valid); expectEqual(switched.check?.duration, stored.modelProbes?["a-fast"]?.duration)
                expectEqual(switched.stateTitle, "调用通过")
                // Removing a model from the list drops its result, so it cannot stay "fastest".
                expectTrue(store.removeModel("a-medium", from: switched))
                expectNil(store.credentials.first { $0.id == stored.id }?.modelProbes?["a-medium"])
                checkpoint("ModelProbe.batch-calls-each-key-models-in-order-keys-in-parallel-and-ranks-the-fastest")
            }
        } catch { checkFailures.append("ModelProbe.batch: " + error.localizedDescription); checkpoint("ModelProbe.batch") }
    }

    static func cleanup() async {
        do {
            try await withStore { store in
                var live = record(); live.name = "Live relay"; live.apiKey = "fixture-cleanup-live-123456789"; live.variablePrefix = "LIVE_RELAY"
                live.model = "keep-current"; live.manualModels = ["keep-ok", "gone-manual", "rate-limited", "bad-parameter"]
                live.modelCatalog = ModelCatalog(models: ["keep-ok", "gone-catalog"])
                var dead = record(); dead.name = "Dead relay"; dead.apiKey = "fixture-cleanup-dead-123456789"; dead.variablePrefix = "DEAD_RELAY"
                dead.model = "dead-current"; dead.manualModels = ["dead-other"]
                var expired = record(); expired.name = "Expired"; expired.apiKey = "fixture-cleanup-expired-123456789"; expired.variablePrefix = "EXPIRED_KEY"; expired.expiresAt = Date().addingTimeInterval(-60)
                expectTrue(store.save(live)); expectTrue(store.save(dead)); expectTrue(store.save(expired))
                let session = MockURLProtocol.session { request in
                    let model = ((try? JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request))) as? [String: Any])?["model"] as? String ?? ""
                    switch model {
                    case "gone-manual", "gone-catalog", "dead-current", "dead-other":
                        return MockReply(status: 404, body: Data(#"{"error":{"message":"The model does not exist","code":"model_not_found"}}"#.utf8))
                    case "rate-limited": return MockReply(status: 429, body: Data(#"{"error":{"message":"Rate limit reached for model"}}"#.utf8))
                    case "bad-parameter": return MockReply(status: 400, body: Data(#"{"error":{"message":"max_tokens is deprecated"}}"#.utf8))
                    default: return MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8))
                    }
                }; defer { session.invalidateAndCancel() }
                store.verifyAll(session: session); await waitForBatch(store)
                let liveID = try unwrap(store.credentials.first { $0.name == "Live relay" }?.id)
                let deadID = try unwrap(store.credentials.first { $0.name == "Dead relay" }?.id)
                let expiredID = try unwrap(store.credentials.first { $0.name == "Expired" }?.id)
                // Explicit model statements are offline; other failures except rate limits are offered unchecked.
                expectEqual(Set(store.modelCleanup.filter(\.offline).map(\.model)), ["gone-catalog", "gone-manual"])
                expectEqual(Set(store.modelCleanup.filter { !$0.offline }.map(\.model)), ["bad-parameter"])
                expectTrue(store.modelCleanup.allSatisfy { $0.credentialID == liveID })
                // A dead selected model is shown but never removed automatically.
                expectTrue(store.modelCleanupRows.contains { $0.credentialID == deadID && $0.model == "dead-current" && $0.inUse })
                expectFalse(store.modelCleanupRows.contains { $0.model == "dead-other" })
                expectEqual(store.cleanup.map(\.id), [expiredID])
                // A model that recovers after the sheet opened is not removed with the rest.
                let offered = Set(store.modelCleanup.filter(\.offline))
                expectTrue(store.commit { next in
                    if let i = next.credentials.firstIndex(where: { $0.id == liveID }) { next.credentials[i].modelProbes?["gone-catalog"]?.unavailable = false }
                })
                expectTrue(store.cleanUp(keys: [expiredID], models: offered))
                let cleaned = try unwrap(store.credentials.first { $0.id == liveID })
                expectEqual(cleaned.model, "keep-current")
                expectEqual(Set(cleaned.modelOptions), ["keep-current", "keep-ok", "rate-limited", "bad-parameter", "gone-catalog"])
                expectNil(cleaned.modelProbes?["gone-manual"])
                expectTrue(store.credentials.first { $0.id == expiredID }?.archived == true)
                expectEqual(store.toast, "已归档 1 条 Key，已移除 1 个模型")
                expectEqual(try store.disk.load().credentials.first { $0.id == liveID }?.manualModels, cleaned.manualModels)
                expectFalse(store.cleanUp(keys: [], models: []))
                // A failed model is removed only when chosen explicitly.
                expectTrue(store.cleanUp(keys: [], models: Set(store.modelCleanup.filter { $0.model == "bad-parameter" })))
                expectFalse(store.credentials.first { $0.id == liveID }?.modelOptions.contains("bad-parameter") == true)
                expectEqual(store.toast, "已移除 1 个模型")
                checkpoint("ModelProbe.one-click-cleanup-removes-only-models-the-service-reports-gone")
            }
        } catch { checkFailures.append("ModelProbe.cleanup: " + error.localizedDescription); checkpoint("ModelProbe.cleanup") }
    }

    static func cancellation() async {
        do {
            try await withStore { store in
                var value = record(); value.model = "first"; value.manualModels = ["second", "third"]
                expectTrue(store.save(value))
                let session = MockURLProtocol.session { _ in MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8), delay: 0.15) }
                defer { session.invalidateAndCancel() }
                let current = try unwrap(store.selected)
                let task = Task { await store.probeModels(current, session: session) }
                for _ in 0..<100 { if store.modelProbeProgress[current.id]?.done == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
                expectEqual(store.modelProbeProgress[current.id]?.total, 3)
                task.cancel(); await task.value
                let probes = try unwrap(store.selected?.modelProbes)
                expectEqual(Array(probes.keys), ["first"]); expectTrue(probes["first"]?.passed == true)
                expectNil(store.modelProbeProgress[current.id]); expectFalse(store.checking.contains(current.id))
                checkpoint("ModelProbe.stopping-keeps-results-already-received-and-drops-cancelled-calls")
            }
        } catch { checkFailures.append("ModelProbe.cancellation: " + error.localizedDescription); checkpoint("ModelProbe.cancellation") }
    }

    static func layout() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        runCheck("ModelProbe.list-shows-the-fastest-model-and-detail-shows-durations") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256)
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var value = record(); value.name = "Latency relay"; value.model = "slowmodel"; value.manualModels = ["quickmodel", "oldmodel", "lagmodel"]
                expectTrue(store.save(value))
                let id = try unwrap(store.selected?.id)
                func result(_ state: CheckState, _ duration: TimeInterval, status: Int = 200, body: String = "{}") -> CheckResult {
                    var value = CheckResult(state: state, message: state == .valid ? "当前模型调用验证通过。" : "HTTP 404", httpStatus: status, endpoint: "https://example.com/v1/chat/completions", requestMethod: "POST", duration: duration)
                    value.response = CheckedResponse(Data(body.utf8), record: record()); return value
                }
                expectTrue(store.commit { next in
                    guard let i = next.credentials.firstIndex(where: { $0.id == id }) else { return }
                    next.credentials[i].check = result(.valid, 1.84)
                    next.credentials[i].recordProbe(result(.valid, 1.84), model: "slowmodel", protocolKind: .compatible)
                    next.credentials[i].recordProbe(result(.valid, 0.412), model: "quickmodel", protocolKind: .compatible)
                    next.credentials[i].recordProbe(result(.uncertain, 0.2, status: 404, body: #"{"error":{"code":"model_not_found"}}"#), model: "oldmodel", protocolKind: .compatible)
                    next.credentials[i].recordProbe(CheckResult(state: .uncertain, message: APIClient.failureMessage(URLError(.timedOut)), endpoint: "https://example.com/v1/chat/completions", requestMethod: "POST", duration: 60.4), model: "lagmodel", protocolKind: .compatible)
                })
                let detailRecord = try unwrap(store.selected)
                try render(CredentialDetail(record: detailRecord, edit: {}).environmentObject(store), size: NSSize(width: 760, height: 900)) { view in
                    let text = try recognizedText(view).replacingOccurrences(of: " ", with: "")
                    expectTrue(text.contains("耗时1.84s")); expectTrue(text.contains("模型耗时")); expectTrue(text.contains("412ms"))
                    expectTrue(text.contains("已下线")); expectTrue(text.contains("检查全部模型"))
                    expectTrue(text.contains("超时")); expectTrue(text.contains("请求超时"))
                }
                try render(ContentView().environmentObject(store), size: NSSize(width: 1080, height: 760)) { view in
                    let text = try recognizedText(view).replacingOccurrences(of: " ", with: "")
                    expectTrue(text.contains("quickmodel")); expectTrue(text.contains("412ms"))
                }
                try render(CleanupView().environmentObject(store), size: NSSize(width: 740, height: 530)) { view in
                    let text = try recognizedText(view).replacingOccurrences(of: " ", with: "")
                    expectTrue(text.contains("一键清理")); expectTrue(text.contains("oldmodel")); expectTrue(text.contains("清理1项"))
                    expectTrue(text.contains("lagmodel")); expectTrue(text.contains("调用未通过"))
                }
            }
        }
    }

    nonisolated private static func record() -> Credential {
        var record = DeepChecks.record(); record.name = "Probe fixture"; record.baseURL = "https://example.com/v1"; record.apiKey = "fixture-probe-key-123456789"; record.model = "fixture-model"; return record
    }
    private static func withStore(_ work: (VaultStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        try await work(VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false))
    }
    private static func waitForBatch(_ store: VaultStore) async {
        for _ in 0..<200 { if !store.batchRunning { return }; try? await Task.sleep(for: .milliseconds(15)) }
        expectFalse(store.batchRunning)
    }
    private static func render<V: View>(_ root: V, size: NSSize, _ work: (NSView) throws -> Void) throws {
        let view = NSHostingView(rootView: AnyView(root.disclosureGroupStyle(FullRowDisclosureStyle()).tint(Palette.accent).preferredColorScheme(.light).environment(\.controlActiveState, .key).background(Color.white)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.setContentSize(size); defer { window.close() }
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        view.display(); try work(view)
    }
    private static func recognizedText(_ view: NSView) throws -> String {
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["KEYDOCK_PROBE_SNAPSHOTS"] {
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("probe-\(Int(view.bounds.width)).png"))
        }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try unwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
