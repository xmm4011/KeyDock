import AppKit
import SwiftUI
import CryptoKit
import Vision

@MainActor enum CleanupChecks {
    private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    }
    private static let delegate = ApplicationDelegate()
    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited); NSApp.delegate = delegate
        runCheck("Cleanup.recovered-hidden-candidate-is-not-archived-with-the-remaining-selection") {
            try fixture(count: 2) { store, window, view in
                let first = store.credentials[0], second = store.credentials[1]
                recover(first.id, store: store); settle(view)
                let footer = try footerText(view)
                if !footer.contains("清理1项") {
                    print("Cleanup test footer: " + footer)
                    let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/model-alignment-cleanup-debug.png"))
                }
                expectTrue(footer.contains("清理1项"))
                try clickArchive(window: window, view: view)
                let alert = try waitForAlert(window, view: view)
                let confirm = try confirmationButton(alert)
                confirm.performClick(nil); settle(view)
                expectFalse(store.credentials.first { $0.id == first.id }?.archived == true)
                expectTrue(store.credentials.first { $0.id == second.id }?.archived == true)
            }
        }
        runCheck("Cleanup.pending-confirmation-does-not-archive-a-key-recovered-after-opening-the-alert") {
            try fixture(count: 1) { store, window, view in
                let id = try unwrap(store.credentials.first?.id)
                try clickArchive(window: window, view: view)
                let alert = try waitForAlert(window, view: view)
                let confirm = try confirmationButton(alert)
                recover(id, store: store)
                // Confirm immediately, before SwiftUI has rendered the changed list.
                confirm.performClick(nil); settle(view)
                expectFalse(store.credentials.first { $0.id == id }?.archived == true)
            }
        }
    }
    private static func fixture(count: Int, _ work: (VaultStore, NSWindow, NSHostingView<AnyView>) throws -> Void) throws {
        try NewFeatureChecks.isolated { root in
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            for index in 0..<count {
                var record = DeepChecks.record(); record.name = "Cleanup \(index)"; record.apiKey = "fixture-cleanup-key-\(index)"; record.variablePrefix = "CLEANUP_\(index)"; record.expiresAt = Date().addingTimeInterval(-60)
                expectTrue(store.save(record))
            }
            let view = NSHostingView(rootView: AnyView(CleanupView().environmentObject(store).tint(Palette.accent).preferredColorScheme(.light).environment(\.controlActiveState, .key).background(Color.white)))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 740, height: 530), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
            settle(view); try work(store, window, view)
        }
    }
    private static func recover(_ id: UUID, store: VaultStore) {
        expectTrue(store.commit { next in
            if let i = next.credentials.firstIndex(where: { $0.id == id }) { next.credentials[i].expiresAt = nil; next.credentials[i].check = CheckResult(state: .valid, message: "Recovered fixture", requestMethod: "POST") }
        })
    }
    private static func settle(_ view: NSView) {
        for _ in 0..<10 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        view.display()
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func labels(_ view: NSView) throws -> [VNRecognizedTextObservation] {
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try unwrap(bitmap.cgImage)).perform([request]); return request.results ?? []
    }
    private static func compact(_ text: String) -> String { text.replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression) }
    private static func footerText(_ view: NSView) throws -> String { try labels(view).filter { $0.boundingBox.midY < 0.18 }.compactMap { $0.topCandidates(1).first?.string }.map(compact).joined() }
    private static func clickArchive(window: NSWindow, view: NSView) throws {
        let matches = try labels(view)
        guard let label = matches.first(where: { item in
            item.boundingBox.midY < 0.18 && item.topCandidates(1).first.map { compact($0.string).range(of: #"清理[0-9]+项"#, options: .regularExpression) != nil } == true
        }) else { throw KeyDockError.message("Archive button label missing: " + matches.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")) }
        let box = label.boundingBox
        let point = view.convert(NSPoint(x: box.midX * view.bounds.width, y: (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height), to: nil)
        let down = try unwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try unwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down); NSApp.sendEvent(up); settle(view)
        while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
    }
    private static func waitForAlert(_ window: NSWindow, view: NSView) throws -> NSWindow {
        for _ in 0..<30 { if let alert = window.attachedSheet { return alert }; settle(view) }
        throw KeyDockError.message("Cleanup confirmation did not appear in test window")
    }
    private static func confirmationButton(_ alert: NSWindow) throws -> NSButton {
        let buttons = descendants(try unwrap(alert.contentView)).compactMap { $0 as? NSButton }
        guard let button = buttons.first(where: { $0.title == "确认清理" }) else { throw KeyDockError.message("Unexpected cleanup confirmation buttons: " + buttons.map(\.title).joined(separator: ", ")) }
        return button
    }
}
