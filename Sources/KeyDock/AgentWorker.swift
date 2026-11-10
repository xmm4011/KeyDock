import Foundation
import Darwin

final class AgentWorker: @unchecked Sendable {
    let process = Process()
    let events: AsyncThrowingStream<Data, Error>
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let writes = DispatchQueue(label: "keydock.agent.input")
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    // Access only on writes, including closure of the input handle.
    private var inputClosed = false
    private var diagnosticBytes = Data()
    var diagnostics: String { lock.lock(); defer { lock.unlock() }; return String(decoding: diagnosticBytes, as: UTF8.self) }
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(workspace: URL, runtime: URL, node: URL) throws {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }; continuation = captured
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let taskPath = Self.canonicalPath(workspace)
        process.arguments = ["-D", "KEYDOCK_TASK_DIR=" + taskPath,
                             "-D", "KEYDOCK_RUNTIME_DIR=" + Self.canonicalPath(runtime),
                             "-D", "KEYDOCK_NODE_DIR=" + Self.canonicalPath(node.deletingLastPathComponent()),
                             "-f", runtime.appendingPathComponent("sandbox.sb").path, node.path, runtime.appendingPathComponent("bridge.mjs").path]
        process.currentDirectoryURL = URL(fileURLWithPath: taskPath)
        process.environment = ["PATH": node.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": taskPath,
                               "LANG": "en_US.UTF-8", "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
                               "PI_CODING_AGENT_DIR": workspace.appendingPathComponent(".pi-task").path]
#if KEYDOCK_CHECKS
        process.environment?["KEYDOCK_AGENT_CHECKS"] = "1"
#endif
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        // Drain diagnostics without persisting or displaying provider payloads.
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            if let self { self.lock.lock(); self.diagnosticBytes.append(bytes.prefix(max(0, 32768 - self.diagnosticBytes.count))); self.lock.unlock() }
            if !bytes.isEmpty, let self,
               let event = try? JSONSerialization.data(withJSONObject: ["type":"runtime_diagnostic", "message":String(decoding: bytes.prefix(8192), as: UTF8.self)]) { self.continuation.yield(event) }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
            continuation.finish(throwing: KeyDockError.message("无法启动本机 Agent 运行时。")); throw error
        }
    }
    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if data.isEmpty {
            closed = true; output.fileHandleForReading.readabilityHandler = nil; continuation.finish(); return
        }
        buffer.append(data)
        if buffer.count > 2 * 1024 * 1024 { closed = true; continuation.finish(throwing: KeyDockError.message("Agent 通信内容过大。")); requestCancel(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if !line.isEmpty { continuation.yield(line) }
        }
    }
    func send(_ value: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) + Data([10])
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            writes.async {
                guard !self.inputClosed else { result.resume(throwing: KeyDockError.message("Agent 连接已结束。")); return }
                do { try self.input.fileHandleForWriting.write(contentsOf: data); result.resume() }
                catch { result.resume(throwing: KeyDockError.message("Agent 连接已结束。")) }
            }
        }
    }
    func requestCancel() {
        writes.async {
            guard !self.inputClosed else { return }
            try? self.input.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"cancel\"}\n".utf8))
        }
        if process.isRunning { process.terminate() }
    }
    func shutdown() async {
        // Cancellation of the caller must not cancel the grace period needed by
        // Pi to abort official tools and terminate their child process groups.
        await Task.detached { await self.finishShutdown() }.value
    }
    private func finishShutdown() async {
        requestCancel()
        for _ in 0..<100 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            for _ in 0..<50 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        await withCheckedContinuation { (result: CheckedContinuation<Void, Never>) in
            writes.async {
                if !self.inputClosed { self.inputClosed = true; try? self.input.fileHandleForWriting.close() }
                result.resume()
            }
        }
        // Read handles close with their owning objects after in-flight
        // readability callbacks release them, rather than during a callback.
        closeEvents()
    }
    private func closeEvents() { lock.lock(); defer { lock.unlock() }; if !closed { closed = true; continuation.finish() } }
    static func canonicalPath(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return url.path }
        defer { free(path) }; return String(cString: path)
    }
    static func resources() throws -> (runtime: URL, node: URL) {
        if let resources = Bundle.main.resourceURL {
            let runtime = resources.appendingPathComponent("AgentRuntime")
            let node = runtime.appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: node.path) { return (runtime, node) }
        }
#if KEYDOCK_CHECKS
        let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentRuntime")
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let node = URL(fileURLWithPath: String(directory)).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: node.path) { return (runtime, node.resolvingSymlinksInPath()) }
        }
#endif
        throw KeyDockError.message("未找到内置 Agent 运行时，请重新安装完整的 KeyDock 应用。")
    }
}
