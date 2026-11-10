import Foundation

struct HTTPInputError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

// Incremental HTTP/1 request framing. Body bytes are opaque; chunk framing and
// trailers never reach the upstream request, and ambiguous framing is rejected.
struct HTTPRequestDecoder {
    static let bodyLimit = 20 * 1024 * 1024
    private enum Phase { case head, fixed(Int), size, chunk(Int), chunkEnd, trailers, done }
    private var phase = Phase.head
    private var pending = Data(), body = Data()
    private var trailerBytes = 0
    private(set) var head: LocalHTTPRequest?
    private(set) var declaredRequestBytes: Int?
    var expectsContinue: Bool { head?.headers["expect"]?.lowercased() == "100-continue" }

    mutating func feed(_ data: Data) throws -> LocalHTTPRequest? {
        pending.append(data)
        while true {
            switch phase {
            case .head:
                guard let boundary = pending.range(of: Data("\r\n\r\n".utf8)) else {
                    if pending.count > 65536 { throw HTTPInputError(status: 431, message: "请求头过大。") }; return nil
                }
                let size = pending.distance(from: pending.startIndex, to: boundary.lowerBound)
                guard size <= 65536, let text = String(data: pending[..<boundary.lowerBound], encoding: .utf8) else { throw HTTPInputError(status: 400, message: "请求头不合法。") }
                let lines = text.components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ").map(String.init)
                guard first.count == 3, ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(first[0]), first[1].hasPrefix("/"), ["HTTP/1.1", "HTTP/1.0"].contains(first[2]) else { throw HTTPInputError(status: 400, message: "不支持的 HTTP 请求。") }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard pair.count == 2, headers[pair[0].lowercased()] == nil,
                          pair[0].range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                          pair[1].unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else { throw HTTPInputError(status: 400, message: "请求头重复或不合法。") }
                    headers[pair[0].lowercased()] = pair[1].trimmed
                }
                if headers["upgrade"] != nil || (headers["connection"] ?? "").lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) {
                    throw HTTPInputError(status: 501, message: "此代理支持 HTTP 与 SSE，暂不支持 WebSocket 或协议升级。")
                }
                if let expect = headers["expect"], expect.lowercased() != "100-continue" { throw HTTPInputError(status: 417, message: "不支持此 Expect 请求条件。") }
                if let transfer = headers["transfer-encoding"] {
                    guard headers["content-length"] == nil else { throw HTTPInputError(status: 400, message: "不能同时提供 Content-Length 与 Transfer-Encoding。") }
                    guard transfer.lowercased() == "chunked" else { throw HTTPInputError(status: 501, message: "上传仅支持 Content-Length 或 chunked 传输编码。") }
                    phase = .size
                } else {
                    let value = headers["content-length"] ?? "0"
                    guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let count = Int(value) else { throw HTTPInputError(status: 400, message: "Content-Length 不合法。") }
                    guard count <= Self.bodyLimit else { throw HTTPInputError(status: 413, message: "请求正文最大 20 MB。") }
                    declaredRequestBytes = size + 4 + count
                    phase = .fixed(count)
                }
                head = LocalHTTPRequest(method: first[0], target: first[1], headers: headers, body: Data())
                pending.removeSubrange(..<boundary.upperBound)
            case .fixed(let remaining):
                let count = min(remaining, pending.count)
                body.append(pending.prefix(count)); pending.removeFirst(count)
                if count == remaining { phase = .done } else { phase = .fixed(remaining - count); return nil }
            case .size:
                guard let line = try consumeLine(limit: 8192) else { return nil }
                let raw = String(line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmed
                guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), let size = Int(raw, radix: 16) else { throw HTTPInputError(status: 400, message: "分块大小不合法。") }
                guard size <= Self.bodyLimit - body.count else { throw HTTPInputError(status: 413, message: "请求正文最大 20 MB。") }
                phase = size == 0 ? .trailers : .chunk(size)
            case .chunk(let remaining):
                let count = min(remaining, pending.count)
                body.append(pending.prefix(count)); pending.removeFirst(count)
                if count == remaining { phase = .chunkEnd } else { phase = .chunk(remaining - count); return nil }
            case .chunkEnd:
                guard pending.count >= 2 else { return nil }
                guard pending.prefix(2) == Data("\r\n".utf8) else { throw HTTPInputError(status: 400, message: "分块结尾不合法。") }
                pending.removeFirst(2); phase = .size
            case .trailers:
                guard let line = try consumeLine(limit: 65536) else { return nil }
                trailerBytes += line.utf8.count + 2
                guard trailerBytes <= 65536 else { throw HTTPInputError(status: 431, message: "分块尾部过大。") }
                if line.isEmpty { phase = .done; continue }
                let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !["content-length", "transfer-encoding", "host", "authorization", "proxy-authorization", "x-api-key", "api-key", "x-goog-api-key", "cookie"].contains(pair[0].lowercased()),
                      pair[1].unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }),
                      pair[0].range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil else { throw HTTPInputError(status: 400, message: "分块尾部不合法。") }
            case .done:
                guard var request = head else { return nil }
                request.body = body; return request
            }
        }
    }
    private mutating func consumeLine(limit: Int) throws -> String? {
        guard let range = pending.range(of: Data("\r\n".utf8)) else {
            if pending.count > limit { throw HTTPInputError(status: 431, message: "分块头部过大。") }; return nil
        }
        guard pending.distance(from: pending.startIndex, to: range.lowerBound) <= limit, let line = String(data: pending[..<range.lowerBound], encoding: .utf8) else { throw HTTPInputError(status: 400, message: "分块头部不合法。") }
        pending.removeSubrange(..<range.upperBound); return line
    }
}
