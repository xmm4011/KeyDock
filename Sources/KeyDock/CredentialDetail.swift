import SwiftUI
import AppKit

enum DetailTab: String, CaseIterable {
    case use = "使用", activity = "记录", info = "资料"
}

struct CredentialDetail: View {
    @EnvironmentObject var store: VaultStore
    let record: Credential
    let edit: () -> Void
    @State private var tab: DetailTab
    @State private var showSource = false
    @State private var confirmArchive = false
    @State private var addingModel = false

    init(record: Credential, initialTab: DetailTab = .use, edit: @escaping () -> Void) {
        self.record = record; self.edit = edit; _tab = State(initialValue: initialTab)
    }
    var usageRecord: Credential { store.configuredForUse(record) }
    private var modelCheckIssue: String? {
        (record.kind == .custom ? nil : usageRecord.connectionIssue ?? store.modelIssue(usageRecord.model, for: usageRecord)) ?? APIClient.verificationIssue(usageRecord, testModel: record.kind != .custom)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                Picker("详情页面", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).controlSize(.large).labelsHidden().frame(width: 300, alignment: .leading)
                Spacer(minLength: 0)
            }.padding(.horizontal, Layout.pagePadding).padding(.bottom, 20)
            Divider().overlay(Palette.border.opacity(0.6))
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    if record.archived { archivedNotice }
                    switch tab {
                    case .use: connection
                    case .activity: ProxyHistoryPanel(credentialID: record.id, history: store.history, onChangeCapture: store.configureHistory, onUse: { tab = .use })
                    case .info: details
                    }
                }.frame(maxWidth: Layout.contentWidth, alignment: .leading)
                    .padding(Layout.pagePadding).frame(maxWidth: .infinity, alignment: .top)
            }.background(Palette.canvas.opacity(0.5)).id(tab)
        }
        .alert(isPresented: $confirmArchive) { CredentialConfirmation.archiveAlert { store.archive([record.id]) } }
        .sheet(isPresented: $addingModel) { AddModelView(record: record) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ProviderIcon(record: record, size: 44)
            VStack(alignment: .leading, spacing: 8) {
                Text(store.displayText(record.title)).font(.system(size: 21, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 9) {
                    StatusBadge(record: record)
                    Text(store.displayText(record.provider.isEmpty ? record.host : record.provider)).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    if record.archived { store.archive([record.id], archived: false) } else { confirmArchive = true }
                } label: {
                    Image(systemName: record.archived ? "arrow.uturn.backward" : "archivebox")
                        .foregroundStyle(Palette.muted).frame(width: 28, height: 28)
                }.buttonStyle(.plain).help(record.archived ? "恢复" : "归档")
                    .accessibilityLabel(record.archived ? "恢复" : "归档")
                Button { store.toggleFavorite(record) } label: {
                    Image(systemName: record.favorite ? "star.fill" : "star")
                        .foregroundStyle(record.favorite ? Color.orange : Palette.muted).frame(width: 28, height: 28)
                }.buttonStyle(.plain).help(record.favorite ? "取消收藏" : "收藏")
                    .accessibilityLabel(record.favorite ? "取消收藏" : "收藏")
                Button("编辑", action: edit).controlSize(.regular)
            }.fixedSize()
        }.padding(.horizontal, Layout.pagePadding).padding(.top, 24).padding(.bottom, 20)
    }
    private var archivedNotice: some View {
        Label("此条目已归档，本机调用已停用，可在右上角恢复。", systemImage: "archivebox")
            .font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var connection: some View {
        Group {
            SurfaceCard {
                HStack {
                    Text("接入项目").font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("本机配置，不含真实 Key").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                if record.kind != .custom { modelSelector }
                Button { store.copy(usageRecord.safeShareText) } label: {
                    Label("复制使用", systemImage: "doc.on.doc").frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.usageIssue(record) != nil).help(store.usageIssue(record) ?? "复制本机接入配置与调用示例，不含真实 Key")
                if let issue = store.usageIssue(record) { Text(issue).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3) }
                Divider().overlay(Palette.border.opacity(0.5))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("复制真实使用", systemImage: "doc.on.doc") { store.copy(usageRecord.realUsageText, sensitive: true) }
                        .disabled(store.usageIssue(record) != nil).help(store.usageIssue(record) ?? "复制直连服务的真实配置与调用示例，不计入本机记录；45 秒后清空剪贴板")
                    Button(store.installedEnvironmentIDs.contains(record.id) ? "移除系统变量" : "添加系统变量", systemImage: "terminal") { store.toggleSystemEnvironment(record) }
                        .help(record.connectionIssue ?? "添加一次，新开的终端或重启后的 IDE / 应用即可读取；只写入本机占位配置。")
                        .disabled((record.archived || record.expired || record.connectionIssue != nil) && !store.installedEnvironmentIDs.contains(record.id))
                }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 6)).controlSize(.regular)
            }
            SurfaceCard {
                HStack {
                    Text(record.kind == .custom ? "连接检查" : "调用验证").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if store.checking.contains(record.id) { ProgressView().controlSize(.mini) }
                    Button(record.verificationActionTitle, systemImage: "arrow.clockwise") {
                        Task { await store.verify(usageRecord, testModel: record.kind != .custom) }
                    }.disabled(store.checking.contains(record.id) || modelCheckIssue != nil).controlSize(.regular)
                        .help(modelCheckIssue ?? (record.kind == .custom ? "按配置的 GET 接口检查连接" : "向当前模型发送简短请求，会产生少量用量"))
                }
                if let issue = modelCheckIssue { Text(issue).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                if let check = record.check {
                    Text(store.displayText(check.displayMessage))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4).lineLimit(3).textSelection(.enabled)
                    Text("上次" + check.actionTitle + " " + check.checkedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else {
                    Text(record.kind == .custom ? "按配置的 GET 接口检查连接。" : "向当前模型发送简短请求，会产生少量用量。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                }
                if let connection = recentConnectionCheck {
                    Text(connection.state == .valid ? "最近连接检查正常，已保留上次模型调用结果。" : "最近连接检查未能确认可用性，已保留上次模型调用结果。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                }
                if record.check != nil { Divider().overlay(Palette.border.opacity(0.5)); checkDetails }
            }
            SurfaceCard {
                Text(record.kind == .custom ? "环境变量" : "环境变量与 curl").font(.system(size: 13, weight: .medium))
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("独立环境变量").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("复制变量") { store.copy(usageRecord.environmentText) }.controlSize(.small)
                        }
                        CodePanel(text: usageRecord.environmentText)
                        if record.kind != .custom {
                            HStack {
                                Text("模型调用请求").font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button("复制 curl") { store.copy(usageRecord.localCurl) }.controlSize(.small).disabled(store.usageIssue(record) != nil)
                            }
                            CodePanel(text: usageRecord.localCurl)
                            Text("变量可手动粘贴到终端执行。调用模型会产生正常用量。")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        }
                    }.padding(.top, 4)
            }
            Label("关窗口后留在菜单栏，项目仍可继续使用。", systemImage: "menubar.rectangle")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 2)
        }
    }
    private var modelSelector: some View {
        let models = store.rendering.models(usageRecord)
        return HStack(spacing: 12) {
            Spacer(minLength: 0)
            Text("调用模型").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Menu(store.modelsChecking.contains(record.id) ? "正在获取模型…" : (usageRecord.model.trimmed.isEmpty ? "选择模型" : store.displayText(usageRecord.model))) {
                Button(record.availableModels.isEmpty ? "获取模型列表" : "刷新模型列表") { Task { await store.fetchModels(record) } }.disabled(store.modelsChecking.contains(record.id) || APIClient.catalogIssue(record) != nil).help(APIClient.catalogIssue(record) ?? "读取当前 Key 的模型目录")
                if let issue = APIClient.catalogIssue(record) { Text(issue) }
                Button("复制模型列表") { store.copy(models.joined(separator: "\n")) }.disabled(models.isEmpty)
                Button("添加模型…") { addingModel = true }
                if !models.isEmpty { Divider() }
                if record.availableModels.isEmpty && !models.isEmpty { Text("当前已配置模型") }
                if record.modelCatalog?.source == "资料" { Text("来自资料，调用权限需验证") }
                ForEach(models, id: \.self) { model in
                    Button(store.displayText(model)) { store.selectModel(model, for: record) }.disabled(store.modelIssue(model, for: usageRecord) != nil)
                }
            }.lineLimit(1).frame(maxWidth: 200, alignment: .trailing).fixedSize(horizontal: true, vertical: false).help(usageRecord.model.isEmpty ? "选择用于生成请求的模型" : store.displayText(usageRecord.model))
            Menu(record.inferenceKind.protocolTitle) {
                let known = ProviderPreset.matching(record.baseURL)?.protocols ?? [.compatible, .anthropic, .responses, .gemini]
                ForEach(ServiceKind.allCases.filter { known.contains($0) || $0 == record.inferenceKind }) { kind in
                    Button { store.selectProtocol(kind, for: record) } label: {
                        if kind == record.inferenceKind { Label(kind.protocolTitle, systemImage: "checkmark") } else { Text(kind.protocolTitle) }
                    }
                }
            }.frame(width: 185).help("切换调用协议；实际接口可能带有厂商专用前缀，以生成的 curl 为准。")
                .disabled(record.archived)
        }
    }

    @ViewBuilder private func docsLink(_ title: String) -> some View {
        if !record.docsURL.isEmpty, let url = URL(string: record.docsURL), ["https", "http"].contains(url.scheme ?? "") {
            Link(destination: url) { Label(title, systemImage: "arrow.up.right.square").font(.system(size: 11)) }.help(record.docsURL)
        }
    }
    private var details: some View {
        Group {
            SurfaceCard {
                Text("连接资料").font(.system(size: 15, weight: .semibold))
                info("Base URL", value: record.baseURL)
                Divider().overlay(Palette.border.opacity(0.5))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("API Key").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button { store.copy(record.apiKey, sensitive: true) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help("复制真实 Key").accessibilityLabel("复制真实 API Key").disabled(record.apiKey.isEmpty)
                    }
                    Text(store.showFullContent ? (record.apiKey.isEmpty ? "未填写密钥" : record.apiKey) : record.maskedKey).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !record.docsURL.isEmpty { HStack { Text("接口文档").font(.system(size: 12)).foregroundStyle(Palette.muted); Spacer(); docsLink("打开文档") } }
            }
            SurfaceCard {
                Text("用途与备注").font(.system(size: 15, weight: .semibold))
                if !record.purpose.isEmpty { info("用途", value: record.purpose) }
                if !record.notes.isEmpty { info("备注", value: record.notes) }
                if record.purpose.isEmpty && record.notes.isEmpty { Text("还没有备注，点击右上角编辑即可补充。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                if !record.tags.isEmpty { info("标签", value: record.tags) }
                if let date = record.expiresAt { info("到期时间", value: date.formatted(date: .abbreviated, time: .omitted)) }
            }
            SurfaceCard {
                HStack {
                    Text("账户余额").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if let preset = ProviderPreset.matching(record.baseURL), preset.balanceURL == nil, record.balanceURL.isEmpty {
                        Link("前往控制台", destination: URL(string: preset.console)!).controlSize(.regular)
                    }
                    Button { Task { await store.queryBalance(record) } } label: {
                        HStack { if store.balanceChecking.contains(record.id) { ProgressView().controlSize(.mini) }; Text("查询余额") }
                    }.disabled(store.balanceChecking.contains(record.id) || APIClient.balanceIssue(record) != nil).help(APIClient.balanceIssue(record) ?? "查询当前账户余额").controlSize(.regular)
                }
                if !record.balanceSummary.isEmpty { Text(store.displayText(record.balanceSummary)).font(.system(size: 22, weight: .semibold, design: .rounded)).textSelection(.enabled) }
                Text(APIClient.balanceIssue(record) ?? record.balanceCheckedAt.map { "更新于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ProviderPreset.matching(record.baseURL)?.balanceNote ?? "按需查询账户余额。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
            SurfaceCard {
                DisclosureGroup("导入原文", isExpanded: $showSource) { source.padding(.top, 18) }.font(.system(size: 13, weight: .medium))
            }
            Text("创建于 \(record.createdAt.formatted(date: .abbreviated, time: .omitted)) · 更新于 \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
    private var checkDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = record.check {
                VerificationEvidenceView(result: result, request: checkedRequest)
            }
            if let connection = recentConnectionCheck {
                Divider().overlay(Palette.border.opacity(0.5))
                Text("最近连接检查 · " + connection.checkedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .medium))
                Text(store.displayText(connection.message)).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4).textSelection(.enabled)
                VerificationEvidenceView(result: connection, request: connection.request)
            }
        }
    }
    private var recentConnectionCheck: CheckResult? {
        guard let check = record.check, check.state == .valid, check.requestMethod == "POST",
              let connection = record.connectionCheck, connection.checkedAt >= check.checkedAt else { return nil }
        return connection
    }
    private var checkedRequest: CheckedRequest? {
        guard let check = record.check else { return nil }
        if let request = check.request { return request }
        // 旧数据只能按当前配置重建，地址和方法不符时不冒充历史请求。
        let request: URLRequest?
        if check.requestMethod == "POST" { request = try? APIClient.modelTestRequest(for: usageRecord) }
        else if check.requestMethod == "GET" { request = try? APIClient.verificationRequest(for: usageRecord) }
        else { return nil }
        guard let request, request.url?.absoluteString == check.endpoint else { return nil }
        return CheckedRequest(request)
    }
    private var source: some View { CredentialSourceView(record: record) }
    private func info(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(store.displayText(value)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

