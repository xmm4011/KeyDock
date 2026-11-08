import Foundation

// Explicit portable fields only: no local route IDs, trust results, other keys'
// source material, cached models, balances or history can enter a shared record.
enum CredentialTransfer {
    static func text(_ record: Credential) -> String {
        var object: [String: Any] = [
            "format": "keydock-credential", "version": 1,
            "name": record.name, "provider": record.provider, "kind": record.kind.rawValue,
            "base_url": record.baseURL, "api_key": record.apiKey, "auth": record.auth.rawValue,
            "model": record.model, "extra_headers": record.extraHeaders,
            "docs_url": record.docsURL, "purpose": record.purpose, "notes": record.notes, "tags": record.tags,
            "verification_url": record.verificationURL, "balance_url": record.balanceURL,
            "balance_path": record.balancePath, "balance_unit": record.balanceUnit,
            "usage_notice": "包含真实凭据。接口调用可能产生正常用量。"
        ]
        if let template = record.callTemplate {
            var value = ["path": template.path, "body": template.body]
            if let model = template.model { value["model"] = model }
            object["call_template"] = value
        }
        if let date = record.expiresAt {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            object["expires_at"] = formatter.string(from: date)
        }
        if record.kind != .custom, !record.model.trimmed.isEmpty { object["curl"] = record.realModelCurl }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "无法生成完整凭据，请重试。" }
        return String(decoding: data, as: UTF8.self)
    }
}
