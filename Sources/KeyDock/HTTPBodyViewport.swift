import SwiftUI
import AppKit
import CoreText

final class HTTPTextDocument: @unchecked Sendable {
    let id = UUID()
    let text: String
    let length: Int
    let initialLayout: HTTPTextLayout?
    let notice: String?
    init(text: String, notice: String? = nil) throws {
        self.notice = notice
        self.text = text; length = text.utf16.count
        initialLayout = length > 32768 ? try HTTPTextLayout(text: text, width: 700) : nil
    }
}

// Bound each shaping operation, including JSON containing a megabyte-long
// string with no newlines. Only source ranges are indexed; copy uses the source.
final class HTTPTextLayout: @unchecked Sendable {
    static let font = CTFontCreateWithName("Menlo-Regular" as CFString, 12, nil)
    static let cellWidth: CGFloat = {
        var character: UniChar = 77, glyph: CGGlyph = 0, advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }()
    let source: NSString
    let rows: [NSRange]
    let width: CGFloat
    init(text: String, width: CGFloat) throws {
        self.width = max(100, width); source = text as NSString
        let bytes = Array(text.utf16)
        var rows: [NSRange] = [], offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            if bytes[offset] == 10 { rows.append(NSRange(location: offset, length: 0)); offset += 1; if offset == bytes.count { rows.append(NSRange(location: offset, length: 0)) }; continue }
            var end = offset, used: CGFloat = 0
            // Index conservatively in monospace cells. This is linear scanning,
            // not document-wide glyph shaping. CoreText shapes visible rows only.
            while end < bytes.count && bytes[end] != 10 && end - offset < 512 {
                let unit = bytes[end], surrogate = (0xd800...0xdbff).contains(unit) && end + 1 < bytes.count && (0xdc00...0xdfff).contains(bytes[end + 1])
                let combining = (0x0300...0x036f).contains(unit) || (0x1ab0...0x1aff).contains(unit) || (0x1dc0...0x1dff).contains(unit) || (0x20d0...0x20ff).contains(unit) || (0xfe00...0xfe0f).contains(unit) || unit == 0x200d || unit == 13
                let cells: CGFloat = combining ? 0 : (unit == 9 ? 8 : (unit < 128 ? 1 : 2))
                if used + cells * Self.cellWidth > self.width && end > offset { break }
                used += cells * Self.cellWidth; end += surrogate ? 2 : 1
            }
            if end < bytes.count && end > offset && bytes[end] != 10 {
                let cluster = source.rangeOfComposedCharacterSequence(at: end)
                if cluster.location > offset && cluster.location < end { end = cluster.location }
            }
            rows.append(NSRange(location: offset, length: end - offset))
            offset = end
            if offset < bytes.count && bytes[offset] == 10 { offset += 1; if offset == bytes.count { rows.append(NSRange(location: offset, length: 0)) } }
        }
        self.rows = rows.isEmpty ? [NSRange(location: 0, length: 0)] : rows
    }
    func row(containing offset: Int) -> Int {
        var low = 0, high = rows.count
        while low < high { let middle = (low + high) / 2; if rows[middle].location <= offset { low = middle + 1 } else { high = middle } }
        return max(0, low - 1)
    }
}

struct HTTPBodyViewport: NSViewRepresentable {
    var documents: [HTTPLogVariant: HTTPTextDocument]
    var selected: HTTPLogVariant
    var onCopy: (String) -> Void
    func makeNSView(context: Context) -> HTTPBodyViewportHost { HTTPBodyViewportHost() }
    func updateNSView(_ view: HTTPBodyViewportHost, context: Context) { view.configure(documents, selected: selected, copy: onCopy) }
    static func dismantleNSView(_ view: HTTPBodyViewportHost, coordinator: ()) { view.clear() }
}

// One scroll view per prepared choice preserves selection and reading position.
// Switching is a visibility change, never NSTextStorage replacement or relayout.
final class HTTPBodyViewportHost: NSView {
    private var views: [UUID: NSScrollView] = [:]
    private(set) var documentID: UUID?
    private(set) var activationCount = 0
    private(set) var availableDocumentCount = 0
    override var isFlipped: Bool { true }
    func configure(_ documents: [HTTPLogVariant: HTTPTextDocument], selected: HTTPLogVariant, copy: @escaping (String) -> Void) {
        let retained = Set(documents.values.map(\.id))
        availableDocumentCount = documents.count
        let readerFocused = views.values.contains { window?.firstResponder === $0.documentView }
        for id in Array(views.keys) where !retained.contains(id) {
            let scroll = views.removeValue(forKey: id)
            if window?.firstResponder === scroll?.documentView { window?.makeFirstResponder(nil) }
            (scroll?.documentView as? HTTPVirtualTextView)?.revoke()
            (scroll?.documentView as? HTTPBodyTextView.ReadOnlyTextView)?.copySelection = { _ in }
            scroll?.removeFromSuperview()
        }
        guard let document = documents[selected] else { if readerFocused { window?.makeFirstResponder(nil) }; views.values.forEach { $0.isHidden = true }; documentID = nil; return }
        if views[document.id] == nil {
            let scroll: NSScrollView
            if let layout = document.initialLayout {
                scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
                let text = HTTPVirtualTextView(document: document, layout: layout); text.copySelection = copy
                scroll.documentView = text
            } else {
                scroll = HTTPBodyTextView.makeScrollView()
                if let text = scroll.documentView as? HTTPBodyTextView.ReadOnlyTextView { text.string = document.text.isEmpty ? "（空正文）" : document.text; text.copySelection = copy }
            }
            scroll.frame = bounds; scroll.autoresizingMask = [.width, .height]; views[document.id] = scroll; addSubview(scroll)
        }
        for (id, scroll) in views {
            scroll.isHidden = id != document.id
            (scroll.documentView as? HTTPVirtualTextView)?.copySelection = copy
            (scroll.documentView as? HTTPBodyTextView.ReadOnlyTextView)?.copySelection = copy
        }
        if documentID != document.id {
            documentID = document.id; activationCount += 1
            if readerFocused { window?.makeFirstResponder(views[document.id]?.documentView) }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for scroll in views.values where !scroll.isHidden {
            scroll.frame = bounds
            if let view = scroll.documentView as? HTTPVirtualTextView { view.resize(to: scroll.contentSize) }
        }
    }
    func clear() { for view in views.values { if window?.firstResponder === view.documentView { window?.makeFirstResponder(nil) }; (view.documentView as? HTTPVirtualTextView)?.revoke(); view.removeFromSuperview() }; views.removeAll(); documentID = nil }
}

final class HTTPVirtualTextView: NSView {
    static let rowHeight: CGFloat = 20, padding: CGFloat = 14
    let document: HTTPTextDocument
    private(set) var textLayout: HTTPTextLayout
    private var selection = NSRange(location: 0, length: 0), anchor = 0
    private var active = true
    private var widthTicket: Int?
    private var reflow: Task<Void, Never>?
    private var layouts: [Int: HTTPTextLayout] = [:]
    private var lineCache: [Int: CTLine] = [:]
    private(set) var renderedRowCount = 0
    var copySelection: ((String) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(document: HTTPTextDocument, layout: HTTPTextLayout) {
        self.document = document; textLayout = layout; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.textArea); setAccessibilityLabel("调用正文，可全选复制")
        setAccessibilityValue(layout.source)
        let menu = NSMenu()
        for (title, action) in [("全选", #selector(selectAll(_:))), ("复制", #selector(copy(_:)))] { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }; self.menu = menu
    }
    required init?(coder: NSCoder) { nil }
    deinit { reflow?.cancel() }
    func cancelLayout() { reflow?.cancel(); reflow = nil }
    func revoke() { active = false; cancelLayout(); selection = NSRange(location: 0, length: 0); copySelection = { _ in }; setAccessibilityValue("") }
    func resize(to size: NSSize) {
        frame.size = NSSize(width: size.width, height: max(size.height, CGFloat(textLayout.rows.count) * Self.rowHeight + Self.padding * 2))
        let width = max(100, Int((size.width - Self.padding * 2) / 8) * 8)
        guard widthTicket != width else { return }; widthTicket = width
        reflow?.cancel()
        if let layout = layouts[width] { apply(layout); return }
        let text = document.text
        reflow = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
                let task = Task.detached(priority: .userInitiated) { try HTTPTextLayout(text: text, width: CGFloat(width)) }
                let layout = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation(); guard let self, self.widthTicket == width else { return }
                if self.layouts.count >= 3 { self.layouts.removeAll() }; self.layouts[width] = layout; self.apply(layout)
            } catch { }
        }
    }
    private func apply(_ layout: HTTPTextLayout) {
        let visible = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        let row = min(textLayout.rows.count - 1, max(0, Int((visible - Self.padding) / Self.rowHeight)))
        let offset = textLayout.rows[row].location
        let remainder = max(0, visible - Self.padding - CGFloat(row) * Self.rowHeight)
        textLayout = layout; lineCache.removeAll()
        frame.size.height = max(enclosingScrollView?.contentSize.height ?? 0, CGFloat(layout.rows.count) * Self.rowHeight + Self.padding * 2)
        let y = visible == 0 ? 0 : Self.padding + CGFloat(layout.row(containing: offset)) * Self.rowHeight + remainder
        scroll(NSPoint(x: 0, y: y)); needsDisplay = true
    }
    private func line(_ row: Int) -> CTLine {
        if let cached = lineCache[row] { return cached }
        if lineCache.count > 200 { lineCache.removeAll() }
        let value = textLayout.source.substring(with: textLayout.rows[row])
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): HTTPTextLayout.font, .init(kCTForegroundColorAttributeName as String): NSColor.labelColor.cgColor]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attrs)); lineCache[row] = line; return line
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); lineCache.removeAll(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = dirtyRect.intersection(visibleRect)
        guard !visible.isEmpty else { return }
        let start = max(0, Int((visible.minY - Self.padding) / Self.rowHeight)), end = min(textLayout.rows.count, Int(ceil((visible.maxY - Self.padding) / Self.rowHeight)) + 1)
        renderedRowCount = max(0, end - start)
        guard start < end else { return }
        for row in start..<end {
            let range = textLayout.rows[row], line = line(row), top = Self.padding + CGFloat(row) * Self.rowHeight
            let selected = NSIntersectionRange(selection, range)
            if selected.length > 0 {
                let x = CTLineGetOffsetForStringIndex(line, selected.location - range.location, nil), right = CTLineGetOffsetForStringIndex(line, NSMaxRange(selected) - range.location, nil)
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill(); NSRect(x: Self.padding + min(x, right), y: top, width: max(2, abs(right - x)), height: Self.rowHeight).fill()
            }
            context.saveGState(); context.translateBy(x: Self.padding, y: top + 14); context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero
            CTLineDraw(line, context); context.restoreGState()
        }
    }
    private func offset(at point: NSPoint) -> Int {
        let row = min(textLayout.rows.count - 1, max(0, Int((point.y - Self.padding) / Self.rowHeight))), range = textLayout.rows[row]
        let index = CTLineGetStringIndexForPosition(line(row), CGPoint(x: max(0, point.x - Self.padding), y: 0))
        return range.location + min(range.length, max(0, index == kCFNotFound ? range.length : index))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); let offset = offset(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift) { select(to: offset) }
        else if event.clickCount >= 2 && offset < document.length {
            var word = textLayout.source.rangeOfComposedCharacterSequence(at: offset)
            let row = textLayout.rows[textLayout.row(containing: offset)], value = textLayout.source.substring(with: row) as NSString
            value.enumerateSubstrings(in: NSRange(location: 0, length: value.length), options: [.byWords, .substringNotRequired]) { _, range, _, stop in
                if NSLocationInRange(offset - row.location, range) { word = NSRange(location: row.location + range.location, length: range.length); stop.pointee = true }
            }
            selection = word; anchor = word.location; needsDisplay = true
        } else { anchor = offset; selection = NSRange(location: offset, length: 0); needsDisplay = true }
    }
    override func mouseDragged(with event: NSEvent) { autoscroll(with: event); select(to: offset(at: convert(event.locationInWindow, from: nil))) }
    private func select(to offset: Int) { selection = NSRange(location: min(anchor, offset), length: abs(offset - anchor)); needsDisplay = true }
    override func selectAll(_ sender: Any?) { guard active else { return }; anchor = 0; selection = NSRange(location: 0, length: document.length); needsDisplay = true }
    @objc func copy(_ sender: Any?) { guard active, selection.length > 0 else { return }; copySelection?(textLayout.source.substring(with: selection)) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard active, !isHiddenOrHasHiddenAncestor, window?.firstResponder === self else { return false }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command else { return false }
        if event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(nil); return true }
        if event.charactersIgnoringModifiers?.lowercased() == "c" { copy(nil); return true }; return false
    }
    override func keyDown(with event: NSEvent) {
        if performKeyEquivalent(with: event) { return }
        if [115, 119].contains(event.keyCode) { scroll(NSPoint(x: 0, y: event.keyCode == 115 ? 0 : frame.height)); return }
        if [116, 121].contains(event.keyCode) { scroll(NSPoint(x: 0, y: max(0, (enclosingScrollView?.contentView.bounds.minY ?? 0) + (event.keyCode == 116 ? -1 : 1) * (enclosingScrollView?.contentSize.height ?? 400)))); return }
        guard [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
        let current = event.modifierFlags.contains(.shift) ? (anchor == selection.location ? NSMaxRange(selection) : selection.location) : selection.location
        var next = current
        if event.keyCode == 123 { next = current > 0 ? textLayout.source.rangeOfComposedCharacterSequence(at: current - 1).location : 0 }
        if event.keyCode == 124 { next = current < document.length ? NSMaxRange(textLayout.source.rangeOfComposedCharacterSequence(at: current)) : document.length }
        if event.keyCode == 125 || event.keyCode == 126 {
            let row = textLayout.row(containing: current), target = min(textLayout.rows.count - 1, max(0, row + (event.keyCode == 125 ? 1 : -1)))
            next = textLayout.rows[target].location + min(current - textLayout.rows[row].location, textLayout.rows[target].length)
        }
        if event.modifierFlags.contains(.shift) { select(to: next) } else { anchor = next; selection = NSRange(location: next, length: 0); needsDisplay = true }
        scrollToVisible(NSRect(x: 0, y: Self.padding + CGFloat(textLayout.row(containing: next)) * Self.rowHeight, width: 1, height: Self.rowHeight))
    }
    var selectedRange: NSRange { selection }
    override func accessibilityNumberOfCharacters() -> Int { document.length }
    override func accessibilitySelectedText() -> String? { textLayout.source.substring(with: selection) }
    override func accessibilitySelectedTextRange() -> NSRange { selection }
}
