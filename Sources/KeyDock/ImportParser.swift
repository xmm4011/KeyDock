import Foundation

enum ImportParser {
    static func parse(_ input: String) -> [Credential] {
        if let data = input.trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            let structured = fromJSON(json)
            if !structured.isEmpty { return unique(structured) }
        }
        let text = input.replacingOccurrences(of: "\\\r\n", with: " ").replacingOccurrences(of: "\\\n", with: " ")
        var blocks: [String] = [], current: [String] = []
        var currentKeys = Set<String>()
        var currentHasEndpoint = false
        for line in text.components(separatedBy: .newlines) {
            if Task.isCancelled { return [] }
            let clean = line.trimmed
            let hasKey = !currentKeys.isEmpty
            let newBase = !clean.matches(#"(?i)^(?:export\h+)?[\"']?(?:[A-Z0-9_]*BASE_URL|base[_ -]?url|endpoint|接口地址|服务地址|地址)[\"']?\h*[:：=]"#).isEmpty
            let newName = !clean.matches(#"(?i)^[\"']?(?:name|名称|服务名(?:称)?|项目)[\"']?\h*[:：=]"#).isEmpty
            let newHeading = clean.hasPrefix("##") || clean == "---" || clean == "==="
            if hasKey && (clean.isEmpty || (newBase && currentHasEndpoint && currentKeys.count == 1) || newHeading || newName) {
                blocks.append(current.joined(separator: "\n")); current = []; currentKeys.removeAll(); currentHasEndpoint = false
            }
            if !clean.hasPrefix("```") && clean != "---" && clean != "===" {
                current.append(line); currentKeys.formUnion(keys(in: line))
                if urls(in: line).contains(where: { !isDocsURL($0) }) { currentHasEndpoint = true }
            }
        }
        if !current.joined(separator: "").trimmed.isEmpty { blocks.append(current.joined(separator: "\n")) }
        var entries: [Credential] = []
        var pending = ""
        for block in blocks {
            if keys(in: block).isEmpty { pending += (pending.isEmpty ? "" : "\n") + block; continue }
            entries += parseBlock(pending + "\n" + block)
            pending = ""
        }
        if !pending.trimmed.isEmpty {
            if !entries.isEmpty { entries[entries.count - 1].notes += "\n" + pending.trimmed }
            else if !input.trimmed.isEmpty { entries = parseBlock(input, allowEmptyKey: true) }
        }
        return unique(entries)
    }

    static func keys(in text: String) -> [String] {
        // A shell parameter operator (API_KEY:-fallback) is not a key label.
        // Known literal key formats below still detect real keys inside defaults.
        let labeledText = text.replacingOccurrences(of: #"\$\{[^}\r\n]*\}"#, with: "", options: .regularExpression)
        var values = labeledText.matches(#"(?i)(?:[\"']?(?:[A-Z0-9_]*API[_-]?KEY|apiKey|access[_-]?token|token|密钥|秘钥|API\h*Key)[\"']?\h*[:：=]\h*[\"']?)([^\s\"'`,;，；}]+)"#, group: 1)
        values += text.matches(#"(?i)(?:Bearer\h+|x-api-key\h*:\h*|api-key\h*:\h*|x-goog-api-key\h*:\h*)([^\s\"'`,;}]+)"#, group: 1)
        values += text.matches(#"\b(?:sk-[A-Za-z0-9_-]{8,}|AIza[A-Za-z0-9_-]{15,})\b"#)
        values += text.matches(#"[?&]key=([^\s&\"']+)"#, group: 1)
        var seen = Set<String>()
        return values.map { $0.trimmed }.filter { value in
            !value.isEmpty && !value.hasPrefix("$") && !value.hasPrefix("<") && !["your_api_key", "your-api-key", "xxx", "密钥", "your_key"].contains(value.lowercased()) && seen.insert(value).inserted
        }
    }

    static func urls(in text: String) -> [String] {
        text.matches(#"https?://[^\s<>\"'`\\\[\]{}]+"#).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",，。;；)）")) }
    }

    static func parseBlock(_ text: String, allowEmptyKey: Bool = false) -> [Credential] {
        let keys = keys(in: text)
        guard !keys.isEmpty || allowEmptyKey else { return [] }
        let urls = urls(in: text)
        let explicitBase = label(["base[_ -]?url", "[A-Z_]*BASE_URL", "endpoint", "接口地址", "服务地址", "地址"], in: text)
        let docs = label(["docs?[_ -]?url", "接口文档", "文档(?:地址)?"], in: text)
        let docsURL = Self.urls(in: docs).first ?? urls.first { isDocsURL($0) } ?? ""
        let candidates = urls.filter { $0 != docsURL && !isDocsURL($0) }
        var base = Self.urls(in: explicitBase).first ?? candidates.first ?? ""
        let ambiguous = keys.count > 1 && Set(candidates.map(normalizeBase)).count > 1
        if ambiguous { base = "" }
        base = normalizeBase(base)
        let name = label(["name", "名称", "服务名(?:称)?", "项目"], in: text)
        // A standalone title is useful; credential-looking lines are never used as titles.
        let safeHeading = text.components(separatedBy: .newlines).map { $0.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.first { line in
            !line.isEmpty && line.count < 65 && !line.contains(":") && !line.contains("：") && !line.contains("=") && !line.hasPrefix("curl") && !line.hasPrefix("http") && Self.keys(in: line).isEmpty
        }
        let originalSource = text.trimmed
        return (keys.isEmpty ? [""] : keys).enumerated().map { index, key in
            var record = Credential()
            record.apiKey = key
            record.baseURL = base
            record.docsURL = docsURL
            record.source = originalSource
            record.curl = text.components(separatedBy: .newlines).filter { $0.trimmed.hasPrefix("curl ") }.joined(separator: "\n")
            record.provider = provider(base: base, text: text)
            record.name = name.isEmpty ? (safeHeading ?? record.provider) : name
            if record.name.isEmpty { record.name = URL(string: base)?.host ?? "导入的服务" }
            if keys.count > 1 { record.name += " · \(index + 1)" }
            record.purpose = label(["purpose", "用途", "场景", "用来"], in: text)
            record.notes = label(["notes?", "备注", "说明"], in: text)
            record.tags = label(["tags?", "标签"], in: text)
            record.model = label(["model", "模型"], in: text)
            if record.model.isEmpty { record.model = text.matches(#"[\"']model[\"']\s*:\s*[\"']([^\"']+)"#, group: 1).first ?? "" }
            if ambiguous { record.notes += "\n同一段包含多组密钥和地址，请手动确认每条 Base URL。" }
            if text.lowercased().contains("anthropic-version") || record.provider == "Anthropic" {
                record.kind = .anthropic; record.auth = .xAPIKey
            } else if text.lowercased().contains("x-goog-api-key") || base.contains("generativelanguage.googleapis.com") || key.hasPrefix("AIza") {
                record.kind = .gemini; record.auth = .googleKey
            } else if text.lowercased().contains("x-api-key") { record.auth = .xAPIKey; record.kind = .custom }
            else if !text.matches(#"(?i)(?:[\"']api-key\s*:|\bapi-key\s*:)"#).isEmpty { record.auth = .apiKey }
            let curlHeaders = headers(in: text)
            let authorization = curlHeaders.first { $0.key.lowercased() == "authorization" }?.value ?? ""
            if urls.contains(where: { URL(string: $0)?.path.hasSuffix("/chat/completions") == true }) { record.kind = .compatible }
            if urls.contains(where: { URL(string: $0)?.path.hasSuffix("/responses") == true }) { record.kind = .responses }
            if urls.contains(where: { URL(string: $0)?.path.hasSuffix("/messages") == true }) { record.kind = .anthropic }
            if authorization.lowercased().hasPrefix("bearer ") { record.auth = .bearer }
            if ["阿里云", "腾讯云", "第三方"].contains(record.provider) && !base.contains("/v1") && record.model.isEmpty { record.kind = .custom }
            record.extraHeaders = headers(in: text).filter { name, _ in
                !["authorization", "x-api-key", "api-key", "x-goog-api-key", "content-type"].contains(name.lowercased())
            }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            let dateText = label(["expires?(?:[_ -]?at)?", "到期(?:时间|日期)?", "有效期至"], in: text)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = .current
            if let date = formatter.date(from: String(dateText.prefix(10))) {
                record.expiresAt = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date)
            }
            return record
        }
    }

    static func normalizeBase(_ value: String) -> String {
        guard var components = URLComponents(string: value.trimmed), components.host != nil else { return value.trimmed }
        components.query = nil; components.fragment = nil
        components.path = components.path.replacingOccurrences(of: #"/(?:chat/completions|completions|responses|messages|models(?:/[^/]+:generateContent)?)?/?$"#, with: "", options: .regularExpression)
        return (components.string ?? value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func provider(base: String, text: String) -> String {
        if let preset = ProviderPreset.matching(base) { return preset.providerLabel }
        let names = [("deepseek", "DeepSeek"), ("anthropic", "Anthropic"), ("claude", "Anthropic"), ("openai", "OpenAI"), ("gemini", "Google Gemini"), ("generativelanguage", "Google Gemini"), ("siliconflow", "硅基流动"), ("dashscope", "通义千问"), ("maas.aliyuncs.com", "通义千问"), ("moonshot", "Kimi"), ("baichuan", "百川"), ("bigmodel", "智谱"), ("volces", "豆包 / 火山方舟"), ("千问", "通义千问"), ("百炼", "通义千问"), ("qwen", "通义千问"), ("豆包", "豆包 / 火山方舟"), ("doubao", "豆包 / 火山方舟"), ("kimi", "Kimi"), ("百川", "百川")]
        for content in [base.lowercased(), text.lowercased()] {
            for (needle, name) in names where content.contains(needle) { return name }
        }
        return ""
    }

    private static func label(_ names: [String], in text: String) -> String {
        let pattern = "(?im)^\\h*(?:export\\h+)?[\\\"']?(?:" + names.joined(separator: "|") + ")[\\\"']?\\h*[:：=]\\h*[\\\"']?([^\\n\\r]+)"
        return (text.matches(pattern, group: 1).first ?? "").trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"',，"))
    }

    static func isDocsURL(_ value: String) -> Bool {
        let url = URL(string: value)
        return url?.host?.hasPrefix("docs.") == true || url?.host?.contains("api-docs.") == true || url?.path.contains("/docs") == true || value.contains("/documentation") || value.contains("/wiki/")
    }

    static func headers(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for header in text.matches(#"(?:-H|--header)\s+["']([^"']+)["']"#, group: 1) {
            let pair = header.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0].trimmed] = pair[1].trimmed }
        }
        return result
    }

    private static func fromJSON(_ object: Any) -> [Credential] {
        if Task.isCancelled { return [] }
        if let array = object as? [Any] { return array.flatMap(fromJSON) }
        guard let dict = object as? [String: Any] else { return [] }
        let flat = Dictionary(dict.map { ($0.key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: ""), $0.value) }, uniquingKeysWith: { first, _ in first })
        func value(_ names: [String]) -> String { names.compactMap { flat[$0] as? String }.first ?? "" }
        let key = value(["apikey", "key", "accesstoken", "token"])
        if !key.isEmpty || value(["auth"]) == AuthKind.none.rawValue || value(["format"]) == "keydock-credential" {
            var record = Credential()
            record.apiKey = key
            let base = value(["baseurl", "endpoint", "url"])
            record.baseURL = value(["format"]) == "keydock-credential" ? base.trimmed : normalizeBase(base)
            record.name = value(["name", "title"])
            record.provider = value(["provider", "vendor"])
            if record.provider.isEmpty { record.provider = provider(base: record.baseURL, text: "") }
            if record.name.isEmpty { record.name = record.provider }
            record.docsURL = value(["docsurl", "documentation", "docs"])
            record.purpose = value(["purpose", "usage"])
            record.notes = value(["notes", "remark", "description"])
            record.model = value(["model"])
            record.tags = value(["tags"])
            record.curl = value(["curl"])
            record.verificationURL = value(["verificationurl"])
            record.balanceURL = value(["balanceurl"])
            record.balancePath = value(["balancepath"])
            record.balanceUnit = value(["balanceunit"])
            record.extraHeaders = value(["extraheaders"])
            if let template = flat["calltemplate"] as? [String: Any], let path = template["path"] as? String, let body = template["body"] as? String {
                record.callTemplate = ModelCallTemplate(path: path, body: body, model: template["model"] as? String)
            }
            let expiry = value(["expiresat"])
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            record.expiresAt = formatter.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry)
            if let kind = ServiceKind(rawValue: value(["kind"])) { record.kind = kind }
            else if record.provider == "Anthropic" { record.kind = .anthropic; record.auth = .xAPIKey }
            else if record.provider == "Google Gemini" { record.kind = .gemini; record.auth = .googleKey }
            if let auth = AuthKind(rawValue: value(["auth"])) { record.auth = auth }
            else if record.kind == .anthropic { record.auth = .xAPIKey }
            else if record.kind == .gemini { record.auth = .googleKey }
            record.source = String(data: (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? ""
            return [record]
        }
        return dict.values.flatMap(fromJSON)
    }

    private static func unique(_ records: [Credential]) -> [Credential] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.fingerprint).inserted }
    }
}
