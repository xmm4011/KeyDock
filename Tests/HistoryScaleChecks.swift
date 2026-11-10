import Foundation
import CryptoKit

@MainActor enum HistoryScaleChecks {
    static func run() async {
        runCheck("History.formatting-preserves-JSON-values-Chinese-escapes-large-integers-and-truncated-text") {
            let raw = #"{"text":"\u4f60\u597d\n\"世界\"","literal":"\\u4f60","large":12345678901234567890123456789012345678901234567890,"array":[1,true,null]}"#
            let value = HTTPBodyFormatting.formatted(raw)
            expectTrue(value.contains("你好")); expectTrue(value.contains("世界")); expectTrue(value.contains("\\\\u4f60"))
            expectTrue(value.contains("12345678901234567890123456789012345678901234567890")); expectTrue(value.contains("\n  \"text\""))
            expectEqual(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? NSDictionary, try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? NSDictionary)
            let partial = HTTPBodyFormatting.formatted(#"{"text":"\u4f60\u597d\u5"#)
            expectTrue(partial.contains("你好")); expectTrue(partial.hasSuffix("\\u5")); expectFalse(partial.hasSuffix("}"))
            let stream = "event: response.output_text.delta\ndata: {\"delta\":\"\\u4f60\\u597d\"}\n\ndata: [DONE]\n\n"
            let formatted = HTTPBodyFormatting.formatted(stream)
            expectTrue(formatted.contains("你好")); expectTrue(formatted.contains("event: response.output_text.delta")); expectTrue(formatted.contains("data: [DONE]"))
            let eventData = formatted.components(separatedBy: "\n\n")[0].components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) }.joined(separator: "\n")
            expectEqual((try JSONSerialization.jsonObject(with: Data(eventData.utf8)) as? [String: String])?["delta"], "你好")
            expectEqual(HTTPBodyFormatting.formatted("[说明] 中文原文"), "[说明] 中文原文")
            expectEqual(HTTPBodyFormatting.formatted(#""\u4f60\u597d""#), "\"你好\"")
            expectTrue(HTTPBodyFormatting.formatted(#"{"text":中文}"#).contains("中文"))
        }
        runCheck("History.retains-5000-metadata-entries-and-loads-compressed-encrypted-large-details-on-demand") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), id = UUID(), history = ProxyHistory(directory: root, keyProvider: { key })
                for index in 0..<5003 { var e = ProxyLogEntry(credentialID: id, method: "POST", requestURL: "/call/\(index)"); e.status = 200; history.append(e) }
                var large = ProxyLogEntry(credentialID: id, method: "POST", requestURL: "/large")
                large.bodiesCaptured = true; large.requestHeaders = "Authorization: Bearer fixture-history-secret"
                large.requestBody = #"{"text":""# + String(repeating: "\\u4f60\\u597d", count: 30000) + #""}"#
                large.responseBody = String(repeating: "你好，完整响应。", count: 20000); history.append(large)
                history.flush(); expectNil(history.error); expectEqual(history.entries.count, 5000); expectEqual(history.totals[id]?.calls, 5004)
                expectTrue(history.entries.first?.requestBody.isEmpty == true)
                let restored = ProxyHistory(directory: root, keyProvider: { key }), metadata = try unwrap(restored.entries.first)
                expectEqual(restored.entries.count, 5000)
                let detail = try restored.detail(for: metadata)
                expectEqual(detail.requestBody, large.requestBody); expectEqual(detail.responseBody, large.responseBody)
                let indexBytes = try Data(contentsOf: history.fileURL), bodyFile = history.detailDirectory.appendingPathComponent(large.id.uuidString + ".kdv")
                let bodyBytes = try Data(contentsOf: bodyFile)
                expectTrue(indexBytes.count < 4 * 1024 * 1024); expectTrue(bodyBytes.count < large.requestBody.utf8.count / 2)
                expectFalse(String(decoding: bodyBytes, as: UTF8.self).contains("fixture-history-secret"))
                restored.clear(id); restored.flush(); expectTrue(restored.entries.isEmpty)
                expectFalse(FileManager.default.fileExists(atPath: bodyFile.path))
            }
        }
        runCheck("History.migrates-inline-records-without-loss-and-missing-detail-does-not-block-the-index") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), id = UUID()
                var old = ProxyLogEntry(credentialID: id, method: "POST", requestURL: "/legacy")
                old.bodiesCaptured = true; old.requestBody = "legacy-request"; old.responseBody = "legacy-response"
                let bytes = try AES.GCM.seal(JSONEncoder().encode(ProxyHistory.Payload(entries: [old], captureBodies: [id], totals: nil)), using: key).combined!
                try bytes.write(to: root.appendingPathComponent("history.kdv"))
                let history = ProxyHistory(directory: root, keyProvider: { key })
                expectEqual(try history.detail(for: unwrap(history.entries.first)).responseBody, "legacy-response")
                history.flush(); expectNil(history.error)
                let reloaded = ProxyHistory(directory: root, keyProvider: { key })
                expectEqual(try reloaded.detail(for: unwrap(reloaded.entries.first)).requestBody, "legacy-request")
                try FileManager.default.removeItem(at: reloaded.detailDirectory.appendingPathComponent(old.id.uuidString + ".kdv"))
                expectThrows(try reloaded.detail(for: unwrap(reloaded.entries.first)))
                reloaded.append(ProxyLogEntry(credentialID: id, method: "GET", requestURL: "/new")); reloaded.flush()
                expectTrue(reloaded.isReadable); expectNil(reloaded.error); expectEqual(reloaded.entries.count, 2)
            }
        }
        await backgroundWrites()
        await timeoutAndCapture()
        await admissionLimits()
        await parallelSSE()
    }
    static func backgroundWrites() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-HistoryOrdering-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let key = SymmetricKey(size: .bits256), id = UUID(), other = UUID(), history = ProxyHistory(directory: root, keyProvider: { key })
            for _ in 0..<50 { var e = ProxyLogEntry(credentialID: id, method: "POST", requestURL: "/old"); e.bodiesCaptured = true; e.responseBody = String(repeating: "fixture", count: 10000); history.append(e) }
            try await Task.sleep(for: .milliseconds(310))
            history.clear(id)
            history.append(ProxyLogEntry(credentialID: other, method: "GET", requestURL: "/retained")); history.flush()
            try await Task.sleep(for: .milliseconds(100))
            let restored = ProxyHistory(directory: root, keyProvider: { key })
            expectEqual(restored.entries.count, 1); expectEqual(restored.entries.first?.credentialID, other); expectNil(restored.totals[id]); expectNil(history.error)
            checkpoint("History.background-save-and-explicit-flush-never-resurrect-cleared-records")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("History.background-ordering") }
    }
    static func timeoutAndCapture() async {
        let server = FixtureServer { request in
            if request.target.hasSuffix("/slow") { return FixtureResponse(chunks: [Data("slow".utf8)], headerDelay: 2) }
            if request.target.hasSuffix("/upstream-error") { return FixtureResponse(status: 502, chunks: [Data(#"{"error":{"message":"fixture upstream unavailable"}}"#.utf8)]) }
            return FixtureResponse(chunks: [request.body])
        }
        let proxy = LocalProxy(port: 0, policy: .init(idleTimeout: 0.5, resourceTimeout: 5))
        let session = URLSession(configuration: .ephemeral)
        var logs: [ProxyLogEntry] = []
        defer { proxy.stop(); server.stop(); session.invalidateAndCancel() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.recordHistory(captureBodies: [record.id]) { entry in Task { @MainActor in logs.append(entry) } }
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            func request(_ path: String, body: Data? = nil) throws -> URLRequest {
                var r = URLRequest(url: URL(string: "http://127.0.0.1:\(try unwrap(proxy.listeningPort))/s/\(record.routeID)/" + path)!)
                r.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); r.httpMethod = "POST"; r.httpBody = body ?? Data("{}".utf8); return r
            }
            let timeout = try await session.data(for: request("slow")); await InteractionFlowChecks.wait { logs.count == 1 }
            expectEqual((timeout.1 as? HTTPURLResponse)?.statusCode, 504); expectTrue(String(decoding: timeout.0, as: UTF8.self).contains("keydock_proxy_error"))
            expectEqual(logs.last?.responseOrigin, "proxy"); expectEqual(logs.last?.transportErrorCode, URLError.timedOut.rawValue)
            expectTrue(logs.last?.responseBody.contains("超时") == true); expectEqual(server.received.count, 1)
            let upstream = try await session.data(for: request("upstream-error")); await InteractionFlowChecks.wait { logs.count == 2 }
            expectEqual((upstream.1 as? HTTPURLResponse)?.statusCode, 502); expectEqual(logs.last?.responseOrigin, "upstream"); expectNil(logs.last?.transportErrorCode)
            checkpoint("Proxy.timeout-is-504-with-transport-cause-and-upstream-502-is-forwarded-without-retrying")
            let body = Data((#"{"input":""# + String(repeating: "\\u4f60\\u597d", count: 20000) + #""}"#).utf8)
            let echo = try await session.data(for: request("echo", body: body)); await InteractionFlowChecks.wait { logs.count == 3 }
            expectEqual(echo.0, body); expectEqual(logs.last?.requestBody, String(decoding: body, as: UTF8.self)); expectEqual(logs.last?.responseBody, String(decoding: body, as: UTF8.self))
            expectFalse(logs.last?.requestTruncated == true); expectFalse(logs.last?.responseTruncated == true)
            expectTrue(ProxyTransportPolicy().idleTimeout > 120)
            checkpoint("Proxy.captures-request-and-response-larger-than-128KB-without-changing-wire-content")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Proxy.timeout-and-large-capture") }
    }
    static func parallelSSE() async {
        let delivery = SSEDeliveryGate()
        let interval = 0.05
        let chunks: @Sendable (String) -> [Data] = { sequence in (0..<8).map { Data("data: {\"sequence\":\"\(sequence)\",\"part\":\($0),\"text\":\"你好\"}\n\n".utf8) } }
        let server = FixtureServer { request in
            let sequence = request.target.components(separatedBy: "/").last ?? ""
            return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: chunks(sequence), interval: interval, waitAfterFirstChunk: Int(sequence) == nil ? nil : { delivery.wait(sequence, $0) })
        }
        let proxy = LocalProxy(port: 0), configuration = URLSessionConfiguration.ephemeral
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ParallelHistory-" + UUID().uuidString), key = SymmetricKey(size: .bits256)
        let history = ProxyHistory(directory: root, keyProvider: { key })
        configuration.httpMaximumConnectionsPerHost = 128; configuration.timeoutIntervalForRequest = 15; configuration.urlCache = nil
        let session = URLSession(configuration: configuration), streamClient = ConcurrentSSEClient(configuration: configuration)
        defer { delivery.clear(); streamClient.stop(); proxy.stop(); server.stop(); session.invalidateAndCancel(); history.flush(); try? FileManager.default.removeItem(at: root) }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.recordHistory(captureBodies: [record.id]) { entry in Task { @MainActor in history.append(entry) } }
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            let requests = try (0..<128).map { index -> URLRequest in
                var r = URLRequest(url: URL(string: "http://127.0.0.1:\(try unwrap(proxy.listeningPort))/s/\(record.routeID)/stream/\(index)")!)
                r.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); return r
            }
            let started = Date()
            let passed = await withTaskGroup(of: Bool.self) { group in
                for (index, request) in requests.enumerated() { group.addTask {
                    do {
                        let reply = try await streamClient.run(request, onFirstData: { delivery.release(String(index)) })
                        if reply.status != 200 || reply.body != chunks(String(index)).reduce(Data(), +) || reply.chunks < 2 { print("SSE FAILURE sequence=\(index) status=\(reply.status) bytes=\(reply.body.count) streaming=\(reply.streamingDuration) chunks=\(reply.chunks)"); return false }
                        return true
                    } catch { return false }
                } }
                var count = 0; for await ok in group { if ok { count += 1 } }; return count
            }
            expectEqual(passed, 128)
            await InteractionFlowChecks.wait { history.entries.count == 128 }
            history.flush(); expectNil(history.error); expectEqual(history.totals[record.id]?.calls, 128)
            let active = await proxy.activeConnections(); expectEqual(active, 0)
            checkpoint("Proxy.128-parallel-SSE-streams-are-incremental-complete-and-never-cross-deliver")
            print("PARALLEL SSE METRICS calls=128 passed=\(passed) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s upstream_pool=64 client_limit=256")
            var firstReceived = false
            var cancelRequest = requests[0]; cancelRequest.url = URL(string: cancelRequest.url!.absoluteString + "-cancel")!
            let cancelTask = Task { @MainActor in
                let (bytes, _) = try await session.bytes(for: cancelRequest)
                for try await _ in bytes { firstReceived = true; try Task.checkCancellation() }
            }
            let survivor = Task { try await session.data(for: requests[1]) }
            await InteractionFlowChecks.wait { firstReceived }; cancelTask.cancel(); _ = try? await cancelTask.value
            let reply = try await survivor.value
            expectEqual((reply.1 as? HTTPURLResponse)?.statusCode, 200); expectEqual(reply.0, chunks("1").reduce(Data(), +))
            await InteractionFlowChecks.wait { history.entries.count == 130 }
            checkpoint("Proxy.cancelling-one-SSE-client-does-not-cancel-the-shared-session-or-other-streams")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Proxy.parallel-SSE") }
    }
    static func admissionLimits() async {
        let server = FixtureServer { request in FixtureResponse(chunks: [request.body], headerDelay: request.target.hasSuffix("/hold") ? 0.4 : 0) }
        let proxy = LocalProxy(port: 0, policy: .init(maximumClients: 1, maximumBufferedRequestBytes: 2048)), session = URLSession(configuration: .ephemeral)
        defer { proxy.stop(); server.stop(); session.invalidateAndCancel() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            func request(_ path: String, body: Data = Data("{}".utf8)) throws -> URLRequest {
                var value = URLRequest(url: URL(string: "http://127.0.0.1:\(try unwrap(proxy.listeningPort))/s/\(record.routeID)/" + path)!)
                value.httpMethod = "POST"; value.httpBody = body; value.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); return value
            }
            let holdRequest = try request("hold")
            let first = Task { try await session.data(for: holdRequest) }
            await InteractionFlowChecks.wait { !server.received.isEmpty }
            let busy = try await session.data(for: request("busy"))
            expectEqual((busy.1 as? HTTPURLResponse)?.statusCode, 503); expectEqual((busy.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), "1")
            _ = try await first.value
            let oversized = try await session.data(for: request("over-budget", body: Data(repeating: 65, count: 3000)))
            expectEqual((oversized.1 as? HTTPURLResponse)?.statusCode, 503)
            let recovered = try await session.data(for: request("recovered"))
            expectEqual((recovered.1 as? HTTPURLResponse)?.statusCode, 200); expectEqual(recovered.0, Data("{}".utf8))
            checkpoint("Proxy.client-and-upload-memory-admission-limits-return-503-and-release-capacity")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Proxy.admission-limits") }
    }
    static func longRequests() async {
        let server = FixtureServer { request in
            if request.target.hasSuffix("/quiet") { return FixtureResponse(chunks: [Data("completed after 125 seconds".utf8)], headerDelay: 125) }
            return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: first\n\n".utf8), Data("data: [DONE]\n\n".utf8)], interval: 125)
        }
        let proxy = LocalProxy(port: 0), configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 200; configuration.timeoutIntervalForResource = 250
        let session = URLSession(configuration: configuration)
        defer { proxy.stop(); server.stop(); session.invalidateAndCancel() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            func request(_ path: String) throws -> URLRequest {
                var value = URLRequest(url: URL(string: "http://127.0.0.1:\(try unwrap(proxy.listeningPort))/s/\(record.routeID)/" + path)!, timeoutInterval: 200)
                value.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); return value
            }
            let started = Date()
            let quietRequest = try request("quiet"), streamRequest = try request("stream")
            async let quiet = session.data(for: quietRequest)
            let (bytes, response) = try await session.bytes(for: streamRequest)
            var lines = bytes.lines.makeAsyncIterator()
            let first = try await lines.next()
            expectEqual((response as? HTTPURLResponse)?.statusCode, 200); expectEqual(first, "data: first")
            let firstLatency = Date().timeIntervalSince(started)
            expectTrue(firstLatency < 5)
            print("LONG WAIT: first SSE event in \(String(format: "%.3f", firstLatency)) seconds; waiting through a 125-second idle gap")
            var done = false
            while let line = try await lines.next() { if line == "data: [DONE]" { done = true } }
            expectTrue(done); expectTrue(Date().timeIntervalSince(started) > 120)
            checkpoint("Proxy.SSE-first-event-is-forwarded-immediately-and-a-125-second-idle-gap-survives")
            let reply = try await quiet
            expectEqual((reply.1 as? HTTPURLResponse)?.statusCode, 200); expectEqual(String(decoding: reply.0, as: UTF8.self), "completed after 125 seconds")
            expectTrue(Date().timeIntervalSince(started) > 120)
            checkpoint("Proxy.non-streaming-first-response-after-125-seconds-is-not-cut-off")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Proxy.long-wait-completes") }
    }
}

private final class SSEDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = Set<String>(), waiting: [String: () -> Void] = [:]
    func wait(_ id: String, _ completion: @escaping () -> Void) {
        lock.lock()
        if released.contains(id) { lock.unlock(); completion() }
        else { waiting[id] = completion; lock.unlock() }
    }
    func release(_ id: String) {
        lock.lock(); released.insert(id); let completion = waiting.removeValue(forKey: id); lock.unlock(); completion?()
    }
    func clear() { lock.lock(); waiting.removeAll(); released.removeAll(); lock.unlock() }
}

final class ConcurrentSSEClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Reply { var status: Int; var body: Data; var streamingDuration: TimeInterval; var chunks: Int }
    private struct Pending { var continuation: CheckedContinuation<Reply, Error>; var status = 0; var body = Data(); var first: Date?; var chunks = 0; var onFirstData: (() -> Void)? }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!
    init(configuration: URLSessionConfiguration) { super.init(); session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil) }
    func stop() { session.invalidateAndCancel() }
    func run(_ request: URLRequest, onFirstData: (() -> Void)? = nil) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock(); pending[task.taskIdentifier] = Pending(continuation: continuation, onFirstData: onFirstData); lock.unlock(); task.resume()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); pending[dataTask.taskIdentifier]?.status = (response as? HTTPURLResponse)?.statusCode ?? 0; lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let notification = pending[dataTask.taskIdentifier]?.onFirstData
        pending[dataTask.taskIdentifier]?.onFirstData = nil
        if pending[dataTask.taskIdentifier]?.first == nil { pending[dataTask.taskIdentifier]?.first = Date() }
        pending[dataTask.taskIdentifier]?.chunks += 1
        pending[dataTask.taskIdentifier]?.body.append(data)
        lock.unlock(); notification?()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let value = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let value else { return }
        if let error { value.continuation.resume(throwing: error) }
        else { value.continuation.resume(returning: Reply(status: value.status, body: value.body, streamingDuration: Date().timeIntervalSince(value.first ?? Date()), chunks: value.chunks)) }
    }
}
