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

@MainActor final class AgentInteraction: ObservableObject {
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
    func begin() { failure = nil; error = nil }
    func fail(_ message: String, recovery: AgentImportResult? = nil) {
        let previous = lastReply?.question ?? ""
        failure = AgentQuestion(question: previous.isEmpty || message.contains(previous) ? message : previous + "\n\n执行中断：" + message)
        if let recovery { self.recovery = recovery }
        if lastReply == nil { lastReply = failure }
    }

    func ask(_ question: AgentQuestion, validate: @escaping @MainActor (ImportPaste) throws -> Void) async throws -> ImportPaste? {
        try Task.checkCancellation()
        guard pending == nil else { throw KeyDockError.message("已有待回答的问题。") }
        self.question = question; lastReply = question; self.validate = validate; error = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func submit() {
        var paste = document.paste
        if paste.text.trimmed.isEmpty && paste.images.isEmpty {
            guard question?.canContinueWithoutReply == true else { error = "粘贴文字或图片后继续。"; return }
            paste.text = "请根据现有资料继续尝试；如仍无法完成，请说明实际原因。"
        }
        do { try validate?(paste) } catch { self.error = error.localizedDescription; return }
        let continuation = pending; pending = nil; question = nil; validate = nil
        document = ImportDocument(); error = nil; continuation?.resume(returning: paste)
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
