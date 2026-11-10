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
    var detailsStored: Bool?
    var detailsUnavailable: String?
    var requestBodyLimit: Int?
    var responseBodyLimit: Int?
    var responseOrigin: String?
    var transportErrorDomain: String?
    var transportErrorCode: Int?
    var succeeded: Bool { error == nil && status.map { (200..<300).contains($0) || $0 == 304 } == true }
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
    static let limit = 2 * 1024 * 1024
    private enum Mode { case unknown, json, sse, other }
    private var mode = Mode.unknown
    private var buffer = Data(), pendingLine = Data(), eventData = Data()
    private var overflow = false, eventOverflow = false, firstLine = true
    private var eventType = ""
    var bufferedByteCount: Int { buffer.count + pendingLine.count + eventData.count }
    var input: Int?
    var output: Int?
    var total: Int?
    var hasAPIError = false
    mutating func setContentType(_ value: String?) {
        guard let value else { return }
        if value.lowercased().contains("text/event-stream") { mode = .sse }
        // Compatible gateways sometimes omit or mislabel Content-Type. Sniff
        // JSON/SSE bytes rather than losing their usage/error information.
        else { mode = .unknown }
    }
    mutating func receive(_ bytes: Data) {
        switch mode {
        case .other: return
        case .unknown:
            guard buffer.count + bytes.count <= Self.limit else { mode = .other; buffer.removeAll(); return }
            buffer.append(bytes)
            let bom = Data([0xef, 0xbb, 0xbf])
            if buffer.count < 3 && bom.starts(with: buffer) { return }
            if buffer.starts(with: bom) { buffer.removeFirst(3) }
            guard let first = buffer.first(where: { ![9, 10, 13, 32].contains($0) }) else { return }
            if first == 123 || first == 91 { mode = .json; return }
            if [100, 101, 105, 114, 58].contains(first) {
                mode = .sse; let initial = buffer; buffer = Data(); receive(initial)
            } else { mode = .other; buffer.removeAll() }
        case .json:
            guard !overflow else { return }
            if buffer.count + bytes.count > Self.limit { buffer.removeAll(); overflow = true }
            else { buffer.append(bytes) }
        case .sse:
            var start = bytes.startIndex
            while let end = bytes[start...].firstIndex(of: 10) {
                appendLine(bytes[start..<end]); consumeLine(); start = bytes.index(after: end)
            }
            if start < bytes.endIndex { appendLine(bytes[start...]) }
        }
    }
    private mutating func appendLine(_ data: Data) {
        guard !overflow else { return }
        guard pendingLine.count + eventData.count + data.count <= Self.limit else {
            pendingLine.removeAll(); eventData.removeAll(); overflow = true; eventOverflow = true; return
        }
        pendingLine.append(data)
    }
    private mutating func consumeLine() {
        defer { pendingLine.removeAll(keepingCapacity: pendingLine.count <= 65536); overflow = false; firstLine = false }
        var line = String(decoding: pendingLine, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        if firstLine && line.hasPrefix("\u{feff}") { line.removeFirst() }
        if line.isEmpty && !overflow { finishEvent(); return }
        guard !eventOverflow else { return }
        if line.hasPrefix("event:") { eventType = String(line.dropFirst(6)).trimmed; return }
        guard line.hasPrefix("data:") else { return }
        var data = String(line.dropFirst(5)); if data.hasPrefix(" ") { data.removeFirst() }
        if !eventData.isEmpty { eventData.append(10) }; eventData.append(contentsOf: data.utf8)
    }
    private mutating func finishEvent() {
        if eventType == "error" || eventType == "response.failed" { hasAPIError = true }
        if !eventOverflow, let json = (try? JSONSerialization.jsonObject(with: eventData)) as? [String: Any] { absorb(json) }
        eventData.removeAll(keepingCapacity: eventData.count <= 65536); eventOverflow = false; eventType = ""
    }
    mutating func finish() {
        if mode == .json || mode == .unknown {
            if !overflow, let json = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] { absorb(json) }
        } else if mode == .sse { if !pendingLine.isEmpty || overflow { consumeLine() }; finishEvent() }
    }
    private mutating func absorb(_ json: [String: Any]) {
        for container in [json, json["response"] as? [String: Any], json["message"] as? [String: Any]].compactMap({ $0 }) {
            if APIClient.hasAPIError(container) || ["error", "response.failed"].contains(container["type"] as? String ?? "") { hasAPIError = true }
            guard let usage = container["usage"] as? [String: Any] ?? container["usageMetadata"] as? [String: Any] else { continue }
            func count(_ names: [String]) -> Int? {
                for name in names {
                    if let number = usage[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue { return number.intValue }
                }; return nil
            }
            if let value = count(["prompt_tokens", "input_tokens", "promptTokenCount"]) { input = value }
            if let value = count(["completion_tokens", "output_tokens", "candidatesTokenCount"]) {
                let thinking = count(["thoughtsTokenCount"]) ?? 0; output = value <= Int.max - thinking ? value + thinking : value
            }
            if let value = count(["total_tokens", "totalTokenCount"]) { total = value }
            else if let input, let output, input <= Int.max - output { total = input + output }
        }
    }
}

// Local evidence preserves original values. Bound storage without masking fields.
enum RecordedContent {
    static let bodyLimit = 131_072
    static let historyBodyLimit = 2 * 1024 * 1024
    static func historyBody(_ data: Data) -> String {
        var limited = Data(data.prefix(historyBodyLimit))
        // Preserve raw JSON/SSE. Formatting belongs to the viewer, off the
        // forwarding queue; only trim an incomplete UTF-8 suffix here.
        for _ in 0..<3 {
            if String(data: limited, encoding: .utf8) != nil || limited.isEmpty { break }
            limited.removeLast()
        }
        return String(decoding: limited, as: UTF8.self)
    }
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
        let source = value as NSString
        var output = "", cursor = 0
        output.reserveCapacity(value.utf8.count)
        for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let fragment = source.substring(with: match.range)
            output += decode(fragment) ?? fragment
            cursor = NSMaxRange(match.range)
        }
        output += source.substring(from: cursor)
        return output
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
    static let entryLimit = 5000
    static let pageSize = 10
    private nonisolated static let indexLimit = 64 * 1024 * 1024
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
    private let io = DispatchQueue(label: "keydock.history.persistence", qos: .utility)
    private var saveTask: Task<Void, Never>?
    private var loaded = false, dirty = false, writeFailed = false, needsCleanup = true
    private var revision = 0, completedRevision = -1, savingRevision: Int?
    private var entryIDs = Set<UUID>()
    private var pendingDetails: [UUID: ProxyLogEntry] = [:]
    private(set) var pendingDetailBytes = 0
    private let pendingDetailLimit: Int
    private var pendingDeletes = Set<UUID>()
#if KEYDOCK_CHECKS
    var pendingDeletionCount: Int { pendingDeletes.count }
#endif
    private var credentialIDs: Set<UUID>?
    private var clearedBefore: [UUID: Date] = [:]
    var isReadable: Bool { loaded }
    var fileURL: URL { directory.appendingPathComponent("history.kdv") }
    var detailDirectory: URL { directory.appendingPathComponent("history-bodies", isDirectory: true) }
    init(directory: URL, pendingDetailLimit: Int = 64 * 1024 * 1024, keyProvider: @escaping () throws -> SymmetricKey) {
        self.directory = directory; self.keyProvider = keyProvider; self.pendingDetailLimit = max(0, pendingDetailLimit)
        retryLoading()
    }
    func retryLoading() {
        if loaded { writeFailed = false; flush(); return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { loaded = true; error = nil; return }
        do {
            let bytes = try Data(contentsOf: fileURL)
            guard bytes.count <= Self.indexLimit else { throw KeyDockError.message("调用记录索引过大。") }
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyProvider())
            let payload = try JSONDecoder().decode(Payload.self, from: clear)
            guard Set(payload.entries.map(\.id)).count == payload.entries.count else { throw KeyDockError.message("调用记录包含重复编号。") }
            var restored = Array(payload.entries.prefix(Self.entryLimit))
            var restoredTotals = payload.totals ?? [:]
            if payload.totals == nil { for entry in payload.entries { restoredTotals[entry.credentialID, default: ProxyTotals()].add(entry) } }
            // Migrate old inline details without losing them. The old encrypted
            // index remains intact until all new detail files and index commit.
            for index in restored.indices where restored[index].detailsStored != true && Self.hasDetails(restored[index]) {
                pendingDetails[restored[index].id] = restored[index]
                pendingDetailBytes += Self.detailSize(restored[index])
                restored[index] = Self.metadata(restored[index])
            }
            entries = restored; entryIDs = Set(restored.map(\.id)); captureBodies = payload.captureBodies; totals = restoredTotals
            boundPendingDetails()
            loaded = true; error = nil
            if !pendingDetails.isEmpty || payload.entries.count > Self.entryLimit { changed() }
            if let credentialIDs { synchronize(credentialIDs) }
        } catch { self.error = "调用记录暂时无法读取，原文件未改动。恢复文件或解锁钥匙串后可重试。" }
    }
    func detail(for entry: ProxyLogEntry) throws -> ProxyLogEntry {
        if let pending = pendingDetails[entry.id] { return pending }
        guard entry.detailsStored == true else { return entry }
        let key = try keyProvider(), file = detailDirectory.appendingPathComponent(entry.id.uuidString + ".kdv")
        return try io.sync { try Self.readDetail(file, key: key, metadata: entry) }
    }
    func loadDetail(for entry: ProxyLogEntry) async throws -> ProxyLogEntry {
        try Task.checkCancellation()
        if let pending = pendingDetails[entry.id] { return pending }
        guard entry.detailsStored == true else { return entry }
        let key = try keyProvider(), file = detailDirectory.appendingPathComponent(entry.id.uuidString + ".kdv")
        // Atomic detail files can be read independently of the write queue.
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try Self.readDetail(file, key: key, metadata: entry)
            try Task.checkCancellation(); return value
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private nonisolated static func readDetail(_ file: URL, key: SymmetricKey, metadata: ProxyLogEntry) throws -> ProxyLogEntry {
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 32 * 1024 * 1024 else { throw KeyDockError.message("调用正文文件过大。") }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key)
        let data = clear.starts(with: Data("KDH1".utf8)) ? try (NSData(data: clear.dropFirst(4)).decompressed(using: .lzfse) as Data) : clear
        guard data.count <= 32 * 1024 * 1024 else { throw KeyDockError.message("调用正文过大。") }
        let detail = try JSONDecoder().decode(ProxyLogEntry.self, from: data)
        guard detail.id == metadata.id, detail.credentialID == metadata.credentialID else { throw KeyDockError.message("调用正文与记录不匹配。") }
        return detail
    }
    private static func hasDetails(_ entry: ProxyLogEntry) -> Bool {
        entry.bodiesCaptured || !entry.requestHeaders.isEmpty || !entry.requestBody.isEmpty || !entry.responseHeaders.isEmpty || !entry.responseBody.isEmpty
    }
    private static func metadata(_ entry: ProxyLogEntry) -> ProxyLogEntry {
        var value = entry
        value.requestHeaders = ""; value.responseHeaders = ""; value.requestBody = ""; value.responseBody = ""; value.detailsStored = true
        return value
    }
    private static func detailSize(_ entry: ProxyLogEntry) -> Int {
        entry.requestHeaders.utf8.count + entry.responseHeaders.utf8.count + entry.requestBody.utf8.count + entry.responseBody.utf8.count
    }
    private func removePending(_ id: UUID) {
        if let entry = pendingDetails.removeValue(forKey: id) { pendingDetailBytes -= Self.detailSize(entry) }
    }
    private func retireDetail(_ id: UUID) {
        pendingDeletes.insert(id)
        if pendingDeletes.count > Self.entryLimit {
            // During a prolonged disk failure, retired IDs must also stay
            // bounded. The next successful commit reconciles the directory.
            pendingDeletes.removeAll(); needsCleanup = true
        }
    }
    private func boundPendingDetails() {
        guard pendingDetailBytes > pendingDetailLimit else { return }
        for index in entries.indices.reversed() where pendingDetailBytes > pendingDetailLimit {
            let id = entries[index].id
            guard pendingDetails[id] != nil else { continue }
            removePending(id); retireDetail(id)
            entries[index].detailsStored = false
            entries[index].detailsUnavailable = "正文待写入缓冲已满，本次仅保留调用摘要与统计。"
        }
    }
    func synchronize(_ ids: Set<UUID>) {
        let oldIDs = (credentialIDs ?? []).union(entries.map(\.credentialID)).union(totals.keys).union(captureBodies)
        credentialIDs = ids
        let removed = oldIDs.subtracting(ids), cutoff = Date()
        for id in removed { clearedBefore[id] = cutoff }
        guard loaded else { return }
        let deleted = entries.filter { !ids.contains($0.credentialID) }
        let retainedTotals = totals.filter { ids.contains($0.key) }, retainedCapture = captureBodies.intersection(ids)
        guard !deleted.isEmpty || retainedTotals.count != totals.count || retainedCapture != captureBodies else { return }
        for entry in deleted { discard(entry.id) }
        entries.removeAll { !ids.contains($0.credentialID) }; totals = retainedTotals; captureBodies = retainedCapture
        changed()
    }
    private func discard(_ id: UUID) { entryIDs.remove(id); removePending(id); retireDetail(id) }
    func append(_ entry: ProxyLogEntry) {
        guard loaded, credentialIDs?.contains(entry.credentialID) != false, !entryIDs.contains(entry.id),
              clearedBefore[entry.credentialID].map({ entry.startedAt > $0 }) ?? true else { return }
        totals[entry.credentialID, default: ProxyTotals()].add(entry)
        if Self.hasDetails(entry) { pendingDetails[entry.id] = entry; pendingDetailBytes += Self.detailSize(entry) }
        entries.insert(Self.hasDetails(entry) ? Self.metadata(entry) : entry, at: 0); entryIDs.insert(entry.id)
        if entries.count > Self.entryLimit { for entry in entries.suffix(entries.count - Self.entryLimit) { discard(entry.id) }; entries.removeLast(entries.count - Self.entryLimit) }
        boundPendingDetails()
        changed()
    }
    func setCapture(_ value: Bool, for id: UUID) {
        guard loaded, credentialIDs?.contains(id) != false else { return }
        if value { captureBodies.insert(id) } else { captureBodies.remove(id) }
        changed()
    }
    func clear(_ id: UUID) {
        guard loaded else { return }
        clearedBefore[id] = Date()
        for entry in entries where entry.credentialID == id { discard(entry.id) }
        entries.removeAll { $0.credentialID == id }; totals.removeValue(forKey: id)
        changed()
    }
    private func changed() { dirty = true; revision += 1; saveSoon() }
    private func saveSoon() {
        guard saveTask == nil, !writeFailed, savingRevision == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil; self.saveInBackground()
        }
    }
    private func saveInBackground() {
        guard loaded && dirty && !writeFailed, savingRevision == nil else { return }
        do {
            let key = try keyProvider(), payload = Payload(entries: entries, captureBodies: captureBodies, totals: totals)
            let details = pendingDetails, deletes = pendingDeletes, ticket = revision, cleanup = needsCleanup, directory = directory
            savingRevision = ticket
            io.async { [weak self] in
                let result = Result { try Self.persist(payload, details: details, deletes: deletes, directory: directory, key: key, cleanup: cleanup) }
                Task { @MainActor [weak self] in self?.completed(result, ticket: ticket, details: Set(details.keys), deletes: deletes) }
            }
        } catch { writeFailed = true; self.error = "调用记录保存失败，可解锁钥匙串或恢复磁盘权限后重试。" }
    }
    private func completed(_ result: Result<Void, Error>, ticket: Int, details: Set<UUID>, deletes: Set<UUID>) {
        if savingRevision == ticket { savingRevision = nil }
        guard ticket >= completedRevision else { return }
        completedRevision = ticket
        switch result {
        case .success:
            if revision == ticket { needsCleanup = false }
            for id in details { removePending(id) }; pendingDeletes.subtract(deletes)
            dirty = revision != ticket; error = nil
            if dirty { saveSoon() }
        case .failure: writeFailed = true; needsCleanup = true; error = "调用记录保存失败，密钥保险库未受影响。解锁钥匙串或恢复磁盘权限后可重试。"
        }
    }
    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard loaded && dirty && !writeFailed else { return }
        let ticket = revision, details = pendingDetails, deletes = pendingDeletes
        let result = Result { () throws -> Void in
            let key = try keyProvider(), payload = Payload(entries: entries, captureBodies: captureBodies, totals: totals), directory = directory, cleanup = needsCleanup
            try io.sync { try Self.persist(payload, details: details, deletes: deletes, directory: directory, key: key, cleanup: cleanup) }
        }
        savingRevision = nil
        completed(result, ticket: ticket, details: Set(details.keys), deletes: deletes)
    }
    private nonisolated static func persist(_ payload: Payload, details: [UUID: ProxyLogEntry], deletes: Set<UUID>, directory: URL, key: SymmetricKey, cleanup: Bool) throws {
        let manager = FileManager.default, bodies = directory.appendingPathComponent("history-bodies", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !details.isEmpty { try manager.createDirectory(at: bodies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        for (id, entry) in details {
            let raw = try JSONEncoder().encode(entry)
            let compressed = try NSData(data: raw).compressed(using: .lzfse) as Data
            let sealed = try AES.GCM.seal(Data("KDH1".utf8) + compressed, using: key).combined!
            let file = bodies.appendingPathComponent(id.uuidString + ".kdv")
            try sealed.write(to: file, options: .atomic); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let raw = try JSONEncoder().encode(payload)
        guard raw.count < indexLimit - 1024 else { throw KeyDockError.message("调用记录索引过大。") }
        let bytes = try AES.GCM.seal(raw, using: key).combined!, file = directory.appendingPathComponent("history.kdv")
        try bytes.write(to: file, options: .atomic); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        for id in deletes { try? manager.removeItem(at: bodies.appendingPathComponent(id.uuidString + ".kdv")) }
        if cleanup, let files = try? manager.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil) {
            let keep = Set(payload.entries.filter { $0.detailsStored == true }.map { $0.id.uuidString + ".kdv" })
            for file in files where file.pathExtension == "kdv" && !keep.contains(file.lastPathComponent) { try? manager.removeItem(at: file) }
        }
    }
}
