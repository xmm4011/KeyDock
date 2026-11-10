import SwiftUI
import AppKit

struct ImportDocument {
    private final class Storage {
        let content: NSAttributedString
        let lock = NSLock()
        var cached: (text: String, paste: ImportPaste)?
        var builds = 0
        init(_ content: NSAttributedString) { self.content = NSAttributedString(attributedString: content) }
        func derived() -> (text: String, paste: ImportPaste) {
            lock.lock(); defer { lock.unlock() }
            if let cached { return cached }
            builds += 1
            var images: [ImportImage] = [], positions: [(NSRange, String)] = []
            content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                guard let image = (value as? ImportImageAttachment)?.value else { return }
                let index: Int
                if let existing = images.firstIndex(where: { $0.fingerprint == image.fingerprint }) { index = existing }
                else { index = images.count; images.append(image) }
                positions.append((range, "[图片 \(index + 1)]"))
            }
            let raw = content.string, source = raw as NSString
            var text = "", offset = 0
            if positions.isEmpty { text = raw }
            else {
                for (range, label) in positions { text += source.substring(with: NSRange(location: offset, length: range.location - offset)) + label; offset = NSMaxRange(range) }
                text += source.substring(from: offset)
            }
            let value = (text: text, paste: ImportPaste(text: raw.replacingOccurrences(of: "\u{fffc}", with: ""), images: images))
            cached = value; return value
        }
    }
    private var storage: Storage
    var identity: ObjectIdentifier { ObjectIdentifier(storage) }
    var derivationCount: Int { storage.lock.lock(); defer { storage.lock.unlock() }; return storage.builds }
    var content: NSAttributedString { get { storage.content } set { storage = Storage(newValue) } }
    init(_ paste: ImportPaste = ImportPaste()) { storage = Storage(Self.attributed(paste)) }
    init(content: NSAttributedString) { storage = Storage(content) }
    var images: [ImportImage] { storage.derived().paste.images }
    var text: String { storage.derived().text }
    var paste: ImportPaste { storage.derived().paste }
    mutating func append(_ paste: ImportPaste) throws {
        let result = NSMutableAttributedString(attributedString: content)
        if result.length > 0 && (!paste.text.isEmpty || !paste.images.isEmpty) { result.append(NSAttributedString(string: "\n", attributes: Self.attributes)) }
        let newImages = paste.images.filter { image in !images.contains(where: { $0.fingerprint == image.fingerprint }) }
        result.append(Self.attributed(ImportPaste(text: paste.text, images: newImages)))
        let candidate = ImportDocument(content: result); try ImportImage.validate(candidate.images)
        self = candidate
    }
    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left; paragraph.lineSpacing = 5
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }
    static func attributed(_ paste: ImportPaste) -> NSAttributedString {
        let result = NSMutableAttributedString(string: paste.text, attributes: attributes)
        for image in paste.images {
            if result.length > 0 && !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            result.append(NSAttributedString(attachment: ImportImageAttachment(image)))
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        return result
    }
}

final class ImportImageAttachment: NSTextAttachment {
    override class var supportsSecureCoding: Bool { true }
    let value: ImportImage
    init(_ value: ImportImage) {
        self.value = value; super.init(data: nil, ofType: nil)
        configureCell()
    }
    private func configureCell() {
        fileWrapper = FileWrapper(regularFileWithContents: value.data)
        fileWrapper?.preferredFilename = "image-" + value.id.uuidString + ".jpg"
        if let image = value.thumbnail {
            let scale = min(1, 340 / max(1, image.size.width), 190 / max(1, image.size.height))
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            attachmentCell = NSTextAttachmentCell(imageCell: image)
        }
    }
    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "KeyDock.imageData") as Data?,
              let name = coder.decodeObject(of: NSString.self, forKey: "KeyDock.imageName") as String?,
              let id = coder.decodeObject(of: NSString.self, forKey: "KeyDock.imageID") as String?, let uuid = UUID(uuidString: id),
              let value = try? ImportImage(restoring: uuid, name: name, normalizedJPEG: data) else { return nil }
        self.value = value; super.init(data: nil, ofType: nil); configureCell()
    }
    override func encode(with coder: NSCoder) {
        coder.encode(value.data as NSData, forKey: "KeyDock.imageData")
        coder.encode(value.name as NSString, forKey: "KeyDock.imageName")
        coder.encode(value.id.uuidString as NSString, forKey: "KeyDock.imageID")
    }
}

struct ImportTextEditor: NSViewRepresentable {
    @Binding var document: ImportDocument
    var onError: (String) -> Void
    var onPreview: (ImportImage) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ImportScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = PasteTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        editor.delegate = context.coordinator; editor.font = .systemFont(ofSize: 13)
        editor.isRichText = true; editor.importsGraphics = false; editor.isEditable = true; editor.isSelectable = true; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 1); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.typingAttributes = ImportDocument.attributes
        editor.onError = { [weak coordinator = context.coordinator] message in coordinator?.parent.onError(message) }
        editor.onPreview = { [weak coordinator = context.coordinator] image in coordinator?.parent.onPreview(image) }
        editor.onDocumentChange = { [weak coordinator = context.coordinator] content in coordinator?.changed(content) }
        scroll.documentView = editor
        DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PasteTextView else { return }
        if !editor.hasMarkedText(), context.coordinator.identity != document.identity {
            context.coordinator.identity = document.identity
            editor.textStorage?.setAttributedString(document.content)
            editor.setSelectedRange(NSRange(location: document.content.length, length: 0)); editor.typingAttributes = ImportDocument.attributes
        }
    }
    final class ImportScrollView: NSScrollView {
        override func tile() {
            super.tile()
            if let editor = documentView as? NSTextView {
                editor.minSize = NSSize(width: 0, height: contentSize.height)
                let size = NSSize(width: contentSize.width, height: max(editor.frame.height, contentSize.height))
                if editor.frame.size != size { editor.setFrameSize(size) }
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ImportTextEditor
        var identity: ObjectIdentifier?
        init(_ parent: ImportTextEditor) { self.parent = parent }
        func changed(_ content: NSAttributedString) {
            let document = ImportDocument(content: content); identity = document.identity; parent.document = document
        }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { changed(editor.attributedString()) }
        }
        func textView(_ textView: NSTextView, doubleClickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            if let image = (cell.attachment as? ImportImageAttachment)?.value { parent.onPreview(image) }
        }
    }
    final class PasteTextView: NSTextView {
        var onError: ((String) -> Void)?
        var onPreview: ((ImportImage) -> Void)?
        var onDocumentChange: ((NSAttributedString) -> Void)?
        private var undoObservers: [NSObjectProtocol] = []
        var pasteboardProvider: () -> NSPasteboard = { .general }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            undoObservers.forEach(NotificationCenter.default.removeObserver); undoObservers = []
            guard window != nil else { return }
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    guard let self, Thread.isMainThread else { return }; self.onDocumentChange?(self.attributedString())
                })
            }
        }
        deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }
        override func paste(_ sender: Any?) { insert(ImportPaste.from(pasteboardProvider())) }
        func image(at point: NSPoint) -> ImportImageAttachment? {
            guard let manager = layoutManager, let container = textContainer, manager.numberOfGlyphs > 0 else { return nil }
            let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let glyph = manager.glyphIndex(for: local, in: container)
            guard glyph < manager.numberOfGlyphs, manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
            let index = manager.characterIndexForGlyph(at: glyph)
            return textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? ImportImageAttachment
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let image = image(at: convert(event.locationInWindow, from: nil)) { onPreview?(image.value); return }
            super.mouseDown(with: event)
        }
        func insert(_ paste: ImportPaste) {
            if let error = paste.errors.first { onError?(error) }
            guard !paste.text.isEmpty || !paste.images.isEmpty else { return }
            let replacement = ImportDocument.attributed(paste)
            let candidate = NSMutableAttributedString(attributedString: attributedString())
            candidate.replaceCharacters(in: selectedRange(), with: replacement)
            do { try ImportImage.validate(ImportDocument(content: candidate).images) }
            catch { onError?(error.localizedDescription); return }
            insertText(replacement, replacementRange: selectedRange()); typingAttributes = ImportDocument.attributes
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let paste = ImportPaste.from(sender.draggingPasteboard)
            guard !paste.text.isEmpty || !paste.images.isEmpty || !paste.errors.isEmpty else { return false }
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
            insert(paste); return true
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let image = image(at: convert(event.locationInWindow, from: nil)) else { return super.menu(for: event) }
            let menu = NSMenu()
            for (title, action) in [("查看图片", #selector(previewImage(_:))), ("移除图片", #selector(removeImage(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = image; menu.addItem(item)
            }
            return menu
        }
        @objc func previewImage(_ sender: NSMenuItem) { if let image = sender.representedObject as? ImportImageAttachment { onPreview?(image.value) } }
        @objc func removeImage(_ sender: NSMenuItem) {
            guard let image = sender.representedObject as? ImportImageAttachment else { return }
            var location: NSRange?
            attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedString().length)) { value, range, stop in
                if let value = value as? ImportImageAttachment, value === image { location = range; stop.pointee = true }
            }
            if let location { insertText("", replacementRange: location) }
        }
    }
}

struct ImportImagePreview: View {
    let image: ImportImage
    @Environment(\.dismiss) private var dismiss
    @State private var actualSize = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(image.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(); Button(actualSize ? "适合窗口" : "实际大小") { actualSize.toggle() }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let preview = image.preview {
                        Image(nsImage: preview).resizable().scaledToFit()
                            .frame(width: actualSize ? preview.size.width : geometry.size.width - 32)
                            .padding(16).onTapGesture(count: 2) { actualSize.toggle() }
                    }
                }.background(Palette.canvas)
            }
        }.frame(width: 850, height: 640).sheetShortcuts { dismiss() }
    }
}
