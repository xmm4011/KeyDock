import Foundation
import CryptoKit
import Combine

struct ProxyLogEntry: Identifiable, Codable {
    var id = UUID()
    var credentialID: UUID
    var startedAt = Date()
    var duration: Double = 0
    var method: String
    var model = ""
    var status: Int?
    var error: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var requestURL: String
    var requestHeaders = ""
    var requestBody = ""
    var responseHeaders = ""
    var responseBody = ""
    var bodiesCaptured = false
    var requestTruncated = false
    var responseTruncated = false
    var succeeded: Bool { error == nil && status.map { (200..<300).contains($0) } == true }
}

struct ProxyTotals: Codable {
    var calls = 0
    var successes = 0
    var input = 0
    var output = 0
    var inputReported = 0
    var outputReported = 0
    mutating func add(_ entry: ProxyLogEntry) {
        func sum(_ a: Int, _ b: Int) -> Int { a <= Int.max - b ? a + b : Int.max }
        calls = sum(calls, 1); if entry.succeeded { successes = sum(successes, 1) }
        if let value = entry.inputTokens { input = sum(input, value); inputReported = sum(inputReported, 1) }
        if let value = entry.outputTokens { output = sum(output, value); outputReported = sum(outputReported, 1) }
    }
}

struct TokenUsage {
    private var buffer = Data()
    private var pendingLine = Data()
    var input: Int?
    var output: Int?
    var total: Int?
    var hasAPIError = false
    mutating func receive(_ bytes: Data) {
        buffer.append(bytes)
        if buffer.count > 262_144 { buffer.removeFirst(buffer.count - 262_144) }
        pendingLine.append(bytes)
        while let newline = pendingLine.firstIndex(of: 10) {
            let line = String(decoding: pendingLine[..<newline], as: UTF8.self)
            pendingLine.removeSubrange(...newline)
            absorbLine(line)
        }
        if pendingLine.count > 65_536 { pendingLine.removeFirst(pendingLine.count - 65_536) }
    }
    mutating func finish() {
        if let json = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] { absorb(json); return }
        absorbLine(String(decoding: pendingLine, as: UTF8.self))
    }
    private mutating func absorbLine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let value = String(line.dropFirst(5)).trimmed
        if let data = value.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { absorb(json) }
    }
    private mutating func absorb(_ json: [String: Any]) {
        if APIClient.hasAPIError(json) { hasAPIError = true }
        let usage = json["usage"] as? [String: Any] ?? json["usageMetadata"] as? [String: Any] ?? (json["message"] as? [String: Any])?["usage"] as? [String: Any]
        guard let usage else { return }
        func count(_ names: [String]) -> Int? {
            for name in names {
                if let number = usage[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue { return number.intValue }
            }
            return nil
        }
        if let value = count(["prompt_tokens", "input_tokens", "promptTokenCount"]) { input = value }
        if let value = count(["completion_tokens", "output_tokens", "candidatesTokenCount"]) {
            let thinking = count(["thoughtsTokenCount"]) ?? 0
            output = value <= Int.max - thinking ? value + thinking : value
        }
        if let value = count(["total_tokens", "totalTokenCount"]) { total = value }
        else if let input, let output, input <= Int.max - output { total = input + output }
    }
}

// Local evidence preserves original values. Bound storage without masking fields.
enum RecordedContent {
    static let bodyLimit = 131_072
    static func headers(_ values: [String: String]) -> String {
        values.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { $0.key + ": " + $0.value }.joined(separator: "\n")
    }
    static func body(_ data: Data) -> String {
        var limited = Data(String(decoding: data.prefix(bodyLimit), as: UTF8.self).utf8.prefix(bodyLimit))
        while String(data: limited, encoding: .utf8) == nil && !limited.isEmpty { limited.removeLast() }
        if data.count <= bodyLimit,
           let json = try? JSONSerialization.jsonObject(with: limited, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           pretty.count <= bodyLimit { return String(decoding: pretty, as: UTF8.self) }
        return String(decoding: limited, as: UTF8.self)
    }
}

// Used for outbound AI context and explicitly credential-free configurations.
enum LogRedaction {
    static let bodyLimit = 131_072
    static func isSensitiveHeader(_ name: String) -> Bool {
        let name = name.lowercased()
        if name.hasPrefix("access-control-") { return false }
        return ["authorization", "proxy-authorization", "x-api-key", "api-key", "x-goog-api-key", "cookie", "set-cookie"].contains(name)
            || ["token", "secret", "api-key", "api_key", "apikey", "credential", "password", "signature", "authorization"].contains(where: { name.contains($0) })
            || name.hasSuffix("-auth") || name.hasSuffix("-key")
    }
    static func text(_ value: String, secret: String, otherSecrets: [String] = []) -> String {
        guard !value.isEmpty else { return value }
        let secrets = Set([secret] + otherSecrets).filter { !$0.isEmpty }
        guard !secrets.isEmpty else { return value }
        let masked = value.replacingSecrets(Dictionary(uniqueKeysWithValues: secrets.map { ($0, "[已隐藏]") }))
        var decoded = masked
        for _ in 0..<3 {
            guard decoded.contains("\\") || decoded.contains("%") else { break }
            var next = decoded.replacingOccurrences(of: #"\/"#, with: "/").replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#)
            next = decodeParts(next, pattern: #"(?:\\u[0-9A-Fa-f]{4})+"#) { fragment in
                (try? JSONSerialization.jsonObject(with: Data(("\"" + fragment + "\"").utf8), options: [.fragmentsAllowed])) as? String
            }
            next = decodeParts(next, pattern: #"(?:%[0-9A-Fa-f]{2})+"#) { $0.removingPercentEncoding }
            if secrets.contains(where: { next.contains($0) }) { return "[已隐藏敏感内容]" }
            if next == decoded { break }; decoded = next
        }
        return masked
    }
    private static func decodeParts(_ value: String, pattern: String, decode: (String) -> String?) -> String {
        guard let expression = RegexCache.expression(pattern) else { return value }
        let source = value as NSString, output = NSMutableString(string: value)
        for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)).reversed() {
            if let decoded = decode(source.substring(with: match.range)) { output.replaceCharacters(in: match.range, with: decoded) }
        }
        return output as String
    }
    static func headers(_ values: [String: String], secret: String, otherSecrets: [String] = []) -> String {
        return values.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { name, value in
            name + ": " + (isSensitiveHeader(name) ? "[已隐藏]" : text(value, secret: secret, otherSecrets: otherSecrets))
        }.joined(separator: "\n")
    }
    static func body(_ data: Data, secret: String, otherSecrets: [String] = []) -> String {
        guard ([secret] + otherSecrets).allSatisfy({ $0.utf8.count <= 8192 }) else { return "[密钥过长，正文未记录]" }
        let safe = text(String(decoding: data.prefix(bodyLimit + 8192), as: UTF8.self), secret: secret, otherSecrets: otherSecrets)
        var limited = Data(Data(safe.utf8).prefix(bodyLimit))
        while String(data: limited, encoding: .utf8) == nil && !limited.isEmpty { limited.removeLast() }
        if let json = try? JSONSerialization.jsonObject(with: limited), let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), pretty.count <= bodyLimit { return text(String(decoding: pretty, as: UTF8.self), secret: secret, otherSecrets: otherSecrets) }
        return String(decoding: limited, as: UTF8.self)
    }
}

@MainActor final class ProxyHistory: ObservableObject {
    struct Payload: Codable {
        var entries: [ProxyLogEntry] = []
        var captureBodies: Set<UUID> = []
        var totals: [UUID: ProxyTotals]?
    }
    @Published private(set) var entries: [ProxyLogEntry] = []
    @Published private(set) var captureBodies = Set<UUID>()
    @Published private(set) var totals: [UUID: ProxyTotals] = [:]
    @Published var error: String?
    let directory: URL
    let keyProvider: () throws -> SymmetricKey
    private var saveTask: Task<Void, Never>?
    private var loaded = false
    private var dirty = false
    private var writeFailed = false
    private var sizes: [UUID: Int] = [:]
    private var credentialIDs: Set<UUID>?
    private var clearedBefore: [UUID: Date] = [:]
    var isReadable: Bool { loaded }
    var fileURL: URL { directory.appendingPathComponent("history.kdv") }
    init(directory: URL, keyProvider: @escaping () throws -> SymmetricKey) {
        self.directory = directory; self.keyProvider = keyProvider
        retryLoading()
    }
    func retryLoading() {
        if loaded { writeFailed = false; flush(); return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { loaded = true; error = nil; return }
        do {
            let bytes = try Data(contentsOf: fileURL)
            guard bytes.count <= 12 * 1024 * 1024 else { throw KeyDockError.message("调用记录过大。") }
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyProvider())
            let payload = try JSONDecoder().decode(Payload.self, from: clear)
            let restored = Array(payload.entries.prefix(100))
            guard Set(restored.map(\.id)).count == restored.count else { throw KeyDockError.message("调用记录包含重复编号。") }
            var restoredTotals = payload.totals ?? [:]
            if payload.totals == nil { for entry in restored { restoredTotals[entry.credentialID, default: ProxyTotals()].add(entry) } }
            entries = restored; captureBodies = payload.captureBodies; totals = restoredTotals
            sizes = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, (try? JSONEncoder().encode($0).count) ?? 0) })
            loaded = true; error = nil
            if let credentialIDs { synchronize(credentialIDs) }
        } catch { self.error = "调用记录暂时无法读取，原文件未改动。恢复文件或解锁钥匙串后可重试。" }
    }
    func synchronize(_ ids: Set<UUID>) {
        let oldIDs = (credentialIDs ?? []).union(entries.map(\.credentialID)).union(totals.keys).union(captureBodies)
        credentialIDs = ids
        let removed = oldIDs.subtracting(ids), cutoff = Date()
        for id in removed { clearedBefore[id] = cutoff }
        guard loaded else { return }
        let retained = entries.filter { ids.contains($0.credentialID) }
        let retainedTotals = totals.filter { ids.contains($0.key) }
        let retainedCapture = captureBodies.intersection(ids)
        guard retained.count != entries.count || retainedTotals.count != totals.count || retainedCapture != captureBodies else { return }
        entries = retained; totals = retainedTotals; captureBodies = retainedCapture
        sizes = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, sizes[$0.id] ?? 0) })
        dirty = true; saveSoon()
    }
    func append(_ entry: ProxyLogEntry) {
        guard loaded, credentialIDs?.contains(entry.credentialID) != false, sizes[entry.id] == nil,
              clearedBefore[entry.credentialID].map({ entry.startedAt > $0 }) ?? true else { return }
        totals[entry.credentialID, default: ProxyTotals()].add(entry)
        entries.insert(entry, at: 0)
        sizes[entry.id] = (try? JSONEncoder().encode(entry).count) ?? 0
        while entries.count > 100 || (sizes.values.reduce(0, +) > 8 * 1024 * 1024 && entries.count > 1) { let removed = entries.removeLast(); sizes.removeValue(forKey: removed.id) }
        dirty = true; saveSoon()
    }
    func setCapture(_ value: Bool, for id: UUID) {
        guard loaded, credentialIDs?.contains(id) != false else { return }
        if value { captureBodies.insert(id) } else { captureBodies.remove(id) }
        dirty = true; saveSoon()
    }
    func clear(_ id: UUID) {
        guard loaded else { return }
        clearedBefore[id] = Date()
        for entry in entries where entry.credentialID == id { sizes.removeValue(forKey: entry.id) }
        entries.removeAll { $0.credentialID == id }; totals.removeValue(forKey: id)
        dirty = true; saveSoon()
    }
    private func saveSoon() {
        guard saveTask == nil, !writeFailed else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil; self.flush()
        }
    }
    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard loaded && dirty && !writeFailed else { return }
        do {
            let payload = Payload(entries: entries, captureBodies: captureBodies, totals: totals)
            let bytes = try AES.GCM.seal(JSONEncoder().encode(payload), using: keyProvider()).combined!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            dirty = false; error = nil
        } catch { writeFailed = true; self.error = "调用记录保存失败，密钥保险库未受影响。解锁钥匙串或恢复磁盘权限后可重试。" }
    }
}
