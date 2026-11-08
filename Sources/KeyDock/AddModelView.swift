import SwiftUI

struct AddModelView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    let record: Credential
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "添加模型", subtitle: "已有模型会保留，添加后可在下拉框中切换。")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("模型 ID", text: $name, prompt: Text("填写服务提供的完整模型 ID"))
                    .textFieldStyle(.roundedBorder).controlSize(.large).focused($focused).onSubmit(add)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).lineSpacing(4).textSelection(.enabled) }
            }.padding(24)
            Divider()
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("添加", action: add).buttonStyle(.borderedProminent).disabled(name.trimmed.isEmpty).keyboardShortcut(.defaultAction) }.padding(20)
        }.frame(width: 460).onAppear { focused = true }.onChange(of: name) { _, _ in error = nil }
    }
    private func add() {
        guard !name.trimmed.isEmpty else { return }
        if store.addModel(name, to: record) { dismiss() }
        else { error = store.error; store.error = nil }
    }
}
