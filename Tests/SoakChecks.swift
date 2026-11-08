import Foundation

enum SoakChecks {
    @MainActor static func run() async {
        let started = Date()
        let server = FixtureServer { request in
            let index = request.target.components(separatedBy: "/").last ?? ""
            guard request.headers["authorization"] == "Bearer fixture-soak-" + index else { return FixtureResponse(status: 403) }
            return FixtureResponse(chunks: [request.body])
        }
        let proxy = LocalProxy(port: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 24; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { proxy.stop(); server.stop(); session.invalidateAndCancel() }
        do {
            try server.start()
            for _ in 0..<200 { if server.port != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard let upstreamPort = server.port else { throw KeyDockError.message("soak server failed") }
            var records = (0..<32).map { index -> Credential in
                var record = Credential(); record.baseURL = "http://127.0.0.1:\(upstreamPort)/v1"; record.apiKey = "fixture-soak-\(index)"; return record
            }
            proxy.update(records); proxy.start()
            for _ in 0..<200 { if proxy.running { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard let port = proxy.listeningPort else { throw KeyDockError.message("soak proxy failed") }
            func makeRequest(_ sequence: Int) -> URLRequest {
                let index = sequence % records.count, record = records[index]
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(record.routeID)/echo/\(index)")!)
                request.httpMethod = "POST"; request.httpBody = Data("request-\(sequence)-你好".utf8)
                request.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization")
                return request
            }
            func batch(_ start: Int, count: Int) async -> Int {
                let requests = (start..<(start + count)).map { makeRequest($0) }
                return await withTaskGroup(of: Bool.self) { group in
                    for request in requests { group.addTask {
                        do { let reply = try await session.data(for: request); return (reply.1 as? HTTPURLResponse)?.statusCode == 200 && reply.0 == request.httpBody }
                        catch { return false }
                    } }
                    var passed = 0; for await ok in group { if ok { passed += 1 } }; return passed
                }
            }
            let warmed = await batch(0, count: 48); expectEqual(warmed, 48)
            try await Task.sleep(for: .milliseconds(300))
            func descriptors() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
            let before = try descriptors()
            var passed = 0
            for step in 0..<50 { passed += await batch(48 + step * 24, count: 24) }
            expectEqual(passed, 1200); checkpoint("Soak.1200-calls-32-keys-24-concurrent-correct-route-and-body")
            try await Task.sleep(for: .seconds(1))
            let connections = await proxy.activeConnections(), after = try descriptors()
            expectEqual(connections, 0); expectTrue(after <= before + 12)
            checkpoint("Soak.connections-return-to-zero-and-file-descriptors-stay-bounded")
            // Rotate a key without changing its public alias; old upstream credentials must vanish.
            records[0].apiKey = "rotated-fixture-key"; proxy.update(records)
            let denied = try await session.data(for: makeRequest(0))
            expectEqual((denied.1 as? HTTPURLResponse)?.statusCode, 403)
            records[0].archived = true; proxy.update(records)
            let archived = try await session.data(for: makeRequest(0))
            expectEqual((archived.1 as? HTTPURLResponse)?.statusCode, 400)
            checkpoint("Soak.rotation-and-archive-take-effect-after-load")
            print("SOAK METRICS calls=1248 successful=\(passed + warmed) connections=\(connections) fd_before=\(before) fd_after=\(after) seconds=\(Int(Date().timeIntervalSince(started)))")
        } catch { checkFailures.append("soak: " + error.localizedDescription) }
        if checkFailures.isEmpty { print("ALL SOAK CHECKS PASSED (\(checkCount) scenarios)") }
        else { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
    }
}
