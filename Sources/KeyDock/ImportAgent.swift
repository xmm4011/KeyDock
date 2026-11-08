import Foundation

struct AgentImportResult {
    var records: [Credential]
    var summary: String
    var activity: [String]
    var reply = ""
}

@MainActor final class ImportAgentHost {
    var redacted: RedactedImport
    var original: String
    var credentialSource: String
    var images: [ImportImage]
    let workspace: URL
    let session: URLSession
    private let documentSession: URLSession
    var source: String
    var documents: [String: String] = [:]
    var documentTexts: [String] = []
    var documentIssues: [String] = []
    var candidates: [Credential] = []
    var activity: [String] = []
    var summary = ""
    var finished = false
    var verificationCalls = 0
    var catalogAttempts = Set<String>()
    var allowLocalDocuments = false
    var organizerSecret = ""
    var organizerOtherSecrets: [String] = []
    var providerReferences: [ProviderPreset] { ProviderPreset.matches(in: credentialSource) }
    private var presetEvidence: String {
        let presets = providerReferences
        // A generic EOS mention does not authorize guessing the Key's region.
        let allowed = presets.filter { !$0.isBCE || presets.filter(\.isBCE).count == 1 }
        return allowed.flatMap { item in item.protocols.map(item.connectionBase) }.joined(separator: "\n")
    }
    func validateSupplement(_ paste: ImportPaste) throws {
        guard (credentialSource + "\n" + paste.text).utf8.count <= 100_000 else { throw KeyDockError.message("本次累计文字不能超过 100 KB。") }
        try ImportImage.validate(images + paste.images.filter { image in !images.contains(where: { $0.fingerprint == image.fingerprint }) })
    }
    func supplement(_ paste: ImportPaste) async throws -> (String, [ImportImage]) {
        try validateSupplement(paste)
        let addedImages = paste.images.filter { image in !images.contains(where: { $0.fingerprint == image.fingerprint }) }
        let ocr = try await ImportImage.recognizedText(in: addedImages)
        let addition = paste.text + (ocr.isEmpty ? "" : "\n[补充图片文字索引，可能有误]\n" + ocr)
        original += "\n" + paste.text; credentialSource += "\n" + addition; source += "\n" + addition
        images += addedImages
        redacted = RedactedImport(credentialSource, preserving: redacted.keys)
        activity.append("已收到补充资料，继续整理")
        return (addition.replacingSecrets(Dictionary(redacted.keys.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })), addedImages)
    }
    init(original: String, imageText: String, images: [ImportImage], workspace: URL, session: URLSession) {
        self.original = original; self.images = images; self.workspace = workspace; self.session = session
        // Public document sites may require an anonymous visitor cookie across
        // redirects. Keep it task-local, separate from API authentication.
        let configuration = session.configuration
        configuration.httpCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage
        configuration.httpShouldSetCookies = true; configuration.httpCookieAcceptPolicy = .always
        configuration.urlCredentialStorage = nil; configuration.httpAdditionalHeaders = nil; configuration.urlCache = nil
        documentSession = URLSession(configuration: configuration, delegate: APIClient.delegate, delegateQueue: nil)
        source = original + (imageText.isEmpty ? "" : "\n[图片文字索引，可能有误]\n" + imageText)
        credentialSource = source
        redacted = RedactedImport(source)
    }
    deinit { documentSession.invalidateAndCancel() }
    func call(_ name: String, args: [String: Any]) async -> [String: Any] {
        do {
            try Task.checkCancellation()
            switch name {
            case "lookup_provider":
                let query = (args["query"] as? String ?? "").trimmed.lowercased()
                let matches = query.isEmpty ? providerReferences : ProviderPreset.all.filter { $0.id == query || $0.name.lowercased().contains(query) }
                return ["ok": true, "references": matches.map(\.reference), "matched_to_material": providerReferences.map(\.id),
                        "instruction": "参考资料不是调用验证。仅使用与用户地址、地域、账户相符的配置；地域不明时不能擅自挑选。优先使用实际 WorkspaceId、部署 ID，不编造模型列表。"]
            case "fetch_document": return try await fetchDocument(args["url"] as? String ?? "")
            case "propose_credential": return try propose(args)
            case "verify_credential": return try await verify(args)
            case "list_models":
                guard let id = args["id"] as? String, let index = candidates.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else { throw KeyDockError.message("请先创建候选配置。") }
                return try await loadCatalog(index)
            case "finish_import":
                let ids = args["ids"] as? [String] ?? []
                guard !ids.isEmpty, ids.allSatisfy({ id in candidates.contains(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) }) else { throw KeyDockError.message("请提交现有候选编号。") }
                // Keep all drafts: an agent may not silently drop an unresolved credential.
                candidates = reviewResult().records
                var catalogNotes: [String] = []
                for index in candidates.indices where candidates[index].kind != .custom && (candidates[index].modelCatalog == nil || candidates[index].modelCatalog?.source == "资料") && candidates[index].connectionIssue == nil && candidates[index].check?.state != .invalid && !catalogAttempts.contains(candidates[index].fingerprint) {
                    guard verificationCalls < 30 else { catalogNotes.append("部分模型列表未获取：本次探测次数已达上限，可稍后手动刷新。"); break }
                    let result = try await loadCatalog(index)
                    if result["ok"] as? Bool != true {
                        catalogNotes.append(candidates[index].title + (candidates[index].modelCatalog?.source == "资料" ? "：接口未提供目录，保留资料中的模型；调用权限需单独验证。" : "：未获取模型列表，保留当前模型；可按服务文档或稍后刷新。"))
                    }
                }
                summary = safe(args["summary"] as? String ?? "已完成整理")
                let missingCatalogs = candidates.filter { $0.kind != .custom && $0.modelCatalog == nil }.count
                if catalogNotes.isEmpty && missingCatalogs > 0 { catalogNotes.append("\(missingCatalogs) 条记录未获取模型列表；保留已知模型，可按服务文档或稍后刷新。") }
                if !catalogNotes.isEmpty { summary += "\n" + catalogNotes.joined(separator: "\n") }
                if !documentIssues.isEmpty { summary += "\n" + documentIssues.joined(separator: "\n") }
                finished = true
                return ["ok": true, "verified": candidates.filter { $0.check?.state == .valid }.count, "unresolved": candidates.filter { $0.check?.state != .valid }.count]
            default: throw KeyDockError.message("未知宿主工具。")
            }
        } catch {
            let message = safe((error as? KeyDockError)?.localizedDescription ?? (Task.isCancelled ? "任务已停止。" : "操作未完成，请根据已有结果调整后重试。"))
            activity.append(message)
            return ["ok": false, "error": message]
        }
    }
    private func loadCatalog(_ index: Int) async throws -> [String: Any] {
        guard verificationCalls < 30 else { throw KeyDockError.message("本次探测次数已达上限。") }
        verificationCalls += 1
        let record = candidates[index]
        catalogAttempts.insert(record.fingerprint)
        let result = await APIClient.fetchModels(record, session: session)
        try Task.checkCancellation()
        guard let current = candidates.firstIndex(where: { $0.id == record.id && $0.fingerprint == record.fingerprint }) else { throw KeyDockError.message("候选配置已改变，请重新获取模型列表。") }
        let models = result.models.filter { safe($0) == $0 }
        if result.state == .valid, !models.isEmpty || candidates[current].modelCatalog == nil { candidates[current].modelCatalog = ModelCatalog(models: models) }
        activity.append("获取模型列表：" + (result.state == .valid ? "\(models.count) 个（接口当前页）" : safe(result.message)))
        return ["ok": result.state == .valid, "models": models, "message": safe(result.message)]
    }
    func safe(_ text: String) -> String {
        let models = Set(candidates.map(\.model)), keys = Set(candidates.flatMap(\.secretValues))
        return LogRedaction.text(text, secret: organizerSecret, otherSecrets: redacted.keys.values.filter { !models.contains($0) || keys.contains($0) } + Array(keys) + organizerOtherSecrets)
    }
    func reviewResult(reply: String = "") -> AgentImportResult {
        var records = candidates
        for index in records.indices {
            for field in [\Credential.name, \.provider, \.purpose, \.notes, \.tags, \.docsURL] { records[index][keyPath: field] = safe(records[index][keyPath: field]) }
            records[index].source = credentialSource
            if let template = records[index].callTemplate, safe(template.body) != template.body {
                records[index].callTemplate = nil; records[index].check = nil
                records[index].notes += "\n调用示例混入了其他凭据，已移除，请修正后重新验证。"
            }
        }
        return AgentImportResult(records: records, summary: safe(summary), activity: activity.map(safe), reply: safe(reply))
    }
    func propose(_ args: [String: Any]) throws -> [String: Any] {
        let key = args["api_key"] as? String ?? ""
        let fromVision = !images.isEmpty && !key.isEmpty && key.utf8.count <= 8192 && !key.contains(where: \.isWhitespace) && !key.hasPrefix("KEYDOCK_SECRET_") && !source.contains(key) && !documentTexts.contains(where: { $0.contains(key) })
        guard redacted.keys[key] != nil || (!key.isEmpty && credentialSource.contains(key) && !key.hasPrefix("KEYDOCK_SECRET_")) || fromVision else {
            throw KeyDockError.message("密钥必须来自用户提供的文字或图片，不接受文档示例或猜测的值。")
        }
        let data = try JSONSerialization.data(withJSONObject: [args])
        guard data.count <= 64_000, let record = try AIOrganizer.records(from: String(decoding: data, as: UTF8.self), redacted: redacted, fullSource: source + "\n" + presetEvidence, hasImages: !images.isEmpty).first else { throw KeyDockError.message("候选配置无效。") }
        var candidate = record
        if let auth = args["auth"] as? String, let value = AuthKind(rawValue: auth) { candidate.auth = value }
        candidate.extraHeaders = redacted.restore(args["extra_headers"] as? String ?? "")
        if let preset = ProviderPreset.matching(candidate.baseURL) {
            if args["auth"] == nil { candidate.auth = preset.authentication(candidate.kind) }
            if candidate.docsURL.isEmpty { candidate.docsURL = preset.docs[0] }
            candidate.verificationURL = preset.catalogURL ?? ""
            candidate.balanceURL = preset.balanceURL ?? ""; candidate.balancePath = preset.balancePath; candidate.balanceUnit = preset.balanceUnit
        }
        candidate.modelCatalog = candidates.first(where: { $0.fingerprint == candidate.fingerprint })?.modelCatalog
        if let models = args["models"] as? [String] {
            guard models.count <= 1000 else { throw KeyDockError.message("资料中的模型列表过长，请分批核对。") }
            let evidence = credentialSource + "\n" + documentTexts.joined(separator: "\n")
            let values = Array(Set(models.map { redacted.restore($0).trimmed }.filter { !$0.isEmpty })).sorted()
            guard values.allSatisfy({ evidence.contains($0) && candidate.modelIssue($0) == nil && safe($0) == $0 && !$0.contains("KEYDOCK_SECRET_") }) else { throw KeyDockError.message("模型列表含未经资料核对的名称或敏感片段，请使用正文中实际出现的模型 ID。") }
            if !values.isEmpty, candidate.modelCatalog == nil || candidate.modelCatalog?.source == "资料" {
                candidate.modelCatalog = ModelCatalog(models: values, source: "资料")
            }
        }
        candidate.source = credentialSource
        if let sections = args["notes_sections"] as? [String: Any] {
            candidate.notes = Self.structuredNotes(sections)
        }
        candidate.name = safe(candidate.name); candidate.provider = safe(candidate.provider)
        candidate.purpose = safe(candidate.purpose); candidate.notes = safe(candidate.notes); candidate.tags = safe(candidate.tags)
        if let id = args["id"] as? String, let index = candidates.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) {
            guard candidates[index].apiKey == candidate.apiKey else { throw KeyDockError.message("不能把已有候选改为另一个 Key，请为不同 Key 新建候选。") }
            candidate.id = candidates[index].id; candidates[index] = candidate
        } else if let index = candidates.firstIndex(where: { $0.fingerprint == candidate.fingerprint }) {
            candidate.id = candidates[index].id; candidates[index] = candidate
        } else {
            guard candidates.count < 30 else { throw KeyDockError.message("本次候选过多，请分批导入。") }; candidates.append(candidate)
        }
        let issue = candidate.baseURL.isEmpty ? "基础地址不在已提供或已获取的资料中，已留空；请先读取对应文档后修正。" : ""
        activity.append("已整理：" + candidate.title)
        return ["ok": true, "id": candidate.id.uuidString, "base_url": candidate.baseURL, "model": candidate.model, "issues": issue, "verified": false]
    }
    static func structuredNotes(_ sections: [String: Any]) -> String {
        var seen = Set<String>()
        return [("access", "接入要点"), ("limits", "使用限制"), ("pending", "待确认")].compactMap { key, title in
            let lines = (sections[key] as? [String] ?? []).map { $0.trimmed }.filter { !$0.isEmpty && seen.insert($0).inserted }
            return lines.isEmpty ? nil : "【" + title + "】\n" + lines.map { "• " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    func verify(_ args: [String: Any]) async throws -> [String: Any] {
        guard let id = args["id"] as? String, let index = candidates.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else { throw KeyDockError.message("请先创建候选，再使用返回的编号验证。") }
        guard verificationCalls < 30 else { throw KeyDockError.message("本次验证请求已达到上限，请保留问题并结束本次任务。") }
        verificationCalls += 1
        var candidate = candidates[index]
        guard !candidate.baseURL.isEmpty else { throw KeyDockError.message("基础地址为空，请先补全候选配置。") }
        var restored = args
        for field in ["body", "headers"] { if let value = args[field] as? String { restored[field] = redacted.restore(value) } }
        let (request, template) = try AgentVerification.request(candidate, arguments: restored)
        if let body = request.httpBody, safe(String(decoding: body, as: UTF8.self)) != String(decoding: body, as: UTF8.self) { throw KeyDockError.message("验证正文包含敏感片段，请使用文档指定的 Header 鉴权。") }
        let (data, response) = try await AgentVerification.boundedData(for: request, session: session, limit: 1_048_576)
        try Task.checkCancellation()
        var check = AgentVerification.classify(data, response: response, record: candidate, method: request.httpMethod ?? "GET", endpoint: request.url?.absoluteString ?? "")
        check.request = CheckedRequest(request)
        candidate.check = check
        if check.state == .valid, let template {
            guard safe(template.body) == template.body else { throw KeyDockError.message("调用示例含真实敏感片段，请改用 Header 鉴权，不在正文中嵌入密钥。") }
            candidate.callTemplate = template
            candidate.kind = candidate.inferenceKind
            if let headers = restored["headers"] as? String, !headers.isEmpty { candidate.extraHeaders += (candidate.extraHeaders.isEmpty ? "" : "\n") + headers }
        }
        candidates[index] = candidate
        let status = "HTTP \(response.statusCode) · " + check.state.title
        activity.append(candidate.title + "：" + status)
        return ["ok": check.state == .valid, "id": id, "state": check.state.rawValue, "status": response.statusCode, "message": safe(check.message),
                "request": ["method": request.httpMethod ?? "GET", "url": safe(request.url?.absoluteString ?? ""), "body": safe(String(decoding: request.httpBody ?? Data(), as: UTF8.self))],
                "response_excerpt": safe(String(decoding: data.prefix(8192), as: UTF8.self))]
    }
    func fetchDocument(_ address: String) async throws -> [String: Any] {
        guard documents.count < 8 else { throw KeyDockError.message("本次已获取多份文档，请先使用现有资料完成任务。") }
        guard safe(address) == address else { throw KeyDockError.message("文档地址中包含敏感片段，不会发送。") }
        let known = Set(ImportParser.urls(in: source) + providerReferences.flatMap(\.docs))
        guard known.contains(address) else { throw KeyDockError.message("请只读取用户资料或已获取文档中实际出现的链接，不猜测文档地址。") }
        if let file = documents[address] { return ["ok": true, "path": file, "cached": true] }
        var url = try documentURL(address)
        for attempt in 0..<8 {
            var request = URLRequest(url: url); request.timeoutInterval = 20
            request.setValue("text/html, text/plain, application/json, application/pdf", forHTTPHeaderField: "Accept")
            let (data, response) = try await AgentVerification.boundedData(for: request, session: documentSession, limit: 1_500_000)
            if (300..<400).contains(response.statusCode), attempt < 7, let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: url)?.absoluteURL {
                url = try documentURL(target.absoluteString); continue
            }
            guard (200..<300).contains(response.statusCode) else {
                let note = "文档未读到正文：HTTP \(response.statusCode)（\(url.host ?? "")）"
                documentIssues.append(note); throw KeyDockError.message(note)
            }
            let isPDF = response.mimeType == "application/pdf"
            let name = "document-\(documents.count + 1)." + (isPDF ? "pdf" : "txt")
            let file = workspace.appendingPathComponent(name)
            var readablePath = isPDF ? name + ".txt" : name
            if isPDF {
                try data.write(to: file, options: [.atomic])
                // PDF text is extracted locally so read/bash can analyze it without extra installs.
                let text = AgentPDF.text(data)
                guard !text.trimmed.isEmpty else { throw KeyDockError.message("PDF 没有可提取的文字，请添加文档截图或可复制的正文。") }
                try Data(safe(text).utf8).write(to: workspace.appendingPathComponent(name + ".txt"))
                addDocumentEvidence(text)
            } else {
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                try Data(safe(text).utf8).write(to: file, options: [.atomic])
                let feishu = url.host?.lowercased().hasSuffix(".feishu.cn") == true
                let body = feishu ? DocumentText.body(text) : text
                addDocumentEvidence(body)
                if feishu, !body.trimmed.isEmpty, body != text {
                    readablePath = name + ".body.txt"
                    try Data(safe(body).utf8).write(to: workspace.appendingPathComponent(readablePath), options: [.atomic])
                }
            }
            documents[address] = readablePath; activity.append("已获取文档：" + (url.host ?? ""))
            return ["ok": true, "path": readablePath, "raw_path": name, "url": address, "bytes": data.count,
                    "instruction": "这是获取到的文件，尚不代表已阅读。请充分读取相关正文与示例。飞书正文可能位于 clientVars.data.block_map，可编写临时代码解析 JSON；嵌入表格需要继续读取。不要执行网页脚本。只有登录页或空壳时明确报告，不要声称读懂文档。"]
        }
        throw KeyDockError.message("文档跳转次数过多。")
    }
    func documentURL(_ address: String) throws -> URL {
        let url = try APIClient.safeURL(address), host = url.host?.lowercased() ?? ""
        guard safe(address) == address else { throw KeyDockError.message("文档链接包含敏感内容。") }
        let privateHost = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.contains(":") || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") || host == "0.0.0.0" || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
        guard allowLocalDocuments || !privateHost else { throw KeyDockError.message("文档读取不访问本机和内网地址，请粘贴相关文档正文。") }
        return url
    }
    private func addDocumentEvidence(_ text: String) {
        documentTexts.append(text)
        let normalized = text.replacingOccurrences(of: #"\/"#, with: "/").replacingOccurrences(of: "&amp;", with: "&")
        source += "\n" + Array(Set(ImportParser.urls(in: normalized))).prefix(2000).joined(separator: "\n")
    }
}

@MainActor enum ImportAgent {
    static func run(raw: String, reviewedText: String? = nil, service: Credential, model: String, images: [ImportImage], session: URLSession = APIClient.session,
                    allowLocalDocuments: Bool = false, interaction: AgentInteraction? = nil, onSupplement: @escaping (ImportPaste) -> Void = { _ in }, progress: @escaping (String) -> Void) async throws -> AgentImportResult {
        let service = ProviderPreset.configuration(service)
        guard service.kind != .custom, !model.trimmed.isEmpty else { throw KeyDockError.message("请选择支持工具调用的可信模型。") }
        if let issue = service.connectionIssue { throw KeyDockError.message("整理服务：" + issue) }
        if let issue = service.modelIssue(model) { throw KeyDockError.message(issue) }
        guard !service.archived, !service.expired else { throw KeyDockError.message("整理服务已归档或到期，请先恢复或更换可用的 Key。") }
        guard raw.utf8.count <= 100_000 else { throw KeyDockError.message("请将输入文字控制在 100 KB 以内。") }
        guard (reviewedText?.utf8.count ?? 0) <= 100_000 else { throw KeyDockError.message("发送预览中的文字不能超过 100 KB。") }
        try ImportImage.validate(images)
        interaction?.begin()
        let resources = try AgentWorker.resources()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Agent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let imageText = try await ImportImage.recognizedText(in: images)
        let host = ImportAgentHost(original: raw, imageText: imageText, images: images, workspace: workspace, session: session)
        host.organizerSecret = service.apiKey
        host.organizerOtherSecrets = service.secretValues
        host.allowLocalDocuments = allowLocalDocuments
        let privateProxy = LocalProxy(port: 0); privateProxy.update([service]); privateProxy.start()
        defer { privateProxy.stop() }
        for _ in 0..<200 { if privateProxy.running { break }; try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
        guard let port = privateProxy.listeningPort, privateProxy.running else { throw KeyDockError.message("无法建立本机 Agent 连接。") }
        let worker = try AgentWorker(workspace: workspace, runtime: resources.runtime, node: resources.node)
        let timeout = Task {
            var activeSeconds = 0
            while !Task.isCancelled && activeSeconds < 600 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if interaction?.isWaiting != true { activeSeconds += 1 }
                if !worker.process.isRunning { interaction?.cancel(error: KeyDockError.message("Agent 运行时意外退出，当前资料和结果已保留。")); return }
            }
            if !Task.isCancelled { worker.requestCancel(); interaction?.cancel(error: KeyDockError.message("本次整理已达到运行时间上限，当前资料和结果已保留。")) }
        }
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler {
                var text = reviewedText ?? host.redacted.text
                // Reviewed text can only reduce context, never restore real known secrets.
                text = text.replacingSecrets(Dictionary(host.redacted.keys.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a }))
                if !service.apiKey.isEmpty { text = text.replacingOccurrences(of: service.apiKey, with: "[整理服务密钥已隐藏]") }
                try await worker.send(["type": "start", "task": "整理这些服务凭据。根据实际资料自行规划，充分阅读相关接口文档，必要时编写并运行代码，修正配置并完成真实验证，最后提交可供确认的结果。",
                                       "text": text, "providerReferences": host.providerReferences.map(\.reference), "service": ["kind": service.kind.rawValue, "model": model, "baseURL": "http://127.0.0.1:\(port)/s/" + service.routeID, "alias": service.localKey, "requiresOutputLimit": APIClient.requiresOutputLimit(service, path: service.kind == .anthropic ? "messages" : ""),
                                                                   "providerHint": ["api.deepseek.com": "deepseek", "api.moonshot.cn": "moonshot", "api.moonshot.ai": "moonshot", "api.openai.com": "openai"][URL(string: service.baseURL)?.host?.lowercased() ?? ""] ?? "keydock"],
                                       "images": images.map { ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mimeType] }])
                var settled = false, finalReply = ""
                @MainActor func ask(_ question: AgentQuestion) async throws -> (String, [ImportImage])? {
                    guard let interaction else { throw KeyDockError.message(question.question) }
                    host.activity.append("Agent：" + question.question + (question.reason.isEmpty ? "" : "\n" + question.reason))
                    progress("等待你的回复")
                    guard let paste = try await interaction.ask(question, validate: host.validateSupplement) else { return nil }
                    onSupplement(paste)
                    let result = try await host.supplement(paste)
                    host.activity.append("你的回复：" + result.0 + (result.1.isEmpty ? "" : "（附 \(result.1.count) 张图片）"))
                    progress("已收到补充，继续整理")
                    return (result.0.replacingOccurrences(of: service.apiKey.isEmpty ? "\u{0}" : service.apiKey, with: "[整理服务密钥已隐藏]"), result.1)
                }
                for try await line in worker.events {
                    try Task.checkCancellation()
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = message["type"] as? String else { throw KeyDockError.message("Agent 返回了无法识别的内容。") }
                    switch type {
                    case "progress": let label = message["label"] as? String ?? "正在处理"; progress(label)
                    case "host_tool":
                        let name = message["name"] as? String ?? "", args = message["args"] as? [String: Any] ?? [:]
                        let result: [String: Any]
                        if name == "ask_user" {
                            let question = AgentQuestion(question: host.safe(args["question"] as? String ?? "请补充接口资料。"), reason: host.safe(args["reason"] as? String ?? ""), items: (args["items"] as? [String] ?? []).map(host.safe), example: host.safe(args["example"] as? String ?? ""))
                            guard let reply = try await ask(question) else { throw CancellationError() }
                            result = ["ok": true, "reply": reply.0, "images": reply.1.map { ["type":"image", "data":$0.data.base64EncodedString(), "mimeType":$0.mimeType] }]
                        } else { result = await host.call(name, args: args) }
                        try Task.checkCancellation()
                        try await worker.send(["type": "tool_result", "id": message["id"] as? String ?? "", "result": result])
                    case "failed": throw KeyDockError.message(host.safe(message["message"] as? String ?? "Agent 未完成，输入已保留。"))
                    case "settled":
                        finalReply = host.safe(message["text"] as? String ?? "").trimmed
                        if host.finished && !host.candidates.isEmpty && host.candidates.allSatisfy({ $0.check?.state == .valid }) { settled = true }
                        else {
                            let explanation = finalReply.isEmpty && host.finished ? host.summary : finalReply
                            let failure = host.safe(message["error"] as? String ?? "").trimmed
                            let actualReply = [explanation, failure.isEmpty ? "" : "服务返回：" + failure].filter { !$0.isEmpty }.joined(separator: "\n\n")
                            if message["budgetExceeded"] as? Bool == true { throw KeyDockError.message(actualReply) }
                            guard !actualReply.isEmpty else { throw KeyDockError.message("模型没有提交整理结果，也没有返回文字说明。请检查模型是否支持工具调用；资料已保留。") }
                            // Every unfinished turn shows the actual reply, not just questions.
                            let canReview = host.finished && !host.candidates.isEmpty
                            if let reply = try await ask(AgentQuestion(question: actualReply, canContinueWithoutReply: true, canReview: canReview)) {
                                host.finished = false
                                try await worker.send(["type":"continue", "text":reply.0, "images":reply.1.map { ["type":"image", "data":$0.data.base64EncodedString(), "mimeType":$0.mimeType] }])
                            } else { settled = true }
                        }
                    default: break
                    }
                    if settled { break }
                }
                try Task.checkCancellation()
                guard settled, host.finished, !host.candidates.isEmpty else { throw KeyDockError.message("整理任务意外中断，资料已保留，可重试。") }
                await worker.shutdown()
                return host.reviewResult(reply: finalReply)
            } onCancel: { worker.requestCancel() }
        } catch {
            await worker.shutdown()
            if !Task.isCancelled && !(error is CancellationError) {
                let message = host.safe((error as? KeyDockError)?.localizedDescription ?? "整理连接意外中断，资料已保留。")
                var result = host.reviewResult(reply: interaction?.lastReply?.question ?? "")
                if result.summary.isEmpty { result.summary = message }
                interaction?.fail(message, recovery: result.records.isEmpty ? nil : result)
            }
#if KEYDOCK_CHECKS
            if !worker.diagnostics.isEmpty { print("AGENT FIXTURE DIAGNOSTICS", worker.diagnostics) }
#endif
            throw error
        }
    }
}

import PDFKit
private enum AgentPDF {
    static func text(_ data: Data) -> String { PDFDocument(data: data)?.string ?? "" }
}
