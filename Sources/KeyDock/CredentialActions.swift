import SwiftUI

enum CredentialConfirmation: String, Identifiable {
    case archive, delete
    var id: String { rawValue }
    static func archiveAlert(count: Int = 1, action: @escaping () -> Void) -> Alert {
        Alert(title: Text(count == 1 ? "归档这条 Key？" : "归档 \(count) 条 Key？"),
              message: Text("归档后本机调用会停止，记录和备注会保留，可随时恢复。"),
              primaryButton: .default(Text("确认归档"), action: action), secondaryButton: .cancel(Text("取消")))
    }
}

struct CredentialMenuItems: View {
    @EnvironmentObject var store: VaultStore
    let record: Credential
    let edit: () -> Void
    let archive: () -> Void
    let delete: () -> Void
    var body: some View {
        Button("复制使用", systemImage: "doc.on.doc") { store.copy(store.configuredForUse(record).safeShareText) }
            .disabled(store.usageIssue(record) != nil).help(store.usageIssue(record) ?? "复制本机接入配置与调用示例")
        Button("复制真实使用", systemImage: "doc.on.doc") { store.copy(store.configuredForUse(record).realUsageText, sensitive: true) }
            .disabled(store.usageIssue(record) != nil).help(store.usageIssue(record) ?? "复制直连服务的真实配置与调用示例，不计入本机调用记录")
        Button("编辑…", systemImage: "square.and.pencil", action: edit)
        Button(record.verificationActionTitle + (record.kind == .custom ? "" : "（少量用量）"), systemImage: "arrow.clockwise") {
            Task { await store.verify(record, testModel: record.kind != .custom) }
        }.disabled(record.archived || store.checking.contains(record.id) || (record.kind != .custom && (store.configuredForUse(record).connectionIssue != nil || store.modelIssue(store.configuredForUse(record).model, for: record) != nil)))
        Divider()
        Button(record.archived ? "恢复此条目" : "归档此条目", systemImage: record.archived ? "arrow.uturn.backward" : "archivebox") {
            if record.archived { store.archive([record.id], archived: false) } else { archive() }
        }
        Button(record.favorite ? "取消收藏" : "收藏", systemImage: record.favorite ? "star.slash" : "star") { store.toggleFavorite(record) }
        if record.archived { Divider(); Button("永久删除…", role: .destructive, action: delete) }
    }
}

struct CredentialContextActions: ViewModifier {
    @EnvironmentObject var store: VaultStore
    let record: Credential
    let edit: () -> Void
    @State private var confirmation: CredentialConfirmation?
    @State private var deletionSnapshot: Credential?
    func body(content: Content) -> some View {
        content.contextMenu { CredentialMenuItems(record: record, edit: edit, archive: { confirmation = .archive }, delete: { deletionSnapshot = record; confirmation = .delete }) }
            .alert(item: $confirmation) { action in
                switch action {
                case .archive: return CredentialConfirmation.archiveAlert { store.archive([record.id]) }
                case .delete:
                    let target = deletionSnapshot ?? record
                    return Alert(title: Text("永久删除此条目？"), message: Text("此操作无法撤销。加密备份中的副本不会受影响。"), primaryButton: .destructive(Text("永久删除")) { store.permanentlyDelete(target, expectedUpdatedAt: target.updatedAt) }, secondaryButton: .cancel(Text("取消")))
                }
            }
    }
}
