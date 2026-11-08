import Foundation
import CryptoKit

enum DeepChecks {
    static func record() -> Credential {
        var record = Credential(); record.name = "Fixture"; record.baseURL = "https://example.com/v1"; record.apiKey = "sk-deep-check-secret-123456789"; return record
    }
    static func run() {
        runCheck("Deep.redaction-equal-length-keys-is-repeatable") {
            let raw = "API_KEY=sk-alpha-123456789\ntoken=sk-bravo-123456789"
            let variants = Set((0..<100).map { _ in RedactedImport(raw).text })
            expectEqual(variants.count, 1)
        }
        runCheck("Deep.redaction-does-not-rewrite-its-own-placeholders") {
            let redacted = RedactedImport("API_KEY=KEYDOCK\ntoken=sk-another-secret-123456789")
            expectTrue(redacted.keys.keys.allSatisfy { redacted.text.contains($0) })
            expectEqual(redacted.keys.count, 2)
        }
        runCheck("Deep.redaction-placeholders-do-not-collide-with-user-text") {
            let raw = "备注：KEYDOCK_SECRET_1\nAPI_KEY=sk-alpha-123456789"
            let redacted = RedactedImport(raw)
            expectTrue(redacted.keys.keys.allSatisfy { !raw.contains($0) })
            expectTrue(redacted.text.contains("备注：KEYDOCK_SECRET_1"))
        }
        runCheck("Deep.empty-key-does-not-consume-next-line") {
            expectTrue(ImportParser.keys(in: "API_KEY=\nBASE_URL=https://example.com/v1").isEmpty)
            expectTrue(ImportParser.keys(in: "API Key：\n用途：开发").isEmpty)
        }
        runCheck("Deep.provider-endpoint-wins-over-unrelated-chat-text") {
            let values = ImportParser.parse("Base URL：https://api.openai.com/v1\nAPI Key：sk-example-secret-123456789\n用途：与 Claude 对比")
            expectEqual(values.first?.provider, "OpenAI")
            expectEqual(values.first?.kind, .compatible)
            expectEqual(values.first?.auth, .bearer)
        }
        runCheck("Deep.curl-protocol-and-authorization-win-over-model-name") {
            let raw = "Claude 兼容接口\ncurl https://gateway.example.com/v1/chat/completions -H 'Authorization: Bearer sk-fixture-123456789' -d '{\"model\":\"claude-test\"}'"
            let record = ImportParser.parse(raw).first
            expectEqual(record?.kind, .compatible); expectEqual(record?.auth, .bearer)
        }
        runCheck("Deep.key-before-URL-is-associated-correctly") {
            let values = ImportParser.parse("API Key：sk-test-key-123456789\nBase URL：https://example.com/v1")
            expectEqual(values.count, 1); expectEqual(values.first?.baseURL, "https://example.com/v1")
        }
        runCheck("Deep.adjacent-named-records-preserve-their-names") {
            let raw = "名称：账号A\nBase URL：https://example.com/v1\nAPI Key：sk-account-a-123456789\n名称：账号B\nBase URL：https://example.com/v1\nAPI Key：sk-account-b-123456789"
            let values = ImportParser.parse(raw)
            expectEqual(values.count, 2); expectEqual(values.first?.name, "账号A"); expectEqual(values.last?.name, "账号B")
        }
        runCheck("Deep.endpoint-suffix-must-be-a-path-component") {
            var value = record(); value.baseURL = "https://example.com/tenant/custom-models"
            expectEqual(try APIClient.verificationRequest(for: value).url?.path, "/tenant/custom-models/models")
        }
        runCheck("Deep.null-error-is-not-an-API-error") {
            let data = Data(#"{"data":[],"error":null}"#.utf8)
            expectEqual(APIClient.classify(status: 200, data: data, record: record()).state, .valid)
        }
        runCheck("Deep.control-characters-in-keys-are-rejected") {
            var value = record(); value.apiKey = "secret\0suffix"
            expectThrows(try APIClient.verificationRequest(for: value))
        }
        runCheck("Deep.proxy-forwards-SSE-Accept-header") {
            let value = record()
            let incoming = LocalHTTPRequest(method: "GET", target: "/s/\(value.routeID)/events", headers: ["authorization": "Bearer " + value.localKey, "accept": "text/event-stream"], body: Data())
            expectEqual(try incoming.upstream(records: [value]).0.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        }
        runCheck("Deep.proxy-rejects-malformed-header-names") {
            expectThrows(try LocalHTTPRequest.parse(Data("GET / HTTP/1.1\r\nBad Header: value\r\n\r\n".utf8)))
            expectThrows(try LocalHTTPRequest.parse(Data("GET / HTTP/1.1\r\n X-Api-Key: value\r\n\r\n".utf8)))
        }
        runCheck("Deep.valid-empty-HTTP-header-values-are-accepted") {
            let parsed = try LocalHTTPRequest.parse(Data("GET / HTTP/1.1\r\nX-Empty:\r\n\r\n".utf8))
            expectEqual(parsed?.headers["x-empty"], "")
        }
        runCheck("Deep.proxy-never-forwards-hop-by-hop-client-headers") {
            let value = record()
            let request = LocalHTTPRequest(method: "GET", target: "/s/\(value.routeID)/models", headers: ["authorization": "Bearer " + value.localKey, "connection": "X-Local", "x-local": "must-stay-local", "upgrade": "websocket"], body: Data())
            let upstream = try request.upstream(records: [value]).0
            expectNil(upstream.value(forHTTPHeaderField: "X-Local")); expectNil(upstream.value(forHTTPHeaderField: "Upgrade"))
        }
        runCheck("Deep.normal-copy-retains-working-local-alias") {
            let value = record()
            expectTrue(value.safeShareText.contains(value.localKey)); expectTrue(value.safeShareText.contains(value.localBaseURL))
            expectFalse(value.safeShareText.contains(value.apiKey))
        }
        runCheck("Deep.copy-assets-never-embed-key-from-model-metadata") {
            var value = record(); value.model = value.apiKey; value.name = "Fixture " + value.apiKey
            expectFalse(value.environmentText.contains(value.apiKey))
            expectFalse(value.localCurl.contains(value.apiKey))
            expectFalse(value.safeShareText.contains(value.apiKey))
        }
        runCheck("Deep.dedup-fingerprint-is-unambiguous") {
            var a = record(); a.baseURL = "https://example.com/a|b"; a.apiKey = "c"
            var b = record(); b.baseURL = "https://example.com/a"; b.apiKey = "b|c"
            expectNotEqual(a.fingerprint, b.fingerprint)
        }
        runCheck("Deep.backup-rejects-empty-password-and-tampered-envelope") {
            let data = try PortableBackup.create(VaultData(credentials: [record()]), password: "test-password-123")
            expectThrows(try PortableBackup.restore(data, password: ""))
            var envelope = try JSONDecoder().decode(PortableBackup.self, from: data)
            envelope.rounds = Int.max
            expectThrows(try PortableBackup.restore(JSONEncoder().encode(envelope), password: "test-password-123"))
            envelope.rounds = 310_000; envelope.encrypted[envelope.encrypted.count - 1] ^= 1
            expectThrows(try PortableBackup.restore(JSONEncoder().encode(envelope), password: "test-password-123"))
        }
        runCheck("Deep.import-malformed-and-empty-inputs-do-not-crash") {
            for raw in ["", "\n\n", "null", "123", "[]", "{}", "{broken", "```\n```", "😀中文测试"] { _ = ImportParser.parse(raw) }
            expectTrue(ImportParser.parse("").isEmpty)
        }
        runCheck("Deep.import-1000-records-preserves-all-associations") {
            let text = (0..<1000).map { "名称：Fixture \($0)\nBase URL：https://example.com/v1\nAPI Key：sk-fixture-\($0)-123456789\n" }.joined(separator: "\n")
            let start = Date(); let records = ImportParser.parse(text)
            expectEqual(records.count, 1000)
            expectTrue(records.enumerated().allSatisfy { index, record in record.name == "Fixture \(index)" && record.apiKey == "sk-fixture-\(index)-123456789" })
            expectTrue(Date().timeIntervalSince(start) < 8)
        }
        runCheck("Deep.proxy-denies-encoded-traversal-and-wrong-auth") {
            let value = record()
            for path in ["/../admin", "/%2e%2e/admin", "/%2F../admin"] {
                let request = LocalHTTPRequest(method: "GET", target: "/s/\(value.routeID)" + path, headers: ["authorization": "Bearer " + value.localKey], body: Data())
                expectThrows(try request.upstream(records: [value]))
            }
            let request = LocalHTTPRequest(method: "GET", target: "/s/\(value.routeID)/models", headers: ["authorization": "Bearer wrong"], body: Data())
            expectThrows(try request.upstream(records: [value]))
        }
    }
}
