import SwiftUI

struct OrganizerSettingsView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State private var selectedID: UUID?
    @State private var model = ""
    @State private var adding = false
    @State private var error: String?
    var services: [Credential] { store.active.filter(\.canOrganize) }
    var service: Credential? { services.first { $0.id == selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "智能整理", subtitle: "选一个你信任的直连 API，设置一次，以后粘贴就能整理。")
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("使用哪个 Key", selection: $selectedID) { Text("仅用本地识别").tag(nil as UUID?); ForEach(services) { Text(store.displayText($0.title)).tag(Optional($0.id)) } }
                    Button("添加 Key…") { adding = true }
                }
                if let service {
                    ModelSelectionField(service: service, model: $model)
                    Label("直连 " + service.host, systemImage: "checkmark.shield").font(.system(size: 11)).foregroundStyle(Palette.teal)
                    Text("整理前会替换已识别的密钥。待发送文本可在导入时预览，调用会产生该服务的正常用量。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                } else {
                    Text("本地识别无需配置，也不联网。添加可信 API 后可处理更零散的文字。").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存设置") { save() }.buttonStyle(.borderedProminent).disabled(selectedID != nil && (service == nil || service.flatMap { store.modelIssue(model, for: $0) } != nil)).keyboardShortcut(.defaultAction) }.padding(20)
        }.frame(width: 620)
            .onAppear { selectedID = services.first { $0.id == store.data.organizerServiceID }?.id; updateModel() }
            .onChange(of: selectedID) { _, _ in updateModel() }
            .onChange(of: services.map(\.id)) { old, ids in
                if let added = ids.first(where: { !old.contains($0) }) { selectedID = added }
                else if let selectedID, !ids.contains(selectedID) { self.selectedID = nil; error = "所选 Key 已不可用，请重新选择整理服务。" }
            }
            .sheet(isPresented: $adding) { CredentialEditor(record: Credential()) }
            .alert("设置提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(error ?? "") }
    }
    func updateModel() { model = selectedID == store.data.organizerServiceID ? (store.data.organizerModel ?? service?.model ?? "") : (service?.model ?? "") }
    func save() {
        guard selectedID == nil || (service != nil && !model.trimmed.isEmpty) else { error = "请重新选择可用的 Key 并填写模型。"; return }
        if let service, let issue = store.modelIssue(model, for: service) { error = issue; return }
        if store.configureOrganizer(serviceID: selectedID, model: model) { store.showToast("已保存，以后会记住这个选择"); dismiss() }
        else { error = store.error; store.error = nil }
    }
}
