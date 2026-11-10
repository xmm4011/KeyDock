import Foundation

struct CredentialListProjection {
    var records: [Credential]
    var hints: [UUID: String]
}

@MainActor final class CredentialRenderCache {
    private struct Query: Hashable { let shelf: Shelf; let text: String }
    private struct Models: Sendable {
        let current: String, manual: [String], available: [String], choices: [String]
        init(_ record: Credential) { current = record.model; manual = record.manualModels ?? []; available = record.availableModels; choices = record.modelOptions }
        func matches(_ record: Credential) -> Bool { current == record.model && manual == (record.manualModels ?? []) && available == record.availableModels }
    }
    private var queries: [Query: CredentialListProjection] = [:]
    private var modelCache: [UUID: Models] = [:]
    private var warming: Task<Void, Never>?
    private var generation = UUID()
    private var policy: HTTPLogDisplayPolicy?
    private var secrets: [String]?
    private(set) var queryBuilds = 0, modelBuilds = 0, policyBuilds = 0
    deinit { warming?.cancel() }
    func reset(_ records: [Credential]) {
        generation = UUID(); warming?.cancel(); queries.removeAll(); policy = nil; secrets = nil
        let ids = Set(records.map(\.id)); modelCache = modelCache.filter { ids.contains($0.key) }
        let missing = records.filter { modelCache[$0.id]?.matches($0) != true }
        guard !missing.isEmpty else { return }
        let ticket = generation
        warming = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { () throws -> [UUID: Models] in
                var result: [UUID: Models] = [:]
                for record in missing { try Task.checkCancellation(); result[record.id] = Models(record) }; return result
            }
            do {
                let values = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation(); guard let self, generation == ticket else { return }
                modelCache.merge(values) { _, new in new }
            } catch { }
        }
    }
    func allSecrets(_ records: [Credential]) -> [String] {
        if let secrets { return secrets }
        let value = Array(Set(records.flatMap(\.secretValues))).filter { !$0.isEmpty }.sorted(); secrets = value; return value
    }
    func displayPolicy(_ records: [Credential], full: Bool) -> HTTPLogDisplayPolicy {
        if let policy, policy.fullContent == full { return policy }
        policyBuilds += 1
        let aliases = Set(records.map(\.localKey)), value = HTTPLogDisplayPolicy(fullContent: full, secrets: allSecrets(records).filter { !aliases.contains($0) }, aliases: aliases)
        policy = value; return value
    }
    func models(_ record: Credential) -> [String] {
        if let value = modelCache[record.id], value.matches(record) { return value.choices }
        modelBuilds += 1; let value = Models(record); modelCache[record.id] = value; return value.choices
    }
    func list(_ records: [Credential], shelf: Shelf, query: String) -> CredentialListProjection {
        let key = Query(shelf: shelf, text: query.trimmed)
        if let value = queries[key] { return value }
        queryBuilds += 1
        let matched = records.compactMap { record -> (Credential, CredentialSearchMatch)? in
            let included = shelf == .archived ? record.archived : !record.archived && (shelf != .favorites || record.favorite)
            guard included, let match = record.searchMatch(for: key.text, modelChoices: models(record)) else { return nil }
            return (record, match)
        }.sorted {
            if $0.1.rank != $1.1.rank { return $0.1.rank < $1.1.rank }
            if $0.0.favorite != $1.0.favorite { return $0.0.favorite }
            if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        let value = CredentialListProjection(records: matched.map { $0.0 }, hints: Dictionary(uniqueKeysWithValues: matched.compactMap { pair in pair.1.detail.map { (pair.0.id, $0) } }))
        if queries.count >= 8 { queries.removeAll() }; queries[key] = value; return value
    }
}
