import Foundation

extension APIClient {
    // Configuration checks only: no network traffic or guessed provider APIs.
    static func balanceIssue(_ record: Credential) -> String? {
        if record.archived { return "此 Key 已归档，恢复后可查询余额。" }
        do {
            let request = try balanceRequest(for: record)
            let preset = ProviderPreset.matching(record.baseURL)
            let isDeepSeekBalance = request.url?.host == "api.deepseek.com" && request.url?.path == "/user/balance"
            let path = record.balancePath.trimmed.isEmpty ? (preset?.balancePath ?? "") : record.balancePath.trimmed
            if !isDeepSeekBalance && path.isEmpty { return "请先在高级选项中填写余额 JSON 字段路径。" }
            return nil
        } catch {
            if record.balanceURL.trimmed.isEmpty, ProviderPreset.matching(record.baseURL) == nil { return "未配置余额查询接口，可在编辑的高级选项中添加。" }
            return failureMessage(error)
        }
    }
    static func catalogIssue(_ record: Credential) -> String? {
        if record.archived { return "此 Key 已归档，恢复后可获取模型。" }
        if record.kind == .custom { return "此服务没有通用模型目录，可手动添加模型。" }
        if let issue = record.connectionIssue { return issue }
        let observedCatalog = record.modelCatalog != nil && record.modelCatalog?.source != "资料"
        if !observedCatalog, record.verificationURL.trimmed.isEmpty, let preset = ProviderPreset.matching(record.baseURL), preset.catalogURL == nil { return preset.catalogNote }
        do {
            var catalog = ProviderPreset.configuration(record)
            let url: URL
            if !catalog.verificationURL.trimmed.isEmpty { url = try safeURL(catalog.verificationURL) }
            else if let address = ProviderPreset.matching(catalog.baseURL)?.catalogURL { url = try safeURL(address); catalog.auth = .bearer }
            else { url = try endpoint(base: catalog.baseURL, suffix: "models", defaultVersion: catalog.kind == .gemini ? "v1beta" : "v1") }
            _ = try authenticatedRequest(url: url, record: catalog)
            return nil
        } catch { return failureMessage(error) }
    }
    static func verificationIssue(_ record: Credential, testModel: Bool) -> String? {
        if record.archived { return "此 Key 已归档，恢复后可验证。" }
        if testModel, record.model.trimmed.isEmpty { return "请先选择或填写需要验证的模型。" }
        do {
            if testModel { _ = try modelTestRequest(for: record) }
            else { _ = try verificationRequest(for: record) }
            return nil
        } catch { return failureMessage(error) }
    }
}
