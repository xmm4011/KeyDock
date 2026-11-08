import Foundation
import CryptoKit


final class ParserTests: TestSuite {
    func testCurlImportPreservesEndpointModelAndHeaders() throws {
        let text = """
        测试账号
        curl 'https://api.example.com/compatible-mode/v1/chat/completions' \
          -H 'Authorization: Bearer sk-local-test-123456789' \
          -H 'X-Project: sandbox' \
          -d '{"model":"test-model","messages":[]}'
        用途：代码生成
        文档：https://docs.example.com/api
        """
        let records = ImportParser.parse(text)
        expectEqual(records.count, 1)
        let record = try unwrap(records.first)
        expectEqual(record.baseURL, "https://api.example.com/compatible-mode/v1")
        expectEqual(record.apiKey, "sk-local-test-123456789")
        expectEqual(record.model, "test-model")
        expectEqual(record.purpose, "代码生成")
        expectEqual(record.docsURL, "https://docs.example.com/api")
        expectEqual(record.extraHeaders, "X-Project: sandbox")
    }
    func testMultipleKeysForSameVendorRemainSeparate() {
        let text = """
        名称：DeepSeek 工作 01
        Base URL：https://api.deepseek.com
        API Key：sk-first-local-test-123456

        名称：DeepSeek 工作 02
        Base URL：https://api.deepseek.com
        API Key：sk-second-local-test-123456
        """
        let records = ImportParser.parse(text)
        expectEqual(records.count, 2)
        expectNotEqual(records[0].id, records[1].id)
        expectNotEqual(records[0].envPrefix, records[1].envPrefix)
        expectEqual(Set(records.map(\.baseURL)), ["https://api.deepseek.com"])
    }
    func testJSONAndNestedConfig() {
        let text = #"{"services":[{"name":"A","base_url":"https://a.example/v1","api_key":"secret-a"},{"name":"B","base_url":"https://a.example/v1","api_key":"secret-b","kind":"custom","auth":"apiKey"}]}"#
        let records = ImportParser.parse(text)
        expectEqual(records.count, 2)
        expectEqual(records.last?.auth, .apiKey)
        expectEqual(records.last?.kind, .custom)
    }
    func testEnvironmentVariablesAndNoShellExecution() {
        let text = "export DEEPSEEK_BASE_URL='https://api.deepseek.com/v1'\nexport DEEPSEEK_API_KEY='sk-local-env-test-123456'\n备注：$(touch /tmp/never-execute-keydock)"
        let record = ImportParser.parse(text).first
        expectEqual(record?.baseURL, "https://api.deepseek.com/v1")
        expectEqual(record?.apiKey, "sk-local-env-test-123456")
        expectTrue(record?.source.contains("$(touch") == true)
    }
    func testAmbiguousMultiEndpointBlockDoesNotGuess() {
        let text = "密钥：sk-first-local-123456\n另一个密钥：sk-second-local-123456\nhttps://a.example/v1\nhttps://b.example/v1"
        let records = ImportParser.parse(text)
        expectEqual(records.count, 2)
        expectTrue(records.allSatisfy { $0.baseURL.isEmpty })
    }
    func testDuplicatesAreRemovedByKeyAndURL() {
        let text = "Base URL：https://api.example.com/v1\nAPI Key：sk-same-test-123456\n\nBase URL：https://api.example.com/v1\nAPI Key：sk-same-test-123456"
        expectEqual(ImportParser.parse(text).count, 1)
    }
    func testRedactionReplacesEveryOccurrenceAndJSONKey() {
        let raw = #"{"base_url":"https://example.com","key":"opaque-secret-123"}"#
        let value = RedactedImport(raw)
        expectFalse(value.text.contains("opaque-secret-123"))
        expectEqual(value.keys.count, 1)
        expectEqual(value.keys.values.first, "opaque-secret-123")
    }
    func testProviderAndExpiry() {
        let record = ImportParser.parse("Base URL：https://api.anthropic.com/v1/messages\nAPI Key：sk-ant-test-123456789\n到期日期：2020-01-01").first
        expectEqual(record?.kind, .anthropic)
        expectEqual(record?.auth, .xAPIKey)
        expectTrue(record?.expired == true)
        let explicit = ImportParser.parse(#"[{"api_key":"fixture-opaque","base_url":"https://api.anthropic.com","kind":"anthropic"}]"#)
        expectEqual(explicit.first?.auth, .xAPIKey)
    }
}

final class RequestTests: TestSuite {
    func record(_ base: String = "https://api.example.com/v1") -> Credential {
        var value = Credential(); value.name = "test"; value.baseURL = base; value.apiKey = "never-real-test-secret"; return value
    }
    func testEndpointPreservesGatewayPrefix() throws {
        let request = try APIClient.verificationRequest(for: record("https://gateway.example/tenant/compatible/v1/"))
        expectEqual(request.url?.absoluteString, "https://gateway.example/tenant/compatible/v1/models")
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer never-real-test-secret")
    }
    func testDefaultVersionAndGemini() throws {
        expectEqual(try APIClient.verificationRequest(for: record("https://api.deepseek.com")).url?.path, "/models")
        var value = record("https://generativelanguage.googleapis.com")
        value.kind = .gemini; value.auth = .googleKey
        let request = try APIClient.verificationRequest(for: value)
        expectEqual(request.url?.path, "/v1beta/models")
        expectEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), value.apiKey)
        expectNil(request.url?.query)
    }
    func testRejectsInsecureRemoteAndHeaderInjection() {
        expectThrows(try APIClient.verificationRequest(for: record("http://remote.example.com")))
        expectThrows(try APIClient.verificationRequest(for: record("https://user:password@api.example.com")))
        var value = record(); value.extraHeaders = "Host: attacker.example.com"
        expectThrows(try APIClient.verificationRequest(for: value))
        value.extraHeaders = ""; value.apiKey = "abc\r\nInjected: x"
        expectThrows(try APIClient.verificationRequest(for: value))
    }
    func testQueryURLMustBeExplicitCustomVerification() throws {
        var value = record("https://api.example/v1?api-version=2026")
        expectThrows(try APIClient.verificationRequest(for: value))
        value.verificationURL = "https://api.example/models?api-version=2026"
        expectEqual(try APIClient.verificationRequest(for: value).url?.query, "api-version=2026")
    }
    func testStatusNeverConfusesNetworkQuotaOrPermissionsWithInvalidKey() {
        let value = record()
        for code in [403, 404, 429, 402, 500, 302] {
            expectNotEqual(APIClient.classify(status: code, data: Data(), record: value).state, .invalid)
        }
        expectEqual(APIClient.classify(status: 401, data: Data(), record: value).state, .uncertain)
        expectEqual(APIClient.classify(status: 401, data: Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8), record: value).state, .invalid)
        expectEqual(APIClient.classify(status: 200, data: Data("<html>login</html>".utf8), record: value).state, .uncertain)
        expectEqual(APIClient.classify(status: 200, data: Data(#"{"error":{"message":"expired"}}"#.utf8), record: value).state, .uncertain)
        let valid = APIClient.classify(status: 200, data: Data(#"{"data":[{"id":"model-a"}]}"#.utf8), record: value)
        expectEqual(valid.state, .valid); expectEqual(valid.models, ["model-a"])
    }
    func testSafeConfigurationHasNoRealSecretAndDifferentAliases() {
        var a = record(); a.variablePrefix = "DEEPSEEK_WORK_01"; a.model = "test-model"
        var b = record(); b.variablePrefix = "DEEPSEEK_WORK_02"
        expectFalse(a.safeShareText.contains(a.apiKey))
        expectTrue(a.environmentText.contains("DEEPSEEK_WORK_01_BASE_URL"))
        expectTrue(a.localCurl.contains("${DEEPSEEK_WORK_01_API_KEY"))
        expectNotEqual(a.localBaseURL, b.localBaseURL)
        expectNotEqual(a.localKey, b.localKey)
    }
    func testOnlyOfficialDeepSeekHostGetsAutomaticBalanceRequest() throws {
        expectThrows(try APIClient.balanceRequest(for: record("https://deepseek.attacker.example")))
        expectEqual(try APIClient.balanceRequest(for: record("https://api.deepseek.com/v1")).url?.absoluteString, "https://api.deepseek.com/user/balance")
    }
}

final class VaultTests: TestSuite {
    func testEncryptedPersistenceAndTamperDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let disk = EncryptedVault(directory: directory, keyProvider: { key })
        var record = Credential(); record.apiKey = "secret-never-plain"; record.source = "also-secret-source"; record.curl = "private-curl"
        let vault = VaultData(credentials: [record]); try disk.save(vault)
        expectEqual(try disk.load().credentials, vault.credentials)
        let raw = try Data(contentsOf: disk.fileURL)
        expectNil(raw.range(of: Data(record.apiKey.utf8)))
        expectNil(raw.range(of: Data(record.source.utf8)))
        let attrs = try FileManager.default.attributesOfItem(atPath: disk.fileURL.path)
        expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let other = EncryptedVault(directory: directory, keyProvider: { SymmetricKey(size: .bits256) })
        expectThrows(try other.load())
        var tampered = raw; tampered[tampered.count - 1] ^= 1; try tampered.write(to: disk.fileURL)
        expectThrows(try disk.load())
    }
    func testPortableBackupRoundtripWrongPasswordAndTampering() throws {
        var record = Credential(); record.apiKey = "hidden-test-secret"
        let data = try PortableBackup.create(VaultData(credentials: [record]), password: "测试密码123456")
        expectFalse(String(data: data, encoding: .utf8)!.contains(record.apiKey))
        expectEqual(try PortableBackup.restore(data, password: "测试密码123456").credentials, [record])
        expectThrows(try PortableBackup.restore(data, password: "wrong-password"))
        expectThrows(try PortableBackup.create(VaultData(), password: "short"))
    }
}

final class ProxyTests: TestSuite {
    func sample() -> Credential {
        var record = Credential(); record.baseURL = "https://api.example.com/team/v1"; record.apiKey = "real-key-only-in-vault"; return record
    }
    func request(_ record: Credential, headers: [String: String] = [:], path: String = "/chat/completions") -> LocalHTTPRequest {
        var all = ["authorization": "Bearer " + record.localKey, "content-type": "application/json"]
        for (key, value) in headers { all[key] = value }
        return LocalHTTPRequest(method: "POST", target: "/s/" + record.routeID + path, headers: all, body: Data(#"{"model":"test","stream":true}"#.utf8))
    }
    func testAliasMapsToExactKeyAndPreservesPathBodyQuery() throws {
        let record = sample()
        let (upstream, id) = try request(record, path: "/chat/completions?stream=true&key=placeholder").upstream(records: [record])
        expectEqual(id, record.id)
        expectEqual(upstream.url?.absoluteString, "https://api.example.com/team/v1/chat/completions?stream=true")
        expectEqual(upstream.value(forHTTPHeaderField: "Authorization"), "Bearer real-key-only-in-vault")
        expectTrue(String(data: upstream.httpBody!, encoding: .utf8)!.contains("stream"))
        expectFalse(upstream.allHTTPHeaderFields!.values.contains(record.localKey))
    }
    func testMultipleKeysOnOneVendorRouteSeparately() throws {
        let a = sample(); var b = sample(); b.apiKey = "second-real-key"
        let records = [a, b]
        expectEqual(try request(a).upstream(records: records).0.value(forHTTPHeaderField: "Authorization"), "Bearer " + a.apiKey)
        expectEqual(try request(b).upstream(records: records).0.value(forHTTPHeaderField: "Authorization"), "Bearer " + b.apiKey)
        expectThrows(try request(a, headers: ["authorization": "Bearer " + b.localKey]).upstream(records: records))
    }
    func testBrowserArchivedExpiredTraversalAndUnknownAliasesAreDenied() {
        var record = sample()
        expectThrows(try request(record, headers: ["origin": "https://attacker.example"]).upstream(records: [record]))
        expectThrows(try request(record, path: "/../admin").upstream(records: [record]))
        expectThrows(try request(record).upstream(records: []))
        record.archived = true
        expectThrows(try request(record).upstream(records: [record]))
        record.archived = false; record.expiresAt = Date(timeIntervalSince1970: 0)
        expectThrows(try request(record).upstream(records: [record]))
    }
    func testHTTPFramingAndChunkedUploadRejection() throws {
        let partial = Data("POST /s/test/models HTTP/1.1\r\nContent-Length: 5\r\n\r\n123".utf8)
        expectNil(try LocalHTTPRequest.parse(partial))
        let full = partial + Data("45".utf8)
        expectEqual(try LocalHTTPRequest.parse(full)?.body, Data("12345".utf8))
        expectThrows(try LocalHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\n12".utf8)))
        expectThrows(try LocalHTTPRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        expectThrows(try LocalHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 9999999999\r\n\r\n".utf8)))
    }
}
