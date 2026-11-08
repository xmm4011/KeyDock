import Foundation

enum DocumentText {
    // Read Feishu's public SSR JSON as data, never execute downloaded scripts.
    // Exclude application translations and UI settings from document evidence.
    static func body(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"clientVars\s*:\s*Object\s*\("#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        let bytes = Array(text[range.upperBound...].utf8)
        guard let start = bytes.firstIndex(of: 123) else { return "" }
        var depth = 0, quoted = false, escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0 {
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(bytes[start...index]))) as? [String: Any],
                          let data = object["data"] as? [String: Any], let blocks = data["block_map"] as? [String: [String: Any]] else { return "" }
                    var parts: [String] = [], visited = Set<String>()
                    func visit(_ id: String) {
                        guard visited.insert(id).inserted, let data = blocks[id]?["data"] as? [String: Any] else { return }
                        if let text = data["text"] as? [String: Any] {
                            if let attributed = text["initialAttributedTexts"] as? [String: Any], let values = attributed["text"] as? [String: String] {
                                parts.append(values.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { values[$0] }.joined())
                            }
                            if let pool = text["apool"] as? [String: Any], let attrs = pool["numToAttrib"] as? [String: [String]] {
                                for attr in attrs.values where attr.count == 2 && ["link", "href"].contains(attr[0]) { parts.append(attr[1]) }
                            }
                        }
                        if let code = data["code"] as? String { parts.append(code) }
                        for child in data["children"] as? [String] ?? [] { visit(child) }
                    }
                    for (id, block) in blocks where (block["data"] as? [String: Any])?["type"] as? String == "page" { visit(id) }
                    for id in blocks.keys.sorted() { visit(id) }
                    return parts.joined(separator: "\n")
                }
            }
        }
        return ""
    }
}
