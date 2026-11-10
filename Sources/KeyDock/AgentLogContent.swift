import Foundation

enum AgentLogContent {
    // This only transforms the local diagnostic copy, never the wire request.
    static func modelRequest(_ text: String, includeHistory: Bool) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return "（请求正文无法解析，未记录）" }
        func clean(_ value: Any) -> Any {
            if let string = value as? String { return string.hasPrefix("data:image/") ? "[图片内容未记录]" : string }
            if let array = value as? [Any] {
                return array.filter { item in
                    guard let object = item as? [String: Any] else { return true }
                    if object["thought"] as? Bool == true { return false }
                    guard let type = object["type"] as? String else { return true }
                    return !["thinking", "redacted_thinking", "reasoning"].contains(type)
                }.map(clean)
            }
            if var object = value as? [String: Any] {
                if object["type"] as? String == "image" || object["type"] as? String == "input_image" || object["image_url"] != nil || object["inlineData"] != nil { return ["type": "image", "detail": "图片内容未记录"] }
                for key in ["reasoning_content", "reasoning_details", "encrypted_content", "thoughtSignature"] { object.removeValue(forKey: key) }
                if object["role"] as? String == "assistant" {
                    for key in ["reasoning", "thinking", "signature"] { object.removeValue(forKey: key) }
                }
                for key in object.keys { object[key] = clean(object[key]!) }
                return object
            }
            return value
        }
        var value = clean(json)
        if !includeHistory, var object = value as? [String: Any] {
            if let messages = object["messages"] as? [Any], messages.count > 2 {
                object["messages"] = Array(messages.suffix(2)); object["earlier_messages_omitted"] = messages.count - 2
            }
            if let input = object["input"] as? [Any], input.count > 2 {
                object["input"] = Array(input.suffix(2)); object["earlier_input_items_omitted"] = input.count - 2
            }
            if let contents = object["contents"] as? [Any], contents.count > 2 {
                object["contents"] = Array(contents.suffix(2)); object["earlier_contents_omitted"] = contents.count - 2
            }
            object.removeValue(forKey: "instructions"); object.removeValue(forKey: "system"); object.removeValue(forKey: "systemInstruction")
            if let tools = object.removeValue(forKey: "tools") as? [[String: Any]] {
                object["tool_names"] = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String ?? $0["name"] as? String }
            }
            object["diagnostic_note"] = "后续请求仅记录最新消息；初始上下文与工具定义见首次请求。"
            value = object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "（请求摘要无法生成）" }
        return String(decoding: data, as: UTF8.self)
    }

    static func toolSummary(_ name: String, arguments: String, output: String, failed: Bool) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let result = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
        if failed { return String((result["error"] as? String ?? result["message"] as? String ?? output).prefix(700)) }
        switch name {
        case "propose_credential":
            return [args["name"] as? String, result["model"] as? String, result["verified"] as? Bool == true ? "保留已有验证" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "list_models": return (result["models"] as? [String]).map { "已获取 \($0.count) 个模型" } ?? "正在获取模型目录"
        case "verify_credential": return [result["status"].map { "HTTP \($0)" }, result["message"] as? String].compactMap { $0 }.joined(separator: " · ")
        case "finish_import": return args["summary"] as? String ?? "正在汇总"
        case "fetch_document": return args["url"] as? String ?? "正在读取文档"
        case "read", "write", "edit": return args["path"] as? String ?? ""
        case "bash": return output.isEmpty ? "正在运行临时命令" : String(output.prefix(300))
        default: return String(output.prefix(300))
        }
    }
}
