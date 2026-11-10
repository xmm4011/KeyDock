import Foundation

@MainActor enum HTTP2AuditChecks {
    static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-HTTP2-" + UUID().uuidString)
        let process = Process(), config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 64; config.timeoutIntervalForRequest = 8
        let client = URLSession(configuration: config), streams = ConcurrentSSEClient(configuration: config)
        var proxy: LocalProxy?
        defer { proxy?.stop(); streams.stop(); client.invalidateAndCancel(); if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let certificateConfig = "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\nCN=127.0.0.1\n[v3]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n"
            try certificateConfig.write(to: root.appendingPathComponent("openssl.cnf"), atomically: true, encoding: .utf8)
            func openssl(_ args: [String]) throws {
                let tool = Process(); tool.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); tool.arguments = args; tool.currentDirectoryURL = root
                tool.standardOutput = FileHandle.nullDevice; tool.standardError = FileHandle.nullDevice; try tool.run(); tool.waitUntilExit()
                guard tool.terminationStatus == 0 else { throw KeyDockError.message("HTTP/2 fixture certificate generation failed") }
            }
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "1", "-config", "openssl.cnf"])
            try openssl(["x509", "-in", "cert.pem", "-outform", "der", "-out", "cert.der"])
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node", URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/http2-fixture.mjs").path, root.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
            let ready = root.appendingPathComponent("ready.json")
            await InteractionFlowChecks.wait { FileManager.default.fileExists(atPath: ready.path) }
            let info = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Int]
            let port = try unwrap(info?["port"])
            let records = (0..<32).map { i -> Credential in var r = DeepChecks.record(); r.baseURL = "https://127.0.0.1:\(port)/v1"; r.apiKey = "fixture-h2-\(i)"; return r }
            var policy = ProxyTransportPolicy(maximumConnectionsPerHost: 1); policy.testCertificate = try Data(contentsOf: root.appendingPathComponent("cert.der"))
            let current = LocalProxy(port: 0, policy: policy); proxy = current; current.update(records); current.start(); await InteractionFlowChecks.wait { current.running }
            func request(_ record: Credential, _ path: String, _ body: String = "") throws -> URLRequest {
                var r = URLRequest(url: URL(string: "http://127.0.0.1:\(try unwrap(current.listeningPort))/s/\(record.routeID)/\(path)")!)
                r.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); r.httpMethod = "POST"; r.httpBody = Data(body.utf8); return r
            }
            let requests = try records.enumerated().map { try request($0.element, "stream", String($0.offset)) }
            let started = Date()
            let passed = await withTaskGroup(of: Bool.self) { group in
                for (index, request) in requests.enumerated() { group.addTask {
                    do {
                        let reply = try await streams.run(request)
                        let first = String(decoding: reply.body, as: UTF8.self).components(separatedBy: "\n").first ?? ""
                        let json = try JSONSerialization.jsonObject(with: Data(first.dropFirst(6).utf8)) as? [String: String]
                        return reply.status == 200 && reply.chunks >= 2 && reply.streamingDuration > 0.02 && json?["key"] == "Bearer fixture-h2-\(index)" && json?["body"] == String(index)
                    } catch { return false }
                } }
                var passed = 0; for await ok in group { if ok { passed += 1 } }; return passed
            }
            expectEqual(passed, 32)
            let h2Stats = try await client.data(for: request(records[0], "stats"))
            let statsJSON = try JSONSerialization.jsonObject(with: h2Stats.0) as? [String: Int]
            expectEqual(statsJSON?["sessions"], 1)
            checkpoint("Audit.HTTP2-TLS-multiplexes-32-isolated-SSE-calls-on-one-upstream-connection")
            print("HTTP2 METRICS calls=32 passed=\(passed) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s TLS_sessions=\(statsJSON?["sessions"] ?? -1)")
            var first = false
            let cancellationRequest = try request(records[0], "cancel")
            let cancellation = Task { @MainActor in
                let (bytes, _) = try await client.bytes(for: cancellationRequest)
                for try await _ in bytes { first = true; try Task.checkCancellation() }
            }
            await InteractionFlowChecks.wait { first }; cancellation.cancel(); _ = try? await cancellation.value
            let survivor = try await client.data(for: requests[1]); expectEqual((survivor.1 as? HTTPURLResponse)?.statusCode, 200)
            expectTrue(String(decoding: survivor.0, as: UTF8.self).contains("[DONE]"))
            checkpoint("Audit.HTTP2-cancelled-stream-does-not-reset-other-streams-or-the-session")
            let untrusted = LocalProxy(port: 0); defer { untrusted.stop() }; untrusted.update(records); untrusted.start(); await InteractionFlowChecks.wait { untrusted.running }
            var denied = requests[0]; denied.url = URL(string: "http://127.0.0.1:\(try unwrap(untrusted.listeningPort))/s/\(records[0].routeID)/stream")
            let rejected = try await client.data(for: denied); expectEqual((rejected.1 as? HTTPURLResponse)?.statusCode, 502)
            checkpoint("Audit.untrusted-TLS-is-rejected-without-changing-the-system-trust-store")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Audit.HTTP2") }
    }
}
