import Foundation

enum DomesticProviderChecks {
    static let providers: [(String, String, String)] = [
        ("千问北京", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
        ("千问业务空间", "https://workspace-fixture.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
        ("千问Coding", "https://coding.dashscope.aliyuncs.com/v1", "qwen-example"),
        ("豆包", "https://ark.cn-beijing.volces.com/api/v3", "ep-20260101-fixture"),
        ("豆包Coding", "https://ark.cn-beijing.volces.com/api/coding/v3", "doubao-seed-code"),
        ("Kimi", "https://api.moonshot.cn/v1", "kimi-example"),
        ("Kimi海外", "https://api.moonshot.ai/v1", "kimi-example"),
        ("DeepSeek", "https://api.deepseek.com", "deepseek-chat"),
        ("DeepSeek版本地址", "https://api.deepseek.com/v1", "deepseek-chat"),
        ("百川", "https://api.baichuan-ai.com/v1", "Baichuan-example"),
        ("中转", "https://relay-fixture.invalid/team/account/openai/v1", "alias/qwen-work")
    ]
    @MainActor static func run() async {
        for (name, base, model) in providers {
            var record = DeepChecks.record(); record.baseURL = base; record.model = model
            record.apiKey = "fixture-" + UUID().uuidString; record.extraHeaders = "X-Workspace: fixture-group"
            let expected = base + "/chat/completions"
            let session = MockURLProtocol.session { request in
                expectEqual(request.url?.absoluteString, expected)
                expectEqual(request.httpMethod, "POST")
                expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + record.apiKey)
                expectEqual(request.value(forHTTPHeaderField: "X-Workspace"), "fixture-group")
                let body = try JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request)) as? [String: Any]
                expectEqual(body?["model"] as? String, model)
                expectNil(body?["max_tokens"]); expectEqual(body?["stream"] as? Bool, false)
                return MockReply(body: Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"},"finish_reason":"length"}],"usage":{"total_tokens":3}}"#.utf8))
            }
            let result = await APIClient.verify(record, session: session, testModel: true)
            expectEqual(result.state, .valid); expectEqual(result.requestMethod, "POST")
            expectFalse(result.message.contains(record.apiKey))
            session.invalidateAndCancel(); checkpoint("Domestic.model-test-" + name)
        }
        for base in ["https://dashscope.aliyuncs.com/compatible-mode/v1", "https://api.baichuan-ai.com/v1"] {
            var record = DeepChecks.record(); record.baseURL = base
            let session = MockURLProtocol.session { _ in
                checkFailures.append("unsupported list endpoint was called"); return MockReply()
            }
            let result = await APIClient.verify(record, session: session)
            expectEqual(result.state, .uncertain); expectFalse(record.cleanupCandidate)
            expectThrows(try APIClient.modelTestRequest(for: record))
            session.invalidateAndCancel()
        }
        checkpoint("Domestic.unsupported-lists-never-auto-generate-or-expire-keys")
        runCheck("Domestic.models-paths-preserve-region-and-gateway-prefix") {
            for (_, base, _) in providers {
                var record = DeepChecks.record(); record.baseURL = base
                if APIClient.requiresModelTest(record) { continue }
                let request = try APIClient.verificationRequest(for: record)
                expectEqual(request.url?.absoluteString, ProviderPreset.matching(base)?.catalogURL ?? (base + "/models"))
                expectEqual(request.httpMethod, "GET")
            }
        }
        runCheck("Domestic.curl-import-retains-five-vendors-and-relay-alias") {
            let expectedNames = ["通义千问", "通义千问", "通义千问", "豆包 / 火山方舟", "豆包 / 火山方舟", "Kimi", "Kimi", "DeepSeek", "DeepSeek", "百川", "OpenAI"]
            for (index, provider) in providers.enumerated() {
                let (_, base, model) = provider
                let key = "fixture-" + UUID().uuidString
                let curl = "curl '\(base)/chat/completions' -H 'Authorization: Bearer \(key)' -H 'X-Workspace: fixture' -d '{\"model\":\"\(model)\",\"messages\":[]}'"
                let records = ImportParser.parse(curl)
                expectEqual(records.count, 1); expectEqual(records.first?.apiKey, key)
                expectEqual(records.first?.baseURL, base); expectEqual(records.first?.model, model)
                expectEqual(records.first?.provider, expectedNames[index])
                expectEqual(records.first?.kind, .compatible); expectEqual(records.first?.auth, .bearer)
            }
        }
        runCheck("Domestic.proxy-HTTP-errors-dont-delete-good-keys") {
            var record = DeepChecks.record(); record.baseURL = "https://relay-fixture.invalid/v1"
            let cases: [(Int, String, CheckState)] = [
                (401, "<html>login required</html>", .uncertain),
                (401, #"{"error":{"code":"model_not_found"}}"#, .uncertain),
                (401, #"{"error":{"type":"invalid_api_key"}}"#, .invalid),
                (403, #"{"error":{"code":"AccessDenied"}}"#, .restricted),
                (429, #"{"error":{"code":"insufficient_quota"}}"#, .quota),
                (400, #"{"error":{"code":"ModelNotOpen"}}"#, .uncertain),
                (404, #"{"error":{"message":"models not supported"}}"#, .uncertain),
                (200, #"{"success":false,"message":"invalid token"}"#, .uncertain)
            ]
            for (status, body, state) in cases {
                record.check = APIClient.classify(status: status, data: Data(body.utf8), record: record)
                expectEqual(record.check?.state, state)
                expectEqual(record.cleanupCandidate, state == .invalid)
            }
            record.baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
            expectEqual(APIClient.classify(status: 401, data: Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8), record: record).state, .uncertain)
        }
        runCheck("Domestic.failed-model-tests-never-look-successful-or-leak-keys") {
            let record = DeepChecks.record()
            for body in [#"{"choices":[]}"#, #"{"data":[]}"#, #"{"error":{"message":"secret echoed by provider"}}"#, "<html>proxy error</html>"] {
                expectEqual(APIClient.classify(status: 200, data: Data(body.utf8), record: record, testModel: true).state, .uncertain)
            }
        }
        runCheck("Domestic.old-vault-verification-record-decodes-without-new-field") {
            let result = try JSONDecoder().decode(CheckResult.self, from: Data(#"{"state":"valid","message":"old","checkedAt":0,"models":[],"endpoint":"https://fixture.invalid/models"}"#.utf8))
            expectEqual(result.state, .valid); expectNil(result.requestMethod)
        }
        runCheck("Domestic.copied-real-verification-curl-uses-the-correct-method-and-body") {
            var record = DeepChecks.record(); record.baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"; record.model = "qwen-plus"
            let curl = record.generatedCurl
            expectTrue(curl.contains("curl --request POST")); expectTrue(curl.contains("/chat/completions"))
            expectTrue(curl.contains("--data")); expectFalse(curl.contains("max_tokens")); expectTrue(curl.contains("正常用量"))
            record.model = ""; expectTrue(record.generatedCurl.contains("请先"))
            record.baseURL = "https://api.deepseek.com"
            expectTrue(record.generatedCurl.contains("curl --request GET")); expectFalse(record.generatedCurl.contains("--data"))
        }
    }
}
