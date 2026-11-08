import SwiftUI
import AppKit

struct ImportView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    var initialPaste = ImportPaste()
    @State private var document = ImportDocument()
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
    @State private var busy = false
    @State private var requestTask: Task<Void, Never>?
    @State private var error: String?
    @State private var consumedInitialPaste = false
    @State private var agentSummary = ""
    @State private var agentActivity: [String] = []
    @State private var agentReply = ""
    @State private var requireVerified = false
    @State private var progress = "正在整理…"
    @StateObject private var interaction = AgentInteraction()
    @State private var verifyingDrafts = Set<UUID>()
    @State private var verificationTasks: [UUID: Task<Void, Never>] = [:]
    var organizer: Credential? { store.active.first { $0.id == store.data.organizerServiceID && $0.canOrganize } }
    var organizerModel: String { store.data.organizerModel ?? organizer?.model ?? "" }
    var canUseAI: Bool { organizer != nil && !organizerModel.trimmed.isEmpty }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: parsed ? "看一眼，确认保存" : "直接粘贴，自动整理", subtitle: parsed ? "不对的点编辑，重复的自动跳过。" : "别人发来的文字、curl、配置，原样粘贴就好。", onCancel: cancel)
            Divider()
            if parsed { preview }
            else if interaction.displayedReply != nil { AgentQuestionView(interaction: interaction) }
            else { inputView }
            Divider()
            HStack {
                if parsed { Button("补充或修改资料") { cancelDraftChecks(); parsed = false; interaction.failure = nil } }
                else {
                    Menu("添加文件…") {
                        Button("图片…", action: addImages)
                        Button("文本或配置文件…", action: readFile)
                        if !busy { Divider(); Button("智能整理设置…") { settingsSheet = true } }
                    }.disabled(busy && !interaction.isWaiting).frame(width: 110)
                }
                Spacer()
                if interaction.question?.canReview == true || (!parsed && !busy && (interaction.recovery != nil || !drafts.isEmpty)) {
                    Button(!busy && !drafts.isEmpty ? "返回整理结果" : "查看当前结果") {
                        if busy { interaction.review() }
                        else if !drafts.isEmpty { parsed = true }
                        else if let result = interaction.recovery { accept(result) }
                    }
                }
                if busy && !interaction.isWaiting { ProgressView().controlSize(.small); Text(progress).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1) }
                Button(busy ? "停止" : "取消", action: cancel).keyboardShortcut(.cancelAction)
                if parsed {
                    Button("保存 \(included.count) 条") {
                        if store.importRecords(drafts.filter { included.contains($0.id) }) { dismiss() }
                        else { error = store.error; store.error = nil }
                    }.buttonStyle(.borderedProminent).disabled(included.isEmpty).keyboardShortcut(.defaultAction)
                } else if interaction.question != nil {
                    Button(interaction.question?.canContinueWithoutReply == true && interaction.document.content.length == 0 ? "继续尝试" : "回复并继续") { interaction.submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else if interaction.failure != nil {
                    Button("重试整理") { retry() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(useAI ? (canUseAI ? "AI 整理" : "设置 AI") : "整理") { organize() }.buttonStyle(.borderedProminent).disabled((input.trimmed.isEmpty && images.isEmpty) || busy).keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }.frame(width: 780, height: 650).disclosureGroupStyle(FullRowDisclosureStyle())
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
                if !consumedInitialPaste { consumedInitialPaste = true; useAI = store.data.prefersLocalImport != true; apply(initialPaste) }
            }
            .onChange(of: store.data.prefersLocalImport) { _, local in useAI = local != true || !images.isEmpty }
            .onChange(of: images.count) { _, count in if count > 0 { useAI = true } }
            .onDisappear { requestTask?.cancel(); interaction.cancel(); cancelDraftChecks() }
            .alert("整理提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
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
        }.padding(24).disabled(busy)
    }
    var preview: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !agentSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(agentSummary).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled)
                        if !agentReply.isEmpty && agentReply != agentSummary { Text(agentReply).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled) }
                        Text("默认只勾选验证通过的条目。未通过的可编辑后验证，输入原文仍保留。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        if !agentActivity.isEmpty {
                            DisclosureGroup("查看整理过程") { ForEach(Array(agentActivity.enumerated()), id: \.offset) { _, text in Text(text).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) } }
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(drafts) { record in
                    HStack(alignment: .top, spacing: 14) {
                        Toggle("选择", isOn: Binding(get: { included.contains(record.id) }, set: { if $0 { included.insert(record.id) } else { included.remove(record.id) } })).labelsHidden().toggleStyle(.checkbox).padding(.top, 10).disabled(requireVerified && record.check?.state != .valid)
                        ProviderIcon(record: record)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(store.displayText(record.title)).font(.system(size: 13, weight: .semibold)); Pill(text: record.kind == .custom ? "其他服务" : "大模型"); Spacer() }
                            Text(record.baseURL.isEmpty ? "⚠ 尚未识别到 Base URL，保存后请补充" : record.baseURL).font(.system(size: 11, design: .monospaced)).foregroundStyle(record.baseURL.isEmpty ? .orange : Palette.muted).textSelection(.enabled)
                            Text(store.showFullContent ? record.apiKey : record.maskedKey).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            if requireVerified { StatusBadge(record: record) }
                            if requireVerified, record.check?.state != .valid, let message = record.check?.message { Text(store.displayText(message)).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
                            if !record.purpose.isEmpty { Text(store.displayText("用途：" + record.purpose)).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                            if !record.notes.isEmpty { Text(store.displayText(record.notes)).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(3) }
                        }
                        VStack(spacing: 10) {
                            Button("编辑") { editing = record }.controlSize(.small)
                            if requireVerified && record.check?.state != .valid {
                                Button(verifyingDrafts.contains(record.id) ? "验证中…" : "验证") { verifyDraft(record) }.controlSize(.small).disabled(verifyingDrafts.contains(record.id))
                            }
                        }
                    }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
                }
            }.padding(24)
        }.background(Palette.canvas)
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
        let raw = input, model = organizerModel, selectedOrganizer = useAI && canUseAI ? organizer : nil
        if let selectedOrganizer, let issue = store.modelIssue(model, for: selectedOrganizer) { interaction.fail(issue); return }
        let attachments = images
        guard attachments.isEmpty || selectedOrganizer != nil else { error = "图片需要使用 AI 整理。请在设置中选择可信服务和支持图片的模型。"; return }
        if !drafts.isEmpty {
            interaction.recovery = AgentImportResult(records: drafts, summary: agentSummary, activity: agentActivity, reply: agentReply)
            drafts = []; included = []
        }
        interaction.begin()
        busy = true
        cancelDraftChecks()
        requestTask = Task {
            defer { busy = false }
            do {
                let records: [Credential]
                if let selectedOrganizer {
                    let result = try await ImportAgent.run(raw: raw, reviewedText: reviewedText, service: selectedOrganizer, model: model, images: attachments, interaction: interaction, onSupplement: { paste in apply(paste) }, progress: { progress = $0 })
                    try Task.checkCancellation(); accept(result); return
                } else {
                    let parsing = Task.detached(priority: .userInitiated) { ImportParser.parse(raw) }
                    records = await withTaskCancellationHandler { await parsing.value } onCancel: { parsing.cancel() }
                    requireVerified = false; agentSummary = ""; agentReply = ""; agentActivity = []
                }
                guard !Task.isCancelled else { return }
                setDrafts(records)
            } catch {
                if !Task.isCancelled {
                    let message = (error as? KeyDockError)?.localizedDescription ?? "整理未完成，原文和图片仍保留，可以稍后重试。"
                    if selectedOrganizer != nil {
                        if interaction.failure == nil { interaction.fail(message) }
                    } else { self.error = message }
                }
            }
        }
    }
    func retry() {
        if interaction.document.content.length > 0 {
            do { try document.append(interaction.document.paste); interaction.document = ImportDocument() }
            catch { interaction.error = error.localizedDescription; return }
        }
        organize()
    }
    func cancel() {
        if busy { stop() } else { dismiss() }
    }
    func stop() {
        if interaction.document.content.length > 0 {
            apply(interaction.document.paste)
            interaction.document = ImportDocument()
        }
        requestTask?.cancel(); interaction.cancel()
    }
    func apply(_ paste: ImportPaste) {
        do { try document.append(paste); if !images.isEmpty { useAI = true } }
        catch { self.error = error.localizedDescription }
        if let message = paste.errors.first { error = message }
    }
    func applyFile(_ paste: ImportPaste) {
        guard interaction.displayedReply != nil else { apply(paste); return }
        do { try interaction.document.append(paste) }
        catch { interaction.error = error.localizedDescription }
        if let message = paste.errors.first { interaction.error = message }
    }
    func addImages() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        var paste = ImportPaste()
        for url in panel.urls { do { paste.images.append(try .fromFile(url)) } catch { paste.errors.append(error.localizedDescription) } }
        applyFile(paste)
    }
    func readFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择包含凭据的文本 / JSON 配置文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_000_000 else { throw KeyDockError.message("请使用小于 1 MB 的文本文件。") }
            var paste = ImportPaste(text: try String(contentsOf: url, encoding: .utf8)); paste.absorbPaths(); applyFile(paste)
        } catch { self.error = error.localizedDescription }
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
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    VStack(spacing: 4) {
                        if let preview = image.preview { Image(nsImage: preview).resizable().scaledToFit().frame(width: 100, height: 65).background(.white, in: RoundedRectangle(cornerRadius: 6)) }
                        HStack(spacing: 4) { Text("图片 \(index + 1)").font(.system(size: 10)); if let onRemove { Button { onRemove(image.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("移除此图片") } }
                    }
                }
            }.padding(4)
        }.frame(height: 95)
    }
}
