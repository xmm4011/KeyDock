import Foundation
import Network
import CryptoKit
import Darwin

struct FixtureResponse {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var chunks: [Data] = [Data(#"{"ok":true}"#.utf8)]
    var interval: TimeInterval = 0
    var declaredLength: Int?
    var resetConnection = false
}

final class FixtureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "keydock.deep.fixture")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [LocalHTTPRequest] = []
    private var boundPort: UInt16?
    var port: UInt16? { lock.lock(); defer { lock.unlock() }; return boundPort }
    var received: [LocalHTTPRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    let response: (LocalHTTPRequest) -> FixtureResponse
    init(response: @escaping (LocalHTTPRequest) -> FixtureResponse) { self.response = response }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            if case .ready = state { self.lock.lock(); self.boundPort = listener?.port?.rawValue; self.lock.unlock() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID(); self.connections[id] = connection
            connection.start(queue: self.queue); self.read(connection, id: id, data: Data())
        }
        listener.start(queue: queue)
    }
    private func read(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, done, error in
            guard let self else { return }
            let data = data + (bytes ?? Data())
            do {
                if let request = try LocalHTTPRequest.parse(data) {
                    self.lock.lock(); self.requests.append(request); self.lock.unlock()
                    let response = self.response(request)
                    let size = response.declaredLength ?? response.chunks.reduce(0) { $0 + $1.count }
                    var header = "HTTP/1.1 \(response.status) Test\r\nConnection: close\r\nContent-Length: \(size)\r\n"
                    for (name, value) in response.headers { header += "\(name): \(value)\r\n" }
                    header += "\r\n"
                    connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                        if request.method == "HEAD" { self.finish(connection, id: id, reset: false) }
                        else { self.send(response.chunks, index: 0, interval: response.interval, reset: response.resetConnection, connection: connection, id: id) }
                    })
                } else if done || error != nil { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.read(connection, id: id, data: data) }
            } catch { connection.cancel(); self.connections.removeValue(forKey: id) }
        }
    }
    private func send(_ chunks: [Data], index: Int, interval: TimeInterval, reset: Bool, connection: NWConnection, id: UUID) {
        guard index < chunks.count else { finish(connection, id: id, reset: reset); return }
        connection.send(content: chunks[index], completion: .contentProcessed { error in
            if error != nil { connection.cancel(); self.connections.removeValue(forKey: id); return }
            if index + 1 == chunks.count { self.finish(connection, id: id, reset: reset) }
            else { self.queue.asyncAfter(deadline: .now() + interval) { self.send(chunks, index: index + 1, interval: interval, reset: reset, connection: connection, id: id) } }
        })
    }
    private func finish(_ connection: NWConnection, id: UUID, reset: Bool) {
        if reset { connection.forceCancel(); connections.removeValue(forKey: id); return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel(); self.connections.removeValue(forKey: id)
        })
    }
    func stop() { queue.async { self.listener?.stateUpdateHandler = nil; self.listener?.cancel(); self.listener = nil; self.connections.values.forEach { $0.cancel() }; self.connections.removeAll() } }
}

private final class HalfCloseProbe: @unchecked Sendable {
    let port: UInt16
    let resetAfterFirstEvent: Bool
    let slowRead: Bool
    init(port: UInt16, resetAfterFirstEvent: Bool = false, slowRead: Bool = false) { self.port = port; self.resetAfterFirstEvent = resetAfterFirstEvent; self.slowRead = slowRead }
    func run(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try self.exchange(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func exchange(_ request: Data) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 4, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        if slowRead {
            var smallBuffer: Int32 = 32768
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size))
        }
        if resetAfterFirstEvent {
            var immediate = linger(l_onoff: 1, l_linger: 0)
            guard setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &immediate, socklen_t(MemoryLayout<linger>.size)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += sent
            }
        }
        if !resetAfterFirstEvent { guard shutdown(descriptor, SHUT_WR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) } }
        if slowRead { Thread.sleep(forTimeInterval: 0.25) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { return bytes }
            bytes.append(contentsOf: buffer.prefix(count))
            if slowRead { Thread.sleep(forTimeInterval: 0.001) }
            if resetAfterFirstEvent && String(decoding: bytes, as: UTF8.self).contains("data: first\n\n") { return bytes }
        }
    }
}

enum AdvancedProxyChecks {
    @MainActor static func run() async {
        let big = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
        let slowBody = big + big + big + big
        let target = FixtureServer { _ in FixtureResponse() }
        let provider = FixtureServer { request in
            if request.target.contains("gzip") { return FixtureResponse(headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"], chunks: [Data(base64Encoded: "H4sIAAAAAAAC/6tWys9WsiopKk3VUSpJrShRslJKr8osUEjLrCgpLUpVqgUAlV0EJSEAAAA=")!]) }
            if request.target.contains("hop-response") { return FixtureResponse(headers: ["Connection": "X-Private-Hop", "X-Private-Hop": "must-not-leak", "Keep-Alive": "timeout=5", "X-Application": "keep-this"]) }
            if request.target.contains("reset-truncated") { return FixtureResponse(chunks: [Data("partial".utf8)], declaredLength: 1000, resetConnection: true) }
            if request.target.contains("truncated") { return FixtureResponse(chunks: [Data("partial".utf8)], declaredLength: 1000) }
            if request.target.contains("cancel-stream") { return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: first\n\n".utf8), Data("data: [DONE]\n\n".utf8)], interval: 5) }
            if request.target.contains("stream") { return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: first\n\n".utf8), Data("data: [DONE]\n\n".utf8)], interval: 0.5) }
            if request.target.contains("redirect") { return FixtureResponse(status: 302, headers: ["Location": "http://127.0.0.1:\(target.port ?? 0)/collect"], chunks: []) }
            if request.target.contains("large") {
                let body = request.target.contains("slow-large") ? slowBody : big
                return FixtureResponse(headers: ["Content-Type": "application/octet-stream"], chunks: stride(from: 0, to: body.count, by: 65536).map { body.subdata(in: $0..<min($0 + 65536, body.count)) })
            }
            if request.target.contains("echo") { return FixtureResponse(chunks: [request.body]) }
            if request.target.contains("status") { return FixtureResponse(status: Int(request.target.split(separator: "/").last ?? "500") ?? 500) }
            return FixtureResponse()
        }
        let proxy = LocalProxy(port: 0)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { proxy.stop(); provider.stop(); target.stop(); session.invalidateAndCancel() }
        do {
            try provider.start(); try target.start()
            for _ in 0..<150 { if provider.port != nil && target.port != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard let providerPort = provider.port, target.port != nil else { throw KeyDockError.message("fixture server failed to start") }
            var records: [Credential] = []
            for i in 0..<24 { var record = DeepChecks.record(); record.name = "Key \(i)"; record.apiKey = "fake-load-key-\(i)"; record.baseURL = "http://127.0.0.1:\(providerPort)/v1"; records.append(record) }
            proxy.update(records); proxy.start()
            for _ in 0..<150 { if proxy.running { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard let port = proxy.listeningPort, proxy.running else { throw KeyDockError.message("isolated proxy failed to start") }
            func request(_ record: Credential, _ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(record.routeID)/\(path)")!)
                request.httpMethod = method; request.httpBody = body; request.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization")
                return request
            }
            let requests = records.map { request($0, "models") }
            await withTaskGroup(of: Bool.self) { group in
                for request in requests { group.addTask { do { return (try await session.data(for: request).1 as? HTTPURLResponse)?.statusCode == 200 } catch { return false } } }
                for await success in group { expectTrue(success) }
            }
            let seen = Set(provider.received.compactMap { $0.headers["authorization"] })
            expectTrue(records.allSatisfy { seen.contains("Bearer " + $0.apiKey) })
            checkpoint("Deep.proxy-24-concurrent-keys-never-cross-routes")
            let record = records[0]
            let raw = "GET /s/\(record.routeID)/models HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(record.localKey)\r\n\r\n"
            let halfClosed = try await HalfCloseProbe(port: port).run(Data(raw.utf8))
            expectTrue(String(data: halfClosed, encoding: .utf8)?.hasPrefix("HTTP/1.1 200") == true)
            checkpoint("Deep.half-closed-client-upload-still-receives-response")
            let competing = LocalProxy(port: port); competing.start()
            for _ in 0..<100 { if competing.error != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            expectFalse(competing.running); expectTrue(competing.error != nil)
            let stillWorking = try await session.data(for: request(record, "models"))
            expectEqual((stillWorking.1 as? HTTPURLResponse)?.statusCode, 200); competing.stop()
            checkpoint("Deep.port-collision-does-not-replace-the-running-proxy")
            let binary = try await session.data(for: request(record, "large"))
            expectEqual(binary.0.count, big.count); expectEqual(SHA256.hash(data: binary.0), SHA256.hash(data: big))
            checkpoint("Deep.proxy-preserves-2MB-binary-response")
            let slowRaw = "GET /s/\(record.routeID)/slow-large HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(record.localKey)\r\n\r\n"
            let slowTask = Task { try await HalfCloseProbe(port: port, slowRead: true).run(Data(slowRaw.utf8)) }
            var observedPause = false
            for _ in 0..<120 {
                if await proxy.connectionDiagnostics().contains(where: { $0.contains("paused=true") }) { observedPause = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let rawResponse = try await slowTask.value
            let headerEnd = try unwrap(rawResponse.range(of: Data("\r\n\r\n".utf8)))
            let decoded = try decodeChunks(Data(rawResponse[headerEnd.upperBound...]))
            expectTrue(observedPause); expectEqual(decoded.count, slowBody.count)
            expectEqual(SHA256.hash(data: decoded), SHA256.hash(data: slowBody))
            checkpoint("Deep.slow-client-triggers-backpressure-and-receives-complete-8MB-response")
            let compressed = try await session.data(for: request(record, "gzip"))
            expectEqual(compressed.0, Data(#"{"ok":true,"text":"gzip fixture"}"#.utf8))
            expectNil((compressed.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding"))
            checkpoint("Deep.proxy-decompresses-gzip-with-correct-response-framing")
            let hop = try await session.data(for: request(record, "hop-response"))
            expectNil((hop.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Private-Hop"))
            expectNil((hop.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Keep-Alive"))
            expectEqual((hop.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Application"), "keep-this")
            checkpoint("Deep.proxy-strips-connection-nominated-response-headers")
            let payload = Data(String(repeating: "你好😀", count: 150_000).utf8)
            let echoed = try await session.data(for: request(record, "echo", method: "POST", body: payload))
            expectEqual(echoed.0, payload)
            checkpoint("Deep.proxy-preserves-large-UTF8-request-body")
            for status in [401, 403, 402, 429, 500, 503] {
                let reply = try await session.data(for: request(record, "status/\(status)"))
                expectEqual((reply.1 as? HTTPURLResponse)?.statusCode, status)
            }
            checkpoint("Deep.proxy-preserves-upstream-error-statuses")
            let redirect = try await session.data(for: request(record, "redirect"))
            expectEqual((redirect.1 as? HTTPURLResponse)?.statusCode, 502); expectTrue(target.received.isEmpty)
            expectTrue((try? JSONSerialization.jsonObject(with: redirect.0)) != nil)
            expectEqual(provider.received.filter { $0.target.contains("redirect") }.count, 1)
            checkpoint("Deep.proxy-blocks-redirect-before-credentials-can-be-forwarded")
            let before = provider.received.count
            var browser = request(record, "models"); browser.setValue("https://untrusted.invalid", forHTTPHeaderField: "Origin")
            let denied = try await session.data(for: browser)
            expectEqual((denied.1 as? HTTPURLResponse)?.statusCode, 400); expectEqual(provider.received.count, before)
            checkpoint("Deep.browser-requests-never-reach-upstream")
            let head = try await session.data(for: request(record, "models", method: "HEAD"))
            expectEqual((head.1 as? HTTPURLResponse)?.statusCode, 200); expectTrue(head.0.isEmpty)
            checkpoint("Deep.proxy-HEAD-has-no-response-body")
            do { _ = try await session.data(for: request(record, "truncated")); checkFailures.append("truncated upstream was accepted as complete") } catch {}
            for _ in 0..<100 { if await proxy.activeConnections() == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let truncatedRemaining = await proxy.activeConnections()
            if truncatedRemaining != 0 { print("TRUNCATION DIAGNOSTICS", await proxy.connectionDiagnostics()) }
            expectEqual(truncatedRemaining, 0)
            checkpoint("Deep.proxy-does-not-report-truncated-upstream-as-success")
            do {
                let resetReply = try await session.data(for: request(record, "reset-truncated"))
                expectTrue(((resetReply.1 as? HTTPURLResponse)?.statusCode ?? 0) >= 400)
            } catch {}
            for _ in 0..<100 { if await proxy.activeConnections() == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let resetRemaining = await proxy.activeConnections(); expectEqual(resetRemaining, 0)
            checkpoint("Deep.proxy-releases-abruptly-reset-upstream")
            let cancelRaw = "GET /s/\(record.routeID)/cancel-stream HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(record.localKey)\r\n\r\n"
            let firstEvent = try await HalfCloseProbe(port: port, resetAfterFirstEvent: true).run(Data(cancelRaw.utf8))
            expectTrue(String(decoding: firstEvent, as: UTF8.self).contains("data: first"))
            for _ in 0..<100 { if await proxy.activeConnections() == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let remaining = await proxy.activeConnections()
            if remaining != 0 {
                print("CANCELLATION DIAGNOSTICS", await proxy.connectionDiagnostics(), "recent_requests", provider.received.suffix(5).map(\.target))
            }
            expectEqual(remaining, 0)
            checkpoint("Deep.real-client-disconnect-aborts-upstream-and-releases-connection")
            let (stoppedBytes, _) = try await session.bytes(for: request(record, "cancel-stream"))
            var iterator = stoppedBytes.lines.makeAsyncIterator(); _ = try await iterator.next()
            proxy.stop()
            do { while let _ = try await iterator.next() {}; checkFailures.append("stopped stream was reported as complete") } catch {}
            checkpoint("Deep.stopping-proxy-aborts-active-stream-explicitly")
            proxy.stop(); try await Task.sleep(for: .milliseconds(100)); proxy.start()
            for _ in 0..<150 { if proxy.running { break }; try await Task.sleep(for: .milliseconds(10)) }
            expectTrue(proxy.running)
            checkpoint("Deep.proxy-can-stop-and-restart")
        } catch { checkFailures.append("advanced proxy: " + error.localizedDescription); checkpoint("Deep.proxy-fixture-completion") }
    }
    private static func decodeChunks(_ data: Data) throws -> Data {
        var remaining = data[...], result = Data()
        while let end = remaining.range(of: Data("\r\n".utf8)) {
            guard let size = Int(String(decoding: remaining[..<end.lowerBound], as: UTF8.self), radix: 16) else { throw KeyDockError.message("Invalid fixture chunk size") }
            remaining = remaining[end.upperBound...]
            if size == 0 { return result }
            guard remaining.count >= size + 2 else { throw KeyDockError.message("Incomplete fixture chunk") }
            result.append(contentsOf: remaining.prefix(size)); remaining = remaining.dropFirst(size + 2)
        }
        throw KeyDockError.message("Missing final fixture chunk")
    }
}
