import Foundation
#if KEYDOCK_CHECKS
import Security
#endif

struct ProxyTransportPolicy {
    var idleTimeout: TimeInterval = NetworkTimeouts.defaultProxy
    var resourceTimeout: TimeInterval = 86400
    var maximumConnectionsPerHost = 64
    var maximumClients = 256
    var maximumBufferedRequestBytes = 128 * 1024 * 1024
    var uploadIdleTimeout: TimeInterval = 60
#if KEYDOCK_CHECKS
    // Exact loopback fixture certificate only; absent from production builds.
    var testCertificate: Data?
#endif
}

final class ProxyRequestBudget {
    private var used = 0
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func reserve(_ count: Int) -> Bool { guard count <= limit - used else { return false }; used += count; return true }
    func release(_ count: Int) { used = max(0, used - count) }
}

final class ProxyStateVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func advance() -> UInt64 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
    func matches(_ value: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return self.value == value }
}

// One ephemeral session per proxy. Reuse upstream connections and HTTP/2
// multiplexing while routing each task's events to its own client connection.
final class ProxyUpstreamTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Target { weak var value: ProxyConnection?; init(_ value: ProxyConnection) { self.value = value } }
    private var targets: [Int: Target] = [:]
    private var session: URLSession!
    private var invalidated = false, retiring = false
    let policy: ProxyTransportPolicy
    // Applied per request on the proxy queue; a request's own timeout overrides
    // the session default, so settings changes reach new calls without a new pool.
    var idleTimeout: TimeInterval
    init(queue: DispatchQueue, policy: ProxyTransportPolicy) {
        self.policy = policy; idleTimeout = policy.idleTimeout; super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.idleTimeout
        configuration.timeoutIntervalForResource = policy.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = policy.maximumConnectionsPerHost
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1; delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }
    func start(_ request: URLRequest, target: ProxyConnection) throws -> URLSessionDataTask {
        guard !invalidated && !retiring else { throw HTTPInputError(status: 503, message: "代理连接池正在关闭，请稍后重试。") }
        var request = request; request.timeoutInterval = idleTimeout
        let task = session.dataTask(with: request); targets[task.taskIdentifier] = Target(target); task.resume(); return task
    }
    func cancel(_ task: URLSessionTask?) { if let task { targets.removeValue(forKey: task.taskIdentifier); task.cancel() }; closeIfIdle() }
    func retire() { retiring = true; closeIfIdle() }
    private func closeIfIdle() { if retiring && targets.isEmpty { invalidate() } }
    func invalidate() { guard !invalidated else { return }; invalidated = true; session.invalidateAndCancel(); targets.removeAll() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
#if KEYDOCK_CHECKS
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let pin = policy.testCertificate, let trust = challenge.protectionSpace.serverTrust,
           let certificate = SecCertificateCreateWithData(nil, pin as CFData) {
            SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)); return }
        }
        completionHandler(.performDefaultHandling, nil)
    }
#endif
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let target = targets[dataTask.taskIdentifier]?.value else { completionHandler(.cancel); return }
        target.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { targets[dataTask.taskIdentifier]?.value?.urlSession(session, dataTask: dataTask, didReceive: data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let target = targets.removeValue(forKey: task.taskIdentifier)?.value
        target?.urlSession(session, task: task, didCompleteWithError: error)
        closeIfIdle()
    }
}
