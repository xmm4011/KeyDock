import Foundation
import Network
import Combine

struct LocalHTTPRequest {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    static func parse(_ bytes: Data) throws -> Self? {
        var decoder = HTTPRequestDecoder()
        return try decoder.feed(bytes)
    }

    func upstream(records: [Credential]) throws -> (URLRequest, UUID) {
        guard headers["origin"] == nil, headers["sec-fetch-site"] == nil else { throw KeyDockError.message("本机代理不接受浏览器网页发起的请求。") }
        guard let targetParts = URLComponents(string: target), targetParts.host == nil, targetParts.fragment == nil else { throw KeyDockError.message("请求路径不合法。") }
        let components = targetParts.path.split(separator: "/").map(String.init)
        let encodedComponents = targetParts.percentEncodedPath.split(separator: "/").map(String.init)
        guard encodedComponents.count >= 2, encodedComponents[0].removingPercentEncoding == "s",
              let rawID = encodedComponents[1].removingPercentEncoding, let id = UUID(uuidString: rawID),
              let original = records.first(where: { $0.id == id && !$0.archived && !$0.expired }) else {
            throw KeyDockError.message("此本地别名不存在、已归档或已到期。")
        }
        let token = headers["authorization"].map { value in
            let parts = value.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.count == 2 && parts[0].lowercased() == "bearer" ? String(parts[1]).trimmed : value
        } ?? headers["x-api-key"] ?? headers["x-goog-api-key"] ?? headers["api-key"]
        guard token == original.localKey else { throw KeyDockError.message("请使用此条目的本地占位 Key。") }
        var rest = Array(encodedComponents.dropFirst(2))
        let decodedRest = Array(components.dropFirst(2))
        guard !rest.isEmpty, !decodedRest.contains(".."), !decodedRest.contains("."), !decodedRest.contains(where: { $0.contains("\\") || $0.contains("\0") }) else { throw KeyDockError.message("请求路径不合法。") }
        // Existing project aliases remain usable when the UI's selected protocol changes.
        let relative = decodedRest.filter { $0.range(of: #"^v[0-9]+(?:beta[0-9]*|alpha[0-9]*)?$"#, options: .regularExpression) == nil }.joined(separator: "/")
        let kind: ServiceKind? = relative == "chat/completions" ? .compatible : (relative == "messages" ? .anthropic : (relative == "responses" ? .responses : (relative.hasPrefix("models/") && relative.contains(":") ? .gemini : nil)))
        var record = ProviderPreset.configuration(original, kind: original.kind == .custom ? nil : kind)
        if relative == "models", let preset = ProviderPreset.matching(original.baseURL), let catalog = preset.catalogURL, let url = URL(string: catalog) {
            record.baseURL = url.deletingLastPathComponent().absoluteString
            record.auth = .bearer; rest = ["models"]
        }
        var base = try APIClient.safeURL(record.baseURL)
        let firstSegment = rest.first?.removingPercentEncoding
        let hasVersion = firstSegment?.range(of: #"^v[0-9]+(?:beta[0-9]*|alpha[0-9]*)?$"#, options: .regularExpression) != nil
        if (base.path.isEmpty || base.path == "/") && !hasVersion {
            if record.kind != .custom && base.host != "api.deepseek.com" { base.appendPathComponent(record.kind == .gemini ? "v1beta" : "v1") }
        }
        // Map the SDK's generic v1 onto a known provider's documented v2/v3.
        // Unknown gateway prefixes retain their existing boundary/version rules.
        if record.kind != .custom, hasVersion,
           base.lastPathComponent == firstSegment || (firstSegment == "v1" && kind != nil && ProviderPreset.matching(original.baseURL) != nil) { rest.removeFirst() }
        guard var upstream = URLComponents(url: base, resolvingAgainstBaseURL: false), upstream.query == nil else { throw KeyDockError.message("Base URL 不能包含查询参数。") }
        let encodedBase = upstream.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        upstream.percentEncodedPath = "/" + (encodedBase.isEmpty ? "" : encodedBase + "/") + rest.joined(separator: "/")
        upstream.percentEncodedQuery = targetParts.percentEncodedQuery.map { query in
            query.components(separatedBy: "&").filter { pair in
                let name = String(pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                let authenticationName = ["key", "api_key", "apikey", "access_token"].contains((name.removingPercentEncoding ?? name).lowercased())
                guard authenticationName else { return true }
                guard record.kind == .custom else { return false }
                let value = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
                return (value.removingPercentEncoding ?? value) != record.localKey
            }.joined(separator: "&")
        }
        guard let url = upstream.url else { throw KeyDockError.message("无法构造上游地址。") }
        var request = try APIClient.authenticatedRequest(url: url, record: record)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        let hopHeaders = (headers["connection"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let blocked = Set(["host", "connection", "content-length", "transfer-encoding", "authorization", "x-api-key", "api-key", "x-goog-api-key", "proxy-authorization", "proxy-connection", "keep-alive", "te", "trailer", "upgrade", "expect", "cookie", "accept-encoding", "origin", "referer", "forwarded", "x-forwarded-for"] + hopHeaders)
        let configured = Set(record.extraHeaders.components(separatedBy: .newlines).compactMap { $0.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() })
        for (key, value) in headers where !blocked.contains(key) && !key.hasPrefix("sec-") {
            if !configured.contains(key.lowercased()) { request.setValue(value, forHTTPHeaderField: key) }
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return (request, id)
    }
}

final class LocalProxy: ObservableObject, @unchecked Sendable {
    @Published var running = false
    @Published var error: String?
    @Published var requestCount = 0
    @Published private(set) var listeningPort: UInt16?
    private let queue = DispatchQueue(label: "local.keydock.proxy")
    private var listener: NWListener?
    private var records: [Credential] = []
    private var connections: [UUID: ProxyConnection] = [:]
    private var captureBodies = Set<UUID>()
    private var recorder: ((ProxyLogEntry) -> Void)?
    private var transport: ProxyUpstreamTransport?
    private let stateVersion = ProxyStateVersion()
    private var retiringListeners: [UUID: NWListener] = [:]
    private var startRequested = false
    let policy: ProxyTransportPolicy
    let port: UInt16
    private var upstreamIdleTimeout: TimeInterval
    init(port: UInt16 = 47831, policy: ProxyTransportPolicy = .init()) { self.port = port; self.policy = policy; upstreamIdleTimeout = policy.idleTimeout }
    deinit {
        listener?.stateUpdateHandler = nil; listener?.cancel()
        retiringListeners.values.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        let active = Array(connections.values), transport = transport
        queue.async { active.forEach { $0.abort() }; transport?.invalidate() }
    }

    func update(_ records: [Credential]) { queue.async { self.records = records } }
    // New upstream requests use the latest value; requests already in flight keep theirs.
    func setUpstreamIdleTimeout(_ value: TimeInterval) {
        queue.async { self.upstreamIdleTimeout = value; self.transport?.idleTimeout = value }
    }
    func currentUpstreamIdleTimeout() async -> TimeInterval {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.upstreamIdleTimeout) } }
    }
    func recordHistory(captureBodies: Set<UUID>, recorder: @escaping (ProxyLogEntry) -> Void) {
        queue.async { self.captureBodies = captureBodies; self.recorder = recorder }
    }
    func start() {
        queue.async { self.startRequested = true; self.startOnQueue() }
    }
    private func publish(_ generation: UInt64, running: Bool, port: UInt16? = nil, error: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stateVersion.matches(generation) else { return }
            self.running = running; self.listeningPort = port; self.error = error
        }
    }
    private func startOnQueue() {
            if listener != nil { startRequested = false; return }
            guard startRequested && retiringListeners.isEmpty else { return }
            startRequested = false
            let generation = stateVersion.advance(), listenerID = UUID()
            publish(generation, running: false)
            do {
                let parameters = NWParameters.tcp
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.port)!)
                let listener = try NWListener(using: parameters)
                let transport = ProxyUpstreamTransport(queue: self.queue, policy: self.policy); transport.idleTimeout = self.upstreamIdleTimeout; self.transport = transport
                let budget = ProxyRequestBudget(limit: self.policy.maximumBufferedRequestBytes)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .cancelled = state {
                        listener.stateUpdateHandler = nil
                        if self.retiringListeners.removeValue(forKey: listenerID) != nil { self.startOnQueue() }
                        return
                    }
                    guard self.stateVersion.matches(generation), self.listener === listener else { return }
                    switch state {
                    case .ready: self.publish(generation, running: true, port: listener.port?.rawValue)
                    case .failed(let error):
                        listener.stateUpdateHandler = nil; listener.cancel(); self.listener = nil
                        transport.retire(); if self.transport === transport { self.transport = nil }
                        self.publish(generation, running: false, error: "本机代理无法监听 \(self.port == 0 ? "系统分配端口" : String(self.port))，请检查端口占用或网络状态（\(error)）。")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.stateVersion.matches(generation), self.listener === listener else { connection.cancel(); return }
                    guard self.connections.count < self.policy.maximumClients else {
                        connection.start(queue: self.queue)
                        let body = Data("{\"error\":{\"type\":\"keydock_proxy_busy\",\"message\":\"代理并发已满，请稍后重试。\"}}".utf8)
                        connection.send(content: Data("HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nRetry-After: 1\r\nConnection: close\r\n\r\n".utf8) + body, completion: .contentProcessed { _ in connection.cancel() }); return
                    }
                    let id = UUID()
                    let handler = ProxyConnection(connection: connection, queue: self.queue, transport: transport, budget: budget, records: { [weak self] in self?.records ?? [] }, capture: { [weak self] in self?.captureBodies.contains($0) == true }, recorder: { [weak self] in self?.recorder?($0) }, onRequest: { [weak self] in
                        DispatchQueue.main.async { self?.requestCount += 1 }
                    }, onFinish: { [weak self] in self?.connections.removeValue(forKey: id) })
                    self.connections[id] = handler
                    handler.start()
                }
                listener.start(queue: self.queue)
            } catch { publish(generation, running: false, error: "无法启动本机代理：" + error.localizedDescription) }
    }
    func stop() {
        queue.async {
            self.startRequested = false
            let generation = self.stateVersion.advance()
            if let listener = self.listener {
                // Keep its cancellation callback alive so an immediate restart
                // waits for the old listening socket to release its port.
                let id = UUID()
                self.retiringListeners[id] = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard case .cancelled = state, let self else { return }
                    listener?.stateUpdateHandler = nil; self.retiringListeners.removeValue(forKey: id); self.startOnQueue()
                }
                listener.cancel(); self.listener = nil
            }
            let active = Array(self.connections.values)
            active.forEach { $0.abort() }
            self.connections.removeAll()
            self.transport?.invalidate(); self.transport = nil
            self.publish(generation, running: false)
        }
    }
    func activeConnections() async -> Int {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.connections.count) } }
    }
#if KEYDOCK_CHECKS
    func connectionDiagnostics() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.connections.values.map {
                    "path=\($0.task?.originalRequest?.url?.path ?? "-") received=\($0.received.count) task=\($0.task?.state.rawValue ?? -1) headers=\($0.sentHeaders) done=\($0.upstreamDone) paused=\($0.pausedForBackpressure) writes=\($0.pendingWrites) body=\($0.receivedBodyLength)/\($0.expectedBodyLength)"
                })
            }
        }
    }
#endif
}

final class ProxyConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let records: () -> [Credential]
    let onRequest: () -> Void
    let onFinish: () -> Void
    var received = Data()
    private var decoder = HTTPRequestDecoder()
    private var sentContinue = false
    let transport: ProxyUpstreamTransport
    let budget: ProxyRequestBudget
    private var reservedRequestBytes = 0
    private var requestBytesRead = 0
    var task: URLSessionDataTask?
    var finished = false
    var sentHeaders = false
    var timeout: DispatchWorkItem?
    var pendingWrites = 0
    var pendingWriteBytes = 0
    var pausedForBackpressure = false
    var upstreamDone = false
    var chunkedResponse = false
    var expectedBodyLength: Int64 = -1
    var receivedBodyLength: Int64 = 0
    let capture: (UUID) -> Bool
    let recorder: (ProxyLogEntry) -> Void
    var log: ProxyLogEntry?
    var responseBytes = Data()
    var usage = TokenUsage()

    init(connection: NWConnection, queue: DispatchQueue, transport: ProxyUpstreamTransport, budget: ProxyRequestBudget, records: @escaping () -> [Credential], capture: @escaping (UUID) -> Bool, recorder: @escaping (ProxyLogEntry) -> Void, onRequest: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.records = records; self.onRequest = onRequest; self.onFinish = onFinish
        self.capture = capture; self.recorder = recorder; self.transport = transport; self.budget = budget
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: queue)
        resetUploadTimeout()
        receive()
    }
    private func resetUploadTimeout() {
        timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.sendError("等待客户端继续上传超时。", status: 408) }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + transport.policy.uploadIdleTimeout, execute: timeout)
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.finished, !self.sentHeaders else { return }
            var bytes = Data()
            if let data {
                if !data.isEmpty { self.resetUploadTimeout() }
                self.requestBytesRead += data.count
                let additional = max(0, self.requestBytesRead - self.reservedRequestBytes)
                guard self.budget.reserve(additional) else { self.sendError("代理请求缓冲区繁忙，请稍后重试。", status: 503); return }
                self.reservedRequestBytes += additional; bytes = data
            }
            do {
                let request = try self.decoder.feed(bytes)
                // Admit known-size uploads before promising 100 Continue. This
                // lets accepted uploads finish instead of many partial bodies
                // exhausting the budget together and all failing midway.
                if let planned = self.decoder.declaredRequestBytes, planned > self.reservedRequestBytes {
                    let additional = planned - self.reservedRequestBytes
                    guard self.budget.reserve(additional) else { self.sendError("代理请求缓冲区繁忙，请稍后重试。", status: 503); return }
                    self.reservedRequestBytes += additional
                }
                if let request {
                    self.timeout?.cancel()
                    let (upstream, id) = try request.upstream(records: self.records())
                    let captured = self.capture(id)
                    var entry = ProxyLogEntry(credentialID: id, method: request.method, requestURL: captured ? (upstream.url?.absoluteString ?? "") : (upstream.url?.path ?? ""))
                    entry.bodiesCaptured = captured
                    let model = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["model"] as? String ?? ((upstream.url?.lastPathComponent.contains(":") == true) ? String((upstream.url?.lastPathComponent ?? "").split(separator: ":").first ?? "") : "")
                    entry.model = model
                    if captured {
                        entry.requestHeaders = RecordedContent.headers(upstream.allHTTPHeaderFields ?? [:])
                        entry.requestBody = RecordedContent.historyBody(request.body); entry.requestTruncated = request.body.count > RecordedContent.historyBodyLimit
                        entry.requestBodyLimit = RecordedContent.historyBodyLimit; entry.responseBodyLimit = RecordedContent.historyBodyLimit
                    }
                    self.log = entry
                    self.received = Data()
                    self.decoder = HTTPRequestDecoder()
                    self.onRequest()
                    self.forward(upstream)
                } else if error != nil || complete { self.finish() }
                else {
                    if self.decoder.expectsContinue, !self.sentContinue, let head = self.decoder.head {
                        _ = try head.upstream(records: self.records())
                        self.sentContinue = true; self.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                    }
                    self.receive()
                }
            } catch { self.sendError(error.localizedDescription, status: (error as? HTTPInputError)?.status ?? 400) }
        }
    }
    func forward(_ request: URLRequest) {
        do { task = try transport.start(request, target: self) }
        catch { sendError(error.localizedDescription, status: (error as? HTTPInputError)?.status ?? 503); return }
        // Continue reading to detect a disconnected client and cancel its upstream request.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            // A client may half-close its upload side and continue reading the response.
            if error != nil || data?.isEmpty == false { self?.finish() }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished, let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        log?.status = response.statusCode
        log?.responseOrigin = "upstream"
        usage.setContentType(response.value(forHTTPHeaderField: "Content-Type"))
        if log?.bodiesCaptured == true { log?.responseHeaders = RecordedContent.headers(Dictionary(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { a, _ in a })) }
        guard ![301, 302, 303, 307, 308].contains(response.statusCode) else {
            sendError("上游要求重定向，请在 KeyDock 中填写最终 Base URL。", status: 502); completionHandler(.cancel); return
        }
        var text = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\nConnection: close\r\n"
        let hopHeaders = (response.value(forHTTPHeaderField: "Connection") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let blocked = Set(["connection", "content-length", "transfer-encoding", "content-encoding", "set-cookie", "www-authenticate", "access-control-allow-origin", "authorization", "x-api-key", "api-key", "x-goog-api-key", "proxy-authorization", "proxy-authenticate", "proxy-connection", "keep-alive", "te", "trailer", "upgrade"] + hopHeaders)
        for (name, value) in response.allHeaderFields {
            let key = String(describing: name)
            if !blocked.contains(key.lowercased()) { text += "\(key): \(value)\r\n" }
        }
        chunkedResponse = dataTask.originalRequest?.httpMethod != "HEAD" && ![204, 205, 304].contains(response.statusCode)
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        if chunkedResponse && (encoding == nil || encoding == "identity") { expectedBodyLength = response.expectedContentLength }
        if chunkedResponse { text += "Transfer-Encoding: chunked\r\n" }
        text += "\r\n"
        sentHeaders = true; send(Data(text.utf8)); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, !data.isEmpty else { return }
        receivedBodyLength += Int64(data.count)
        usage.receive(data)
        if log?.bodiesCaptured == true {
            let room = RecordedContent.historyBodyLimit - responseBytes.count
            if room > 0 { responseBytes.append(data.prefix(room)) }
        }
        let payload = chunkedResponse ? Data((String(data.count, radix: 16) + "\r\n").utf8) + data + Data("\r\n".utf8) : data
        send(payload)
        // Pause only when the client falls behind. Pausing every small chunk can
        // race URLSession's EOF handling, leaving a truncated response running.
        if pendingWriteBytes >= 524_288 && !pausedForBackpressure && dataTask.state == .running && (expectedBodyLength < 0 || receivedBodyLength < expectedBodyLength) {
            pausedForBackpressure = true; dataTask.suspend()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if upstreamDone { if pendingWrites == 0 { finish() }; return }
        if let error {
            let ns = error as NSError
            log?.transportErrorDomain = ns.domain; log?.transportErrorCode = ns.code
        }
        if !sentHeaders {
            let timedOut = (error as? URLError)?.code == .timedOut
            let ns = error as NSError?
            let cause = ns.map { "（\($0.domain) \($0.code)）" } ?? ""
            sendError((timedOut ? "等待上游响应超时，上游尚未返回响应。" : "连接上游失败。") + cause, status: timedOut ? 504 : 502)
        }
        else {
            if error != nil || (expectedBodyLength >= 0 && expectedBodyLength != receivedBodyLength) {
                let ns = error as NSError?
                log?.error = "上游响应中断或长度不完整" + (ns.map { "（\($0.domain) \($0.code)）" } ?? "")
                connection.forceCancel(); finish(); return
            }
            if error == nil && chunkedResponse { send(Data("0\r\n\r\n".utf8)) }
            upstreamDone = true; if pendingWrites == 0 { finish() }
        }
    }
    func send(_ data: Data) {
        guard !finished else { return }
        pendingWrites += 1
        pendingWriteBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            self.pendingWrites -= 1
            self.pendingWriteBytes -= data.count
            if error != nil { self.finish(); return }
            if self.pendingWrites == 0 {
                if self.upstreamDone { self.finish() }
                else if self.pausedForBackpressure {
                    self.pausedForBackpressure = false
                    if self.task?.state == .suspended { self.task?.resume() }
                }
            }
        })
    }
    func sendError(_ message: String, status: Int = 400) {
        guard !finished, !sentHeaders else { finish(); return }
        log?.status = status; log?.error = message
        log?.responseOrigin = "proxy"
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "keydock_proxy_error"]])) ?? Data()
        if log?.bodiesCaptured == true {
            log?.responseHeaders = "Content-Type: application/json; charset=utf-8\nContent-Length: \(body.count)"
            responseBytes = body; receivedBodyLength = Int64(body.count)
        }
        let header = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        sentHeaders = true; upstreamDone = true
        send(Data(header.utf8) + body)
    }
    func finish() {
        guard !finished else { return }; finished = true
        if var entry = log {
            entry.duration = Date().timeIntervalSince(entry.startedAt)
            if !upstreamDone && entry.error == nil { entry.error = "连接提前结束或请求已取消" }
            usage.finish(); entry.inputTokens = usage.input; entry.outputTokens = usage.output; entry.totalTokens = usage.total
            if usage.hasAPIError && entry.error == nil { entry.error = "服务返回错误对象" }
            if entry.bodiesCaptured { entry.responseBody = RecordedContent.historyBody(responseBytes); entry.responseTruncated = receivedBodyLength > RecordedContent.historyBodyLimit }
            recorder(entry); log = nil
        }
        timeout?.cancel(); transport.cancel(task); task = nil
        budget.release(reservedRequestBytes); reservedRequestBytes = 0
        connection.stateUpdateHandler = nil; connection.cancel(); onFinish()
    }
    func abort() { connection.forceCancel(); finish() }
}
