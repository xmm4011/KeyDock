import Foundation
import Combine
import AppKit

struct AgentActivityEntry: Codable, Identifiable, Equatable {
    var id: String
    var time = Date()
    var title: String
    var detail: String
    var state: String
    var summary: String?
    var diagnosticOnly: Bool?
}
struct AgentRunRecord: Codable {
    var version = 1
    var id = UUID()
    var startedAt = Date()
    var updatedAt = Date()
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    var model = ""
    var endpoint = ""
    var protocolName = ""
    var input = ""
    var status = "ready"
    var entries: [AgentActivityEntry] = []
    var discardedEntries: Int?
}

@MainActor final class AgentActivity: ObservableObject {
    static var defaultDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KeyDock/Agent", isDirectory: true) }
    @Published private(set) var record = AgentRunRecord()
    @Published private(set) var saveError: String?
    var directory: URL?
    private var secrets: [String] = []
    private var visibleEntries: [String: AgentActivityEntry] = [:]
    private var inputForDisplay = ""
    private var saveTask: Task<Void, Never>?
    private let writer: AgentLogWriter
    private var ticket = 0, completedTicket = 0
    private var terminateObserver: NSObjectProtocol?
    init(writer: AgentLogWriter = AgentLogWriter()) {
        self.writer = writer
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
    }
    deinit { if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) } }
    var active: Bool { ["preparing", "running", "waiting", "stopping"].contains(record.status) }
    var entries: [AgentActivityEntry] { record.entries }
    var keyEntries: [AgentActivityEntry] { record.entries.filter { $0.diagnosticOnly != true && $0.summary != nil } }
    var elapsed: TimeInterval { (active ? Date() : record.updatedAt).timeIntervalSince(record.startedAt) }
    func prepareForRun() {
        saveNow(); saveTask?.cancel(); record = AgentRunRecord()
        visibleEntries = [:]; inputForDisplay = ""; secrets = []
        saveError = nil
    }
    func beginLocal(raw: String) {
        let redacted = RedactedImport(raw)
        secrets = Array(redacted.keys.values); inputForDisplay = raw
        record = AgentRunRecord(model: "本地规则", protocolName: "本地识别", input: safe(redacted.text), status: "running")
        note("读取资料", state: "completed", summary: "按本地规则整理")
    }
    func begin(raw: String, service: Credential, model: String) {
        saveNow(); saveTask?.cancel()
        let redacted = RedactedImport(raw)
        secrets = Array(redacted.keys.values) + service.secretValues
        visibleEntries = [:]
        inputForDisplay = raw
        record = AgentRunRecord(model: safe(model), endpoint: safe(service.baseURL), protocolName: service.inferenceKind.protocolTitle, input: safe(redacted.text), status: "preparing")
        note("开始整理", detail: "模型：\(model)\n协议：\(service.inferenceKind.protocolTitle)\n服务：\(safe(service.baseURL))")
    }
    func addSecrets(_ values: [String]) {
        let combined = Set(secrets + values).filter { !$0.isEmpty }
        guard Set(secrets) != Set(combined) else { return }
        secrets = Array(combined)
        record.input = safe(record.input)
        for i in record.entries.indices {
            record.entries[i].title = safe(record.entries[i].title); record.entries[i].detail = safe(record.entries[i].detail)
            record.entries[i].summary = record.entries[i].summary.map(safe)
        }
    }
    func safe(_ text: String) -> String {
        var value = LogRedaction.text(text, secret: "", otherSecrets: secrets)
        value = withoutAttachments(value)
        // Literal prefixes keep diagnostic streaming linear even for long output.
        let patterns = [#"\b(?:sk-[A-Za-z0-9_-]{8,}|AIza[A-Za-z0-9_-]{15,})\b"#, #"(?i)\b[0-9a-f]{32,}\b"#]
        for pattern in patterns {
            if let expression = RegexCache.expression(pattern) { value = expression.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: value.utf16.count), withTemplate: "[已隐藏]") }
        }
        let pattern = #"(?i)(\b(?:api[_-]?key|API\h+Key|authorization|access[_-]?token|password|secret|cookie)\b[\h\"']*[:=：]\h*[\"']?(?:(?:Bearer|Basic)\h+)?)([^\s\"',;，；}{\[]+)"#
        if let regex = RegexCache.expression(pattern) {
            let original = value as NSString
            var output = "", cursor = 0; output.reserveCapacity(value.utf8.count)
            for match in regex.matches(in: value, range: NSRange(location: 0, length: original.length)) {
                let token = original.substring(with: match.range(at: 2))
                guard !token.hasPrefix("KEYDOCK_SECRET_"), !token.hasPrefix("keydock-local-") else { continue }
                let range = match.range(at: 2)
                output += original.substring(with: NSRange(location: cursor, length: range.location - cursor)) + "[已隐藏]"
                cursor = NSMaxRange(range)
            }
            if cursor > 0 { output += original.substring(from: cursor); value = output }
        }
        return value
    }
    private func withoutAttachments(_ text: String) -> String {
        guard let expression = RegexCache.expression(#"(?:data:image/[A-Za-z0-9.+-]+;base64,)?[A-Za-z0-9+/]{512,}={0,2}"#) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "[附件内容未记录]")
    }
    func phase(_ state: String) { guard active else { return }; record.status = state; changed() }
    func note(_ title: String, detail: String = "", state: String = "info", summary: String? = nil, diagnosticOnly: Bool = false) {
        update(id: UUID().uuidString, title: title, detail: detail, state: state, summary: summary, diagnosticOnly: diagnosticOnly)
    }
    func update(id: String, title: String, detail: String, state: String, summary: String? = nil, diagnosticOnly: Bool = false) {
        guard active else { return }
        let cleaned = safe(detail)
        let bounded = cleaned.count > 12_000 ? "[内容较长，保留末尾 12,000 字]\n" + cleaned.suffix(12_000) : cleaned
        let entry = AgentActivityEntry(id: id, title: String(safe(title).prefix(200)), detail: bounded, state: state, summary: summary.map { String(safe($0).prefix(1000)) }, diagnosticOnly: diagnosticOnly)
        let rawDetail = withoutAttachments(detail)
        let visibleDetail = rawDetail.count > 12_000 ? "[内容较长，保留末尾 12,000 字]\n" + rawDetail.suffix(12_000) : rawDetail
        var visible = AgentActivityEntry(id: id, title: String(title.prefix(200)), detail: visibleDetail, state: state, summary: summary.map { String(withoutAttachments($0).prefix(1000)) }, diagnosticOnly: diagnosticOnly)
        visible.time = visibleEntries[id]?.time ?? entry.time
        visibleEntries[id] = visible
        if let index = record.entries.firstIndex(where: { $0.id == id }) {
            var value = entry; value.time = record.entries[index].time; record.entries[index] = value
        } else { record.entries.append(entry) }
        while record.entries.count > 250 || record.entries.reduce(0, { $0 + $1.detail.utf8.count + $1.title.utf8.count }) > 524_288 {
            record.entries.removeFirst()
            record.discardedEntries = (record.discardedEntries ?? 0) + 1
        }
        let retained = Set(record.entries.map(\.id))
        visibleEntries = visibleEntries.filter { retained.contains($0.key) }
        changed()
    }
    func finish(_ state: String, detail: String) {
        guard active else { return }
        note(state == "completed" ? "整理结束" : (state == "stopped" ? "已停止" : "整理未完成"), detail: detail, state: state)
        for index in record.entries.indices where record.entries[index].state == "running" {
            record.entries[index].state = state == "stopped" ? "stopped" : "interrupted"
            visibleEntries[record.entries[index].id]?.state = record.entries[index].state
        }
        record.status = state; changed(); saveTask?.cancel(); saveNow()
    }
    private func changed() {
        record.updatedAt = Date(); saveTask?.cancel()
        saveTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { self?.saveTask = nil; self?.saveNow() } }
    }
    private func saveNow() {
        guard let directory, !record.entries.isEmpty else { return }
        ticket += 1; let current = ticket, id = record.id
        writer.submit(.init(record: record, directory: directory, ticket: current, completion: { [weak self] result in Task { @MainActor in self?.completed(result, ticket: current, id: id) } }))
    }
    private func completed(_ result: Result<Void, Error>, ticket: Int, id: UUID) {
        guard id == record.id, ticket == self.ticket, ticket >= completedTicket else { return }; completedTicket = ticket
        switch result { case .success: saveError = nil; case .failure(let error): saveError = "运行日志未能保存：" + safe(error.localizedDescription) }
    }
    func flush() {
        saveTask?.cancel(); saveTask = nil; saveNow()
        if let result = writer.flush(record.id) { completed(result, ticket: ticket, id: record.id) }
    }
    func waitForPersistence() async {
        let writer = writer, id = record.id, current = ticket
        if let result = await Task.detached(priority: .utility, operation: { writer.flush(id) }).value { completed(result, ticket: current, id: id) }
    }
    var text: String { displayText(showFullContent: false) }
    func displayEntry(_ entry: AgentActivityEntry, showFullContent: Bool) -> AgentActivityEntry { showFullContent ? (visibleEntries[entry.id] ?? entry) : entry }
    func diagnosticText(showFullContent: Bool) -> String {
        var header = "KeyDock \(record.appVersion) · 任务 \(record.id.uuidString)\n状态：\(record.status)\n开始：\(record.startedAt.formatted())\n模型：\(record.model)\n协议：\(record.protocolName)\n服务：\(record.endpoint)"
        if let discarded = record.discardedEntries, discarded > 0 { header += "\n[较早的 \(discarded) 条记录因日志容量限制已移除]" }
        header += "\n诊断不记录图片和模型内部推理；后续模型请求只记录最新消息，省略的历史会明确标注。\n\n输入资料：\n" + (showFullContent ? inputForDisplay : record.input)
        return header + "\n\n" + displayText(showFullContent: showFullContent)
    }
    func displayText(showFullContent: Bool, detailed: Bool = true) -> String {
        record.entries.filter { detailed || $0.diagnosticOnly != true }.map { entry in
            let entry = displayEntry(entry, showFullContent: showFullContent)
            let time = entry.time.formatted(date: .omitted, time: .standard)
            let detail = detailed ? entry.detail : (entry.summary ?? String(entry.detail.prefix(1000)))
            return "[\(time)] \(entry.title) · \(entry.state)" + (detail.isEmpty ? "" : "\n" + detail)
        }.joined(separator: "\n\n")
    }
}
