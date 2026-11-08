import Foundation

enum LiveChecks {
    @MainActor static func run() async {
        print("等待临时 DeepSeek Key（stdin，仅保留在进程内存，不写入文件）")
        fflush(stdout)
        guard let key = readLine()?.trimmed, !key.isEmpty else { print("未提供 Key"); exit(1) }
        var record = Credential()
        record.name = "DeepSeek 临时联调"; record.provider = "DeepSeek"; record.baseURL = "https://api.deepseek.com"; record.apiKey = key
        let result = await APIClient.verify(record)
        guard result.state == .valid else {
            print("FAIL DeepSeek 鉴权验证：" + result.state.title + " HTTP " + String(result.httpStatus ?? 0)); exit(1)
        }
        print("PASS DeepSeek 模型列表鉴权；模型：" + result.models.joined(separator: ", "))
        do { _ = try await APIClient.balance(record); print("PASS DeepSeek 官方余额接口（余额数值不记录）") }
        catch { print("FAIL DeepSeek 余额查询：" + ((error as? KeyDockError)?.localizedDescription ?? "网络异常")); exit(1) }
        let model = result.models.contains("deepseek-chat") ? "deepseek-chat" : (result.models.first ?? "deepseek-chat")
        record.model = model
        let raw = "名称：虚构测试服务\nBase URL：https://example.com/v1\nAPI Key：sk-fixture-not-real-123456789\n用途：测试整理，请整理以上信息"
        do {
            let redacted = RedactedImport(raw)
            let organized = try await AIOrganizer.organize(redacted, reviewedText: redacted.text, service: record, model: model, original: raw)
            guard organized.count == 1, organized[0].apiKey == "sk-fixture-not-real-123456789", organized[0].baseURL == "https://example.com/v1" else { throw KeyDockError.message("整理结果字段不匹配") }
            print("PASS DeepSeek 直连 AI 整理、占位符还原及字段提取")
        } catch { print("FAIL AI 整理：" + ((error as? KeyDockError)?.localizedDescription ?? "网络异常")); exit(1) }
        let proxy = LocalProxy(); proxy.update([record]); proxy.start()
        for _ in 0..<100 { if proxy.running { break }; try? await Task.sleep(for: .milliseconds(20)) }
        guard proxy.running else { print("FAIL 本机代理无法启动"); exit(1) }
        do {
            var request = URLRequest(url: URL(string: record.localBaseURL + "/chat/completions")!)
            request.httpMethod = "POST"; request.setValue("Bearer " + record.localKey, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": "请只回复 OK"]], "stream": true, "thinking": ["type": "disabled"]])
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw KeyDockError.message("代理调用非 200") }
            var eventCount = 0, done = false
            for try await line in bytes.lines {
                guard !line.contains(key) else { throw KeyDockError.message("响应意外包含真实 Key") }
                if line.hasPrefix("data:") { eventCount += 1 }
                if line.contains("[DONE]") { done = true }
            }
            guard eventCount > 0, done else { throw KeyDockError.message("SSE 响应未完整结束") }
            guard !record.safeShareText.contains(key) else { throw KeyDockError.message("配置泄露检查失败") }
            print("PASS 本机别名 → DeepSeek 真实调用、SSE 完整转发、配置不含真实密钥")
        } catch { proxy.stop(); print("FAIL 代理调用：" + ((error as? KeyDockError)?.localizedDescription ?? "网络异常")); exit(1) }
        proxy.stop()
        try? await Task.sleep(for: .milliseconds(100))
        print("LIVE CHECKS PASSED；临时密钥未保存，可注销。")
    }
}
