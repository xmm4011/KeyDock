import Foundation
import AppKit
import CryptoKit

@MainActor enum LargeBodyChecks {
    static func source() -> String { #"{"text":""# + String(repeating: #"\u4f60\u597d🙂"#, count: 110000) + #"","literal":"\\u4f60","number":123456789012345678901234567890}"# }
    static func baseline() {
        runCheck("BodyPerformance.original-TextKit-large-single-paragraph-baseline") {
            let scroll = HTTPBodyTextView.makeScrollView(), window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll; defer { window.orderOut(nil) }
            let text = try unwrap(scroll.documentView as? NSTextView), raw = source()
            let start = Date(); text.string = raw; scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            text.layoutManager?.ensureLayout(for: try unwrap(text.textContainer))
            print("BODY BASELINE utf8=\(raw.utf8.count) assign-and-full-layout-ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        }
    }
    static func run() async {
        runCheck("BodyPerformance.pathological-format-expansion-is-bounded-and-keeps-the-exact-source") {
            let source = String(repeating: "[", count: 60000)
            let value = HTTPBodyFormatting.prepared(source)
            expectTrue(value.limited); expectEqual(value.text, source)
            let layout = try HTTPTextLayout(text: "\n\n", width: 200); expectEqual(layout.rows.count, 3)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-LargeBody-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let key = SymmetricKey(size: .bits256)
        let history = ProxyHistory(directory: root, keyProvider: { key }), model = HTTPLogPresentation()
        var entry = ProxyLogEntry(credentialID: UUID(), method: "POST", requestURL: "https://fixture.invalid/v1/chat/completions")
        let secret = "fixture-body-secret-123456789"
        entry.bodiesCaptured = true; entry.requestHeaders = "Authorization: Bearer " + secret
        let original = source()
        entry.requestBody = original.replacingOccurrences(of: "{", with: "{\"key\":\"" + secret + "\",", range: original.range(of: "{"))
        entry.responseBody = String(repeating: "data: {\"delta\":\"\\u4f60\\u597d🙂\",\"usage\":{\"input_tokens\":12}}\n\n", count: 18000) + "data: [DONE]\n\n"
        let policy = HTTPLogDisplayPolicy(fullContent: false, secrets: [secret])
        var maxGap = 0.0
        let heartbeat = Task { @MainActor in
            var previous = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }; let now = Date(); maxGap = max(maxGap, now.timeIntervalSince(previous)); previous = now
            }
        }
        defer { heartbeat.cancel(); model.cancel() }
        let started = Date()
        await model.load(entry, history: history, policy: policy)
        heartbeat.cancel()
        do {
            expectNil(model.error); expectEqual(model.documents.count, 4); expectEqual(model.preparationCount, 4)
            let documents = model.documents
            let safe = await Task.detached { documents.values.allSatisfy { !$0.text.contains(secret) && $0.initialLayout != nil } }.value
            expectTrue(safe)
            expectTrue(model.documents[.init(response: false, pretty: true)]?.text.contains("你好🙂") == true)
            expectTrue(model.documents[.init(response: true, pretty: true)]?.text.contains("[DONE]") == true)
            checkpoint("BodyPerformance.large-request-response-prepare-off-main-and-cache-all-four-private-variants")
            let prepare = Date().timeIntervalSince(started)
            let host = HTTPBodyViewportHost(frame: NSRect(x: 0, y: 0, width: 820, height: 500))
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.contentView = host; window.orderFront(nil); defer { host.clear(); window.orderOut(nil) }
            let variants = [HTTPLogVariant(response: false, pretty: true), .init(response: false, pretty: false), .init(response: true, pretty: true), .init(response: true, pretty: false)]
            var copied = ""
            let copy: (String) -> Void = { copied = $0; board.clearContents(); board.setString($0, forType: .string) }
            var slowest = 0.0
            for index in 0..<24 {
                let variant = variants[index % variants.count], tick = Date()
                host.configure(model.documents, selected: variant, copy: copy); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let scroll = try unwrap(host.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
                let text = try unwrap(scroll.documentView as? HTTPVirtualTextView)
                text.display()
                slowest = max(slowest, Date().timeIntervalSince(tick))
                expectTrue(text.renderedRowCount > 0 && text.renderedRowCount < 60); expectTrue(text.textLayout.rows.count > 1000)
                text.selectAll(nil); expectEqual(text.selectedRange.length, try unwrap(model.documents[variant]).length)
                text.copy(nil); expectEqual(copied, model.documents[variant]?.text)
                try await Task.sleep(for: .milliseconds(5))
            }
            expectEqual(model.preparationCount, 4); expectTrue(slowest < 0.15)
            checkpoint("BodyPerformance.24-native-switches-render-only-the-viewport-and-copy-complete-source-without-reformatting")
            try await Task.sleep(for: .milliseconds(300))
            let a = variants[0], b = variants[2]
            host.configure(model.documents, selected: a, copy: copy); host.layoutSubtreeIfNeeded()
            let scroll = try unwrap(host.subviews.compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1200)); scroll.reflectScrolledClipView(scroll.contentView)
            let reading = scroll.contentView.bounds.minY
            host.configure(model.documents, selected: b, copy: copy); host.layoutSubtreeIfNeeded()
            host.configure(model.documents, selected: a, copy: copy); host.layoutSubtreeIfNeeded()
            expectEqual(scroll.contentView.bounds.minY, reading)
            let text = try unwrap(scroll.documentView as? HTTPVirtualTextView)
            window.makeFirstResponder(text); text.selectAll(nil)
            let commandCopy = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
            expectTrue(text.performKeyEquivalent(with: commandCopy)); expectEqual(copied, text.document.text)
            window.makeFirstResponder(nil); copied = ""
            expectFalse(text.performKeyEquivalent(with: commandCopy)); expectEqual(copied, "")
            checkpoint("BodyPerformance.copy-shortcuts-only-handle-the-active-reading-focus")
            window.makeFirstResponder(text)
            copied = ""; host.configure([:], selected: a, copy: copy); text.copy(nil); expectEqual(copied, "")
            expectFalse(window.firstResponder === text)
            checkpoint("BodyPerformance.switches-preserve-reading-position-and-retired-documents-cannot-copy-stale-content")
            print("BODY PERFORMANCE request_utf8=\(entry.requestBody.utf8.count) response_utf8=\(entry.responseBody.utf8.count) prepare_ms=\(Int(prepare * 1000)) max_switch_ms=\(Int(slowest * 1000)) main_heartbeat_max_ms=\(Int(maxGap * 1000))")
            expectTrue(maxGap < 0.15)
            let png = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/body-ui")
            try FileManager.default.createDirectory(at: png, withIntermediateDirectories: true)
            host.configure(model.documents, selected: variants[1], copy: copy); host.layoutSubtreeIfNeeded()
            if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: image); try image.representation(using: .png, properties: [:])?.write(to: png.appendingPathComponent("large-raw.png")) }
            host.configure(model.documents, selected: variants[2], copy: copy); host.layoutSubtreeIfNeeded()
            if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: image); try image.representation(using: .png, properties: [:])?.write(to: png.appendingPathComponent("large-response.png")) }
            // Change visibility while old work is in flight. Its late result
            // must never repopulate the new policy's cache.
            let old = Task { await model.load(entry, history: history, policy: .init(fullContent: true, secrets: [])) }
            try await Task.sleep(for: .milliseconds(1)); old.cancel()
            await model.load(entry, history: history, policy: policy); await old.value
            expectEqual(model.policy, policy); expectEqual(model.documents.count, 4)
            for document in model.documents.values { expectFalse(document.text.contains(secret)) }
            checkpoint("BodyPerformance.privacy-change-cancels-stale-preparation-and-never-reintroduces-unmasked-bodies")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("BodyPerformance.native-viewer") }
        await LayoutChecks.largeBodyDetails()
    }
}
