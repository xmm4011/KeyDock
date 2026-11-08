import Foundation
import Network
import Combine

struct LocalHTTPRequest {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    static func parse(_ bytes: Data) throws -> Self? {
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 65_536 { throw KeyDockError.message("请求头过大。") }
            return nil
        }
        guard boundary.lowerBound <= 65_536, let text = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw KeyDockError.message("请求头不合法。") }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count == 3, ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(first[0]), first[1].hasPrefix("/"), first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw KeyDockError.message("不支持的 HTTP 请求。") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, headers[pair[0].lowercased()] == nil,
                  pair[0].range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                  pair[1].unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else { throw KeyDockError.message("请求头重复或不合法。") }
            headers[pair[0].lowercased()] = pair[1].trimmed
        }
        guard headers["transfer-encoding"] == nil else { throw KeyDockError.message("暂不支持分块上传，请使用带 Content-Length 的请求。") }
        let count: Int
        if let length = headers["content-length"] {
            guard let parsed = Int(length), parsed >= 0 else { throw KeyDockError.message("Content-Length 不合法。") }
            count = parsed
        } else { count = 0 }
        guard count <= 20 * 1024 * 1024 else { throw KeyDockError.message("请求正文最大 20 MB。") }
        let start = boundary.upperBound
        guard bytes.count >= start + count else { return nil }
        return Self(method: first[0], target: first[1], headers: headers, body: bytes.subdata(in: start..<(start + count)))
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
        let token = headers["authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 } ?? headers["x-api-key"] ?? headers["x-goog-api-key"] ?? headers["api-key"]
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
        let blocked = Set(["host", "connection", "content-length", "transfer-encoding", "authorization", "x-api-key", "api-key", "x-goog-api-key", "proxy-authorization", "proxy-connection", "keep-alive", "te", "trailer", "upgrade", "cookie", "accept-encoding", "origin", "referer", "forwarded", "x-forwarded-for"] + hopHeaders)
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
    let port: UInt16
    init(port: UInt16 = 47831) { self.port = port }
    deinit {
        listener?.stateUpdateHandler = nil; listener?.cancel()
        connections.values.forEach { $0.abort() }
    }

    func update(_ records: [Credential]) { queue.async { self.records = records } }
    func recordHistory(captureBodies: Set<UUID>, recorder: @escaping (ProxyLogEntry) -> Void) {
        queue.async { self.captureBodies = captureBodies; self.recorder = recorder }
    }
    func start() {
        queue.async {
            guard self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.port)!)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: DispatchQueue.main.async { self.running = true; self.listeningPort = listener.port?.rawValue; self.error = nil }
                    case .failed:
                        listener.stateUpdateHandler = nil; listener.cancel(); self.listener = nil
                        DispatchQueue.main.async { self.running = false; self.error = "本机代理无法监听 47831 端口，请检查是否有另一个 KeyDock 或其他程序占用。" }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    guard self.connections.count < 64 else { connection.cancel(); return }
                    let id = UUID()
                    let handler = ProxyConnection(connection: connection, queue: self.queue, records: { [weak self] in self?.records ?? [] }, capture: { [weak self] in self?.captureBodies.contains($0) == true }, recorder: { [weak self] in self?.recorder?($0) }, onRequest: { [weak self] in
                        DispatchQueue.main.async { self?.requestCount += 1 }
                    }, onFinish: { [weak self] in self?.connections.removeValue(forKey: id) })
                    self.connections[id] = handler
                    handler.start()
                }
                listener.start(queue: self.queue)
            } catch { DispatchQueue.main.async { self.error = "无法启动本机代理。"; self.running = false } }
        }
    }
    func stop() {
        queue.async {
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel(); self.listener = nil
            let active = Array(self.connections.values)
            active.forEach { $0.abort() }
            self.connections.removeAll()
            DispatchQueue.main.async { self.running = false; self.listeningPort = nil }
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

private final class ProxyConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let records: () -> [Credential]
    let onRequest: () -> Void
    let onFinish: () -> Void
    var received = Data()
    var session: URLSession?
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

    init(connection: NWConnection, queue: DispatchQueue, records: @escaping () -> [Credential], capture: @escaping (UUID) -> Bool, recorder: @escaping (ProxyLogEntry) -> Void, onRequest: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.records = records; self.onRequest = onRequest; self.onFinish = onFinish
        self.capture = capture; self.recorder = recorder
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        receive()
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data { self.received.append(data) }
            do {
                if let request = try LocalHTTPRequest.parse(self.received) {
                    self.timeout?.cancel()
                    let (upstream, id) = try request.upstream(records: self.records())
                    let captured = self.capture(id)
                    var entry = ProxyLogEntry(credentialID: id, method: request.method, requestURL: captured ? (upstream.url?.absoluteString ?? "") : (upstream.url?.path ?? ""))
                    entry.bodiesCaptured = captured
                    let model = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["model"] as? String ?? ((upstream.url?.lastPathComponent.contains(":") == true) ? String((upstream.url?.lastPathComponent ?? "").split(separator: ":").first ?? "") : "")
                    entry.model = model
                    if captured {
                        entry.requestHeaders = RecordedContent.headers(upstream.allHTTPHeaderFields ?? [:])
                        entry.requestBody = RecordedContent.body(request.body); entry.requestTruncated = request.body.count > RecordedContent.bodyLimit
                    }
                    self.log = entry
                    self.received = Data()
                    self.onRequest()
                    self.forward(upstream)
                } else if error != nil || complete { self.finish() }
                else { self.receive() }
            } catch { self.sendError(error.localizedDescription) }
        }
    }
    func forward(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1; delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
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
        if log?.bodiesCaptured == true { log?.responseHeaders = RecordedContent.headers(Dictionary(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { a, _ in a })) }
        guard !(300..<400).contains(response.statusCode) else {
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
            let room = RecordedContent.bodyLimit - responseBytes.count
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
        if !sentHeaders { sendError("无法连接上游服务，请检查网络及服务配置。", status: 502) }
        else {
            if error != nil || (expectedBodyLength >= 0 && expectedBodyLength != receivedBodyLength) {
                log?.error = "上游响应中断或长度不完整"
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
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "keydock_proxy_error"]])) ?? Data()
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
            if entry.bodiesCaptured { entry.responseBody = RecordedContent.body(responseBytes); entry.responseTruncated = receivedBodyLength > RecordedContent.bodyLimit }
            recorder(entry); log = nil
        }
        timeout?.cancel(); task?.cancel(); session?.invalidateAndCancel(); session = nil
        connection.stateUpdateHandler = nil; connection.cancel(); onFinish()
    }
    func abort() { connection.forceCancel(); finish() }
}
