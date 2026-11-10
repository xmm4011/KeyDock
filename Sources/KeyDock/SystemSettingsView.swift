import SwiftUI
import AppKit

struct SystemSettingsView: View {
    @EnvironmentObject var store: VaultStore
    @State private var organizer = false
    @State private var promptEditor = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("系统设置").font(.system(size: 21, weight: .semibold))
            SurfaceCard {
                Toggle("显示完整密钥与请求内容", isOn: Binding(get: { store.showFullContent }, set: { value in update { store.setShowFullContent(value) } }))
                Text("默认隐藏敏感信息。开启后，所有 Key 的详情、请求、响应和记录都显示完整内容。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                Divider()
                Toggle("为所有 Key 记录请求与响应", isOn: Binding(get: { store.recordAllBodies }, set: { value in update { store.setRecordAllBodies(value) } }))
                Text("本机代理默认只记状态、耗时和用量。开启后，现有及新添加的 Key 都记录后续调用的 Header 与正文，仅在本机加密保存。关闭后沿用各 Key 的单独设置。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
            SurfaceCard {
                timeoutRow("验证超时", value: store.verificationTimeout, choices: NetworkTimeouts.verificationChoices) { value in update { store.setVerificationTimeout(value) } }
                Text("调用验证、获取模型列表、查询余额，以及智能整理核对 Key 时，超过此时长未完成即判为超时。推理较慢的模型可以调大。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Divider()
                timeoutRow("代理超时", value: store.proxyTimeout, choices: NetworkTimeouts.proxyChoices) { value in update { store.setProxyTimeout(value) } }
                Text("本机代理转发调用时，上游连续这么久没有返回任何数据就断开。流式输出持续有数据时不会触发。修改后对新请求生效。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            SurfaceCard {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("智能整理").font(.system(size: 13, weight: .medium))
                        Text(store.data.organizerServiceID.flatMap { id in store.credentials.first { $0.id == id } }.map { store.displayText($0.title) } ?? "尚未配置整理服务")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Button("运行日志") {
                        let directory = store.agentLogDirectory
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        NSWorkspace.shared.open(directory)
                    }
                    Button("配置…") { organizer = true }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agent 提示词").font(.system(size: 13, weight: .medium))
                        Text("外置保存，下次新任务生效。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 12)
                    Button("编辑提示词…") { promptEditor = true }
                }
            }
            Text(store.loadError == nil ? "以上设置即时保存。每条 Key 的模型与协议在详情页设置。" : "请先重新打开保险库或恢复备份，再修改设置。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
        }.toggleStyle(.checkbox).padding(28).frame(width: 560).background(Palette.canvas)
            .disabled(store.loadError != nil)
            .sheet(isPresented: $organizer) { OrganizerSettingsView() }
            .sheet(isPresented: $promptEditor) { AgentPromptSettingsView() }
            .alert("设置未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(store.displayText(error ?? "")) }
    }
    private func timeoutRow(_ title: String, value: TimeInterval, choices: [TimeInterval], set: @escaping (TimeInterval) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Picker(title, selection: Binding(get: { value }, set: set)) {
                ForEach(choices, id: \.self) { Text(NetworkTimeouts.title($0)).tag($0) }
            }.labelsHidden().frame(width: 120)
        }
    }
    private func update(_ action: () -> Bool) {
        if !action() { error = store.error; store.error = nil }
    }
}
