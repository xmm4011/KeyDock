import Foundation
import AppKit
import CryptoKit

@MainActor enum RawDisplayChecks {
    static func run() {
        runCheck("RawDisplay.response-keeps-authentication-cookie-boolean-and-escaped-values") {
            var record = DeepChecks.record(); record.apiKey = "fixture-raw-key-123"
            let escaped = record.apiKey.utf16.map { String(format: "\\u%04x", $0) }.joined()
            let data = Data(("{\"echo\":\"" + escaped + "\",\"enabled\":true}").utf8)
            let http = HTTPURLResponse(url: URL(string: record.baseURL)!, statusCode: 400, httpVersion: nil,
                                       headerFields: ["Authorization": "Bearer " + record.apiKey, "Set-Cookie": "sid=fixture-session", "access-control-allow-credentials": "true"])!
            let response = CheckedResponse(data, response: http, record: record)
            expectTrue(response.headers.contains("Bearer " + record.apiKey)); expectTrue(response.headers.contains("sid=fixture-session"))
            expectTrue(response.headers.lowercased().contains("access-control-allow-credentials: true")); expectTrue(response.body.contains(record.apiKey))
            expectFalse(response.text.contains("已隐藏")); expectFalse(response.truncated)
            expectEqual(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? NSDictionary, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        runCheck("RawDisplay.body-capture-is-bounded-for-unicode-invalid-utf8-and-JSON") {
            for text in [String(repeating: "中文😀", count: 30_000), String(repeating: "x", count: RecordedContent.bodyLimit + 10), "data: {\"text\":\"fixture-raw-key\"}\n\n"] {
                let data = Data(text.utf8), body = RecordedContent.body(data)
                expectTrue(body.utf8.count <= RecordedContent.bodyLimit)
                expectTrue(text.hasPrefix(body)); expectFalse(body.contains("已隐藏"))
            }
            expectFalse(RecordedContent.body(Data([0xff, 0xfe, 0x41])).isEmpty)
            expectEqual(RecordedContent.body(Data()), "")
        }
        runCheck("RawDisplay.local-copy-is-exact-while-alias-config-and-Agent-context-stay-credential-free") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false, pasteboard: board)
                var record = DeepChecks.record(); record.model = "fixture-model"; record.name = "Fixture " + record.apiKey
                expectTrue(store.save(record)); expectTrue(store.setShowFullContent(true))
                let raw = "Authorization: Bearer " + record.apiKey + "\nflag: true\n尾部  "
                store.copy(raw); expectEqual(board.string(forType: .string), raw); expectEqual(store.toast, "已复制")
                expectTrue(record.title.contains(record.apiKey)); expectFalse(record.safeShareText.contains(record.apiKey))
                let host = ImportAgentHost(original: "API Key: " + record.apiKey, imageText: "", images: [], workspace: root, session: APIClient.session)
                expectFalse(host.safe(raw).contains(record.apiKey))
            }
        }
        runCheck("RawDisplay.raw-evidence-persists-encrypted-and-old-masked-evidence-is-not-fabricated") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), history = ProxyHistory(directory: root, keyProvider: { key })
                var record = DeepChecks.record()
                let response = CheckedResponse(Data(("echo " + record.apiKey).utf8), record: record)
                record.check = CheckResult(state: .uncertain, message: "fixture", response: response)
                let disk = EncryptedVault(directory: root, keyProvider: { key }); try disk.save(VaultData(credentials: [record]))
                var entry = ProxyLogEntry(credentialID: record.id, method: "POST", requestURL: record.baseURL)
                entry.bodiesCaptured = true; entry.requestHeaders = "Authorization: Bearer " + record.apiKey; entry.responseBody = response.body
                history.append(entry); history.flush()
                expectEqual(ProxyHistory(directory: root, keyProvider: { key }).entries.first?.requestHeaders, entry.requestHeaders)
                expectEqual(try disk.load().credentials.first?.check?.response, response)
                for name in ["vault.kdv", "history.kdv"] { expectFalse(String(decoding: try Data(contentsOf: root.appendingPathComponent(name)), as: UTF8.self).contains(record.apiKey)) }
                let old = #"{"headers":"Authorization: [已隐藏]","body":"old [已隐藏]","truncated":false}"#
                expectEqual(try JSONDecoder().decode(CheckedResponse.self, from: Data(old.utf8)).body, "old [已隐藏]")
            }
        }
    }
}
