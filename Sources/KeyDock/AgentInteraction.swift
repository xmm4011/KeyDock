import SwiftUI
import Combine

struct AgentQuestion: Equatable {
    var question: String
    var reason = ""
    var items: [String] = []
    var example = ""
    var canContinueWithoutReply = false
    var canReview = false
}

struct AgentChatMessage: Identifiable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var images: [ImportImage] = []
}

enum AgentTaskState: Equatable {
    case idle, running, waiting, stopping, completed, failed, stopped
    var isBusy: Bool { self == .running || self == .waiting || self == .stopping }
}

@MainActor final class AgentInteraction: ObservableObject {
    let activity: AgentActivity
    init(activity: AgentActivity? = nil) { self.activity = activity ?? AgentActivity() }
    @Published private(set) var taskState: AgentTaskState = .idle
    private(set) var runID = UUID()
    var isBusy: Bool { taskState.isBusy }
    var isStopping: Bool { taskState == .stopping }
    @Published var messages: [AgentChatMessage] = []
    var supplement: (@MainActor (ImportPaste) async throws -> Void)?
    func postUser(_ paste: ImportPaste) { messages.append(AgentChatMessage(isUser: true, text: paste.text, images: paste.images)) }
    func postReply(_ text: String, runID: UUID? = nil) {
        guard runID == nil || runID == self.runID else { return }
        guard taskState != .stopping && taskState != .stopped else { return }
        let value = text.trimmed
        guard !value.isEmpty, messages.last?.isUser != false || messages.last?.text != value else { return }
        messages.append(AgentChatMessage(isUser: false, text: value))
    }
    func postCompletion(summary: String, reply: String, runID: UUID? = nil) {
        guard runID == nil || runID == self.runID else { return }
        guard taskState != .stopping && taskState != .stopped else { return }
        let value = summary.trimmed.isEmpty ? reply : summary
        if let last = messages.indices.last, !messages[last].isUser, messages[last].text == reply {
            messages[last].text = value
        } else { postReply(value) }
    }
    @Published var question: AgentQuestion?
    @Published var lastReply: AgentQuestion?
    @Published var failure: AgentQuestion?
    @Published var recovery: AgentImportResult?
    @Published var document = ImportDocument()
    @Published var error: String?
    private var pending: CheckedContinuation<ImportPaste?, Error>?
    private var validate: (@MainActor (ImportPaste) throws -> Void)?
    var isWaiting: Bool { pending != nil }
    var displayedReply: AgentQuestion? { question ?? failure }
    @discardableResult func begin() -> UUID {
        guard !isBusy else { return runID }
        activity.prepareForRun()
        runID = UUID(); taskState = .running; failure = nil; error = nil
        return runID
    }
    @discardableResult func requestStop() -> Bool {
        guard taskState == .running || taskState == .waiting else { return false }
        taskState = .stopping; error = nil; supplement = nil
        activity.phase("stopping"); cancel()
        return true
    }
    func finishRun(_ id: UUID, cancelled: Bool = false) {
        guard id == runID else { return }
        if cancelled || taskState == .stopping {
            guard taskState != .completed && taskState != .failed && taskState != .stopped else { return }
            taskState = .stopped
            activity.finish("stopped", detail: "已停止，输入资料和已有结果已保留。")
        } else if taskState == .running || taskState == .waiting {
            taskState = .completed
            activity.finish("completed", detail: "整理完成，可以确认保存。")
        }
    }
    func fail(_ message: String, recovery: AgentImportResult? = nil, runID: UUID? = nil) {
        guard runID == nil || runID == self.runID else { return }
        guard taskState != .stopping && taskState != .stopped else { return }
        taskState = .failed
        let previous = lastReply?.question ?? ""
        failure = AgentQuestion(question: previous.isEmpty || message.contains(previous) ? message : previous + "\n\n执行中断：" + message)
        if let recovery { self.recovery = recovery }
        if lastReply == nil { lastReply = failure }
        postReply(message)
        activity.finish("failed", detail: message)
    }

    func ask(_ question: AgentQuestion, validate: @escaping @MainActor (ImportPaste) throws -> Void) async throws -> ImportPaste? {
        try Task.checkCancellation()
        guard pending == nil else { throw KeyDockError.message("已有待回答的问题。") }
        self.question = question; lastReply = question; self.validate = validate; error = nil
        postReply(question.question + (question.reason.isEmpty ? "" : "\n" + question.reason) + question.items.map { "\n• " + $0 }.joined())
        activity.phase("waiting")
        taskState = .waiting
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending = $0 }
            } onCancel: { Task { @MainActor in self.cancel() } }
        } catch {
            if Task.isCancelled && taskState == .waiting { finishRun(runID, cancelled: true) }
            throw error
        }
    }
    @discardableResult func submit() -> Bool {
        var paste = document.paste
        if paste.text.trimmed.isEmpty && paste.images.isEmpty {
            guard question?.canContinueWithoutReply == true else { error = "粘贴文字或图片后继续。"; return false }
            paste.text = "请根据现有资料继续尝试；如仍无法完成，请说明实际原因。"
        }
        do { try validate?(paste) } catch { self.error = error.localizedDescription; return false }
        let continuation = pending; pending = nil; question = nil; validate = nil
        document = ImportDocument(); error = nil; continuation?.resume(returning: paste)
        taskState = .running; activity.phase("running"); return true
    }
    func review() {
        guard question?.canReview == true else { return }
        let continuation = pending; pending = nil; question = nil; validate = nil
        continuation?.resume(returning: nil)
    }
    func cancel(error: Error = CancellationError()) {
        let continuation = pending; pending = nil; question = nil; validate = nil
        continuation?.resume(throwing: error)
    }
}

struct AgentQuestionView: View {
    @ObservedObject var interaction: AgentInteraction
    @State private var preview: ImportImage?
    @State private var replyHeight: CGFloat = 80
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question = interaction.displayedReply {
                Label(interaction.failure == nil ? "Agent 回复" : "整理未完成", systemImage: "bubble.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question.question).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                        if !question.reason.isEmpty { Text(question.reason).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        ForEach(Array(question.items.enumerated()), id: \.offset) { _, item in Text("• " + item).font(.system(size: 12)) }
                        if !question.example.isEmpty { Text("例如：" + question.example).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                    }.lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { geometry in
                            Color.clear.onAppear { replyHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in replyHeight = height }
                        })
                }.frame(height: min(160, max(28, replyHeight)))
                ZStack(alignment: .topLeading) {
                    ImportTextEditor(document: $interaction.document, onError: { interaction.error = $0 }, onPreview: { preview = $0 })
                    if interaction.document.content.length == 0 {
                        Text(interaction.failure == nil ? "回复 Agent，或粘贴 curl、文档正文、截图…" : "可以补充或修改说明，也可以直接重试…").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(16).allowsHitTesting(false)
                    }
                }.background(Palette.canvas, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.border))
                Text(interaction.error ?? (interaction.failure == nil ? "资料和进度已保留。可以回复、纠正或补充，让 Agent 接着做。" : "输入与当前结果已保留。可以调整资料或 AI 设置后重试。"))
                    .font(.system(size: 11)).foregroundStyle(interaction.error == nil ? Palette.muted : .red)
            }
        }.padding(24).sheet(item: $preview) { ImportImagePreview(image: $0) }
    }
}
