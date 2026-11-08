import Foundation
import SwiftUI
import AppKit
import CryptoKit

// Exercises newly constructed controls in an invisible test window. It never targets
// an existing application/window or the user's clipboard and cannot read vault data.
@MainActor enum EditorInteractionChecks {
    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        runCheck("UI.native-editor-trailing-spaces-move-caret-immediately") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256)
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.purpose = "D"
                let hosting = NSHostingView(rootView: CredentialEditor(record: record).environmentObject(store).disclosureGroupStyle(FullRowDisclosureStyle()))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 680, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting; defer { window.close() }
                hosting.layoutSubtreeIfNeeded()
                for _ in 0..<20 {
                    if fields(hosting).contains(where: { $0.stringValue == "D" }) { break }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02)); hosting.layoutSubtreeIfNeeded()
                }
                let field = try unwrap(fields(hosting).first { $0.stringValue == "D" })
                expectTrue(field.alignment == .left || field.alignment == .natural)
                field.selectText(nil)
                let editor = try unwrap(field.currentEditor() as? NSTextView)
                editor.setSelectedRange(NSRange(location: 1, length: 0))
                let before = editor.firstRect(forCharacterRange: NSRange(location: 1, length: 0), actualRange: nil)
                editor.insertText("  ", replacementRange: editor.selectedRange())
                editor.layoutManager?.ensureLayout(for: editor.textContainer!)
                let after = editor.firstRect(forCharacterRange: NSRange(location: 3, length: 0), actualRange: nil)
                expectEqual(editor.string, "D  "); expectTrue(after.minX > before.minX + 3)
                editor.insertText("国内 测试", replacementRange: editor.selectedRange())
                expectEqual(editor.string, "D  国内 测试")
            }
        }
        runCheck("UI.native-paste-inserts-text-and-adds-real-image-attachment") {
            try NewFeatureChecks.isolated { root in
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let image = try NewFeatureChecks.image(), file = root.appendingPathComponent("fixture.jpg"); try image.data.write(to: file)
                var document = ImportDocument(), previewed: UUID?
                let control = ImportTextEditor(document: Binding(get: { document }, set: { document = $0 }), onError: { checkFailures.append($0) }, onPreview: { previewed = $0.id })
                let hosting = NSHostingView(rootView: control)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting; defer { window.close() }
                hosting.layoutSubtreeIfNeeded()
                let editor = try unwrap(descendants(hosting).compactMap { $0 as? ImportTextEditor.PasteTextView }.first)
                editor.pasteboardProvider = { board }
                board.setString("聊天内容\n" + file.path, forType: .string)
                editor.paste(nil)
                expectEqual(document.images.count, 1); expectTrue(editor.string.contains("聊天内容")); expectTrue(document.text.contains("聊天内容")); expectFalse(editor.string.contains(file.path))
                let attachmentRange = (editor.string as NSString).range(of: "\u{fffc}")
                expectTrue(attachmentRange.location != NSNotFound)
                let attachment = try unwrap(editor.textStorage?.attribute(.attachment, at: attachmentRange.location, effectiveRange: nil) as? ImportImageAttachment)
                let manager = try unwrap(editor.layoutManager), container = try unwrap(editor.textContainer)
                manager.ensureLayout(for:container)
                let glyphs = manager.glyphRange(forCharacterRange:attachmentRange,actualCharacterRange:nil)
                let bounds = manager.boundingRect(forGlyphRange:glyphs,in:container).offsetBy(dx:editor.textContainerOrigin.x,dy:editor.textContainerOrigin.y)
                let point = NSPoint(x:bounds.midX,y:bounds.midY)
                expectTrue(editor.image(at:point) === attachment)
                let location = editor.convert(point,to:nil)
                let event = try unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:2,pressure:1))
                editor.mouseDown(with:event)
                expectEqual(previewed, document.images.first?.id)
                let menu = try unwrap(editor.menu(for:event))
                expectEqual(menu.items.map(\.title),["查看图片","移除图片"])
                editor.setSelectedRange(attachmentRange); editor.deleteBackward(nil)
                expectTrue(document.images.isEmpty); expectTrue(document.text.contains("聊天内容"))
                board.clearContents(); board.setData(image.data, forType: .png)
                editor.paste(nil); expectEqual(document.images.count, 1)
            }
        }
        runCheck("UI.inline-image-delete-undo-and-text-edits-keep-attachments-synchronized") {
            let image = try NewFeatureChecks.image()
            var document = ImportDocument(ImportPaste(text: "前面的文字", images: [image]))
            let control = ImportTextEditor(document: Binding(get: { document }, set: { document = $0 }), onError: { checkFailures.append($0) }, onPreview: { _ in })
            let hosting = NSHostingView(rootView: control)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 620, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; defer { window.close() }
            for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let editor = try unwrap(descendants(hosting).compactMap { $0 as? ImportTextEditor.PasteTextView }.first)
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.insertText("新文字 ", replacementRange: editor.selectedRange())
            expectEqual(document.images.count, 1); expectTrue(document.text.hasPrefix("新文字 前面的文字"))
            let range = (editor.string as NSString).range(of: "\u{fffc}")
            editor.setSelectedRange(range); editor.deleteBackward(nil); expectTrue(document.images.isEmpty)
            let undo = try unwrap(editor.undoManager); expectTrue(undo.canUndo); undo.undo()
            expectEqual(document.images.count, 1); expectTrue(document.text.contains("[图片 1]"))
        }
        runCheck("UI.inline-image-limit-rejects-paste-without-losing-existing-content") {
            var document = ImportDocument(ImportPaste(text: "保留这段输入"))
            var unique: [ImportImage] = []
            for index in 0..<7 {
                // Different valid images, not seven references to the same attachment.
                let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                let bytes = bitmap.bitmapData!
                for x in 0..<8 { for y in 0..<8 { let offset = y * bitmap.bytesPerRow + x * 3; bytes[offset] = UInt8(index * 32); bytes[offset+1] = 70; bytes[offset+2] = 140 } }
                unique.append(try ImportImage(data:bitmap.representation(using:.png,properties:[:])!))
            }
            expectEqual(Set(unique.map(\.fingerprint)).count,7)
            try document.append(ImportPaste(images:Array(unique.prefix(6))))
            let before = document.content
            expectThrows(try document.append(ImportPaste(text:"不能覆盖原文",images:[unique[6]])))
            expectTrue(document.content.isEqual(to:before)); expectEqual(document.images.count,6)
        }
        runCheck("UI.image-attachment-secure-archive-preserves-original-bytes-and-identity") {
            let image = try NewFeatureChecks.image()
            let data = try NSKeyedArchiver.archivedData(withRootObject:ImportImageAttachment(image),requiringSecureCoding:true)
            let restored = try unwrap(NSKeyedUnarchiver.unarchivedObject(ofClass:ImportImageAttachment.self,from:data))
            expectEqual(restored.value.id,image.id); expectEqual(restored.value.data,image.data)
            expectEqual(restored.fileWrapper?.regularFileContents,image.data)
        }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func fields(_ view: NSView) -> [NSTextField] { descendants(view).compactMap { $0 as? NSTextField } }
}
