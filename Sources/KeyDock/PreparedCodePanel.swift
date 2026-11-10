import SwiftUI

enum CodeContent: Equatable, Sendable {
    case text(String), source(String), request(CheckedRequest), response(CheckedResponse, CheckedRequest?)
    func rendered(_ policy: HTTPLogDisplayPolicy) -> String {
        switch self {
        case .text(let text): return policy.text(text, extra: [])
        case .source(let text): return policy.fullContent ? text : policy.text(RedactedImport(text).text, extra: [])
        case .request(let request):
            var credential = Credential(); credential.extraHeaders = RecordedContent.headers(request.headers)
            return request.curl(redacting: policy.fullContent ? nil : policy.secrets + credential.secretValues)
        case .response(let response, let request):
            var credential = Credential(); credential.extraHeaders = response.headers + "\n" + RecordedContent.headers(request?.headers ?? [:])
            let extra = credential.secretValues, headers = policy.headers(response.headers, extra: extra)
            return (headers.isEmpty ? "" : headers + "\n\n") + (response.body.isEmpty ? "（空正文）" : policy.text(response.body, extra: extra))
        }
    }
    var large: Bool {
        switch self {
        case .text(let value), .source(let value): return value.utf8.count > 16384
        case .request(let value): return (value.body?.utf8.count ?? 0) + value.headers.values.reduce(0) { $0 + $1.utf8.count } > 16384
        case .response(let value, _): return value.body.utf8.count + value.headers.utf8.count > 16384
        }
    }
}

struct CodeScope: Equatable { let contents: [CodeContent]; let policy: HTTPLogDisplayPolicy }

@MainActor final class CodePresentation: ObservableObject {
    @Published private(set) var scope: CodeScope?
    @Published private(set) var documents: [HTTPLogVariant: HTTPTextDocument] = [:]
    private var generation = UUID()
    private(set) var preparations = 0
    func prepare(_ next: CodeScope) async {
        guard next != scope || documents.count != next.contents.count else { return }
        let ticket = UUID(); generation = ticket; scope = next; documents = [:]; preparations = 0
        for (index, content) in next.contents.enumerated() {
            let task = Task.detached(priority: .userInitiated) { try HTTPTextDocument(text: content.rendered(next.policy)) }
            do {
                let document = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation(); guard generation == ticket else { return }
                preparations += 1; documents[.init(response: index == 1, pretty: false)] = document
            } catch { return }
        }
    }
}

struct PreparedCodePanel: View {
    var contents: [CodeContent]
    var response = false
    var policy: HTTPLogDisplayPolicy
    var onCopy: ((String) -> Void)? = nil
    @StateObject private var model = CodePresentation()
    private var scope: CodeScope { .init(contents: contents, policy: policy) }
    private var selected: HTTPLogVariant { .init(response: response, pretty: false) }
    var body: some View {
        HTTPBodyViewport(documents: model.scope == scope ? model.documents : [:], selected: selected, onCopy: { onCopy?($0) })
            .frame(height: 300).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.border))
            .overlay { if model.scope != scope || model.documents[selected] == nil { ProgressView("正在准备内容…") } }
            .task(id: scope) { await model.prepare(scope) }
    }
}
