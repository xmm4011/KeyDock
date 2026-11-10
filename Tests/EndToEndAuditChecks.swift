import Foundation
import CryptoKit
import Darwin

@MainActor enum EndToEndAuditChecks {
    static func run() async {
        runCheck("Audit.chunked-upload-decoding-and-strict-framing") {
            let head = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
            expectNil(try LocalHTTPRequest.parse(Data((head + "5\r\nhe").utf8)))
            let request = try unwrap(LocalHTTPRequest.parse(Data((head + "5;test=yes\r\nhello\r\n6\r\n world\r\n0\r\nX-Trace: fixture\r\n\r\n").utf8)))
            expectEqual(request.body, Data("hello world".utf8))
            for framing in ["Content-Length: +2", "Content-Length: 2, 2", "Transfer-Encoding: chunked\r\nContent-Length: 2", "Transfer-Encoding: gzip, chunked"] {
                expectThrows(try LocalHTTPRequest.parse(Data(("POST / HTTP/1.1\r\n" + framing + "\r\n\r\n12").utf8)))
            }
        }
        runCheck("Audit.Responses-SSE-nested-usage-and-error-events-are-not-lost") {
            var usage = TokenUsage()
            usage.receive(Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":19,\"output_tokens\":7}}}\n\n".utf8)); usage.finish()
            expectEqual(usage.input, 19); expectEqual(usage.output, 7); expectEqual(usage.total, 26)
            var error = TokenUsage(); error.receive(Data("event: error\ndata: {\"type\":\"error\",\"message\":\"fixture failure\"}\n\n".utf8)); error.finish(); expectTrue(error.hasAPIError)
            var failed = TokenUsage(); failed.receive(Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\"}}}\n\n".utf8)); failed.finish(); expectTrue(failed.hasAPIError)
            var mislabeled = TokenUsage(); mislabeled.setContentType("text/plain")
            mislabeled.receive(Data("{\"error\":{\"message\":\"fixture failure\"},\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}".utf8)); mislabeled.finish()
            expectTrue(mislabeled.hasAPIError); expectEqual(mislabeled.total, 3)
            var mislabeledStream = TokenUsage(); mislabeledStream.setContentType("application/json")
            mislabeledStream.receive(Data("data: {\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}\n\n".utf8)); mislabeledStream.finish(); expectEqual(mislabeledStream.total, 3)
        }
        runCheck("Audit.large-fragmented-JSON-and-SSE-retain-actual-usage") {
            for stream in [false, true] {
                let json = "{\"padding\":\"" + String(repeating: "x", count: 350000) + "\",\"usage\":{\"prompt_tokens\":123,\"completion_tokens\":45}}"
                let bytes = Data((stream ? "data: " + json + "\n\n" : json).utf8)
                var usage = TokenUsage()
                for offset in stride(from: 0, to: bytes.count, by: 8192) { usage.receive(Data(bytes[offset..<min(offset + 8192, bytes.count)])) }
                usage.finish(); expectEqual(usage.input, 123); expectEqual(usage.output, 45); expectEqual(usage.total, 168)
            }
        }
        runCheck("Audit.SSE-parser-recovers-after-oversized-events-and-handles-bytewise-BOM-and-multiline-data") {
            var usage = TokenUsage(); usage.setContentType("text/event-stream; charset=utf-8")
            let huge = Data(("data: " + String(repeating: "x", count: TokenUsage.limit + 10) + "\n\n").utf8)
            usage.receive(huge); expectTrue(usage.bufferedByteCount <= TokenUsage.limit)
            usage.receive(Data("data: {\"usage\":\ndata: {\"input_tokens\":5,\"output_tokens\":3}}\n\n".utf8)); usage.finish(); expectEqual(usage.total, 8)
            var bytewise = TokenUsage()
            for byte in Data("\u{feff}data: {\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}\r\n\r\n".utf8) { bytewise.receive(Data([byte])) }
            bytewise.finish(); expectEqual(bytewise.total, 6)
            expectTrue(AIOrganizer.session.configuration.timeoutIntervalForResource >= ProxyTransportPolicy().resourceTimeout)
        }
        await exchanges()
        await uploadProgress()
        await uploadAdmission()
        await lifecycle()
        await historyFailure()
        await HTTP2AuditChecks.run()
    }
    static func exchanges() async {
        let server = FixtureServer { request in request.target.hasSuffix("/cached") ? FixtureResponse(status: 304, chunks: []) : FixtureResponse(chunks: [request.body]) }
        let proxy = LocalProxy(port: 0)
        defer { proxy.stop(); server.stop() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            let port = try unwrap(proxy.listeningPort)
            func head(_ path: String, extra: String = "") -> String { "POST /s/\(record.routeID)/\(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(record.localKey)\r\n" + extra + "\r\n" }
            let bytes = try await AuditSocket.exchange(port: port, head: head("echo", extra: "Expect: 100-continue\r\nContent-Length: 5\r\n"), body: Data("hello".utf8), waitForContinue: true)
            expectTrue(String(decoding: bytes, as: UTF8.self).contains("100 Continue")); expectTrue(String(decoding: bytes, as: UTF8.self).contains("200")); expectEqual(server.received.last?.body, Data("hello".utf8))
            checkpoint("Audit.Expect-100-continue-does-not-deadlock-or-forward-before-authentication")
            let beforeChunk = server.received.count
            let chunk = try await AuditSocket.exchange(port: port, head: head("echo", extra: "Transfer-Encoding: chunked\r\n"), body: Data("5\r\nhello\r\n6\r\n world\r\n0\r\nX-Trace: test\r\n\r\n".utf8))
            expectTrue(String(decoding: chunk, as: UTF8.self).hasPrefix("HTTP/1.1 200")); expectEqual(server.received.count, beforeChunk + 1)
            expectEqual(server.received.last?.body, Data("hello world".utf8)); expectNil(server.received.last?.headers["expect"])
            let beforeUnauthorized = server.received.count
            let badHead = head("echo", extra: "Expect: 100-continue\r\nContent-Length: 5\r\n").replacingOccurrences(of: record.localKey, with: "wrong-key")
            let denied = try await AuditSocket.exchange(port: port, head: badHead, body: Data(), waitForContinue: true)
            expectFalse(String(decoding: denied, as: UTF8.self).contains("100 Continue")); expectEqual(server.received.count, beforeUnauthorized)
            checkpoint("Audit.chunked-wire-upload-is-decoded-and-unauthorized-continue-never-reaches-upstream")
            let cached = try await AuditSocket.exchange(port: port, head: head("cached"), body: Data())
            expectTrue(String(decoding: cached, as: UTF8.self).hasPrefix("HTTP/1.1 304"))
            var cachedLog = ProxyLogEntry(credentialID: record.id, method: "GET", requestURL: "/cached"); cachedLog.status = 304; expectTrue(cachedLog.succeeded)
            checkpoint("Audit.304-is-forwarded-as-cache-validation-not-rewritten-as-redirect-error")
            let before = server.received.count
            let upgrade = try await AuditSocket.exchange(port: port, head: head("socket", extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n"), body: Data())
            expectTrue(String(decoding: upgrade, as: UTF8.self).hasPrefix("HTTP/1.1 501")); expectEqual(server.received.count, before)
            checkpoint("Audit.unsupported-upgrade-is-rejected-explicitly-before-upstream")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Audit.HTTP-exchanges") }
    }
    static func lifecycle() async {
        let server = FixtureServer { _ in FixtureResponse(chunks: [Data("lifecycle-ok".utf8)]) }, probe = LocalProxy(port: 0)
        let session = URLSession(configuration: .ephemeral)
        var proxy: LocalProxy?, competitor: LocalProxy?
        defer { probe.stop(); proxy?.stop(); competitor?.stop(); server.stop(); session.invalidateAndCancel() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            probe.start(); await InteractionFlowChecks.wait { probe.running }
            let port = try unwrap(probe.listeningPort); probe.stop(); await InteractionFlowChecks.wait { !probe.running }
            try await Task.sleep(for: .milliseconds(100))
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            let current = LocalProxy(port: port); proxy = current; current.update([record]); current.start(); await InteractionFlowChecks.wait { current.running }
            for _ in 0..<30 { current.stop(); current.start() }
            // A read-only queue barrier lets all stop/start intents be consumed.
            _ = await current.activeConnections(); await InteractionFlowChecks.wait { current.running && current.listeningPort == port }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(record.routeID)/models")!)
            request.setValue("bEaReR " + record.localKey, forHTTPHeaderField: "Authorization")
            let reply = try await session.data(for: request); expectEqual(reply.0, Data("lifecycle-ok".utf8)); expectNil(current.error)
            checkpoint("Audit.30-immediate-stop-starts-reuse-the-port-and-publish-only-current-state")
            let competing = LocalProxy(port: port); competitor = competing; competing.start(); await InteractionFlowChecks.wait { competing.error != nil }
            expectFalse(competing.running); expectTrue(competing.error?.contains(String(port)) == true)
            current.stop(); await InteractionFlowChecks.wait { !current.running }; try await Task.sleep(for: .milliseconds(100))
            competing.start(); await InteractionFlowChecks.wait { competing.running }; expectNil(competing.error)
            competing.stop(); competing.start(); competing.stop()
            _ = await competing.activeConnections(); try await Task.sleep(for: .milliseconds(100)); expectFalse(competing.running); expectNil(competing.listeningPort)
            checkpoint("Audit.port-collision-recovers-and-final-stop-cannot-be-overridden-by-stale-ready")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Audit.lifecycle") }
    }
    static func uploadProgress() async {
        let server = FixtureServer { FixtureResponse(chunks: [$0.body]) }
        let proxy = LocalProxy(port: 0, policy: .init(uploadIdleTimeout: 0.3))
        defer { proxy.stop(); server.stop() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            let port = try unwrap(proxy.listeningPort)
            let head = "POST /s/\(record.routeID)/echo HTTP/1.1\r\nAuthorization: Bearer \(record.localKey)\r\nContent-Length: 3\r\n\r\n"
            let continued = try await AuditSocket.exchange(port: port, head: head, body: Data(), bodyChunks: [Data("a".utf8), Data("b".utf8), Data("c".utf8)], chunkDelay: 0.15)
            expectTrue(String(decoding: continued, as: UTF8.self).hasPrefix("HTTP/1.1 200")); expectEqual(server.received.last?.body, Data("abc".utf8))
            let stalled = try await AuditSocket.exchange(port: port, head: head, body: Data(), bodyChunks: [Data()], chunkDelay: 0.6)
            expectTrue(String(decoding: stalled, as: UTF8.self).hasPrefix("HTTP/1.1 408")); expectEqual(server.received.count, 1)
            try await Task.sleep(for: .milliseconds(100)); let active = await proxy.activeConnections(); expectEqual(active, 0)
            checkpoint("Audit.upload-idle-timeout-resets-on-progress-and-stalled-upload-releases-capacity")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Audit.upload-progress") }
    }
    static func historyFailure() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-AuditHistory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let key = SymmetricKey(size: .bits256), id = UUID()
            var locked = true
            let history = ProxyHistory(directory: root, pendingDetailLimit: 4096, keyProvider: { if locked { throw KeyDockError.message("fixture locked") }; return key })
            for i in 0..<100 {
                var entry = ProxyLogEntry(credentialID: id, method: "POST", requestURL: "/fixture/\(i)"); entry.status = 200
                entry.bodiesCaptured = true; entry.requestBody = String(repeating: "x", count: 1024); entry.responseBody = String(repeating: "y", count: 1024)
                history.append(entry)
            }
            history.flush(); expectTrue(history.error != nil); expectTrue(history.pendingDetailBytes <= 4096)
            expectEqual(history.entries.count, 100); expectEqual(history.totals[id]?.calls, 100)
            expectEqual(history.entries.filter { $0.detailsUnavailable != nil }.count, 98)
            locked = false; history.retryLoading(); expectNil(history.error); expectEqual(history.pendingDetailBytes, 0)
            let restored = ProxyHistory(directory: root, keyProvider: { key })
            expectEqual(restored.entries.count, 100); expectEqual(restored.totals[id]?.successes, 100)
            let newest = try await restored.loadDetail(for: unwrap(restored.entries.first)); expectEqual(newest.responseBody.count, 1024)
            let oldest = try await restored.loadDetail(for: unwrap(restored.entries.last)); expectTrue(oldest.detailsUnavailable != nil); expectFalse(oldest.detailsStored == true)
            let canceled = Task { @MainActor in try Task.checkCancellation(); return try await restored.loadDetail(for: unwrap(restored.entries.first)) }
            canceled.cancel(); do { _ = try await canceled.value; checkFailures.append("canceled detail load returned data") } catch is CancellationError {} catch { throw error }
            restored.clear(id); restored.flush(); expectTrue(restored.entries.isEmpty); expectEqual(restored.pendingDetailBytes, 0)
            checkpoint("Audit.locked-history-keeps-bounded-memory-and-truthful-metadata-then-recovers-and-clears")
            var diskLocked = true
            let sustained = ProxyHistory(directory: root.appendingPathComponent("sustained"), pendingDetailLimit: 2048, keyProvider: { if diskLocked { throw KeyDockError.message("fixture unavailable") }; return key })
            for _ in 0..<6100 {
                var entry = ProxyLogEntry(credentialID: id, method: "POST", requestURL: "/bounded"); entry.bodiesCaptured = true; entry.responseBody = String(repeating: "z", count: 1024)
                sustained.append(entry)
            }
            sustained.flush(); expectTrue(sustained.pendingDetailBytes <= 2048); expectTrue(sustained.pendingDeletionCount <= ProxyHistory.entryLimit)
            expectEqual(sustained.entries.count, 5000); expectEqual(sustained.totals[id]?.calls, 6100)
            diskLocked = false; sustained.retryLoading(); expectNil(sustained.error)
            expectEqual(try FileManager.default.contentsOfDirectory(at: sustained.detailDirectory, includingPropertiesForKeys: nil).count, 2)
            let reopened = ProxyHistory(directory: sustained.directory, keyProvider: { key }); expectEqual(reopened.entries.count, 5000); expectEqual(reopened.totals[id]?.calls, 6100)
            checkpoint("Audit.prolonged-storage-failure-bounds-retired-IDs-and-cleans-orphans-on-recovery")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Audit.history-recovery") }
    }
    static func uploadAdmission() async {
        let server = FixtureServer { FixtureResponse(chunks: [$0.body]) }, proxy = LocalProxy(port: 0, policy: .init(maximumBufferedRequestBytes: 4096))
        defer { proxy.stop(); server.stop() }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"
            proxy.update([record]); proxy.start(); await InteractionFlowChecks.wait { proxy.running }
            let port = try unwrap(proxy.listeningPort)
            let head = "POST /s/\(record.routeID)/echo HTTP/1.1\r\nAuthorization: Bearer \(record.localKey)\r\nExpect: 100-continue\r\nContent-Length: 3000\r\n\r\n"
            let body = Data(repeating: 97, count: 3000)
            let first = Task { try await AuditSocket.exchange(port: port, head: head, body: Data(), waitForContinue: true, bodyChunks: [body], chunkDelay: 0.4) }
            defer { first.cancel() }
            try await Task.sleep(for: .milliseconds(100))
            let rejected = try await AuditSocket.exchange(port: port, head: head, body: Data(), waitForContinue: true)
            expectTrue(String(decoding: rejected, as: UTF8.self).hasPrefix("HTTP/1.1 503"))
            let completed = try await first.value; expectTrue(String(decoding: completed, as: UTF8.self).contains("HTTP/1.1 200")); expectEqual(server.received.count, 1)
            let recovered = try await AuditSocket.exchange(port: port, head: head, body: body, waitForContinue: true)
            expectTrue(String(decoding: recovered, as: UTF8.self).contains("HTTP/1.1 200")); expectEqual(server.received.count, 2)
            checkpoint("Audit.known-upload-size-is-admitted-before-continue-and-overload-does-not-starve-accepted-uploads")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Audit.upload-admission") }
    }
}

enum AuditSocket {
    static func exchange(port: UInt16, head: String, body: Data, waitForContinue: Bool = false, bodyChunks: [Data]? = nil, chunkDelay: TimeInterval = 0) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try blocking(port: port, head: head, body: body, waitForContinue: waitForContinue, bodyChunks: bodyChunks, chunkDelay: chunkDelay) }) }
        }
    }
    private static func blocking(port: UInt16, head: String, body: Data, waitForContinue: Bool, bodyChunks: [Data]?, chunkDelay: TimeInterval) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }; guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        func write(_ data: Data) throws {
            try data.withUnsafeBytes { bytes in var offset = 0; while offset < bytes.count { let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0); guard count > 0 else { throw POSIXError(.EIO) }; offset += count } }
        }
        try write(Data(head.utf8)); var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        if waitForContinue {
            while result.range(of: Data("\r\n\r\n".utf8)) == nil {
                let count = recv(fd, &buffer, buffer.count, 0); guard count > 0 else { throw KeyDockError.message("100-continue 未及时返回") }; result.append(contentsOf: buffer.prefix(count))
            }
            guard String(decoding: result, as: UTF8.self).hasPrefix("HTTP/1.1 100") else { return result }
        }
        for part in bodyChunks ?? [body] { if chunkDelay > 0 { Thread.sleep(forTimeInterval: chunkDelay) }; if !part.isEmpty { try write(part) } }; _ = shutdown(fd, SHUT_WR)
        while true { let count = recv(fd, &buffer, buffer.count, 0); if count == 0 { break }; if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; result.append(contentsOf: buffer.prefix(count)) }
        return result
    }
}
