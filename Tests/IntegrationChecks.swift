import Foundation
import Network

final class StubProvider: @unchecked Sendable {
    private let queue = DispatchQueue(label: "keydock.check.stub")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let lock = NSLock()
    private var observed: [String] = []
    private var bodies: [String] = []
    var seenAuth: [String] { lock.lock(); defer { lock.unlock() }; return observed }
    var seenBodies: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47832)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let id = UUID(); self.connections[id] = connection
            connection.start(queue: self.queue)
            self.receive(connection, id: id, bytes: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, _ in
            guard let self else { return }
            let bytes = bytes + (data ?? Data())
            guard let parsed = try? LocalHTTPRequest.parse(bytes) else {
                if done { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.receive(connection, id: id, bytes: bytes) }
                return
            }
            self.lock.lock(); self.observed.append(parsed.headers["authorization"] ?? ""); self.bodies.append(String(data: parsed.body, encoding: .utf8) ?? ""); self.lock.unlock()
            if parsed.target.contains("stream-check") {
                let first = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: first\n\n"
                connection.send(content: Data(first.utf8), completion: .contentProcessed { _ in })
                self.queue.asyncAfter(deadline: .now() + 0.8) {
                    connection.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in connection.cancel(); self.connections.removeValue(forKey: id) })
                }
            } else {
                let body: Data
                let content = #"[{"name":"Fixture","base_url":"https://example.com/v1","api_key":"KEYDOCK_SECRET_1","kind":"compatible","purpose":"整理测试"}]"#
                if parsed.target.contains("chat/completions") {
                    body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                } else if parsed.target.contains("messages") {
                    body = try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": content]]])
                } else if parsed.target.contains("generateContent") {
                    body = try! JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": content]]]]]])
                } else { body = Data(#"{"data":[{"id":"test-model"}]}"#.utf8) }
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel(); self.connections.removeValue(forKey: id) })
            }
        }
    }
    func stop() { queue.async { self.listener?.cancel(); self.connections.values.forEach { $0.cancel() }; self.connections.removeAll() } }
}

enum IntegrationChecks {
    @MainActor static func run() async {
        let stub = StubProvider(); let proxy = LocalProxy(port: 47833)
        do {
            try stub.start()
            var a = Credential(); a.baseURL = "http://127.0.0.1:47832/v1"; a.apiKey = "fake-key-a-for-loopback-only"
            var b = Credential(); b.baseURL = a.baseURL; b.apiKey = "fake-key-b-for-loopback-only"
            proxy.update([a, b]); proxy.start()
            for _ in 0..<100 { if proxy.running { break }; try await Task.sleep(for: .milliseconds(20)) }
            guard proxy.running else { throw KeyDockError.message("测试代理无法启动，端口可能被占用。") }
            func local(_ record: Credential, _ suffix: String) -> URLRequest {
                var request = URLRequest(url: URL(string: record.localBaseURL.replacingOccurrences(of: ":47831/", with: ":47833/") + suffix)!)
                request.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); return request
            }
            let requestA = local(a, "/models"), requestB = local(b, "/models")
            async let first = URLSession.shared.data(for: requestA)
            async let second = URLSession.shared.data(for: requestB)
            let results = try await [first, second]
            expectTrue(results.allSatisfy { ($0.1 as? HTTPURLResponse)?.statusCode == 200 })
            expectTrue(stub.seenAuth.contains("Bearer " + a.apiKey)); expectTrue(stub.seenAuth.contains("Bearer " + b.apiKey))
            checkpoint("Integration.concurrent-same-provider-distinct-keys")
            let start = Date()
            let (bytes, response) = try await URLSession.shared.bytes(for: local(a, "/stream-check"))
            expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
            var lines = bytes.lines.makeAsyncIterator()
            let line = try await lines.next()
            expectEqual(line, "data: first"); expectTrue(Date().timeIntervalSince(start) < 0.65)
            var sawDone = false
            while let line = try await lines.next() { if line.contains("[DONE]") { sawDone = true } }
            expectTrue(sawDone)
            checkpoint("Integration.sse-chunks-arrive-before-completion")
            let raw = "Base URL：https://example.com/v1\nAPI Key：sk-imported-secret-fixture-123456789"
            let redacted = RedactedImport(raw)
            for kind in [ServiceKind.compatible, .anthropic, .gemini] {
                var service = a; service.kind = kind
                if kind == .anthropic { service.auth = .xAPIKey }
                if kind == .gemini { service.auth = .googleKey }
                let organized = try await AIOrganizer.organize(redacted, reviewedText: redacted.text, service: service, model: "fixture-model", original: raw)
                expectEqual(organized.first?.apiKey, "sk-imported-secret-fixture-123456789")
                expectEqual(organized.first?.baseURL, "https://example.com/v1")
            }
            expectFalse(stub.seenBodies.contains { $0.contains("sk-imported-secret-fixture-123456789") })
            checkpoint("Integration.ai-three-protocols-redaction-and-local-key-restoration")
            var archived = a; archived.archived = true; proxy.update([archived, b])
            try await Task.sleep(for: .milliseconds(30))
            let denied = try await URLSession.shared.data(for: local(a, "/models"))
            expectEqual((denied.1 as? HTTPURLResponse)?.statusCode, 400)
            expectFalse(String(data: denied.0, encoding: .utf8)!.contains(a.apiKey))
            checkpoint("Integration.archive-disables-route-without-exposing-secret")
        } catch { checkFailures.append("proxy integration: " + error.localizedDescription) }
        proxy.stop(); stub.stop()
        try? await Task.sleep(for: .milliseconds(100))
    }
}
