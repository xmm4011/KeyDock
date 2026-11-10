import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CleanupView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State private var selected = Set<UUID>()
    @State private var confirmArchive = false
    private var selectedCandidates: Set<UUID> { selected.intersection(Set(store.cleanup.map(\.id))) }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "整理不再使用的 Key", subtitle: "仅列出已到期或 HTTP 401 鉴权失败的条目。归档后本机别名立即停用，可随时恢复。")
            Divider()
            if store.cleanup.isEmpty {
                ContentUnavailableView("暂时没有需要清理的 Key", systemImage: "checkmark.seal", description: Text("网络异常、权限受限、额度不足的条目不会列入。"))
            } else {
                List(store.cleanup) { record in
                    HStack(spacing: 12) {
                        Toggle("选择", isOn: Binding(get: { selected.contains(record.id) }, set: { if $0 { selected.insert(record.id) } else { selected.remove(record.id) } })).labelsHidden().toggleStyle(.checkbox)
                        ProviderIcon(record: record)
                        VStack(alignment: .leading, spacing: 5) { Text(store.displayText(record.title)).font(.system(size: 13, weight: .semibold)); Text(record.envPrefix).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        Spacer(); StatusBadge(record: record)
                    }.padding(.vertical, 8)
                }
            }
            Divider()
            HStack { Text("归档会保留原文、备注与验证记录。").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("取消") { dismiss() }; Button("归档 \(selectedCandidates.count) 条") { confirmArchive = true }.buttonStyle(.borderedProminent).disabled(selectedCandidates.isEmpty) }.padding(20)
        }.frame(width: 740, height: 530).onAppear { selected = Set(store.cleanup.map(\.id)) }
            .onChange(of: store.cleanup.map(\.id)) { _, ids in
                selected.formIntersection(Set(ids))
                if selectedCandidates.isEmpty { confirmArchive = false }
            }
            .alert(isPresented: $confirmArchive) { CredentialConfirmation.archiveAlert(count: selectedCandidates.count) {
                let ids = selectedCandidates
                guard !ids.isEmpty else { return }
                store.archive(ids); dismiss()
            } }
    }
}

struct BackupView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var mode = "export"
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    private var exporting: Bool { store.loadError == nil && mode == "export" }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "加密备份与恢复", subtitle: "使用独立密码保护，可迁移到另一台 Mac；无需导出明文密钥。")
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                if store.loadError == nil {
                    Picker("操作", selection: $mode) { Text("导出加密备份").tag("export"); Text("从备份恢复").tag("import") }.pickerStyle(.segmented)
                } else { Label("从备份恢复保险库", systemImage: "arrow.counterclockwise").font(.system(size: 13, weight: .medium)) }
                Text(exporting ? "将备份全部 \(store.credentials.count) 条记录，包括已归档条目。请妥善保管备份密码，遗忘后无法恢复。" : (store.loadError == nil ? "选择 .keydockbackup 文件并输入备份密码。恢复会合并条目，重复项自动跳过。" : "当前保险库无法读取，将使用备份重建；原保险库文件会保留。选择备份并输入对应密码。")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                SecureField(exporting ? "设置备份密码（至少 8 位）" : "输入备份密码", text: $password)
                if exporting { SecureField("再次输入备份密码", text: $confirm) }
                Label("AES-256-GCM · PBKDF2-SHA256", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(Palette.teal)
                if busy { ProgressView("正在处理加密数据…").controlSize(.small) }
            }.padding(25).disabled(busy)
            Divider()
            HStack { Spacer(); Button("关闭") { dismiss() }.disabled(busy); Button(exporting ? "选择位置并备份…" : "选择备份并恢复…") { perform() }.buttonStyle(.borderedProminent).disabled(busy || password.isEmpty) }.padding(20)
        }.frame(width: 650)
            .onDisappear { operation?.cancel() }
            .alert("备份提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(error ?? "") }
    }
    func perform() {
        if exporting {
            guard password.count >= 8, password == confirm else { error = "密码至少 8 位，且两次输入必须一致。"; return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "KeyDock-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).keydockbackup"
            panel.allowedContentTypes = [UTType(filenameExtension: "keydockbackup") ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            busy = true
            let snapshot = store.data, pass = password
            operation = Task {
                do {
                    let worker = Task.detached {
                        let data = try PortableBackup.create(snapshot, password: pass)
                        try Task.checkCancellation()
                        try data.write(to: url, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                    try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    try Task.checkCancellation()
                    store.showToast("加密备份已保存"); dismiss()
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                busy = false
            }
        } else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            busy = true
            let pass = password
            operation = Task {
                do {
                    let restored = try await Task.detached {
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50_000_000 else { throw KeyDockError.message("备份文件过大。") }
                        return try PortableBackup.restore(Data(contentsOf: url), password: pass)
                    }.value
                    try Task.checkCancellation()
                    if store.restore(restored) { dismiss() } else { self.error = store.error; store.error = nil }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                busy = false
            }
        }
    }
}
