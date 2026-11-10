import Foundation
import AppKit
import Combine

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var data = VaultData() { didSet { rendering.reset(data.credentials) } }
    let rendering = CredentialRenderCache()
    @Published var loadError: String?
    @Published var error: String?
    @Published var toast: String?
    @Published var selectedID: UUID?
    @Published var checking = Set<UUID>()
    @Published var modelsChecking = Set<UUID>()
    @Published var balanceChecking = Set<UUID>()
    @Published var batchRunning = false
    @Published var batchProgress = ""
    // Models already answered / planned for each Key while its models are checked.
    @Published private(set) var modelProbeProgress: [UUID: ProbeProgress] = [:]
    // Different Keys run in parallel; one Key's models go one at a time so a
    // check stays within that Key's rate limit and timings are not queued.
    static let batchKeyConcurrency = 8
    private var batchCounts = BatchCounts()
    let disk: EncryptedVault
    let proxy: LocalProxy
    let userEnvironment: UserEnvironment
    let history: ProxyHistory
    @Published private(set) var installedEnvironmentIDs = Set<UUID>()
    private var clipboardTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private let automaticProxy: Bool
    private let pasteboard: NSPasteboard
    private let clipboardLifetime: Duration
    private var sensitiveChangeCount: Int?
    private var terminateObserver: NSObjectProtocol?
    private var localeObserver: NSObjectProtocol?
    private var revision: VaultRevision?
    var agentLogDirectory: URL { automaticProxy ? AgentActivity.defaultDirectory : disk.directory.appendingPathComponent("agent-logs", isDirectory: true) }
    var credentials: [Credential] { data.credentials }
    var selected: Credential? { data.credentials.first { $0.id == selectedID } }
    var active: [Credential] { credentials.filter { !$0.archived } }
    var cleanup: [Credential] { credentials.filter(\.cleanupCandidate) }
    // Models whose last call failed, on Keys that still answer for another model:
    // ones the service reported gone, and other failures except quota limits.
    // The selected model is never removed automatically.
    var modelCleanup: [ModelCleanupItem] { modelCleanupRows.filter { !$0.inUse } }
    var modelCleanupRows: [ModelCleanupItem] {
        credentials.filter { !$0.archived && !$0.cleanupCandidate && $0.kind != .custom && $0.modelProbes != nil }.flatMap { record -> [ModelCleanupItem] in
            let listed = Set(rendering.models(record)), current = record.model.trimmed, serves = record.servesSomeModel
            return (record.modelProbes ?? [:]).filter { listed.contains($0.key) && $0.value.cleanable }.sorted { $0.key < $1.key }.compactMap { name, probe in
                if name == current { return probe.unavailable ? ModelCleanupItem(credentialID: record.id, model: name, inUse: true) : nil }
                guard serves else { return nil }
                return ModelCleanupItem(credentialID: record.id, model: name, offline: probe.unavailable)
            }
        }
    }
    var showFullContent: Bool { data.showFullContent ?? false }
    var recordAllBodies: Bool { data.recordAllBodies ?? false }
    var capturedCredentialIDs: Set<UUID> { recordAllBodies ? Set(credentials.map(\.id)) : history.captureBodies }
    var logDisplayPolicy: HTTPLogDisplayPolicy {
        rendering.displayPolicy(credentials, full: showFullContent)
    }
    func listing(shelf: Shelf, search: String) -> CredentialListProjection { rendering.list(credentials, shelf: shelf, query: search) }
    @discardableResult func setShowFullContent(_ value: Bool) -> Bool { commit { $0.showFullContent = value } }
    @discardableResult func setRecordAllBodies(_ value: Bool) -> Bool { commit { $0.recordAllBodies = value } }
    var verificationTimeout: TimeInterval { data.verificationTimeout.flatMap { NetworkTimeouts.verificationChoices.contains($0) ? $0 : nil } ?? NetworkTimeouts.defaultVerification }
    var proxyTimeout: TimeInterval { data.proxyTimeout.flatMap { NetworkTimeouts.proxyChoices.contains($0) ? $0 : nil } ?? NetworkTimeouts.defaultProxy }
    @discardableResult func setVerificationTimeout(_ value: TimeInterval) -> Bool {
        guard NetworkTimeouts.verificationChoices.contains(value) else { error = "不支持此验证超时时长。"; return false }
        return commit { $0.verificationTimeout = value }
    }
    @discardableResult func setProxyTimeout(_ value: TimeInterval) -> Bool {
        guard NetworkTimeouts.proxyChoices.contains(value) else { error = "不支持此代理超时时长。"; return false }
        return commit { $0.proxyTimeout = value }
    }
    private func applyNetworkSettings() {
        APIClient.verificationTimeout = verificationTimeout
        proxy.setUpstreamIdleTimeout(proxyTimeout)
    }
    func displayText(_ text: String, additionalSecrets: [String] = []) -> String {
        logDisplayPolicy.text(text, extra: additionalSecrets)
    }
    func headerSecrets(_ headers: String) -> [String] {
        var record = Credential(); record.extraHeaders = headers
        return record.secretValues
    }
    func displayHeaders(_ headers: String, additionalSecrets: [String] = []) -> String {
        guard !showFullContent else { return headers }
        let secrets = headerSecrets(headers) + additionalSecrets
        return headers.components(separatedBy: "\n").map { line in
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, LogRedaction.isSensitiveHeader(String(pair[0]).trimmed) { return String(pair[0]) + ": [已隐藏]" }
            return displayText(line, additionalSecrets: secrets)
        }.joined(separator: "\n")
    }
    func displayResponse(_ response: CheckedResponse, request: CheckedRequest?) -> String {
        let secrets = headerSecrets(response.headers) + headerSecrets(RecordedContent.headers(request?.headers ?? [:]))
        let headers = displayHeaders(response.headers, additionalSecrets: secrets)
        return (headers.isEmpty ? "" : headers + "\n\n") + (response.body.isEmpty ? "（空正文）" : displayText(response.body, additionalSecrets: secrets))
    }
    func configuredForUse(_ record: Credential) -> Credential {
        var value = ProviderPreset.configuration(record)
        if value.kind != .custom, value.model.trimmed.isEmpty, data.organizerServiceID == value.id, let model = data.organizerModel?.trimmed, !model.isEmpty { value.model = model }
        let secrets = Set(rendering.allSecrets(credentials) + record.secretValues)
        value.provider = value.provider.replacingSecrets(Dictionary(uniqueKeysWithValues: secrets.map { ($0, "SERVICE") }))
        if secrets.contains(where: { !value.variablePrefix.isEmpty && value.variablePrefix.range(of: $0, options: .caseInsensitive) != nil }) { value.variablePrefix = value.suggestedPrefix }
        return value
    }
    private func environmentRecord(_ record: Credential) -> Credential {
        var value = configuredForUse(record)
        if !value.model.trimmed.isEmpty && modelIssue(value.model, for: value) != nil { value.model = "[已隐藏]" }
        return value
    }
    private func synchronizeEnvironment() {
        do { try userEnvironment.synchronize(credentials.map(environmentRecord)); installedEnvironmentIDs = Set(userEnvironment.entries.map(\.id)) }
        catch { self.error = "密钥库已打开，但系统变量未同步：" + error.localizedDescription }
    }
    func modelIssue(_ model: String, for service: Credential) -> String? {
        if let issue = service.modelIssue(model) { return issue }
        if rendering.allSecrets(credentials).contains(where: { model == $0 || ($0.count >= 8 && model.contains($0)) }) { return "模型名称中包含鉴权信息，请填写实际的模型 ID。" }
        return nil
    }
    func selectProtocol(_ kind: ServiceKind, for record: Credential) {
        guard let current = credentials.first(where: { $0.id == record.id }), current.updatedAt == record.updatedAt else { error = "此条目已更新，请重新选择协议。"; return }
        guard kind != .custom, current.kind != .custom, !current.archived else { return }
        var changed = current.selectingProtocol(kind)
        changed.restoreVerification(from: current); changed.adoptProbedCheck()
        guard changed != current else { return }
        _ = commit { next in
            guard let index = next.credentials.firstIndex(where: { $0.id == current.id }) else { return }
            next.credentials[index] = changed
            next.credentials[index].updatedAt = Date()
        }
    }
    func selectModel(_ name: String, for record: Credential) {
        guard let current = credentials.first(where: { $0.id == record.id }), current.updatedAt == record.updatedAt else { error = "此条目已更新，请重新选择模型。"; return }
        _ = updateModel(name, current: current, adding: false)
    }
    private func updateModel(_ name: String, current: Credential, adding: Bool) -> Bool {
        guard !current.archived, current.kind != .custom else { error = "请先恢复此 Key，再选择调用模型。"; return false }
        if let issue = modelIssue(name, for: current) { error = issue; return false }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else { error = "模型 ID 不能包含换行或控制字符。"; return false }
        var value = current.selectingModel(name)
        if current.model != value.model {
            if !current.availableModels.contains(current.model) { value.rememberModel(current.model) }
            if !current.availableModels.contains(value.model) { value.rememberModel(value.model) }
        }
        if adding { value.rememberModel(name) }
        guard value != current else { return true }
        value.restoreVerification(from: current); value.adoptProbedCheck()
        value.updatedAt = Date()
        return commit { next in
            if let index = next.credentials.firstIndex(where: { $0.id == current.id }) { next.credentials[index] = value }
        }
    }
    func usageIssue(_ record: Credential) -> String? {
        let configured = configuredForUse(record)
        return configured.usageIssue ?? (configured.kind == .custom ? nil : modelIssue(configured.model, for: configured))
    }

    init(disk: EncryptedVault = EncryptedVault(), automaticProxy: Bool = true, pasteboard: NSPasteboard = .general, clipboardLifetime: Duration = .seconds(45), proxyPort: UInt16 = 47831) {
        self.disk = disk; self.automaticProxy = automaticProxy; self.pasteboard = pasteboard
        proxy = LocalProxy(port: proxyPort)
        self.clipboardLifetime = clipboardLifetime
        history = ProxyHistory(directory: disk.directory, keyProvider: disk.keyProvider)
        userEnvironment = automaticProxy ? UserEnvironment() : UserEnvironment(home: disk.directory.appendingPathComponent("environment-test-home"), command: { _ in "" })
        installedEnvironmentIDs = Set(userEnvironment.entries.map(\.id)); load()
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearSensitiveClipboard(); self?.history.flush() }
        }
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.rendering.reset(self.credentials); self.objectWillChange.send() }
        }
    }
    deinit { if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }; if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) } }
    func load() {
        do {
            let snapshot = try disk.loadSnapshot(); data = snapshot.data; revision = snapshot.revision; loadError = nil
            selectedID = active.first?.id
            synchronizeEnvironment()
            history.retryLoading(); history.synchronize(Set(credentials.map(\.id)))
            configureHistory(); applyNetworkSettings()
            proxy.update(credentials); if automaticProxy { proxy.start() }
        } catch { loadError = error.localizedDescription; revision = try? disk.revision(); proxy.update([]); proxy.stop() }
    }
    func configureHistory() {
        proxy.recordHistory(captureBodies: capturedCredentialIDs) { [weak history] entry in
            Task { @MainActor in history?.append(entry) }
        }
    }

    @discardableResult
    func commit(_ change: (inout VaultData) throws -> Void) -> Bool {
        guard loadError == nil else { error = "保险库尚未成功打开，请先重试或恢复备份。"; return false }
        do {
            var next = data; try change(&next)
            if let id = next.organizerServiceID, !next.credentials.contains(where: { $0.id == id }) { next.organizerServiceID = nil; next.organizerModel = nil }
            revision = try disk.save(next, replacing: revision); data = next; proxy.update(credentials); applyNetworkSettings()
            history.synchronize(Set(credentials.map(\.id))); configureHistory()
            do { try userEnvironment.synchronize(credentials.map(environmentRecord)); installedEnvironmentIDs = Set(userEnvironment.entries.map(\.id)) }
            catch { self.error = "记录已保存，但系统变量未更新：" + error.localizedDescription }
            return true
        } catch is VaultWriteConflict {
            refreshAfterConflict(); return false
        } catch { self.error = error.localizedDescription; return false }
    }
    func toggleSystemEnvironment(_ record: Credential) {
        do {
            if userEnvironment.contains(record.id) { try userEnvironment.remove(record.id); showToast("已移除此 Key 的系统变量，新开的程序生效") }
            else {
                guard let current = credentials.first(where: { $0.id == record.id }) else { throw KeyDockError.message("此条目已删除，无法添加系统变量。") }
                guard !current.archived, !current.expired else { throw KeyDockError.message("此条目已归档或到期，请先恢复或修改到期时间。") }
                if let issue = current.connectionIssue { throw KeyDockError.message(issue) }
                try userEnvironment.install(environmentRecord(current)); showToast("已添加系统变量，新开终端或重启 IDE / 应用后使用")
            }
            installedEnvironmentIDs = Set(userEnvironment.entries.map(\.id))
        } catch { self.error = error.localizedDescription }
    }

    private func refreshAfterConflict() {
        let selected = selectedID; load()
        if credentials.contains(where: { $0.id == selected }) { selectedID = selected }
        error = "另一份 KeyDock 已修改保险库，已刷新最新记录。此次修改未保存，请重新打开编辑或重试操作。"
    }

    func save(_ value: Credential, expectedUpdatedAt: Date? = nil) -> Bool {
        if let expectedUpdatedAt, credentials.first(where: { $0.id == value.id })?.updatedAt != expectedUpdatedAt {
            error = "这条记录已修改或删除。此次编辑未保存，请重新打开记录后再编辑。"; return false
        }
        var record = credentials.first(where: { $0.id == value.id }).map { ProviderPreset.reconcileDefaults(value, previous: $0) } ?? value
        record.name = record.name.trimmed; record.baseURL = record.baseURL.trimmed
        record.apiKey = record.apiKey.trimmed
        record.model = record.model.trimmed
        record.variablePrefix = record.variablePrefix.trimmed.isEmpty ? record.suggestedPrefix : record.variablePrefix.trimmed.uppercased()
        guard !record.name.isEmpty else { error = "请给这条 Key 起个名称。"; return false }
        guard !record.baseURL.isEmpty else { error = "请填写 Base URL。"; return false }
        guard record.baseURL.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")).caseInsensitiveCompare(record.localBaseURL) != .orderedSame else { error = "这里应填写服务提供的 Base URL，不能填写此条目自己的本机接入地址。"; return false }
        guard (try? APIClient.safeURL(record.baseURL)) != nil else { error = "Base URL 应为 HTTP 或 HTTPS 完整地址。"; return false }
        guard !record.apiKey.isEmpty || record.auth == .none else { error = "请填写 API Key。"; return false }
        do {
            let base = try APIClient.safeURL(record.baseURL)
            guard URLComponents(url: base, resolvingAgainstBaseURL: false)?.query == nil else { throw KeyDockError.message("Base URL 只填写基础地址，不含查询参数。") }
            _ = try APIClient.authenticatedRequest(url: base, record: record)
            for address in [record.verificationURL, record.balanceURL] where !address.trimmed.isEmpty { _ = try APIClient.safeURL(address) }
        } catch { self.error = error.localizedDescription; return false }
        guard record.variablePrefix.range(of: #"^[A-Z][A-Z0-9_]{1,55}$"#, options: .regularExpression) != nil,
              !Credential.reservedVariablePrefixes.contains(record.variablePrefix) else { error = "变量前缀请用 2–56 位大写字母、数字、下划线，并以字母开头。"; return false }
        guard !record.secretValues.contains(where: { record.variablePrefix.range(of: $0, options: .caseInsensitive) != nil }) else { error = "变量前缀不能包含真实密钥，请改用用途或项目名称。"; return false }
        guard !credentials.contains(where: { $0.id != record.id && $0.envPrefix == record.variablePrefix }) else { error = "变量前缀已被另一条 Key 使用，请换一个。"; return false }
        let sameExistingIdentity = credentials.first(where: { $0.id == record.id })?.fingerprint == record.fingerprint
        guard sameExistingIdentity || !credentials.contains(where: { $0.id != record.id && $0.fingerprint == record.fingerprint }) else { error = "相同连接与鉴权配置已经存在，可直接编辑原条目。"; return false }
        if let old = credentials.first(where: { $0.id == record.id }) {
            record.preserveManualModels(from: old)
            let sameProvider = ProviderPreset.matching(record.baseURL).map { $0.id == ProviderPreset.matching(old.baseURL)?.id } ?? false
            record.modelProtocols = record.baseURL == old.baseURL || sameProvider ? (record.modelProtocols ?? old.modelProtocols) : nil
        }
        record.rememberProtocol()
        if let models = record.manualModels {
            let names = Credential.modelChoices(current: "", available: models)
            guard names.allSatisfy({ modelIssue($0, for: record) == nil && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { error = "保存的模型列表包含鉴权信息或控制字符，请修改后保存。"; return false }
            record.manualModels = names
        }
        record.updatedAt = Date()
        if let old = credentials.first(where: { $0.id == record.id }) {
            let authChanged = old.apiKey != record.apiKey || old.baseURL != record.baseURL || old.auth != record.auth || old.extraHeaders != record.extraHeaders
            let balanceChanged = authChanged || old.balanceURL != record.balanceURL || old.balancePath != record.balancePath || old.balanceUnit != record.balanceUnit
            record.balanceSummary = balanceChanged ? "" : old.balanceSummary
            record.balanceCheckedAt = balanceChanged ? nil : old.balanceCheckedAt
            let verificationChanged = authChanged || old.kind != record.kind || old.callTemplate != record.callTemplate || old.verificationURL != record.verificationURL
            record.check = verificationChanged || (old.model != record.model && old.check?.requestMethod == "POST") ? nil : old.check
            record.connectionCheck = verificationChanged ? nil : old.connectionCheck
            // Per-model results describe this Key at this address; another Key starts over.
            record.modelProbes = authChanged ? nil : old.modelProbes
            let sameProviderKey = ProviderPreset.matching(record.baseURL) != nil && record.fingerprint == old.fingerprint
            let catalogChanged = old.verificationURL != record.verificationURL || ((authChanged || old.kind != record.kind || old.inferenceKind != record.inferenceKind) && !sameProviderKey)
            record.modelCatalog = catalogChanged ? nil : (old.modelCatalog ?? (old.availableModels.isEmpty ? nil : ModelCatalog(models: old.availableModels)))
            let sameService = old.apiKey == record.apiKey && old.extraHeaders == record.extraHeaders && (old.baseURL == record.baseURL || sameProviderKey)
            if sameService && (old.model != record.model || old.inferenceKind != record.inferenceKind) { record.restoreVerification(from: old); record.adoptProbedCheck() }
            else if verificationChanged { record.verificationHistory = nil }
            else { record.verificationHistory = old.verificationHistory }
            record.favorite = old.favorite; record.archived = old.archived; record.createdAt = old.createdAt
        }
        let success = commit { next in
            if let index = next.credentials.firstIndex(where: { $0.id == record.id }) { next.credentials[index] = record }
            else { next.credentials.insert(record, at: 0) }
        }
        if success { selectedID = record.id; showToast("已保存") }
        return success
    }

    func addModel(_ name: String, to record: Credential) -> Bool {
        guard let current = credentials.first(where: { $0.id == record.id }), current.hasSameConnection(as: record) else { error = "此 Key 的连接配置已修改或条目已删除，请关闭后重新添加模型。"; return false }
        return updateModel(name.trimmed, current: current, adding: true)
    }
    func removeModel(_ name: String, from record: Credential) -> Bool {
        guard let current = credentials.first(where: { $0.id == record.id }), current.hasSameConnection(as: record) else { error = "此 Key 的连接配置已修改或条目已删除，请重新打开后再移除模型。"; return false }
        guard !current.archived, current.kind != .custom else { error = "请先恢复此 Key，再管理模型。"; return false }
        let target = name.trimmed
        guard target != current.model.trimmed else { error = "此模型正在使用，请先切换到其他模型再移除。"; return false }
        guard current.modelOptions.contains(target) else { return true }
        // Any listed model, added by hand or fetched from the service. A later
        // refresh of the model list may bring a fetched model back.
        var value = current
        value.removeModels([target])
        value.updatedAt = Date()
        let success = commit { next in
            if let index = next.credentials.firstIndex(where: { $0.id == current.id }) { next.credentials[index] = value }
        }
        if success { showToast("已移除模型") }
        return success
    }

    func configureOrganizer(serviceID: UUID?, model: String) -> Bool {
        let name = model.trimmed
        if let serviceID {
            guard let service = active.first(where: { $0.id == serviceID && $0.canOrganize }) else { error = "所选 Key 已不可用，请重新选择。"; return false }
            if let issue = modelIssue(name, for: service) { error = issue; return false }
            guard name.rangeOfCharacter(from: .controlCharacters) == nil else { error = "模型 ID 不能包含换行或控制字符。"; return false }
        }
        return commit { next in
            next.organizerServiceID = serviceID; next.organizerModel = serviceID == nil ? nil : name; next.prefersLocalImport = serviceID == nil
            if let index = next.credentials.firstIndex(where: { $0.id == serviceID }) {
                let previous = next.credentials[index]
                next.credentials[index].rememberModel(name)
                if next.credentials[index].model.trimmed.isEmpty {
                    next.credentials[index].model = name
                    if next.credentials[index].check?.requestMethod == "POST" { next.credentials[index].check = nil }
                }
                if next.credentials[index] != previous { next.credentials[index].updatedAt = Date() }
            }
        }
    }

    func importRecords(_ values: [Credential]) -> Bool {
        var added = 0, duplicate = 0, restoredImages = 0
        var addedID: UUID?, existingID: UUID?
        let success = commit { next in
            var seen = Set(next.credentials.map(\.fingerprint))
            var prefixes = Set(next.credentials.map(\.envPrefix))
            var ids = Set(next.credentials.map(\.id))
            for var record in values {
                record.apiKey = record.apiKey.trimmed; record.baseURL = record.baseURL.trimmed; record.name = record.name.trimmed
                record.rememberProtocol()
                if let existing = next.credentials.first(where: { $0.localKey == record.apiKey.trimmed && $0.localBaseURL.caseInsensitiveCompare(record.baseURL.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame }) { duplicate += 1; existingID = existingID ?? existing.id; continue }
                guard seen.insert(record.fingerprint).inserted else {
                    duplicate += 1
                    if let index = next.credentials.firstIndex(where: { $0.fingerprint == record.fingerprint }) {
                        existingID = existingID ?? next.credentials[index].id
                        if next.credentials[index].fillMissingSourceImages(from: record) { restoredImages += 1 }
                    }
                    continue
                }
                while ids.contains(record.id) { record.id = UUID() }
                record.variablePrefix = record.variablePrefix.trimmed.uppercased()
                let requestedPrefix = record.envPrefix
                record.variablePrefix = requestedPrefix
                var suffix = 2
                while prefixes.contains(record.variablePrefix) {
                    let ending = "_" + String(suffix)
                    record.variablePrefix = String(requestedPrefix.prefix(56 - ending.count)) + ending
                    suffix += 1
                }
                ids.insert(record.id); prefixes.insert(record.variablePrefix)
                next.credentials.insert(record, at: 0); added += 1; addedID = record.id
            }
        }
        if success {
            if let id = addedID ?? existingID { selectedID = id }
            showToast(added == 0 && duplicate > 0 ? (restoredImages > 0 ? "Key 已存在，已补回导入图片" : "Key 已存在，已定位已有条目") : "已导入 \(added) 条" + (duplicate > 0 ? "，跳过 \(duplicate) 条重复项" : ""))
        }
        return success
    }

    func toggleFavorite(_ record: Credential) {
        commit { next in if let i = next.credentials.firstIndex(where: { $0.id == record.id }) { next.credentials[i].favorite.toggle() } }
    }
    func archive(_ ids: Set<UUID>, archived: Bool = true) {
        if commit({ next in
            for i in next.credentials.indices where ids.contains(next.credentials[i].id) { next.credentials[i].archived = archived }
        }) { showToast(archived ? "已归档，可在归档中恢复" : "已恢复") }
    }
    // Archives the chosen failed Keys and removes the chosen offline models in one
    // save. Candidates are read again here, so anything that recovered stays.
    @discardableResult func cleanUp(keys: Set<UUID>, models: Set<ModelCleanupItem>) -> Bool {
        let keyIDs = keys.intersection(Set(cleanup.map(\.id)))
        let removals = Dictionary(grouping: models.intersection(Set(modelCleanup)), by: \.credentialID).mapValues { Set($0.map(\.model)) }
        guard !keyIDs.isEmpty || !removals.isEmpty else { return false }
        let removed = removals.values.reduce(0) { $0 + $1.count }
        let success = commit { next in
            for i in next.credentials.indices {
                let id = next.credentials[i].id
                if keyIDs.contains(id) { next.credentials[i].archived = true }
                else if let names = removals[id] { next.credentials[i].removeModels(names); next.credentials[i].updatedAt = Date() }
            }
        }
        if success {
            showToast([keyIDs.isEmpty ? nil : "已归档 \(keyIDs.count) 条 Key", removed == 0 ? nil : "已移除 \(removed) 个模型"].compactMap { $0 }.joined(separator: "，"))
        }
        return success
    }
    func permanentlyDelete(_ record: Credential, expectedUpdatedAt: Date? = nil) {
        guard let current = credentials.first(where: { $0.id == record.id }) else { return }
        guard current.archived, expectedUpdatedAt == nil || current.updatedAt == expectedUpdatedAt else {
            error = "此条目已更新或恢复，未执行永久删除。请重新检查条目后再操作。"; return
        }
        if commit({ $0.credentials.removeAll { $0.id == record.id } }) {
            if selectedID == record.id { selectedID = nil }
            showToast("已永久删除")
        }
    }

    // No session: model calls pick one by endpoint, so image models can wait longer.
    func verify(_ record: Credential, session: URLSession? = nil, testModel: Bool = false) async {
        guard !checking.contains(record.id), !record.archived else { return }
        guard let current = credentials.first(where: { $0.id == record.id }), current.updatedAt == record.updatedAt, !current.archived else { error = "此条目已修改、归档或删除，请重新选择后验证。"; return }
        if testModel, let issue = modelIssue(configuredForUse(current).model, for: current) { error = issue; return }
        checking.insert(record.id); defer { checking.remove(record.id) }
        let snapshot = configuredForUse(current)
        let result = testModel ? await APIClient.probe(snapshot, session: session) : await APIClient.verify(snapshot, session: session ?? APIClient.session)
        guard !Task.isCancelled else { return }
        commit { next in
            guard let i = next.credentials.firstIndex(where: { $0.id == record.id }), configuredForUse(next.credentials[i]).hasSameVerificationConfiguration(as: snapshot), !next.credentials[i].archived else { return }
            if next.credentials[i].modelCatalog == nil, !next.credentials[i].availableModels.isEmpty { next.credentials[i].modelCatalog = ModelCatalog(models: next.credentials[i].availableModels) }
            if testModel {
                next.credentials[i].check = result
                next.credentials[i].connectionCheck = nil
                if !snapshot.model.trimmed.isEmpty { next.credentials[i].recordProbe(result, model: snapshot.model.trimmed, protocolKind: snapshot.inferenceKind) }
            } else {
                next.credentials[i].connectionCheck = result
                // A directory probe cannot undo a successful call to the current model.
                // An explicit authentication failure still supersedes older evidence.
                let passedCall = next.credentials[i].check?.state == .valid && next.credentials[i].check?.requestMethod == "POST"
                if !passedCall || result.state == .invalid { next.credentials[i].check = result }
            }
            if !result.models.isEmpty { next.credentials[i].modelCatalog = ModelCatalog(models: result.models) }
        }
    }
    func fetchModels(_ record: Credential, session: URLSession = APIClient.session) async {
        guard !modelsChecking.contains(record.id), let current = credentials.first(where: { $0.id == record.id }), current.updatedAt == record.updatedAt, !current.archived else { return }
        modelsChecking.insert(record.id); defer { modelsChecking.remove(record.id) }
        let result = await APIClient.fetchModels(current, session: session)
        guard !Task.isCancelled, credentials.contains(where: { $0.hasSameModelCatalogConfiguration(as: current) && !$0.archived }) else { return }
        guard result.state == .valid else { error = result.message; return }
        if commit({ next in
            guard let i = next.credentials.firstIndex(where: { $0.id == record.id }) else { return }
            next.credentials[i].modelCatalog = ModelCatalog(models: result.models)
        }) { showToast(result.models.isEmpty ? "接口返回了空模型列表，可手动填写模型" : "已获取 \(result.models.count) 个模型（当前页）") }
    }
    // Models this Key would call when checking all models, current model first.
    func probeTargets(_ record: Credential) -> [String] {
        guard record.kind != .custom, !record.archived else { return [] }
        let configured = configuredForUse(record)
        // Same rule as modelIssue, with the secrets gathered once for long catalogs.
        let secrets = rendering.allSecrets(credentials) + configured.secretValues
        return Credential.modelChoices(current: configured.model, available: rendering.models(record)).filter { name in
            name.rangeOfCharacter(from: .controlCharacters) == nil && !secrets.contains { name == $0 || ($0.count >= 8 && name.contains($0)) }
        }
    }
    var batchPlan: BatchPlan {
        active.reduce(into: BatchPlan()) { plan, record in plan.add(record, targets: probeTargets(record)) }
    }
    func probePlan(_ record: Credential) -> BatchPlan {
        var plan = BatchPlan(); plan.add(record, targets: probeTargets(record)); return plan
    }
    // Calls every model in this Key's list one at a time, records each duration,
    // and saves once at the end. A stop keeps the results already received.
    func probeModels(_ record: Credential, session: URLSession? = nil, onResult: (() -> Void)? = nil) async {
        guard !checking.contains(record.id) else { return }
        guard let current = credentials.first(where: { $0.id == record.id }), current.updatedAt == record.updatedAt, !current.archived else { error = "此条目已修改、归档或删除，请重新选择后检查。"; return }
        let targets = probeTargets(current)
        guard !targets.isEmpty else { return }
        let snapshot = configuredForUse(current)
        checking.insert(record.id); modelProbeProgress[record.id] = ProbeProgress(done: 0, total: targets.count)
        defer { checking.remove(record.id); modelProbeProgress[record.id] = nil }
        var results: [(model: String, result: CheckResult, configuration: Credential)] = []
        for name in targets {
            guard !Task.isCancelled else { break }
            let configuration = name == snapshot.model.trimmed ? snapshot : configuredForUse(current.probing(name))
            let result = await APIClient.probe(configuration, session: session)
            // A cancelled request says nothing about the model.
            if Task.isCancelled && result.httpStatus == nil { break }
            results.append((name, result, configuration))
            modelProbeProgress[record.id]?.done = results.count; onResult?()
        }
        guard !results.isEmpty else { return }
        commit { next in
            // Results belong to this Key at this address; a rotated Key or a
            // different service discards them, as a single verification does.
            guard let i = next.credentials.firstIndex(where: { $0.id == record.id }), !next.credentials[i].archived, next.credentials[i].fingerprint == current.fingerprint else { return }
            var value = next.credentials[i]
            // Results only; protocol choices stay as the user set them.
            for item in results { value.recordProbe(item.result, model: item.model, protocolKind: item.configuration.inferenceKind) }
            if let own = results.first(where: { $0.model == snapshot.model.trimmed }), configuredForUse(value).hasSameVerificationConfiguration(as: snapshot) {
                if value.modelCatalog == nil, !value.availableModels.isEmpty { value.modelCatalog = ModelCatalog(models: value.availableModels) }
                value.check = own.result; value.connectionCheck = nil
            }
            next.credentials[i] = value
        }
    }
    // Checks every active Key: model services call each listed model, others
    // (and Keys without a model) keep the GET connection check.
    func verifyAll(session: URLSession? = nil) {
        guard !batchRunning else { return }
        let ids = active.map(\.id)
        let plan = Dictionary(uniqueKeysWithValues: active.map { ($0.id, probeTargets($0).count) })
        batchCounts = BatchCounts(keys: ids.count, models: plan.values.reduce(0, +))
        batchRunning = true; updateBatchProgress()
        batchTask = Task {
            await withTaskGroup(of: Void.self) { group in
                var queue = ids[...]
                func launch(_ group: inout TaskGroup<Void>) {
                    guard !Task.isCancelled, let id = queue.popFirst() else { return }
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return }
                        // Read the Key when its turn comes, so edits made while waiting are used.
                        if let item = self.active.first(where: { $0.id == id }) {
                            if self.probeTargets(item).isEmpty { await self.verify(item, session: session) }
                            else { await self.probeModels(item, session: session) { self.batchCounts.modelsDone += 1; self.updateBatchProgress() } }
                        }
                        self.batchCounts.keysDone += 1; self.updateBatchProgress()
                    }
                }
                for _ in 0..<Self.batchKeyConcurrency { launch(&group) }
                while await group.next() != nil { launch(&group) }
            }
            batchRunning = false; batchProgress = ""
        }
    }
    private func updateBatchProgress() {
        let counts = batchCounts
        batchProgress = "检查 \(counts.keysDone) / \(counts.keys)" + (counts.models > 0 ? " · 模型 \(min(counts.modelsDone, counts.models)) / \(counts.models)" : "")
    }
    func cancelBatch() { batchTask?.cancel() }
    func queryBalance(_ record: Credential, session: URLSession = APIClient.session) async {
        guard !balanceChecking.contains(record.id) else { return }
        guard let current = credentials.first(where: { $0.id == record.id }), current.updatedAt == record.updatedAt else { error = "此条目已修改或删除，请重新选择后查询。"; return }
        guard APIClient.balanceIssue(current) == nil else { return }
        balanceChecking.insert(record.id); defer { balanceChecking.remove(record.id) }
        do {
            let value = try await APIClient.balance(current, session: session)
            guard !Task.isCancelled else { return }
            commit { next in
                guard let i = next.credentials.firstIndex(where: { $0.hasSameBalanceConfiguration(as: current) }) else { return }
                next.credentials[i].balanceSummary = value; next.credentials[i].balanceCheckedAt = Date()
            }
        } catch {
            if !Task.isCancelled && credentials.contains(where: { $0.hasSameBalanceConfiguration(as: current) }) { self.error = error.localizedDescription }
        }
    }

    func copy(_ text: String, sensitive: Bool = false) {
        clipboardTask?.cancel(); sensitiveChangeCount = nil
        let board = pasteboard
        board.clearContents(); board.setString(sensitive ? text : displayText(text), forType: .string)
        if sensitive {
            let count = board.changeCount
            sensitiveChangeCount = count
            let deadline = ContinuousClock.now.advanced(by: clipboardLifetime)
            clipboardTask = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled, board.changeCount == count else { return }
                clearSensitiveClipboard()
            }
        }
        showToast(sensitive ? "已复制，45 秒后清空剪贴板" : "已复制")
    }
    func clearSensitiveClipboard() {
        clipboardTask?.cancel()
        if let count = sensitiveChangeCount, pasteboard.changeCount == count { pasteboard.clearContents() }
        sensitiveChangeCount = nil
    }
    func showToast(_ text: String) {
        toastTask?.cancel(); toast = text
        toastTask = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { toast = nil } }
    }
    func restore(_ restored: VaultData) -> Bool {
        guard restored.version == 1, Set(restored.credentials.map(\.id)).count == restored.credentials.count else {
            error = "备份版本不受支持，或包含重复的记录编号。原保险库未改动。"; return false
        }
        if loadError != nil {
            do {
                guard let revision else { throw KeyDockError.message("无法读取原保险库，请重试打开后再恢复。") }
                self.revision = try disk.save(restored, replacing: revision, preservingOriginal: true)
                data = restored; loadError = nil; selectedID = active.first?.id
                synchronizeEnvironment()
                history.retryLoading(); history.synchronize(Set(credentials.map(\.id))); configureHistory(); applyNetworkSettings()
                proxy.update(credentials); if automaticProxy { proxy.start() }; showToast("已从备份恢复，原保险库已保留")
                return true
            } catch is VaultWriteConflict { refreshAfterConflict(); return false }
            catch { self.error = error.localizedDescription; return false }
        }
        var added = 0
        let success = commit { next in
            var fingerprints = Set(next.credentials.map(\.fingerprint))
            var ids = Set(next.credentials.map(\.id))
            var prefixes = Set(next.credentials.map(\.envPrefix))
            var restoredIDs: [UUID: UUID] = [:]
            for var item in restored.credentials {
                let originalID = item.id
                guard fingerprints.insert(item.fingerprint).inserted else {
                    if let index = next.credentials.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
                        restoredIDs[originalID] = next.credentials[index].id
                        _ = next.credentials[index].fillMissingSourceImages(from: item)
                    }
                    continue
                }
                if ids.contains(item.id) { item.id = UUID() }
                if prefixes.contains(item.envPrefix) { item.variablePrefix = item.suggestedPrefix }
                while prefixes.contains(item.envPrefix) { item.variablePrefix = item.suggestedPrefix + "_" + String(UUID().uuidString.prefix(4)) }
                ids.insert(item.id); prefixes.insert(item.envPrefix)
                restoredIDs[originalID] = item.id
                next.credentials.append(item); added += 1
            }
            if next.organizerServiceID == nil, let id = restored.organizerServiceID, let restoredID = restoredIDs[id] {
                next.organizerServiceID = restoredID; next.organizerModel = restored.organizerModel
            }
            if next.prefersLocalImport == nil { next.prefersLocalImport = restored.prefersLocalImport }
            if next.showFullContent == nil { next.showFullContent = restored.showFullContent }
            if next.recordAllBodies == nil { next.recordAllBodies = restored.recordAllBodies }
        }
        if success { showToast("已恢复 \(added) 条，重复项已跳过") }
        return success
    }
}
