import SwiftUI

// Request and response belong to the same observed verification result.
struct VerificationEvidenceView: View {
    @EnvironmentObject var store: VaultStore
    let result: CheckResult
    let request: CheckedRequest?
    @State var showingResponse = false
    private var contents: [CodeContent] {
        [request.map(CodeContent.request) ?? .text(result.endpoint.isEmpty ? "此记录未保存请求地址，重新检查后即可查看。" : (result.requestMethod ?? "GET") + " " + result.endpoint), result.response.map { .response($0, request) } ?? .text(result.httpStatus == nil ? "尚未收到服务响应。" : "历史记录未保存响应，重新验证后即可查看。")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let status = result.httpStatus { Text("HTTP \(status)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer(minLength: 0)
                Picker("验证内容", selection: $showingResponse) { Text("请求").tag(false); Text("响应").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                if showingResponse {
                    if let response = result.response { Button("复制响应") { store.copy(store.displayResponse(response, request: request), sensitive: true) }.controlSize(.small) }
                } else if let request {
                    Button("复制请求 curl") { store.copy(request.curl, sensitive: true) }.controlSize(.small)
                        .help("包含真实鉴权信息，45 秒后清空剪贴板")
                }
            }
            if contents.contains(where: \.large), (request != nil || result.response != nil) {
                PreparedCodePanel(contents: contents, response: showingResponse, policy: store.logDisplayPolicy, onCopy: { store.copy($0, sensitive: true) })
            } else if showingResponse {
                if let response = result.response {
                    CodePanel(text: store.displayResponse(response, request: request))
                } else {
                    Text(result.httpStatus == nil ? "尚未收到服务响应。" : "历史记录未保存响应，重新验证后即可查看。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            } else if let request {
                CodePanel(text: request.curl(redacting: store.showFullContent ? nil : store.rendering.allSecrets(store.credentials) + store.headerSecrets(RecordedContent.headers(request.headers))))
            } else if !result.endpoint.isEmpty {
                CodePanel(text: store.displayText((result.requestMethod ?? "GET") + " " + result.endpoint))
            } else { Text("此记录未保存请求地址，重新检查后即可查看。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            if showingResponse, result.response?.truncated == true { Text("响应较大，仅保留前 128 KB。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            if !showingResponse, request != nil, result.request == nil { Text("历史记录未保存完整请求，以下按当前配置重建。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
    }
}
