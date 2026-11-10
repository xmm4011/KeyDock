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
            Text(store.loadError == nil ? "显示与记录开关即时保存。每条 Key 的模型与协议在详情页设置。" : "请先重新打开保险库或恢复备份，再修改设置。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
        }.toggleStyle(.checkbox).padding(28).frame(width: 560).background(Palette.canvas)
            .disabled(store.loadError != nil)
            .sheet(isPresented: $organizer) { OrganizerSettingsView() }
            .sheet(isPresented: $promptEditor) { AgentPromptSettingsView() }
            .alert("设置未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(store.displayText(error ?? "")) }
    }
    private func update(_ action: () -> Bool) {
        if !action() { error = store.error; store.error = nil }
    }
}
