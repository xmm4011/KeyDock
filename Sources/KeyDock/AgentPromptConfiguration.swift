import Foundation

struct AgentPromptConfiguration {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyDock/AgentPrompts", isDirectory: true)
    }
    let directory: URL
    init(directory: URL = Self.defaultDirectory) { self.directory = directory }
    var file: URL { directory.appendingPathComponent("credential-import.md") }

    func defaultText(runtime: URL) throws -> String {
        let url = runtime.appendingPathComponent("prompts/credential-import.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw KeyDockError.message("未找到默认 Agent 提示词，请重新安装完整的 KeyDock 应用。")
        }
        try validate(text)
        return text
    }
    // The editable file lives outside the signed app. Seed once; never replace
    // an existing file on launch, task start, or application update.
    @discardableResult func prepare(runtime: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: file.path) {
            do {
                try Data(defaultText(runtime: runtime).utf8).write(to: file, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch CocoaError.fileWriteFileExists { /* Another opener created it. */ }
        }
        return file
    }
    func readForEditing(runtime: URL) throws -> String {
        let url = try prepare(runtime: runtime)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw KeyDockError.message("无法读取 Agent 提示词，请检查文件权限并使用 UTF-8 编码：\n" + url.path)
        }
        return text
    }
    func load(runtime: URL) throws -> String {
        let text = try readForEditing(runtime: runtime)
        try validate(text)
        return text
    }
    func save(_ text: String, runtime: URL, replacing expected: String? = nil) throws {
        try validate(text)
        _ = try prepare(runtime: runtime)
        if let expected, try readForEditing(runtime: runtime) != expected {
            throw KeyDockError.message("提示词文件已在其他位置修改。请重新打开编辑器，避免覆盖新内容。")
        }
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeyDockError.message("Agent 提示词不能为空，请在系统设置中编辑。\n" + file.path)
        }
        guard text.utf8.count <= 256 * 1024 else { throw KeyDockError.message("Agent 提示词不能超过 256 KB。") }
    }
}
