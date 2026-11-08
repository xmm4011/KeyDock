import Foundation

@MainActor enum OutputLimitChecks {
    static let partial = #"{"object":"response","status":"incomplete","error":null,"incomplete_details":{"reason":"max_output_tokens"},"max_output_tokens":32,"output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"A brief reply is appropriate."}]},{"type":"message","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"你好！很高兴见到你"}]}],"usage":{"output_tokens":32}}"#
    static func run() async {
        for kind in [ServiceKind.compatible, .responses, .gemini] {
            runCheck("OutputLimits.default-probe-and-copy-omit-optional-output-limits-\(kind.rawValue)") {
                var record = DeepChecks.record(); record.model = "fixture-model"; record.kind = kind
                for request in [try APIClient.modelTestRequest(for: record), try APIClient.modelRequest(for: record)] {
                    let body = try object(request)
                    expectNoLimits(body)
                }
            }
        }
        for kind in [ServiceKind.compatible, .responses] {
            runCheck("OutputLimits.saved-template-and-Agent-body-cannot-reintroduce-optional-limits-\(kind.rawValue)") {
                var record = DeepChecks.record(); record.model = "fixture-model"; record.kind = kind
                let path = kind == .responses ? "responses" : "chat/completions"
                let text = #"{"model":"fixture-model","messages":[{"role":"user","content":"Hi"}],"input":"Hi","max_tokens":9999,"max_completion_tokens":9999,"max_output_tokens":9999}"#
                record.callTemplate = ModelCallTemplate(path: path, body: text, model: record.model)
                expectNoLimits(try object(APIClient.modelTestRequest(for: record)))
                expectNoLimits(try object(AgentVerification.request(record, arguments: ["path": path, "body": text]).0))
                expectNoLimits(try object(APIClient.modelRequest(for: record)))
            }
        }
        runCheck("OutputLimits.only-required-Messages-limit-is-retained") {
            var record = DeepChecks.record(); record.model = "fixture-model"; record.kind = .anthropic
            expectTrue(try object(APIClient.modelTestRequest(for: record))["max_tokens"] is NSNumber)
            for base in ["https://api.deepseek.com/anthropic/v1", "https://ark.cn-beijing.volces.com/api/compatible/v1"] {
                record.baseURL = base
                expectNoLimits(try object(APIClient.modelTestRequest(for: record)))
            }
        }
        runCheck("OutputLimits.incomplete-Responses-with-visible-answer-proves-inference-and-preserves-the-reason") {
            let result = classify(partial)
            expectEqual(result.state, .valid); expectEqual(result.requestMethod, "POST")
            expectTrue(result.message.contains("未完整")); expectTrue(result.response?.body.contains("max_output_tokens") == true)
            var record = DeepChecks.record(); record.check = result; expectEqual(record.stateTitle, "调用通过")
        }
        runCheck("OutputLimits.incomplete-reasoning-is-distinguished-from-empty-or-failed-Responses") {
            let reasoning = classify(#"{"object":"response","status":"incomplete","error":null,"output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"Working on the answer."}]}],"incomplete_details":{"reason":"max_output_tokens"}}"#)
            expectEqual(reasoning.state, .valid); expectTrue(reasoning.message.contains("推理"))
            for json in [#"{"object":"response","status":"incomplete","output":[]}"#,
                         #"{"object":"response","status":"in_progress","output":[]}"#,
                         #"{"object":"response","status":"failed","error":{"message":"failed"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"partial"}]}]}"#] {
                expectNotEqual(classify(json).state, .valid)
            }
        }
        runCheck("OutputLimits.incomplete-Responses-SSE-is-recognized-without-accepting-stream-errors") {
            let stream = "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":" + partial + "}\n\n"
            expectEqual(classify(stream).state, .valid)
            expectNotEqual(classify(stream + "data: {\"error\":{\"message\":\"failed\"}}\n\n").state, .valid)
        }
        runCheck("OutputLimits.historical-request-snapshot-remains-a-truthful-wire-record") {
            var request = URLRequest(url: URL(string: "https://fixture.invalid/chat/completions")!)
            request.httpMethod = "POST"; request.httpBody = Data(#"{"max_tokens":1}"#.utf8)
            expectTrue(CheckedRequest(request).curl.contains("max_tokens"))
        }
        let calls = AuditCounter()
        let session = MockURLProtocol.session { request in
            calls.increment(); let body = try object(request)
            if body["max_tokens"] != nil || body["max_output_tokens"] != nil || body["max_completion_tokens"] != nil {
                return MockReply(status: 400, body: Data(#"{"error":{"code":"unsupported_parameter","param":"max_tokens","message":"Unsupported parameter: max_tokens"}}"#.utf8))
            }
            return MockReply(body: Data(partial.utf8))
        }
        defer { session.invalidateAndCancel() }
        var record = DeepChecks.record(); record.kind = .responses; record.model = "fixture-model"
        let result = await APIClient.verify(record, session: session, testModel: true)
        expectEqual(result.state, .valid); expectEqual(calls.value, 1)
        checkpoint("OutputLimits.actual-Responses-probe-needs-no-parameter-fallback-or-paid-retry")
    }
    private static func object(_ request: URLRequest) throws -> [String: Any] {
        try unwrap(try JSONSerialization.jsonObject(with: DeepNetworkChecks.bodyData(request)) as? [String: Any])
    }
    private static func expectNoLimits(_ body: [String: Any]) {
        for field in ["max_tokens", "max_completion_tokens", "max_output_tokens"] { expectNil(body[field]) }
        expectNil((body["generationConfig"] as? [String: Any])?["maxOutputTokens"])
    }
    private static func classify(_ text: String) -> CheckResult {
        var record = DeepChecks.record(); record.kind = .responses; record.model = "fixture-model"
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/v1/responses")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return AgentVerification.classify(Data(text.utf8), response: response, record: record, method: "POST", endpoint: response.url!.absoluteString)
    }
}
