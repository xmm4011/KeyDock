import Foundation

// One reference catalog for manual setup, API routing and the import agent.
// Documentation describes capabilities; only an authenticated probe proves access.
struct ProviderPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let docs: [String]
    let console: String
    let protocols: [ServiceKind]
    let catalogURL: String?
    let catalogNote: String
    let balanceURL: String?
    let balancePath: String
    let balanceUnit: String
    let balanceNote: String
    let notes: String

    var isBCE: Bool { id.hasPrefix("bce-") }
    var providerLabel: String { ["qwen": "通义千问", "kimi": "Kimi"][id] ?? name }
    var accountBalanceReference: [String: String] {
        if id == "qwen" { return ["endpoint": "https://business.aliyuncs.com", "action": "QueryAccountBalance", "version": "2017-12-14", "auth": "独立云账户 AccessKey / 签名", "json_path": "Data.AvailableAmount", "documentation": "https://help.aliyun.com/zh/user-center/developer-reference/api-bssopenapi-2017-12-14-queryaccountbalance"] }
        if id == "volcengine" { return ["endpoint": "https://open.volcengineapi.com", "action": "QueryBalanceAcct", "version": "2022-01-01", "auth": "独立费用中心账户权限，不使用模型 API Key", "json_path": "Result.AvailableBalance", "documentation": "https://docs.volcengine.com/docs/billing-center/query-balance-acct-query-user-account-balance-information"] }
        if isBCE || id == "qianfan" { return ["endpoint": "https://billing.baidubce.com/v1/finance/cash/balance", "method": "POST", "auth": "独立云账户 AK/SK 签名；EOS 海外账户适用性需另行确认", "json_path": "cashBalance", "documentation": "https://intl.cloud.baidu.com/zh/doc/Finance/s/Skhtyytwu-intl"] }
        return [:]
    }
    var reference: [String: Any] {
        ["id": id, "provider": name, "base_url": baseURL, "documentation": docs, "console": console,
         "protocols": protocols.map { kind in ["kind": kind.rawValue, "base_url": connectionBase(kind), "path": kind == .compatible ? "chat/completions" : (kind == .anthropic ? "messages" : (kind == .responses ? "responses" : "models/{model}:generateContent")), "auth": authentication(kind).rawValue, "required_headers": kind == .anthropic ? ["anthropic-version": "2023-06-01"] : [:], "required_output_limit": kind == .anthropic && !["deepseek", "volcengine"].contains(id) ? "max_tokens" : ""] as [String: Any] },
         "models": ["url": catalogURL ?? "", "note": catalogNote],
         "balance": ["url": balanceURL ?? "", "json_path": balancePath, "unit": balanceUnit, "note": balanceNote],
         "account_balance_reference": accountBalanceReference, "notes": notes, "reviewed_on": "2026-11-08", "account_verified": false]
    }
    func connectionBase(_ kind: ServiceKind) -> String {
        let origin = URL(string: baseURL).map { "https://" + ($0.host ?? "") } ?? baseURL
        if isBCE { return origin + (kind == .gemini ? "/v1beta" : "/v1") }
        if kind == .anthropic {
            switch id {
            case "deepseek", "kimi", "qianfan": return origin + "/anthropic/v1"
            case "qwen": return origin + "/apps/anthropic/v1"
            case "volcengine": return origin + "/api/compatible/v1"
            default: break
            }
        }
        return baseURL
    }
    func authentication(_ kind: ServiceKind) -> AuthKind {
        // EOS uses Bearer for every protocol, including Gemini and Messages.
        if id == "qianfan", kind == .anthropic { return .xAPIKey }
        return .bearer
    }
    func applying(to source: Credential) -> Credential {
        var value = CredentialEditor.applyingPreset(to: source, name: name, kind: .compatible, url: baseURL, docs: docs[0])
        value.auth = .bearer
        value.verificationURL = catalogURL ?? ""
        value.balanceURL = balanceURL ?? ""; value.balancePath = balancePath; value.balanceUnit = balanceUnit
        // Don't replace the user's own notes when changing a preset.
        return value
    }

    static let bceDocs = "https://tcnxnzs113h4.feishu.cn/wiki/JpXbwpfC3iyrkhkFQYVcoYyknRe"
    static let all: [ProviderPreset] = [
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", docs: ["https://api-docs.deepseek.com/", "https://api-docs.deepseek.com/guides/anthropic_api/", "https://api-docs.deepseek.com/guides/responses_api/", "https://api-docs.deepseek.com/api/list-models/", "https://api-docs.deepseek.com/api/get-user-balance/"], console: "https://platform.deepseek.com/", protocols: [.compatible, .anthropic, .responses], catalogURL: "https://api.deepseek.com/models", catalogNote: "GET /models；目录不代表各模型的调用权限。", balanceURL: "https://api.deepseek.com/user/balance", balancePath: "", balanceUnit: "", balanceNote: "同一 API Key；balance_infos 返回各币种余额。", notes: "Messages 使用 /anthropic/v1/messages；Responses 使用 /responses。不要把不支持的 Claude 别名作为真实模型清单。"),
        ProviderPreset(id: "qwen", name: "通义千问 / 百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", docs: ["https://help.aliyun.com/zh/model-studio/base-url", "https://help.aliyun.com/zh/model-studio/anthropic-api-messages", "https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-responses", "https://help.aliyun.com/zh/model-studio/list-models", "https://help.aliyun.com/zh/user-center/developer-reference/api-bssopenapi-2017-12-14-queryaccountbalance"], console: "https://bailian.console.aliyun.com/", protocols: [.compatible, .anthropic, .responses], catalogURL: nil, catalogNote: "业务空间域名 GET /api/v1/models；需实际 WorkspaceId，不猜测空间。旧域名未确认通用目录，可按文档添加模型。", balanceURL: nil, balancePath: "", balanceUnit: "", balanceNote: "云账户 QueryAccountBalance 需要独立的 AccessKey / 签名与权限，不能用模型 API Key 代替；请在控制台查看。", notes: "预设使用北京公共域名；推荐改成控制台的真实业务空间专属域名。地域与 API Key 必须对应。Responses 使用 /compatible-mode/v1/responses，旧 /api/v2/apps/protocols 路径已停止维护。Coding Plan / Token Plan 的地址和 Key 独立。"),
        ProviderPreset(id: "volcengine", name: "豆包 / 火山方舟", baseURL: "https://ark.cn-beijing.volces.com/api/v3", docs: ["https://docs.volcengine.com/docs/82379/1494384", "https://docs.volcengine.com/docs/ark/messages-api", "https://docs.volcengine.com/docs/ark/agent-model-invocation-practice", "https://docs.volcengine.com/docs/billing-center/query-balance-acct-query-user-account-balance-information"], console: "https://console.volcengine.com/ark", protocols: [.compatible, .anthropic, .responses], catalogURL: nil, catalogNote: "未确认可用模型 API Key 查询的通用目录；请使用控制台实际模型 ID 或推理接入点 ID。", balanceURL: nil, balancePath: "", balanceUnit: "", balanceNote: "QueryBalanceAcct 属于费用中心，需独立账户鉴权；不向该接口发送模型 API Key。", notes: "Chat / Responses 使用 /api/v3；Messages 使用 /api/compatible/v1/messages。按量服务与 Coding Plan 地址、Key 不混用。部署模型可能要求实际 Endpoint ID。"),
        ProviderPreset(id: "kimi", name: "Kimi / Moonshot", baseURL: "https://api.moonshot.cn/v1", docs: ["https://platform.kimi.com/docs/api/chat", "https://platform.kimi.com/docs/api/messages", "https://platform.kimi.com/docs/api/responses", "https://platform.kimi.com/docs/api/list-models", "https://platform.kimi.com/docs/api/balance"], console: "https://platform.kimi.com/", protocols: [.compatible, .anthropic, .responses], catalogURL: "https://api.moonshot.cn/v1/models", catalogNote: "GET /v1/models；使用账户实际返回的模型 ID。", balanceURL: "https://api.moonshot.cn/v1/users/me/balance", balancePath: "data.available_balance", balanceUnit: "CNY", balanceNote: "同一 API Key；可用余额包含现金与代金券。", notes: "国内与国际账户的 Key 独立；Messages 使用 /anthropic/v1/messages，Chat / Responses 使用 /v1。Kimi Code 的专用账户与接口不能混用。"),
        ProviderPreset(id: "baichuan", name: "百川", baseURL: "https://api.baichuan-ai.com/v1", docs: ["https://platform.baichuan-ai.com/docs-v2/api"], console: "https://platform.baichuan-ai.com/", protocols: [.compatible], catalogURL: nil, catalogNote: "公开 API 文档未确认模型目录接口；按文档填写实际模型，并验证调用。", balanceURL: nil, balancePath: "", balanceUnit: "", balanceNote: "公开 API 文档未确认同 Key 余额接口；请在控制台查看。", notes: "已核对 Chat Completions 与 Bearer 鉴权；不把未确认的多协议能力当成已支持。"),
        ProviderPreset(id: "qianfan", name: "百度千帆", baseURL: "https://qianfan.baidubce.com/v2", docs: ["https://cloud.baidu.com/doc/qianfan-docs/s/Fm9l6ocai", "https://cloud.baidu.com/doc/qianfan-api/s/Dmba8k71y", "https://intl.cloud.baidu.com/zh/doc/Finance/s/Skhtyytwu-intl"], console: "https://console.bce.baidu.com/qianfan/", protocols: [.compatible, .anthropic, .responses], catalogURL: "https://qianfan.baidubce.com/v2/models", catalogNote: "GET /v2/models；目录含模型支持的协议，不能推断每个模型都支持全部协议。", balanceURL: nil, balancePath: "", balanceUnit: "", balanceNote: "BCE 财务余额接口需要独立的账户 AK/SK 签名，不能复用模型 Key；请在控制台查看。", notes: "千帆与 EOS / BCEVOD 为不同服务，API Key、域名和模型不能混用。Chat / Responses 使用 /v2；Messages 使用 /anthropic/v1/messages。"),
    ] + [("sg", "新加坡", "eos-sg.aigc.exp.bcevod.com"), ("ca", "加州", "eos-ca.aigc.exp.bcevod.com"), ("de", "德国", "eos-de.aigc.exp.bcevod.com"), ("gz", "广州", "vod.gz.baidubce.com")].map { region, name, host in
        ProviderPreset(id: "bce-" + region, name: "百度 EOS AIGC · " + name, baseURL: "https://" + host + "/v1", docs: [bceDocs, "https://tcnxnzs113h4.feishu.cn/wiki/I9NJw6lPmiqbNFkQF0TcavXln7b"], console: region == "gz" ? "https://console.bce.baidu.com/vod-gz/" : "https://console.bce.baidu.com/vod-overseas", protocols: [.compatible, .anthropic, .responses, .gemini], catalogURL: nil, catalogNote: "接入指南未提供 GET /models；请参考模型资料或控制台添加模型，用实际调用验证。", balanceURL: nil, balancePath: "", balanceUnit: "", balanceNote: "接入指南未提供可复用模型 Key 的余额 API；在对应地域控制台查看。", notes: "地域：" + name + "。地域资源、Key 不混用；海外美元账户与国内人民币账户独立。所有协议均使用 Authorization: Bearer；Gemini 原生路径 /v1beta/models/{model}:{action}。海外登录 https://login.bce.baidu.com/overseas-login 是控制台入口，不是 API。")
    }

    // Match the exact origin and documented base paths only. A lookalike host,
    // plan endpoint or a custom gateway prefix must never be rewritten.
    static func matching(_ raw: String) -> ProviderPreset? {
        guard let url = URL(string: raw), url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let host = url.host?.lowercased() ?? "", path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host.hasSuffix(".maas.aliyuncs.com"), host.split(separator: ".").count == 5,
           ["", "compatible-mode/v1", "apps/anthropic", "apps/anthropic/v1"].contains(path) {
            var value = all.first { $0.id == "qwen" }!
            value = ProviderPreset(id: value.id, name: value.name, baseURL: "https://" + host + "/compatible-mode/v1", docs: value.docs, console: value.console, protocols: value.protocols, catalogURL: "https://" + host + "/api/v1/models", catalogNote: "GET /api/v1/models，返回当前页；目录不等于调用权限。", balanceURL: nil, balancePath: "", balanceUnit: "", balanceNote: value.balanceNote, notes: value.notes)
            return value
        }
        let match = all.first { preset in
            guard URL(string: preset.baseURL)?.host == host else { return false }
            let paths = preset.protocols.compactMap { URL(string: preset.connectionBase($0))?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            return ([""] + paths + (preset.protocols.contains(.anthropic) ? paths.filter { $0.hasSuffix("/v1") }.map { String($0.dropLast(3)) } : []) + (preset.id == "deepseek" ? ["v1", "anthropic"] : [])).contains(path)
        }
        if let match, match.id == "deepseek", path == "v1" {
            return ProviderPreset(id: match.id, name: match.name, baseURL: "https://api.deepseek.com/v1", docs: match.docs, console: match.console, protocols: match.protocols, catalogURL: "https://api.deepseek.com/v1/models", catalogNote: match.catalogNote, balanceURL: match.balanceURL, balancePath: match.balancePath, balanceUnit: match.balanceUnit, balanceNote: match.balanceNote, notes: match.notes)
        }
        return match
    }
    static func configuration(_ record: Credential, kind: ServiceKind? = nil) -> Credential {
        var value = record
        value.kind = record.inferenceKind
        if let kind, kind != record.inferenceKind { value.kind = kind; value.callTemplate = nil }
        if let preset = matching(record.baseURL), preset.protocols.contains(value.kind) {
            value.baseURL = preset.connectionBase(value.kind); value.auth = preset.authentication(value.kind)
        }
        return value
    }
    static func reconcileDefaults(_ source: Credential, previous: Credential? = nil) -> Credential {
        var value = source
        let before = previous.flatMap { matching($0.baseURL.trimmed) }, after = matching(source.baseURL.trimmed)
        let changed = previous.map { URL(string: $0.baseURL.trimmed)?.host?.lowercased() != URL(string: source.baseURL.trimmed)?.host?.lowercased() || before?.id != after?.id } ?? true
        if changed, let previous, let before {
            if value.provider == before.name || value.provider == before.providerLabel { value.provider = "" }
            if before.docs.contains(value.docsURL) { value.docsURL = "" }
            if value.verificationURL == before.catalogURL { value.verificationURL = "" }
            if value.balanceURL == before.balanceURL {
                value.balanceURL = ""
                if value.balancePath == before.balancePath { value.balancePath = "" }
                if value.balanceUnit == before.balanceUnit { value.balanceUnit = "" }
            }
            if value.callTemplate == previous.callTemplate {
                value.kind = value.inferenceKind; value.callTemplate = nil
            }
            if value.auth == before.authentication(previous.inferenceKind), let after, after.protocols.contains(value.inferenceKind) { value.auth = after.authentication(value.inferenceKind) }
        }
        if let after {
            if value.provider.isEmpty { value.provider = after.providerLabel }
            if value.docsURL.isEmpty { value.docsURL = after.docs[0] }
            // A name/note edit must not turn implicit defaults into a changed
            // verification configuration and erase a valid historical result.
            if changed {
                if value.verificationURL.isEmpty { value.verificationURL = after.catalogURL ?? "" }
                if value.balanceURL.isEmpty {
                    value.balanceURL = after.balanceURL ?? ""
                    if value.balancePath.isEmpty { value.balancePath = after.balancePath }
                    if value.balanceUnit.isEmpty { value.balanceUnit = after.balanceUnit }
                }
            }
        }
        return value
    }
    static func matches(in source: String) -> [ProviderPreset] {
        let urls = ImportParser.urls(in: source)
        let exact = urls.compactMap(matching)
        if !exact.isEmpty { return exact.reduce(into: []) { result, preset in if !result.contains(where: { $0.baseURL == preset.baseURL }) { result.append(preset) } } }
        // A relay URL is stronger evidence than a model/provider name in prose.
        if urls.contains(where: { !ImportParser.isDocsURL($0) }) { return [] }
        let aliases: [String: [String]] = ["deepseek": ["deepseek"], "qwen": ["通义千问", "百炼", "dashscope"], "volcengine": ["火山方舟", "豆包"], "kimi": ["moonshot", "kimi"], "baichuan": ["百川"], "qianfan": ["百度千帆"]]
        let hidden = Dictionary(uniqueKeysWithValues: Set(ImportParser.keys(in: source)).map { ($0, "[凭据]") })
        let text = source.replacingSecrets(hidden).lowercased()
        var result = all.filter { preset in (aliases[preset.id] ?? []).contains(where: text.contains) }
        if text.contains("eos") || text.contains("bcevod") || source.contains(bceDocs) {
            let regions = [("bce-sg", ["新加坡", "singapore"], "sg"), ("bce-ca", ["加州", "california"], "ca"), ("bce-de", ["德国", "germany"], "de"), ("bce-gz", ["广州", "guangzhou"], "gz")]
            let explicit = regions.filter { _, names, short in
                names.contains(where: text.contains) || text.range(of: "(?<![a-z0-9_])" + short + "(?![a-z0-9_])", options: .regularExpression) != nil
            }.map { $0.0 }
            result += all.filter { $0.isBCE && (explicit.count != 1 || explicit.contains($0.id)) }
        }
        return result
    }
}
