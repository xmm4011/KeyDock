import Foundation

// The writer owns queued snapshots independently of the UI's lifetime. Slow
// storage coalesces updates for a run; at most the retained 20 runs stay queued.
final class AgentLogWriter: @unchecked Sendable {
    struct Job { let record: AgentRunRecord; let directory: URL; let ticket: Int; let completion: (Result<Void, Error>) -> Void }
    private let queue = DispatchQueue(label: "keydock.agent.logs", qos: .utility)
    private let lock = NSLock()
    private var pending: [UUID: Job] = [:]
    private var running = false
    private var results: [UUID: Result<Void, Error>] = [:]
    private let write: (AgentRunRecord, URL) throws -> Void
    init(write: @escaping (AgentRunRecord, URL) throws -> Void = AgentLogWriter.persist) { self.write = write }
    func submit(_ job: Job) {
        lock.lock(); pending[job.record.id] = job
        if pending.count > 20, let oldest = pending.values.min(by: { $0.ticket < $1.ticket }) { pending.removeValue(forKey: oldest.record.id) }
        let start = !running; running = true; lock.unlock()
        if start { queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let job = pending.values.min(by: { $0.ticket < $1.ticket }) else { running = false; lock.unlock(); return }
            pending.removeValue(forKey: job.record.id); lock.unlock()
            let result = Result { try write(job.record, job.directory) }
            lock.lock(); if results.count >= 20 { results.removeAll() }; results[job.record.id] = result; lock.unlock()
            job.completion(result)
        }
    }
    func flush(_ id: UUID) -> Result<Void, Error>? { queue.sync {}; lock.lock(); defer { lock.unlock() }; return results[id] }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    static func persist(_ record: AgentRunRecord, _ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in files.dropFirst(20) where old != file { try manager.removeItem(at: old) }
    }
}
