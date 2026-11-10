import SwiftUI
import AppKit

enum HTTPBodyFormatting {
    struct Prepared { let text: String; let limited: Bool }
    static let expansionLimit = 8 * 1024 * 1024
    static func formatted(_ raw: String) -> String {
        prepared(raw).text
    }
    static func prepared(_ raw: String) -> Prepared {
        var limited = false
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasPrefix("data:") || normalized.hasPrefix("event:") || normalized.contains("\ndata:") {
            var events: [String] = [], count = 0
            for event in normalized.components(separatedBy: "\n\n") {
                if Task.isCancelled { return Prepared(text: raw, limited: false) }
                let lines = event.components(separatedBy: "\n")
                let data = lines.filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).hasPrefix(" ") ? String($0.dropFirst(6)) : String($0.dropFirst(5)) }
                let value = data.isEmpty ? event : (lines.filter { !$0.hasPrefix("data:") } + json(data.joined(separator: "\n"), limited: &limited).components(separatedBy: "\n").map { "data: " + $0 }).joined(separator: "\n")
                count += value.utf8.count + 2
                if limited || count > expansionLimit { return Prepared(text: raw, limited: true) }
                events.append(value)
            }
            return Prepared(text: events.joined(separator: "\n\n"), limited: false)
        }
        let value = json(raw, limited: &limited)
        return Prepared(text: value, limited: limited)
    }
    // A lexical formatter also works for historical truncated JSON. Preserve
    // numeric spellings and missing delimiters; do not invent a complete body.
    private static func json(_ raw: String, limited: inout Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return raw }
        if trimmed.hasPrefix("\""), let value = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed)) as? String,
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) { return String(decoding: data, as: UTF8.self) }
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return raw }
        let rest = trimmed.dropFirst().drop(while: { $0.isWhitespace })
        if let first = rest.first {
            if trimmed.hasPrefix("{") && first != "\"" && first != "}" { return raw }
            if trimmed.hasPrefix("[") && !"{[\"]-0123456789".contains(first) && !["true", "false", "null"].contains(where: { rest.hasPrefix($0) }) { return raw }
        }
        let bytes = Array(trimmed.utf8)
        var result = "", depth = 0, i = 0
        func newline() -> String { "\n" + String(repeating: "  ", count: min(depth, 100)) }
        while i < bytes.count {
            if i & 4095 == 0 && Task.isCancelled { return raw }
            if i & 4095 == 0 && result.utf8.count > expansionLimit { limited = true; return raw }
            let byte = bytes[i]
            switch byte {
            case 34:
                let start = i; i += 1; var escaped = false, closed = false
                while i < bytes.count {
                    let next = bytes[i]; i += 1
                    if escaped { escaped = false }
                    else if next == 92 { escaped = true }
                    else if next == 34 { closed = true; break }
                }
                var readable: String?
                for suffix in 0...(closed ? 0 : min(12, i - start - 1)) {
                    var token = Data(bytes[start..<(i - suffix)])
                    if !closed { token.append(34) }
                    if let decoded = try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed), decoded is String,
                       let encoded = try? JSONSerialization.data(withJSONObject: decoded, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                       let value = String(data: encoded, encoding: .utf8) {
                        readable = closed ? value : String(value.dropLast()) + String(decoding: bytes[(i - suffix)..<i], as: UTF8.self); break
                    }
                }
                result += readable ?? String(decoding: bytes[start..<i], as: UTF8.self)
                continue
            case 123, 91:
                result.append(Character(UnicodeScalar(byte))); depth += 1
                if i + 1 < bytes.count && bytes[i + 1] != 125 && bytes[i + 1] != 93 { result += newline() }
            case 125, 93:
                depth = max(0, depth - 1)
                if i > 0 && bytes[i - 1] != 123 && bytes[i - 1] != 91 { result += newline() }
                result.append(Character(UnicodeScalar(byte)))
            case 44: result += "," + newline()
            case 58: result += ": "
            case 9, 10, 13, 32: break
            default:
                if byte >= 128 {
                    let start = i
                    while i < bytes.count && bytes[i] >= 128 { i += 1 }
                    result += String(decoding: bytes[start..<i], as: UTF8.self); continue
                }
                result.append(Character(UnicodeScalar(byte)))
            }
            i += 1
        }
        if result.utf8.count > expansionLimit { limited = true; return raw }
        return result
    }
}

struct HTTPBodyTextView: NSViewRepresentable {
    let text: String
    var onCopy: ((String) -> Void)? = nil
    final class ReadOnlyTextView: NSTextView {
        var copySelection: ((String) -> Void)?
        override func copy(_ sender: Any?) {
            let range = selectedRange()
            guard range.length > 0 else { return }
            let value = (string as NSString).substring(with: range)
            if let copySelection { copySelection(value) }
            else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
        }
    }
    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView()
    }
    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let view = ReadOnlyTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textColor = .labelColor
        view.drawsBackground = false; view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.setAccessibilityLabel("调用正文，可全选复制")
        let menu = NSMenu()
        let select = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""); select.target = view; menu.addItem(select)
        let copy = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: ""); copy.target = view; menu.addItem(copy)
        view.menu = menu; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ReadOnlyTextView else { return }
        view.copySelection = onCopy
        guard view.string != text else { return }
        view.string = text; view.scrollToBeginningOfDocument(nil)
    }
}
