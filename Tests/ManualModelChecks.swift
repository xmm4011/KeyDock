import Foundation
import CryptoKit
import AppKit
import SwiftUI

@MainActor enum ManualModelChecks {
    static func run() async {
        runCheck("ManualModels.changing-a-manual-model-keeps-the-previous-model-and-survives-reload") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let store = VaultStore(disk: disk, automaticProxy: false)
                var first = DeepChecks.record(); first.model = "fixture-model-a"
                expectTrue(store.save(first))
                var second = try unwrap(store.selected); second.model = "fixture-model-b"
                expectTrue(store.save(second))
                let saved = try unwrap(try disk.load().credentials.first)
                expectEqual(Set(saved.modelOptions), Set(["fixture-model-a", "fixture-model-b"]))
                expectEqual(saved.model, "fixture-model-b"); expectTrue(saved.availableModels.isEmpty)
                var switched = saved; switched.model = "fixture-model-a"; expectTrue(store.save(switched))
                expectEqual(Set(try unwrap(store.selected).modelOptions), Set(["fixture-model-a", "fixture-model-b"]))
            }
        }
        runCheck("ManualModels.add-deduplicates-keeps-other-keys-isolated-and-updates-copy-search-and-curl") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false, pasteboard: board)
                var record = DeepChecks.record(); record.model = "fixture-a"; record.check = CheckResult(state: .valid, message: "old model passed", requestMethod: "POST")
                expectTrue(store.importRecords([record]))
                var other = record; other.id = UUID(); other.apiKey = "fixture-other-manual-key"; other.check = nil
                expectTrue(store.save(other))
                expectTrue(store.addModel(" fixture-b ", to: record)); expectTrue(store.addModel("fixture-b", to: record))
                let saved = try unwrap(store.credentials.first { $0.id == record.id })
                expectEqual(saved.modelOptions, ["fixture-b", "fixture-a"]); expectNil(saved.check)
                expectTrue(saved.searchMatch(for: "FIXTURE-A") != nil)
                expectEqual(store.credentials.first { $0.id == other.id }?.modelOptions, ["fixture-a"])
                store.copy(saved.modelOptions.joined(separator: "\n")); expectEqual(board.string(forType: .string), "fixture-b\nfixture-a")
                let request = try APIClient.modelRequest(for: saved)
                let json = try unwrap(try JSONSerialization.jsonObject(with: try unwrap(request.httpBody)) as? [String: Any])
                expectEqual(json["model"] as? String, "fixture-b")
                expectFalse(store.addModel(record.apiKey, to: saved)); expectFalse(store.addModel("bad\nmodel", to: saved))
                expectEqual(store.credentials.first { $0.id == record.id }?.modelOptions, saved.modelOptions)
            }
        }
        runCheck("ManualModels.explicit-list-edits-and-service-changes-do-not-resurrect-old-models") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = "fixture-a"; expectTrue(store.save(record))
                expectTrue(store.addModel("fixture-b", to: record))
                var edited = try unwrap(store.selected); edited.manualModels = [" fixture-b ", "fixture-b", "fixture-c", ""]
                expectTrue(store.save(edited)); expectEqual(store.selected?.manualModels, ["fixture-b", "fixture-c"])
                expectFalse(try unwrap(store.selected).modelOptions.contains("fixture-a"))
                edited = try unwrap(store.selected); edited.apiKey = "fixture-rotated-manual-key"; expectTrue(store.save(edited))
                expectNil(store.selected?.manualModels); expectEqual(store.selected?.modelOptions, ["fixture-b"])
                expectFalse(store.addModel("fixture-d", to: record)); expectEqual(store.selected?.modelOptions, ["fixture-b"])
                let preset = CredentialEditor.applyingPreset(to: edited, name: "Other", kind: .gemini, url: "https://other.example/v1beta", docs: "")
                expectNil(preset.manualModels)
            }
        }
        runCheck("ManualModels.remove-drops-added-or-fetched-models-but-keeps-the-active-model") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), disk = EncryptedVault(directory: root, keyProvider: { key })
                let store = VaultStore(disk: disk, automaticProxy: false)
                var record = DeepChecks.record(); record.model = "fixture-a"; record.modelCatalog = ModelCatalog(models: ["catalog-a"])
                expectTrue(store.importRecords([record]))
                expectTrue(store.addModel("fixture-b", to: record)); expectTrue(store.addModel("fixture-c", to: record))
                let before = try unwrap(store.selected)
                expectEqual(before.model, "fixture-c"); expectTrue(before.modelProtocols?["fixture-b"] != nil)
                expectFalse(store.removeModel("fixture-c", from: before)); expectTrue(store.error != nil); store.error = nil
                expectTrue(store.removeModel("fixture-b", from: before))
                let after = try unwrap(store.selected)
                expectFalse(after.modelOptions.contains("fixture-b")); expectNil(after.modelProtocols?["fixture-b"])
                expectEqual(after.model, "fixture-c"); expectTrue(after.modelOptions.contains("catalog-a")); expectTrue(after.modelOptions.contains("fixture-a"))
                expectFalse(try unwrap(try disk.load().credentials.first).modelOptions.contains("fixture-b"))
                expectTrue(store.removeModel("not-added", from: after))
                var rotated = after; rotated.apiKey = "fixture-rotated-remove-key"
                expectFalse(store.removeModel("fixture-a", from: rotated)); expectTrue(store.error != nil); store.error = nil
                expectTrue(store.removeModel("fixture-a", from: after)); expectTrue(store.removeModel("fixture-b", from: after))
                expectEqual(store.selected?.manualModels, ["fixture-c"])
                // A model fetched from the service can be removed as well, with its timing.
                var listed = try unwrap(store.selected)
                expectTrue(store.commit { next in next.credentials[0].modelProbes = ["catalog-a": ModelProbe(CheckResult(state: .valid, message: "ok", httpStatus: 200, duration: 0.2), model: "catalog-a", protocolKind: .compatible)] })
                listed = try unwrap(store.selected)
                expectTrue(store.removeModel("catalog-a", from: listed))
                let trimmed = try unwrap(store.selected)
                expectFalse(trimmed.modelOptions.contains("catalog-a")); expectEqual(trimmed.modelCatalog?.models, [])
                expectNil(trimmed.modelProbes?["catalog-a"]); expectEqual(trimmed.model, "fixture-c")
                expectFalse(try unwrap(try disk.load().credentials.first).modelOptions.contains("catalog-a"))
            }
        }
        runCheck("ManualModels.organizer-choice-is-remembered-without-replacing-the-project-default") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = "project-model"; expectTrue(store.save(record))
                expectTrue(store.configureOrganizer(serviceID: record.id, model: "organizer-model"))
                expectEqual(store.data.organizerModel, "organizer-model"); expectEqual(store.selected?.model, "project-model")
                expectEqual(Set(try unwrap(store.selected).modelOptions), Set(["project-model", "organizer-model"]))
                expectTrue(store.configureOrganizer(serviceID: nil, model: "")); expectNil(store.data.organizerServiceID)
                expectTrue(try unwrap(store.selected).modelOptions.contains("organizer-model"))
                expectFalse(store.configureOrganizer(serviceID: record.id, model: record.apiKey))
            }
        }
        runCheck("ManualModels.backup-roundtrip-and-old-vault-decoding-preserve-model-libraries") {
            var record = DeepChecks.record(); record.model = "fixture-a"; record.manualModels = ["fixture-a", "fixture-b"]
            let bytes = try PortableBackup.create(VaultData(credentials: [record]), password: "fixture-model-backup")
            expectEqual(try PortableBackup.restore(bytes, password: "fixture-model-backup").credentials.first?.manualModels, record.manualModels)
            var json = try unwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]); json.removeValue(forKey: "manualModels")
            let old = try JSONDecoder().decode(Credential.self, from: JSONSerialization.data(withJSONObject: json))
            expectNil(old.manualModels); expectEqual(old.modelOptions, ["fixture-a"])
        }
        await refresh()
    }
    private static func refresh() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            var record = DeepChecks.record(); record.model = "manual-a"; record.modelCatalog = ModelCatalog(models: ["catalog-old"])
            expectTrue(store.importRecords([record])); expectTrue(store.addModel("manual-b", to: record))
            let success = MockURLProtocol.session { _ in MockReply(body: Data(#"{"data":[{"id":"catalog-new"}]}"#.utf8)) }; defer { success.invalidateAndCancel() }
            await store.fetchModels(try unwrap(store.selected), session: success)
            expectEqual(store.selected?.availableModels, ["catalog-new"])
            expectEqual(Set(try unwrap(store.selected).modelOptions), Set(["manual-a", "manual-b", "catalog-new"]))
            let failure = MockURLProtocol.session { _ in MockReply(status: 404) }; defer { failure.invalidateAndCancel() }
            await store.fetchModels(try unwrap(store.selected), session: failure)
            expectEqual(Set(try unwrap(store.selected).modelOptions), Set(["manual-a", "manual-b", "catalog-new"]))
            checkpoint("ManualModels.catalog-refresh-and-failure-retain-manual-models-without-faking-catalog-results")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("ManualModels.refresh") }
    }

    private final class SheetState: ObservableObject { @Published var showing = false }
    private struct Parent: View {
        @ObservedObject var state: SheetState
        let record: Credential
        var body: some View { Text("Independent model fixture").frame(width: 560, height: 350).sheet(isPresented: $state.showing) { AddModelView(record: record) } }
    }
    private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    }
    private static let delegate = ApplicationDelegate()
    static func native() {
        NSApplication.shared.setActivationPolicy(.prohibited); NSApp.delegate = delegate
        runCheck("ManualModels.native-add-sheet-Return-retains-both-models-and-cancel-keeps-the-library") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
                var record = DeepChecks.record(); record.model = "fixture-a"; expectTrue(store.save(record)); record = try unwrap(store.selected)
                let state = SheetState(), view = NSHostingView(rootView: Parent(state: state, record: record).environmentObject(store))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
                defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
                state.showing = true; settle(view)
                let sheet = try unwrap(window.attachedSheet)
                try type("fixture-b", in: sheet); try press(36, "\r", in: sheet); settle(view)
                expectNil(window.attachedSheet); expectEqual(store.selected?.model, "fixture-b")
                expectEqual(Set(try unwrap(store.selected).modelOptions), Set(["fixture-a", "fixture-b"]))
                state.showing = true; settle(view)
                let cancelSheet = try unwrap(window.attachedSheet)
                try type(record.apiKey, in: cancelSheet); try press(36, "\r", in: cancelSheet); settle(view)
                expectTrue(window.attachedSheet === cancelSheet); expectNil(store.error)
                try type("fixture-c", in: cancelSheet); try press(53, "\u{1b}", in: cancelSheet); settle(view)
                expectNil(window.attachedSheet); expectEqual(Set(try unwrap(store.selected).modelOptions), Set(["fixture-a", "fixture-b"]))
            }
        }
    }
    private static func settle(_ view: NSView) {
        for _ in 0..<20 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        view.display()
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func type(_ name: String, in window: NSWindow) throws {
        let field = try unwrap(descendants(try unwrap(window.contentView)).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.selectText(nil); let editor = try unwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText(name, replacementRange: editor.selectedRange())
    }
    private static func press(_ code: UInt16, _ text: String, in window: NSWindow) throws {
        let down = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        let up = try unwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down); NSApp.sendEvent(up)
        while NSApp.nextEvent(matching: .keyUp, until: Date(), inMode: .default, dequeue: true) != nil {}
    }
}
