import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CleanupView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State private var selectedKeys = Set<UUID>()
    @State private var selectedModels = Set<ModelCleanupItem>()
    @State private var confirming = false
    private var keyCandidates: [Credential] { store.cleanup }
    private var modelRows: [ModelCleanupItem] { store.modelCleanupRows }
    private var offlineRows: [ModelCleanupItem] { modelRows.filter(\.offline) }
    private var failedRows: [ModelCleanupItem] { modelRows.filter { !$0.offline } }
    private var chosenKeys: Set<UUID> { selectedKeys.intersection(Set(keyCandidates.map(\.id))) }
    private var chosenModels: Set<ModelCleanupItem> { selectedModels.intersection(Set(store.modelCleanup)) }
    private var total: Int { chosenKeys.count + chosenModels.count }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "一键清理", subtitle: "列出已到期或 HTTP 401 鉴权失败的 Key、服务明确返回已下线的模型，以及调用未通过的模型。Key 归档后本机别名立即停用，可随时恢复；模型从该 Key 的模型列表移除，可重新添加。")
            Divider()
            if keyCandidates.isEmpty && modelRows.isEmpty {
                ContentUnavailableView("暂时没有需要清理的内容", systemImage: "checkmark.seal", description: Text("网络异常、权限受限、额度不足的条目不会列入。在右上角菜单「检查全部连接」后，已下线的模型会出现在这里。"))
            } else {
                List {
                    if !keyCandidates.isEmpty {
                        Section("失效 Key · \(keyCandidates.count)") {
                            ForEach(keyCandidates) { record in
                                HStack(spacing: 12) {
                                    checkbox(selectedKeys.contains(record.id)) { if $0 { selectedKeys.insert(record.id) } else { selectedKeys.remove(record.id) } }
                                    ProviderIcon(record: record)
                                    VStack(alignment: .leading, spacing: 5) { Text(store.displayText(record.title)).font(.system(size: 13, weight: .semibold)); Text(record.envPrefix).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                                    Spacer(); StatusBadge(record: record)
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                    if !offlineRows.isEmpty {
                        Section("已下线模型 · \(offlineRows.filter { !$0.inUse }.count)") {
                            ForEach(offlineRows) { item in modelRow(item) }
                        }
                    }
                    if !failedRows.isEmpty {
                        Section {
                            ForEach(failedRows) { item in modelRow(item) }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("调用未通过的模型 · \(failedRows.count)")
                                Text("服务没有说明模型已下线，可能是超时、无权限或接口不匹配，模型也许仍可使用，默认不勾选。限流和额度不足不列入。")
                                    .font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("归档的 Key 保留原文、备注与验证记录；正在使用的模型需先切换。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(); Button("取消") { dismiss() }
                Button("清理 \(total) 项") { confirming = true }.buttonStyle(.borderedProminent).disabled(total == 0)
            }.padding(20)
        }.frame(width: 740, height: 530)
            .onAppear { selectedKeys = Set(keyCandidates.map(\.id)); selectedModels = Set(store.modelCleanup.filter(\.offline)) }
            .onChange(of: keyCandidates.map(\.id)) { _, ids in
                selectedKeys.formIntersection(Set(ids))
                if total == 0 { confirming = false }
            }
            .onChange(of: store.modelCleanup) { _, items in
                selectedModels.formIntersection(Set(items))
                if total == 0 { confirming = false }
            }
            .alert(isPresented: $confirming) {
                Alert(title: Text(confirmTitle), message: Text("归档后本机调用会停止，记录和备注会保留，可随时恢复；移除的模型可重新添加。"),
                      primaryButton: .default(Text("确认清理")) {
                          // Read the latest candidates at confirmation time.
                          let keys = chosenKeys, models = chosenModels
                          guard keys.count + models.count > 0 else { return }
                          if store.cleanUp(keys: keys, models: models) { dismiss() }
                      }, secondaryButton: .cancel(Text("取消")))
            }
    }
    private var confirmTitle: String {
        [chosenKeys.isEmpty ? nil : "归档 \(chosenKeys.count) 条 Key", chosenModels.isEmpty ? nil : "移除 \(chosenModels.count) 个模型"].compactMap { $0 }.joined(separator: "，") + "？"
    }
    private func checkbox(_ on: Bool, disabled: Bool = false, set: @escaping (Bool) -> Void) -> some View {
        Toggle("选择", isOn: Binding(get: { on }, set: set)).labelsHidden().toggleStyle(.checkbox).disabled(disabled)
    }
    @ViewBuilder private func modelRow(_ item: ModelCleanupItem) -> some View {
        if let record = store.credentials.first(where: { $0.id == item.credentialID }) {
            let probe = record.modelProbes?[item.model]
            HStack(spacing: 12) {
                checkbox(!item.inUse && selectedModels.contains(item), disabled: item.inUse) { if $0 { selectedModels.insert(item) } else { selectedModels.remove(item) } }
                ProviderIcon(record: record, size: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.displayText(item.model)).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(store.displayText(record.title) + (item.inUse ? " · 正在使用，请先在详情中切换模型" : (probe.map { " · " + store.displayText($0.reason) } ?? "")))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                let color: Color = item.offline ? .red : .orange
                Text(item.offline ? (probe?.httpStatus.map { "HTTP \($0)" } ?? "已下线") : (probe?.title ?? "未通过")).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.08), in: Capsule())
            }.padding(.vertical, 6).help(probe.map { store.displayText($0.message) + "\n检查于 " + $0.checkedAt.formatted(date: .abbreviated, time: .shortened) } ?? "")
        }
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
