import SwiftUI

struct CredentialEditor: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State var record: Credential
    @State var expectedUpdatedAt: Date? = nil
    var onSave: ((Credential) -> Bool)? = nil
    @State var advanced = false
    @State var moreInfo = false
    @State private var projectOptions = false
    @State private var localError: String?
    @State private var presetNotice: String?
    @State private var original: Credential?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SheetHeader(title: record.name.isEmpty ? "添加 Key" : "编辑 Key", subtitle: "填写地址和密钥就能保存，其他信息可以以后补。")
                Menu("填入预设") {
                    ForEach(ProviderPreset.all.filter { !$0.isBCE }) { item in Button(item.name) { apply(item) } }
                    Menu("百度 EOS AIGC") {
                        ForEach(ProviderPreset.all.filter(\.isBCE)) { item in Button(item.name) { apply(item) } }
                    }
                    Divider()
                    Button("自定义 / 中转站") { record = Self.changingProtocol(record, to: .compatible) }
                    Button("其他非模型服务") { record = Self.changingProtocol(record, to: .custom) }
                }.frame(width: 110).padding(.trailing, 24)
            }
            Divider()
            Form {
                Section("基本信息") {
                    field("名称（选填）", $record.name, prompt: "留空自动命名")
                    field("Base URL", $record.baseURL, prompt: "https://api.example.com/v1")
                    HStack(spacing: 12) {
                        Text("API Key").frame(width: 115, alignment: .leading)
                        Group {
                            if store.showFullContent { TextField("", text: $record.apiKey) }
                            else { SecureField("", text: $record.apiKey) }
                        }.labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth: .infinity).accessibilityLabel("API Key")
                    }.padding(.vertical, 6)
                    if let presetNotice { Text(presetNotice).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if record.kind != .custom { field("模型（选填）", $record.model, prompt: "留空可在保存后选择") }
                    field("用途（选填）", $record.purpose, prompt: "如：工作项目、个人测试")
                }
                DisclosureGroup("项目变量名", isExpanded: $projectOptions) {
                    field("独立变量前缀", $record.variablePrefix, prompt: record.suggestedPrefix)
                    Text("例如 DEEPSEEK_WORK_01。每条 Key 单独命名，程序自动生成 _BASE_URL / _API_KEY，不会把真实密钥写入变量。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DisclosureGroup("更多信息", isExpanded: $moreInfo) {
                    field("厂商", $record.provider, prompt: "自动识别，也可修改")
                    Picker("调用协议", selection: Binding(get: { record.inferenceKind }, set: { record = Self.changingProtocol(record, to: $0) })) { ForEach(ServiceKind.allCases) { Text($0.protocolTitle).tag($0) } }.padding(.vertical, 6)
                    if record.kind == .custom { field("默认模型", $record.model, prompt: "选填") }
                    if record.kind != .custom {
                        multilineField("保存的模型（每行一个）", Binding(get: { (record.manualModels ?? []).joined(separator: "\n") }, set: { record.manualModels = $0.components(separatedBy: .newlines) }), height: 90, monospaced: true)
                        Text("可增删保存的模型；当前调用模型仍会显示在下拉框。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    field("接口文档", $record.docsURL)
                    field("标签", $record.tags, prompt: "工作, 测试, 个人")
                    multilineField("备注", $record.notes, height: 140)
                    Toggle("设置到期日期", isOn: Binding(get: { record.expiresAt != nil }, set: { record.expiresAt = $0 ? Calendar.current.date(byAdding: .month, value: 1, to: Date()) : nil })).padding(.vertical, 6)
                    if record.expiresAt != nil { DatePicker("到期日期", selection: Binding(get: { record.expiresAt ?? Date() }, set: { record.expiresAt = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: $0) }), displayedComponents: .date).padding(.vertical, 6) }
                }
                DisclosureGroup("高级选项 · 鉴权、验证与余额接口", isExpanded: $advanced) {
                    Picker("鉴权方式", selection: $record.auth) { ForEach(AuthKind.allCases) { Text($0.title).tag($0) } }.padding(.vertical, 6)
                    field("GET 验证地址", $record.verificationURL, prompt: "留空使用默认验证接口")
                    multilineField("附加 Header", $record.extraHeaders, height: 85, monospaced: true)
                    Text("每行 Header-Name: 值。验证与代理会附加这些 Header。鉴权请通过上面的方式选择。").font(.system(size: 10)).foregroundStyle(.secondary)
                    field("GET 余额地址", $record.balanceURL, prompt: "DeepSeek 官方服务可留空")
                    field("余额 JSON 路径", $record.balancePath, prompt: "如 data.balance")
                    field("单位", $record.balanceUnit, prompt: "CNY / USD / 次")
                    Text("查询会将此密钥发送到你填写的地址，请使用该服务提供的接口。代理不会执行导入的 curl。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .multilineTextAlignment(.leading).controlSize(.large)
            Divider()
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }.padding(20)
        }.frame(width: 680, height: 640).disclosureGroupStyle(FullRowDisclosureStyle())
            .onAppear { if original == nil { original = record } }
            .onChange(of: record.apiKey) { _, value in if !value.trimmed.isEmpty { presetNotice = nil } }
            .alert("请检查填写内容", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) { Button("好") {} } message: { Text(localError ?? "") }
    }
    func field(_ title: String, _ value: Binding<String>, prompt: String = "") -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 115, alignment: .leading)
            TextField("", text: value, prompt: Text(prompt)).labelsHidden().textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity).accessibilityLabel(title)
        }.padding(.vertical, 6)
    }
    func multilineField(_ title: String, _ value: Binding<String>, height: CGFloat, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextEditor(text: value).font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .multilineTextAlignment(.leading).lineSpacing(5).scrollContentBackground(.hidden)
                .padding(10).frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
                .accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
    func save() {
        let value = Self.preparedForSave(record, previous: original)
        if let onSave {
            if onSave(value) { dismiss() }
        } else if store.save(value, expectedUpdatedAt: expectedUpdatedAt) { dismiss() }
        else { localError = store.error; store.error = nil }
    }
    func preset(_ name: String, _ kind: ServiceKind, _ url: String, _ docs: String) {
        let previous = record
        record = Self.applyingPreset(to: record, name: name, kind: kind, url: url, docs: docs)
        presetNotice = !previous.apiKey.isEmpty && record.apiKey.isEmpty ? "已切换服务，请填写对应的 API Key。" : nil
    }
    private func apply(_ preset: ProviderPreset) {
        let previous = record
        record = preset.applying(to: record)
        presetNotice = !previous.apiKey.isEmpty && record.apiKey.isEmpty ? "已切换服务，请填写对应的 API Key。" : nil
    }
    static func changingProtocol(_ source: Credential, to kind: ServiceKind) -> Credential {
        guard source.inferenceKind != kind else { return source }
        return source.selectingProtocol(kind)
    }
    static func preparedForSave(_ source: Credential, previous: Credential? = nil) -> Credential {
        var value = ProviderPreset.reconcileDefaults(source, previous: previous)
        if value.provider.isEmpty { value.provider = ImportParser.provider(base: value.baseURL, text: "") }
        // Provider labels describe models, not necessarily the gateway protocol.
        if value.name.trimmed.isEmpty { value.name = (value.provider.isEmpty ? (URL(string: value.baseURL)?.host ?? "服务") : value.provider) + " · " + String(value.id.uuidString.prefix(4)) }
        return value
    }
    static func applyingPreset(to source: Credential, name: String, kind: ServiceKind, url: String, docs: String) -> Credential {
        var value = source
        let changingService = source.baseURL != url || source.kind != kind
        if changingService {
            value.model = ""; value.manualModels = nil; value.modelProtocols = nil; value.callTemplate = nil; value.modelCatalog = nil; value.check = nil
            value.extraHeaders = ""; value.verificationURL = ""; value.balanceURL = ""; value.balancePath = ""; value.balanceUnit = ""
            value.balanceSummary = ""; value.balanceCheckedAt = nil
        }
        if !source.baseURL.trimmed.isEmpty, URL(string: source.baseURL)?.host?.lowercased() != URL(string: url)?.host?.lowercased() { value.apiKey = "" }
        value.provider = name; value.kind = kind; value.baseURL = url; value.docsURL = docs
        switch kind { case .anthropic: value.auth = .xAPIKey; case .gemini: value.auth = .googleKey; default: value.auth = .bearer }
        if value.name.isEmpty { value.name = name }
        return value
    }
}
