import SwiftUI
import AppKit

struct AgentPromptSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let configuration: AgentPromptConfiguration
    @State private var text = ""
    @State private var loadedText: String?
    @State private var error: String?
    @State private var ready = false

    init(configuration: AgentPromptConfiguration = .init()) { self.configuration = configuration }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent 提示词").font(.system(size: 21, weight: .semibold))
            Text("保存后从下次新任务生效，当前任务继续使用原提示词。也可直接编辑下方文件，应用更新会保留你的修改。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced))
                .padding(8).background(Palette.canvas)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
                .accessibilityLabel("Agent 提示词内容")
            Text(configuration.file.path).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(2)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("恢复默认") { perform { text = try configuration.defaultText(runtime: AgentWorker.resources().runtime); ready = true } }
                Button("在 Finder 中显示") { perform { NSWorkspace.shared.activateFileViewerSelecting([try configuration.prepare(runtime: AgentWorker.resources().runtime)]) } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    perform {
                        try configuration.save(text, runtime: AgentWorker.resources().runtime, replacing: loadedText)
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!ready || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 760, height: 650).background(Palette.canvas)
            .onAppear {
                perform {
                    text = try configuration.readForEditing(runtime: AgentWorker.resources().runtime)
                    loadedText = text; ready = true
                }
            }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
