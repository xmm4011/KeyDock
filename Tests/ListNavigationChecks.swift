import AppKit
import SwiftUI
import CryptoKit
import Vision

// Dispatches native events only to newly constructed offscreen test windows.
@MainActor enum ListNavigationChecks {
    private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    }
    private static let applicationDelegate = ApplicationDelegate()

    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.delegate = applicationDelegate
        runCheck("Navigation.initial-selection-is-visible-even-when-it-is-near-the-end-of-a-long-list") {
            try fixture(count: 14, initiallySelectedIndex: 13) { store, rows, _, view in
                expectEqual(store.selectedID, rows.last?.id)
                _ = try textBounds(try unwrap(rows.last).name, in: view, listOnly: true)
            }
        }
        runCheck("Navigation.favorite-sort-changes-keep-the-selected-row-visible") {
            try fixture(count: 14, initiallySelectedIndex: 13) { store, rows, _, view in
                let row = try unwrap(rows.last)
                store.toggleFavorite(row); settle(view)
                expectEqual(store.selectedID, row.id)
                _ = try textBounds(row.name, in: view, listOnly: true)
                store.toggleFavorite(try unwrap(store.selected)); settle(view)
                expectEqual(store.selectedID, row.id)
                _ = try textBounds(row.name, in: view, listOnly: true)
                try search("Navigation1", view: view)
                _ = try textBounds(rows[9].name, in: view, listOnly: true)
                store.toggleFavorite(try unwrap(store.selected)); settle(view)
                _ = try textBounds(row.name, in: view, listOnly: true)
                store.toggleFavorite(try unwrap(store.selected)); settle(view)
                _ = try textBounds(row.name, in: view, listOnly: true)
            }
        }
        runCheck("Navigation.whole-card-click-and-up-down-select-in-visible-order-without-wrapping") {
            try fixture(count: 3) { store, rows, window, view in
                try clickRow(rows[1].name, window: window, view: view)
                expectEqual(store.selectedID, rows[1].id)
                try press(125, "\u{f701}", window: window); settle(view)
                expectEqual(store.selectedID, rows[2].id)
                try press(125, "\u{f701}", window: window); settle(view)
                expectEqual(store.selectedID, rows[2].id)
                for expected in [rows[1], rows[0], rows[0]] {
                    try press(126, "\u{f700}", window: window); settle(view)
                    expectEqual(store.selectedID, expected.id)
                }
            }
        }
        runCheck("Navigation.search-Return-enters-filtered-results-without-stealing-text-or-sheet-keys") {
            try fixture(count: 3) { store, rows, window, view in
                try search("target-group", view: view)
                try press(125, "\u{f701}", window: window); settle(view)
                expectEqual(store.selectedID, rows[0].id)
                expectTrue(try searchField(view).currentEditor() != nil)
                try press(36, "\r", window: window); settle(view)
                expectNil(try searchField(view).currentEditor())
                try press(125, "\u{f701}", window: window); settle(view)
                expectEqual(store.selectedID, rows[1].id)
                try press(125, "\u{f701}", window: window); settle(view)
                expectEqual(store.selectedID, rows[1].id)
                try press(126, "\u{f700}", window: window); settle(view)
                expectEqual(store.selectedID, rows[0].id)
                NotificationCenter.default.post(name: .keydockNew, object: nil)
                for _ in 0..<30 { if window.attachedSheet != nil { break }; settle(view) }
                let sheet = try unwrap(window.attachedSheet)
                // Fix the target explicitly: Down on the preset popup legitimately
                // opens a native menu and waits for a user selection.
                let input = try unwrap(descendants(try unwrap(sheet.contentView)).compactMap { $0 as? NSTextField }.first { $0.isEditable && !($0 is NSSecureTextField) })
                input.selectText(nil)
                expectTrue(input.currentEditor() != nil)
                try press(125, "\u{f701}", window: sheet); settle(view)
                expectEqual(store.selectedID, rows[0].id)
                window.endSheet(sheet); sheet.close()
            }
            try fixture(count: 2) { store, _, window, view in
                try search("no-matching-record", view: view)
                expectNil(store.selectedID)
                try press(36, "\r", window: window); settle(view)
                expectNil(store.selectedID); expectTrue(try searchField(view).currentEditor() != nil)
            }
        }
        runCheck("Navigation.keyboard-selection-scrolls-the-selected-row-into-view") {
            try fixture(count: 14) { store, rows, window, view in
                try clickRow(rows[0].name, window: window, view: view)
                for _ in 1..<rows.count { try press(125, "\u{f701}", window: window); settle(view) }
                expectEqual(store.selectedID, rows.last?.id)
                let bounds = try textBounds(try unwrap(rows.last).name, in: view, listOnly: true)
                expectTrue(bounds.minY >= 0 && bounds.maxY <= view.bounds.height)
                try press(126, "\u{f700}", window: window); settle(view)
                expectEqual(store.selectedID, rows[rows.count - 2].id)
                _ = try textBounds(rows[rows.count - 2].name, in: view, listOnly: true)
            }
        }
        runCheck("Navigation.direct-name-matches-rank-before-favorite-model-matches-and-show-why") {
            var official = DeepChecks.record(); official.name = "DeepSeek"; official.provider = "DeepSeek"; official.model = "deepseek-chat"
            var gateway = official; gateway.id = UUID(); gateway.name = "Baidu Gateway"; gateway.provider = "Baidu"; gateway.apiKey = "fixture-search-gateway-key"; gateway.model = "gemini-flash"; gateway.favorite = true
            gateway.modelCatalog = ModelCatalog(models: ["deepseek-v3", "gemini-flash"])
            expectTrue(try unwrap(official.searchMatch(for: "Deep")).rank < unwrap(gateway.searchMatch(for: "Deep")).rank)
            expectEqual(gateway.searchMatch(for: "Deep")?.detail, "模型：deepseek-v3")
            expectNotEqual(gateway.searchMatch(for: " baidu ")?.detail, "模型：deepseek-v3")
            expectNil(gateway.searchMatch(for: gateway.apiKey))
            var metadata = gateway; metadata.model = "other"; metadata.modelCatalog = nil; metadata.purpose = "图像研究"; metadata.notes = "备用场景"; metadata.tags = "工作标签"
            expectEqual(metadata.searchMatch(for: "研究")?.detail, "用途：图像研究")
            expectEqual(metadata.searchMatch(for: "备用")?.detail, "备注匹配")
            expectEqual(metadata.searchMatch(for: "工作")?.detail, "标签：工作标签")
            try withStore([official, gateway]) { store, window, view in
                store.selectedID = gateway.id; settle(view)
                try search("Deep", view: view)
                let name = try textBounds("DeepSeek", in: view, listOnly: true)
                let indirect = try textBounds("Baidu Gateway", in: view, listOnly: true)
                expectTrue(name.minY < indirect.minY)
                _ = try textBounds("deepseek-v3", in: view, listOnly: true)
                try press(36, "\r", window: window); settle(view)
                expectEqual(store.selectedID, official.id)
                try press(125, "\u{f701}", window: window); settle(view)
                expectEqual(store.selectedID, gateway.id)
            }
        }
    }

    private static func fixture(count: Int, initiallySelectedIndex: Int = 0, _ work: (VaultStore, [Credential], NSWindow, NSHostingView<AnyView>) throws -> Void) throws {
        let rows = (0..<count).map { index -> Credential in
            var record = DeepChecks.record(); record.id = UUID(); record.name = String(format: "Navigation%02d", index + 1)
            record.apiKey = "fixture-navigation-key-\(index)"; record.variablePrefix = "NAVIGATION_\(index)"; record.model = "fixture-model"
            record.purpose = index < 2 ? "target-group" : "other-group"; record.favorite = false
            record.updatedAt = Date(timeIntervalSince1970: Double(count - index)); return record
        }
        try withStore(rows, selectedID: rows[initiallySelectedIndex].id) { store, window, view in try work(store, rows, window, view) }
    }
    private static func withStore(_ rows: [Credential], selectedID: UUID? = nil, _ work: (VaultStore, NSWindow, NSHostingView<AnyView>) throws -> Void) throws {
        try NewFeatureChecks.isolated { root in
            let key = SymmetricKey(size: .bits256)
            let disk = EncryptedVault(directory: root, keyProvider: { key }); try disk.save(VaultData(credentials: rows))
            let store = VaultStore(disk: disk, automaticProxy: false)
            store.selectedID = selectedID ?? rows.first?.id
            let view = NSHostingView(rootView: AnyView(ContentView().environmentObject(store).disclosureGroupStyle(FullRowDisclosureStyle()).preferredColorScheme(.light)))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1080, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
            defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
            settle(view); try work(store, window, view)
        }
    }
    private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func searchField(_ view: NSView) throws -> NSTextField {
        try unwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "搜索名称、厂商、模型、用途" })
    }
    private static func search(_ query: String, view: NSView) throws {
        let field = try searchField(view); field.selectText(nil); settle(view)
        guard let editor = field.currentEditor() as? NSTextView else { throw KeyDockError.message("Search field did not receive native editing focus") }
        editor.selectAll(nil); editor.insertText(query, replacementRange: editor.selectedRange()); settle(view)
    }
    private static func press(_ code: UInt16, _ characters: String, window: NSWindow) throws {
        let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        let up = try unwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(up, atStart: false); NSApp.sendEvent(event); NSApp.sendEvent(up)
        while NSApp.nextEvent(matching: .keyUp, until: Date(), inMode: .default, dequeue: true) != nil {}
    }
    private static func textBounds(_ text: String, in view: NSView, listOnly: Bool) throws -> NSRect {
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US", "zh-Hans"]
        try VNImageRequestHandler(cgImage: try unwrap(bitmap.cgImage)).perform([request])
        let result = try unwrap(request.results?.first { observation in
            guard let recognized = observation.topCandidates(1).first?.string else { return false }
            return recognized.localizedCaseInsensitiveContains(text) && (!listOnly || observation.boundingBox.maxX * view.bounds.width < 284)
        })
        let box = result.boundingBox
        return NSRect(x: box.minX * view.bounds.width, y: (view.isFlipped ? 1 - box.maxY : box.minY) * view.bounds.height, width: box.width * view.bounds.width, height: box.height * view.bounds.height)
    }
    private static func clickRow(_ title: String, window: NSWindow, view: NSView) throws {
        let rect = try textBounds(title, in: view, listOnly: true)
        let point = view.convert(NSPoint(x: 260, y: rect.midY), to: nil)
        let down = try unwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try unwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down); NSApp.sendEvent(up); settle(view)
        while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
    }
}
