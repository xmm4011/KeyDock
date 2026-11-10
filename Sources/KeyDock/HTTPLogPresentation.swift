import Foundation
import Combine

struct HTTPLogDisplayPolicy: Hashable, Sendable {
    var fullContent: Bool
    var secrets: [String]
    var aliases = Set<String>()
    func text(_ value: String, extra: [String]) -> String {
        fullContent ? value : LogRedaction.text(value, secret: "", otherSecrets: (secrets + extra).filter { !aliases.contains($0) })
    }
    func headers(_ value: String, extra: [String]) -> String {
        guard !fullContent else { return value }
        return value.components(separatedBy: "\n").map { line in
            let name = String(line.split(separator: ":", maxSplits: 1).first ?? "").trimmed
            return LogRedaction.isSensitiveHeader(name) ? name + ": [已隐藏]" : text(line, extra: extra)
        }.joined(separator: "\n")
    }
}

struct HTTPLogVariant: Hashable, Sendable {
    var response: Bool
    var pretty: Bool
}

// Immutable documents cross to the UI once. Repaints and tab switches never
// reformat, redact, compare or replace multi-megabyte strings on the main actor.
@MainActor final class HTTPLogPresentation: ObservableObject {
    @Published private(set) var detail: ProxyLogEntry?
    @Published private(set) var documents: [HTTPLogVariant: HTTPTextDocument] = [:]
    @Published private(set) var headers: [Bool: String] = [:]
    @Published private(set) var requestLine = ""
    @Published private(set) var failureMessage: String?
    @Published private(set) var error: String?
    @Published private(set) var policy: HTTPLogDisplayPolicy?
    private var generation = UUID()
    private var worker: Task<HTTPTextDocument, Error>?
    private(set) var preparationCount = 0
    var preferred = HTTPLogVariant(response: false, pretty: true)

    func load(_ metadata: ProxyLogEntry, history: ProxyHistory, policy: HTTPLogDisplayPolicy) async {
        let ticket = UUID(); generation = ticket; worker?.cancel()
        documents = [:]; headers = [:]; requestLine = ""; failureMessage = nil; error = nil; self.policy = policy; preparationCount = 0
        do {
            let entry: ProxyLogEntry
            if let detail { entry = detail } else { entry = try await history.loadDetail(for: metadata) }
            try Task.checkCancellation(); guard generation == ticket else { return }
            detail = entry
            var credential = Credential(); credential.extraHeaders = entry.requestHeaders + "\n" + entry.responseHeaders
            let extra = credential.secretValues
            headers = [false: policy.headers(entry.requestHeaders, extra: extra), true: policy.headers(entry.responseHeaders, extra: extra)]
            requestLine = policy.text(entry.method + " " + entry.requestURL, extra: extra)
            failureMessage = entry.error.map { policy.text($0, extra: extra) }
            guard entry.bodiesCaptured, entry.detailsUnavailable == nil else { return }
            // Prepare the initial view first, then warm the other three choices.
            // A single worker bounds CPU and memory; cancellation stops old work.
            var pending = [HTTPLogVariant(response: false, pretty: true), .init(response: false, pretty: false), .init(response: true, pretty: true), .init(response: true, pretty: false)]
            while !pending.isEmpty {
                let variant = pending.contains(preferred) ? preferred : pending[0]
                pending.removeAll { $0 == variant }
                let raw = variant.response ? entry.responseBody : entry.requestBody
                let task = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let formatted = variant.pretty ? HTTPBodyFormatting.prepared(raw) : .init(text: raw, limited: false)
                    let value = policy.text(formatted.text, extra: extra)
                    try Task.checkCancellation()
                    return try HTTPTextDocument(text: value, notice: formatted.limited ? "格式化展开后内容过大，已显示原文。" : nil)
                }
                worker = task
                let document = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation(); guard generation == ticket else { return }
                preparationCount += 1; documents[variant] = document
            }
            worker = nil
        } catch is CancellationError { }
        catch { if generation == ticket { self.error = "文件缺失、损坏或钥匙串暂不可用；调用状态与统计仍保留。" } }
    }
    func cancel() { generation = UUID(); worker?.cancel(); worker = nil }
}
