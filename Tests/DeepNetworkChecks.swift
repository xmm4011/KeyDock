import Foundation
import CryptoKit

struct MockReply {
    var status = 200
    var headers = ["Content-Type": "application/json"]
    var body = Data()
    var delay: TimeInterval = 0
    var error: URLError?
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> MockReply)?
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let reply = try handler(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
                guard let self else { return }
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                guard !self.stopped else { return }
                if let error = reply.error { self.client?.urlProtocol(self, didFailWithError: error); return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.body)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    static func session(_ handler: @escaping (URLRequest) throws -> MockReply) -> URLSession {
        lock.lock(); Self.handler = handler; lock.unlock()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Self.self]
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
        return URLSession(configuration: config, delegate: APIClient.delegate, delegateQueue: nil)
    }
}

enum DeepNetworkChecks {
    static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        return data
    }
    @MainActor static func run() async {
        let raw = "Base URL：https://example.com/v1\nAPI Key：sk-input-fixture-123456789"
        let prepared = RedactedImport(raw)
        var service = DeepChecks.record(); service.apiKey = "sk-organizer-fixture-123456789"
        func reply(_ values: [[String: Any]]) throws -> MockReply {
            let text = String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
            return MockReply(body: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]]))
        }
        let base: [String: Any] = ["name": "Fixture", "api_key": "KEYDOCK_SECRET_1", "base_url": "https://example.com/v1", "kind": "compatible"]
        for kind in [ServiceKind.compatible, .anthropic, .gemini] {
            var selected = service; selected.kind = kind
            selected.auth = kind == .anthropic ? .xAPIKey : (kind == .gemini ? .googleKey : .bearer)
            let session = MockURLProtocol.session { request in
                let body = try JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any] ?? [:]
                switch kind {
                case .anthropic:
                    expectEqual(request.value(forHTTPHeaderField: "x-api-key"), selected.apiKey)
                    expectEqual(request.url?.path, "/v1/messages"); expectTrue(body["system"] is String); expectEqual(body["max_tokens"] as? Int, 4096)
                    let content = String(data: try JSONSerialization.data(withJSONObject: [["type": "text", "text": String(data: try JSONSerialization.data(withJSONObject: [base]), encoding: .utf8)!]]), encoding: .utf8)!
                    return MockReply(body: Data(("{\"content\":" + content + "}").utf8))
                case .gemini:
                    expectEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), selected.apiKey)
                    expectTrue(request.url?.path.hasSuffix(":generateContent") == true); expectTrue(body["contents"] is [[String: Any]])
                    let text = String(data: try JSONSerialization.data(withJSONObject: [base]), encoding: .utf8)!
                    return MockReply(body: try JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]]))
                default:
                    expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + selected.apiKey)
                    expectTrue(body["messages"] is [[String: Any]]); expectEqual(request.url?.path, "/v1/chat/completions")
                    return try reply([base])
                }
            }; defer { session.invalidateAndCancel() }
            do { let organized = try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: selected, model: "fixture-model", original: raw, session: session); expectEqual(organized.first?.apiKey, "sk-input-fixture-123456789") }
            catch { checkFailures.append("protocol payload: " + error.localizedDescription) }
            checkpoint("Deep.AI-exact-auth-and-payload-" + kind.rawValue)
        }
        do {
            let session = MockURLProtocol.session { _ in checkFailures.append("oversized AI request reached transport"); return try reply([base]) }; defer { session.invalidateAndCancel() }
            do { _ = try await AIOrganizer.organize(prepared, reviewedText: String(repeating: "汉", count: 40_000), service: service, model: "fixture-model", original: raw, session: session); checkFailures.append("AI accepted oversized UTF8 input") } catch {}
        }
        checkpoint("Deep.AI-size-limit-applies-to-UTF8-bytes-before-network")
        do {
            let session = MockURLProtocol.session { _ in var value = try reply([base]); value.delay = 0.3; return value }; defer { session.invalidateAndCancel() }
            let task = Task { try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: service, model: "fixture-model", original: raw, session: session) }
            try? await Task.sleep(for: .milliseconds(30)); task.cancel()
            do { _ = try await task.value; checkFailures.append("cancelled AI request returned records") } catch {}
        }
        checkpoint("Deep.cancelled-AI-request-returns-no-importable-results")
        do {
            var malicious = base
            malicious["verification_url"] = "https://attacker.invalid/collect"
            malicious["balance_url"] = "https://attacker.invalid/collect"
            malicious["auth"] = "none"
            let session = MockURLProtocol.session { _ in try reply([malicious]) }
            defer { session.invalidateAndCancel() }
            let result = try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: service, model: "fixture-model", original: raw, session: session)
            expectEqual(result.first?.verificationURL, ""); expectEqual(result.first?.balanceURL, "")
            expectEqual(result.first?.auth, .bearer)
        } catch { checkFailures.append("AI hidden configuration test: " + error.localizedDescription) }
        checkpoint("Deep.AI-cannot-inject-hidden-network-configuration")
        for (name, address) in [("scheme", "http://example.com/v1"), ("port", "https://example.com:8443/v1"), ("path", "https://example.com/unmentioned-path")] {
            do {
                var changed = base; changed["base_url"] = address
                let session = MockURLProtocol.session { _ in try reply([changed]) }; defer { session.invalidateAndCancel() }
                let result = try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: service, model: "fixture-model", original: raw, session: session)
                expectEqual(result.first?.baseURL, "")
            } catch { checkFailures.append("AI origin test: " + error.localizedDescription) }
            checkpoint("Deep.AI-rejects-invented-" + name)
        }
        do {
            let session = MockURLProtocol.session { request in
                let data = bodyData(request)
                expectFalse(data.isEmpty)
                expectFalse(String(data: data, encoding: .utf8)!.contains("sk-input-fixture-123456789"))
                expectFalse(String(data: data, encoding: .utf8)!.contains(service.apiKey))
                return try reply([base])
            }; defer { session.invalidateAndCancel() }
            let edited = prepared.text + "\n备注：sk-input-fixture-123456789 " + service.apiKey
            _ = try await AIOrganizer.organize(prepared, reviewedText: edited, service: service, model: "fixture-model", original: raw, session: session)
        } catch { checkFailures.append("AI edited preview test: " + error.localizedDescription) }
        checkpoint("Deep.AI-preview-edits-cannot-reintroduce-known-secrets")
        for (name, body) in [("malformed-json", "not json"), ("empty-choices", #"{"choices":[]}"#), ("refusal", #"{"choices":[{"message":{"content":null,"refusal":"refused"}}]}"#), ("invented-key", #"{"choices":[{"message":{"content":"[{\"api_key\":\"invented\",\"base_url\":\"https://example.com/v1\"}]"}}]}"#)] {
            let session = MockURLProtocol.session { _ in MockReply(body: Data(body.utf8)) }; defer { session.invalidateAndCancel() }
            do { _ = try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: service, model: "fixture-model", original: raw, session: session); checkFailures.append("AI accepted " + name) } catch {}
            checkpoint("Deep.AI-rejects-" + name)
        }
        for status in [401, 403, 402, 429, 500, 503] {
            let session = MockURLProtocol.session { _ in MockReply(status: status) }; defer { session.invalidateAndCancel() }
            do { _ = try await AIOrganizer.organize(prepared, reviewedText: prepared.text, service: service, model: "fixture-model", original: raw, session: session); checkFailures.append("AI accepted HTTP \(status)") }
            catch { expectFalse(error.localizedDescription.contains(service.apiKey)) }
            checkpoint("Deep.AI-HTTP-\(status)-does-not-leak-credentials")
        }
        for code in [URLError.timedOut, .notConnectedToInternet, .cannotFindHost, .secureConnectionFailed] {
            let session = MockURLProtocol.session { _ in MockReply(error: URLError(code)) }; defer { session.invalidateAndCancel() }
            let result = await APIClient.verify(service, session: session)
            expectEqual(result.state, .uncertain); expectFalse(result.message.contains(service.apiKey))
            checkpoint("Deep.verification-network-error-\(code.rawValue)-does-not-mark-key-expired")
        }
        let cases: [(String, String, String, String?)] = [
            ("number", #"{"data":{"balance":12.5}}"#, "data.balance", "12.5 USD"),
            ("array", #"{"items":[{"balance":"17"}]}"#, "items.0.balance", "17 USD"),
            ("missing", #"{"data":{}}"#, "data.balance", nil),
            ("object", #"{"data":{"balance":{}}}"#, "data.balance", nil),
            ("boolean", #"{"data":{"balance":true}}"#, "data.balance", nil),
            ("negative-index", #"{"items":[7]}"#, "items.-1", nil),
            ("null-error", #"{"data":{"balance":5},"error":null}"#, "data.balance", "5 USD")
        ]
        for (name, body, path, expected) in cases {
            var record = DeepChecks.record(); record.balanceURL = "https://example.com/balance"; record.balancePath = path; record.balanceUnit = "USD"
            let session = MockURLProtocol.session { _ in MockReply(body: Data(body.utf8)) }; defer { session.invalidateAndCancel() }
            do { let result = try await APIClient.balance(record, session: session); if let expected { expectEqual(result, expected) } else { checkFailures.append("balance unexpectedly accepted " + name) } }
            catch { if expected != nil { checkFailures.append("balance failed " + name) } }
            checkpoint("Deep.balance-" + name)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Deep-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false)
        var original = DeepChecks.record(); expectTrue(store.save(original)); original = store.selected!
        let session = MockURLProtocol.session { _ in MockReply(body: Data(#"{"data":[{"id":"old-model"}]}"#.utf8), delay: 0.1) }
        let task = Task { await store.verify(original, session: session) }
        try? await Task.sleep(for: .milliseconds(25))
        var edited = original; edited.apiKey = "sk-replaced-fixture-123456789"; expectTrue(store.save(edited))
        await task.value
        expectNil(store.selected?.check)
        checkpoint("Deep.stale-check-cannot-overwrite-an-edited-key")
        let cancelled = Task { await store.verify(store.selected!, session: session) }
        try? await Task.sleep(for: .milliseconds(25)); cancelled.cancel(); await cancelled.value
        expectNil(store.selected?.check); expectTrue(store.checking.isEmpty)
        checkpoint("Deep.cancelled-verification-clears-busy-state")
        session.invalidateAndCancel()
    }
}
