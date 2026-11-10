import SwiftUI
import AppKit

struct ImportView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    var initialPaste = ImportPaste()
    @State private var document = ImportDocument()
    @State private var materials = ImportDocument()
    @State private var sending = false
    @State private var readingFiles = false
    @State private var fileTask: Task<Void, Never>?
    @State private var fileTicket = UUID()
    @State private var expandedMessages = Set<UUID>()
    @State private var imagePreview: ImportImage?
    var input: String { document.text }
    var images: [ImportImage] { document.images }
    @State private var drafts: [Credential] = []
    @State private var included = Set<UUID>()
    @State private var parsed = false
    @State private var editing: Credential?
    @State private var aiSheet = false
    @State private var settingsSheet = false
    @State private var useAI = true
    private var busy: Bool { interaction.isBusy }
    @State private var closing = false
    @State private var requestTask: Task<Void, Never>?
    @State private var error: String?
    @State private var scrollToLatest = 0
    @State private var consumedInitialPaste = false
    @State private var agentSummary = ""
    @State private var agentActivity: [String] = []
    @State private var agentReply = ""
    @State private var requireVerified = false
    @State private var progress = "正在整理…"
    @StateObject private var interaction: AgentInteraction
    @State private var verifyingDrafts = Set<UUID>()
    @State private var verificationTasks: [UUID: Task<Void, Never>] = [:]
    var organizer: Credential? { store.active.first { $0.id == store.data.organizerServiceID && $0.canOrganize } }
    var organizerModel: String { store.data.organizerModel ?? organizer?.model ?? "" }
    var canUseAI: Bool { organizer != nil && !organizerModel.trimmed.isEmpty }
    private var composerHeight: CGFloat { !images.isEmpty ? 128 : (input.prefix(500).filter { $0 == "\n" }.count > 1 ? 100 : 66) }
    init(initialPaste: ImportPaste = ImportPaste(), conversation: AgentInteraction? = nil) {
        self.initialPaste = initialPaste; _interaction = StateObject(wrappedValue: conversation ?? AgentInteraction())
    }
    var body: some View {
        VStack(spacing: 0) {
            if interaction.messages.isEmpty {
                SheetHeader(title: "直接粘贴，自动整理", subtitle: "别人发来的文字、curl、配置，原样粘贴就好。", onCancel: cancel)
                Divider()
                inputView
                Divider()
                taskControls.padding(20)
            } else {
                conversationHeader
                Divider()
                conversation.frame(minHeight: 160, maxHeight: .infinity)
                replyComposer
            }
        }.frame(minWidth: 720, idealWidth: 840, maxWidth: 1100, minHeight: 600, idealHeight: 700, maxHeight: 1000).disclosureGroupStyle(FullRowDisclosureStyle())
            .sheet(item: $editing) { record in
                CredentialEditor(record: record, onSave: { value in
                    if let index = drafts.firstIndex(where: { $0.id == value.id }) {
                        let next = Self.mergingDraftEdit(value, original: record, current: drafts[index])
                        if requireVerified && next.check?.state != .valid { included.remove(next.id) }
                        drafts[index] = next
                    }
                    return true
                })
            }
            .sheet(isPresented: $aiSheet) { AIReviewView(raw: input, images: images) { text in aiSheet = false; organize(reviewedText: text) } }
            .sheet(isPresented: $settingsSheet) { OrganizerSettingsView() }
            .sheet(item: $imagePreview) { ImportImagePreview(image: $0) }
            .onAppear {
                interaction.activity.directory = store.agentLogDirectory
                if !consumedInitialPaste { consumedInitialPaste = true; useAI = store.data.prefersLocalImport != true; apply(initialPaste) }
            }
            .onChange(of: store.data.prefersLocalImport) { _, local in useAI = local != true || !images.isEmpty }
            .onChange(of: images.count) { _, count in if count > 0 { useAI = true } }
            .onDisappear { fileTask?.cancel(); cleanupTask() }
    }
    var taskControls: some View {
            HStack {
                Menu("添加文件…") {
                        Button("图片…", action: addImages)
                        Button("文本或配置文件…", action: readFile)
                        if !busy { Divider(); Button("智能整理设置…") { settingsSheet = true } }
                    }.disabled(sending || readingFiles).frame(width: 110)
                if readingFiles { ProgressView("正在读取文件…").controlSize(.small).font(.system(size: 11)) }
                Spacer()
                if interaction.question?.canReview == true || (!parsed && !busy && (interaction.recovery != nil || !drafts.isEmpty)) {
                    Button(!busy && !drafts.isEmpty ? "返回整理结果" : "查看当前结果") {
                        if busy { interaction.review() }
                        else if !drafts.isEmpty { parsed = true }
                        else if let result = interaction.recovery { accept(result) }
                    }
                }
                if interaction.isWaiting { Text("等待你的回复").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Button("关闭", action: closeTaskView)
                if parsed && document.content.length == 0 {
                    Button("保存 \(included.count) 条") {
                        if store.importRecords(drafts.filter { included.contains($0.id) }) { dismiss() }
                        else { error = store.error; store.error = nil }
                    }.buttonStyle(.borderedProminent).disabled(included.isEmpty || readingFiles).keyboardShortcut(.defaultAction)
                } else {
                    Button(interaction.failure != nil && document.content.length == 0 ? "重试" : (interaction.messages.isEmpty ? (useAI ? (canUseAI ? "AI 整理" : "设置 AI") : "整理") : "发送")) { send() }
                        .buttonStyle(.borderedProminent).disabled(interaction.isStopping || closing || sending || readingFiles || (input.trimmed.isEmpty && images.isEmpty && interaction.failure == nil && interaction.question?.canContinueWithoutReply != true) || (busy && !interaction.isWaiting && interaction.supplement == nil)).keyboardShortcut(.defaultAction)
                }
            }
    }
    var conversationHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(parsed ? "确认导入" : "整理凭据").font(.system(size: 17, weight: .semibold))
                Text(interaction.isStopping ? "正在结束当前执行，资料会保留" : (interaction.taskState == .stopped ? "已停止，资料已保留，可继续补充" : (interaction.isWaiting ? "请在下方补充所需资料" : (busy ? progress : (parsed ? "检查配置后保存，也可以继续补充要求" : "可继续补充文字、文档或图片")))))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer()
            Group {
                if busy {
                    Button(interaction.isStopping ? "正在停止…" : "停止") { stop() }
                        .disabled(interaction.isStopping).controlSize(.small)
                } else { Color.clear }
            }.frame(width: 86, height: 28)
            Button { settingsSheet = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(busy).help("智能整理设置").accessibilityLabel("智能整理设置")
        }.padding(.horizontal, 22).padding(.vertical, 14).sheetShortcuts(cancel: cancel, close: closeTaskView)
    }
    var conversation: some View {
        AgentConversationScroll(activity: interaction.activity, revision: "\(interaction.messages.count)-\(parsed)", scrollRequest: scrollToLatest) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(interaction.messages) { message in
                        HStack {
                            if message.isUser { Spacer(minLength: 36) }
                            VStack(alignment: .leading, spacing: 10) {
                                Text(message.isUser ? "你" : "AI").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                                if !message.text.isEmpty {
                                    Text(store.displayText(message.text, additionalSecrets: ImportParser.keys(in: materials.text)))
                                        .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                                        .lineLimit(message.isUser && !expandedMessages.contains(message.id) ? 6 : nil)
                                    if message.isUser && message.text.count > 250 {
                                        Button(expandedMessages.contains(message.id) ? "收起" : "展开资料") {
                                            if !expandedMessages.insert(message.id).inserted { expandedMessages.remove(message.id) }
                                        }.buttonStyle(.link).font(.system(size: 11))
                                    }
                                }
                                if !message.images.isEmpty { ImportImageStrip(images: message.images, onPreview: { imagePreview = $0 }) }
                            }.padding(14).frame(maxWidth: 620, alignment: .leading)
                                .background(message.isUser ? Palette.accent.opacity(0.07) : Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
                            if !message.isUser { Spacer(minLength: 20) }
                        }
                        if message.id == interaction.messages.last(where: { $0.isUser })?.id {
                            AgentProcessView(activity: interaction.activity, showFullContent: store.showFullContent,
                                             onCopy: { store.copy($0, sensitive: store.showFullContent) })
                                .frame(maxWidth: 620, alignment: .leading)
                        }
                    }
                    if parsed { preview }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var replyComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ImportTextEditor(document: $document, onError: { interaction.error = $0 }, onPreview: { imagePreview = $0 })
                    if document.content.length == 0 {
                        Text(interaction.isWaiting ? "回复上面的问题，也可以粘贴文字或图片…" : (busy ? "可以继续补充资料…" : "补充要求，或说明需要调整的地方…"))
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(14).allowsHitTesting(false)
                    }
                }.frame(height: composerHeight)
                taskControls.padding(.horizontal, 10).padding(.bottom, 10)
            }.background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
            if let message = interaction.error ?? error { Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 16)
    }
    func send() {
        guard !interaction.isStopping, !closing else { return }
        scrollToLatest += 1
        if useAI && !canUseAI { settingsSheet = true; return }
        let paste = document.paste
        if busy && interaction.isWaiting {
            interaction.document = document
            if interaction.submit() {
                interaction.postUser(paste.text.trimmed.isEmpty && paste.images.isEmpty ? ImportPaste(text: "请根据已有资料继续尝试。") : paste)
                document = ImportDocument()
            }
            return
        }
        if busy {
            guard let supplement = interaction.supplement, document.content.length > 0 else { return }
            sending = true
            let runID = interaction.runID
            Task {
                defer { sending = false }
                do {
                    try await supplement(paste)
                    guard interaction.runID == runID, !interaction.isStopping, interaction.taskState != .stopped, !closing else { return }
                    interaction.postUser(paste); document = ImportDocument()
                } catch {
                    if interaction.runID == runID, !interaction.isStopping, interaction.taskState != .stopped, !closing { interaction.error = error.localizedDescription }
                }
            }
            return
        }
        do {
            if document.content.length > 0 {
                if materials.content.length == 0 { materials = ImportDocument(content: document.content) }
                else { try materials.append(paste) }
                interaction.postUser(paste); document = ImportDocument()
            }
            guard materials.content.length > 0 else { return }
            parsed = false; organize()
        } catch { interaction.error = error.localizedDescription }
    }
    var inputView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("文字与图片").font(.system(size: 12, weight: .semibold))
            if !busy, let reply = interaction.lastReply {
                DisclosureGroup("上次 Agent 回复") { Text(reply.question).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled).frame(maxHeight: 110) }
            }
            ZStack(alignment: .topLeading) {
                ImportTextEditor(document: $document, onError: { error = $0 }, onPreview: { imagePreview = $0 })
                if input.isEmpty && images.isEmpty {
                    Text("把零散聊天、curl、文档截图粘贴在这里。\n\n支持直接粘贴或拖入图片，\nAI 会结合文字与图片整理。")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.65)).lineSpacing(6).padding(16).allowsHitTesting(false)
                }
            }.background(Palette.canvas, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.border))
            if !images.isEmpty { Text("双击图片放大 · 选中后按 Delete 或右键移除").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(useAI ? (organizer.map { "AI 整理 · " + store.displayText($0.title) } ?? "设置一次 AI，以后自动整理") : "本地规则识别", systemImage: useAI ? "sparkles" : "text.magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer()
                    Menu("整理选项") {
                        Button("智能整理设置…") { settingsSheet = true }
                        Toggle("使用 AI 整理", isOn: Binding(get: { useAI }, set: { value in
                            if value && !canUseAI { settingsSheet = true }
                            else { setImportMode(ai: value) }
                        })).disabled(!images.isEmpty)
                        if useAI && canUseAI {
                            Divider()
                            Button("发送前预览…") { aiSheet = true }.disabled(input.trimmed.isEmpty && images.isEmpty)
                        }
                    }.font(.system(size: 11)).fixedSize()
                }
                if let organizer, canUseAI, useAI {
                    HStack(alignment: .top) {
                        Text(images.isEmpty ? "由可信模型读取资料、编写临时代码并验证；会产生模型和小用量测试费用。" : "文字与 \(images.count) 张图片交给 \(organizer.host) 整理并验证，所选模型需支持看图与工具调用。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
                    }
                }
            }
            if let message = interaction.error ?? error { Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(24).disabled(busy)
    }
    var preview: some View {
            VStack(spacing: 16) {
                HStack {
                    Text("整理结果").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("已选 \(included.count) / \(drafts.count) 条").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                ForEach(drafts) { record in
                    HStack(alignment: .top, spacing: 14) {
                        Toggle("选择", isOn: Binding(get: { included.contains(record.id) }, set: { if $0 { included.insert(record.id) } else { included.remove(record.id) } })).labelsHidden().toggleStyle(.checkbox).padding(.top, 10).disabled(requireVerified && record.check?.state != .valid)
                        ProviderIcon(record: record)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(store.displayText(record.title, additionalSecrets: record.secretValues)).font(.system(size: 13, weight: .semibold)); Pill(text: record.kind == .custom ? "其他服务" : "大模型"); Spacer() }
                            Text(store.displayText(record.baseURL.isEmpty ? "⚠ 尚未识别到 Base URL，保存后请补充" : record.baseURL, additionalSecrets: record.secretValues)).font(.system(size: 11, design: .monospaced)).foregroundStyle(record.baseURL.isEmpty ? .orange : Palette.muted).textSelection(.enabled)
                            Text(store.showFullContent ? record.apiKey : record.maskedKey).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            if requireVerified { StatusBadge(record: record) }
                            if requireVerified, record.check?.state != .valid, let message = record.check?.message { Text(store.displayText(message, additionalSecrets: record.secretValues)).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
                            if !record.purpose.isEmpty { Text(store.displayText("用途：" + record.purpose, additionalSecrets: record.secretValues)).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                            if !record.notes.isEmpty { Text(store.displayText(record.notes, additionalSecrets: record.secretValues)).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(3) }
                        }
                        VStack(spacing: 10) {
                            Button("编辑") { editing = record }.controlSize(.small)
                            if requireVerified && record.check?.state != .valid {
                                Button(verifyingDrafts.contains(record.id) ? "验证中…" : "验证") { verifyDraft(record) }.controlSize(.small).disabled(verifyingDrafts.contains(record.id))
                            }
                        }
                    }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
                }
            }.padding(20).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
    }
    func setDrafts(_ records: [Credential]) {
        guard !records.isEmpty else { error = "没有识别到可整理的内容。可以手动新增，或补上 API Key / Base URL 等标签后重试。"; return }
        drafts = records; included = Set(records.filter { !requireVerified || $0.check?.state == .valid }.map(\.id)); parsed = true
    }
    func accept(_ result: AgentImportResult) { requireVerified = true; agentSummary = result.summary; agentReply = result.reply; agentActivity = result.activity; setDrafts(result.records) }
    func verifyDraft(_ record: Credential) {
        guard !verifyingDrafts.contains(record.id) else { return }
        verifyingDrafts.insert(record.id)
        verificationTasks[record.id] = Task {
            defer { verifyingDrafts.remove(record.id); verificationTasks[record.id] = nil }
            do {
                let (request, template) = try AgentVerification.request(record, arguments: [:])
                let (data, response) = try await AgentVerification.boundedData(for: request, session: APIClient.session, limit: 1_048_576)
                try Task.checkCancellation()
                guard let index = drafts.firstIndex(where: { $0.hasSameVerificationConfiguration(as: record) }) else { return }
                drafts[index].check = AgentVerification.classify(data, response: response, record: record, method: request.httpMethod ?? "GET", endpoint: request.url?.absoluteString ?? "")
                drafts[index].check?.request = CheckedRequest(request)
                if drafts[index].check?.state == .valid { drafts[index].callTemplate = template; included.insert(record.id) }
            } catch { if !Task.isCancelled { self.error = (error as? KeyDockError)?.localizedDescription ?? "验证未完成，条目仍保留，可修改后重试。" } }
        }
    }
    func cancelDraftChecks() { for task in verificationTasks.values { task.cancel() } }
    func setImportMode(ai: Bool) {
        if store.commit({ $0.prefersLocalImport = !ai }) { useAI = ai }
        else { error = store.error; store.error = nil }
    }
    static func mergingDraftEdit(_ edited: Credential, original: Credential, current: Credential) -> Credential {
        var result = edited
        result.preserveManualModels(from: current)
        let changed = !edited.hasSameVerificationConfiguration(as: original)
        result.check = changed ? nil : current.check
        if !changed { result.callTemplate = current.callTemplate }
        result.modelCatalog = edited.hasSameModelCatalogConfiguration(as: current) ? current.modelCatalog : nil
        return result
    }
    func organize(reviewedText: String? = nil) {
        guard !busy else { return }
        if useAI && !canUseAI { settingsSheet = true; return }
        let runID = interaction.begin()
        error = nil
        let raw = materials.text, model = organizerModel, selectedOrganizer = useAI && canUseAI ? organizer : nil
        if let selectedOrganizer, let issue = store.modelIssue(model, for: selectedOrganizer) { interaction.fail(issue); return }
        let attachments = materials.images
        guard attachments.isEmpty || selectedOrganizer != nil else { interaction.fail("图片需要使用 AI 整理。请在设置中选择可信服务和支持图片的模型。"); return }
        if !drafts.isEmpty {
            interaction.recovery = AgentImportResult(records: drafts, summary: agentSummary, activity: agentActivity, reply: agentReply)
            drafts = []; included = []
        }
        if selectedOrganizer == nil { interaction.activity.beginLocal(raw: raw) }
        cancelDraftChecks()
        requestTask = Task {
            defer {
                interaction.finishRun(runID, cancelled: Task.isCancelled)
                if interaction.runID == runID { requestTask = nil }
            }
            do {
                let records: [Credential]
                if let selectedOrganizer {
                    let result = try await ImportAgent.run(raw: raw, reviewedText: reviewedText, service: selectedOrganizer, model: model, images: attachments, interaction: interaction, onSupplement: { paste in
                        do { try materials.append(paste) } catch { interaction.error = error.localizedDescription }
                    }, progress: { progress = $0 })
                    try Task.checkCancellation(); accept(result); return
                } else {
                    let parsing = Task.detached(priority: .userInitiated) { ImportParser.parse(raw) }
                    records = await withTaskCancellationHandler { await parsing.value } onCancel: { parsing.cancel() }
                    requireVerified = false; agentSummary = ""; agentReply = ""; agentActivity = []
                }
                guard !Task.isCancelled else { return }
                setDrafts(records)
            } catch {
                if !Task.isCancelled, interaction.runID == runID, !interaction.isStopping, interaction.taskState != .stopped, !closing {
                    let message = (error as? KeyDockError)?.localizedDescription ?? "整理未完成，原文和图片仍保留，可以稍后重试。"
                    if selectedOrganizer != nil {
                        if interaction.failure == nil { interaction.fail(message) }
                    } else { interaction.fail(message) }
                }
            }
        }
    }
    func retry() { organize() }
    func cancel() {
        if busy { stop() } else { closeTaskView() }
    }
    func stop() {
        guard interaction.requestStop() else { return }
        error = nil; requestTask?.cancel()
    }
    func cleanupTask() {
        _ = interaction.requestStop()
        requestTask?.cancel(); interaction.cancel(); cancelDraftChecks()
        if requestTask == nil { interaction.finishRun(interaction.runID, cancelled: true) }
    }
    func closeTaskView() {
        guard !closing else { return }
        closing = true; cleanupTask(); dismiss()
    }
    func apply(_ paste: ImportPaste) {
        do { try document.append(paste); if !images.isEmpty { useAI = true } }
        catch { self.error = error.localizedDescription }
        if let message = paste.errors.first { error = message }
    }
    func applyFile(_ paste: ImportPaste) {
        apply(paste)
        if let message = paste.errors.first { interaction.error = message }
    }
    func addImages() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        loadFiles(panel.urls, images: true)
    }
    func readFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择包含凭据的文本 / JSON 配置文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFiles([url], images: false)
    }
    private func loadFiles(_ urls: [URL], images: Bool) {
        fileTask?.cancel(); let ticket = UUID(); fileTicket = ticket; readingFiles = true
        fileTask = Task {
            do {
                let paste = try await ImportFileLoader.load(urls, images: images)
                try Task.checkCancellation(); guard fileTicket == ticket else { return }; applyFile(paste)
            } catch { if !Task.isCancelled && fileTicket == ticket { self.error = error.localizedDescription } }
            if fileTicket == ticket { readingFiles = false; fileTask = nil }
        }
    }
}

struct AIReviewView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    let raw: String
    var images: [ImportImage] = []
    let completion: (String) -> Void
    @State private var selectedID: UUID?
    @State private var model = ""
    @State private var reviewed = ""
    @State private var newService = false
    @State private var error: String?
    var redacted: RedactedImport { RedactedImport(raw) }
    var services: [Credential] { store.active.filter(\.canOrganize) }
    var service: Credential? { services.first { $0.id == selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "发送前预览", subtitle: "直连所选服务。已识别密钥已替换为占位符，其他文本请在发送前检查。")
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("整理服务", selection: $selectedID) { Text("请选择").tag(nil as UUID?); ForEach(services) { Text(store.displayText($0.title)).tag(Optional($0.id)) } }
                    Button("新增服务…") { newService = true }
                }
                ModelSelectionField(service: service, model: $model)
                if let service { Label("直接发送至：\(service.host)", systemImage: "arrow.up.right.circle").font(.system(size: 12)).foregroundStyle(Palette.accent) }
                else { Text("请先添加一个你信任的官方或自有大模型 API。支持兼容接口、Anthropic 和 Gemini。").font(.system(size: 12)).foregroundStyle(.secondary) }
                Text("待发送文本（可编辑）").font(.system(size: 12, weight: .semibold))
                TextEditor(text: $reviewed).font(.system(size: 11, design: .monospaced)).padding(8).background(Palette.canvas).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
                if !images.isEmpty { ImportImageStrip(images: images) }
                Text("保留片段编号，由 AI 判断每个值的用途并在本机还原。请检查未覆盖的凭据；附件会发送真实图片内容，图片不自动脱敏。调用会产生正常用量。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(24)
            Divider()
            HStack {
                Spacer(); Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("发送并整理") { organize() }.buttonStyle(.borderedProminent).disabled(service == nil || service.flatMap { store.modelIssue(model, for: $0) } != nil || (reviewed.trimmed.isEmpty && images.isEmpty)).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 800, height: 720)
            .onAppear {
                reviewed = redacted.text
                selectedID = services.first { $0.id == store.data.organizerServiceID }?.id
                updateModel()
            }
            .onChange(of: selectedID) { _, _ in updateModel() }
            .onChange(of: services.map(\.id)) { old, ids in
                if let added = ids.first(where: { !old.contains($0) }) { selectedID = added }
                else if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            }
            .sheet(isPresented: $newService) { CredentialEditor(record: Credential()) }
            .alert("整理未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(error ?? "") }
    }
    func organize() {
        guard let service else { return }
        if let issue = store.modelIssue(model, for: service) { error = issue; return }
        guard store.configureOrganizer(serviceID: service.id, model: model) else { error = store.error; store.error = nil; return }
        completion(reviewed); dismiss()
    }
    func updateModel() {
        model = selectedID == store.data.organizerServiceID ? (store.data.organizerModel ?? service?.model ?? "") : (service?.model ?? "")
    }
}

struct ImportImageStrip: View {
    let images: [ImportImage]
    var onRemove: ((UUID) -> Void)? = nil
    var onPreview: ((ImportImage) -> Void)? = nil
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    VStack(spacing: 4) {
                        if let preview = image.thumbnail { Image(nsImage: preview).resizable().scaledToFit().frame(width: 100, height: 65).background(.white, in: RoundedRectangle(cornerRadius: 6)).onTapGesture(count: 2) { onPreview?(image) } }
                        HStack(spacing: 4) { Text("图片 \(index + 1)").font(.system(size: 10)); if let onRemove { Button { onRemove(image.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("移除此图片") } }
                    }
                }
            }.padding(4)
        }.frame(height: 95)
    }
}
