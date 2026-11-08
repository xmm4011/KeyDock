import Foundation
import SwiftUI
import AppKit
import CryptoKit

@MainActor enum InteractionFlowChecks {
    static func run() async {
        runCheck("Interaction.secret-identifiers-stay-stable-across-supplements") {
            let first = RedactedImport("Key: sk-fixture-short-123456789")
            let next = RedactedImport("Key: sk-fixture-short-123456789\n另一个 sk-fixture-much-longer-supplement-987654321", preserving: first.keys)
            expectEqual(next.keys["KEYDOCK_SECRET_1"],first.keys["KEYDOCK_SECRET_1"])
            expectEqual(next.keys.count,2); expectFalse(next.text.contains("sk-fixture-"))
            expectTrue(next.restore(next.text).contains("sk-fixture-much-longer-supplement-987654321"))
        }
        let interaction = AgentInteraction()
        let task = Task { try await interaction.ask(AgentQuestion(question:"请补充接入地址",reason:"文档需要登录",items:["Base URL"],example:"https://你的服务/v1"),validate:{ paste in
            guard paste.text.contains("https://") else { throw KeyDockError.message("缺少地址") }
        }) }
        await wait { interaction.isWaiting }
        expectEqual(interaction.question?.items,["Base URL"])
        interaction.document = ImportDocument(ImportPaste(text:"还没有地址")); interaction.submit()
        expectTrue(interaction.isWaiting); expectEqual(interaction.error,"缺少地址")
        interaction.document = ImportDocument(ImportPaste(text:"https://example.com/v1",images:[try! NewFeatureChecks.image()])); interaction.submit()
        do {
            let paste = try unwrap(try await task.value)
            expectEqual(paste.text.trimmingCharacters(in:.whitespacesAndNewlines),"https://example.com/v1")
            expectEqual(paste.images.count,1); expectFalse(interaction.isWaiting)
            var original = ImportDocument(); try original.append(paste)
            expectEqual(original.images.count,1); expectEqual(original.text.components(separatedBy:"[图片 1]").count,2)
            checkpoint("Interaction.specific-question-validates-and-resumes-with-text-and-image")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Interaction.answer") }
        let cancelled = Task { try await interaction.ask(AgentQuestion(question:"请补充端点 ID"),validate:{_ in}) }
        await wait { interaction.isWaiting }; cancelled.cancel()
        do { _ = try await cancelled.value; checkFailures.append("Cancelled question unexpectedly returned") } catch { expectTrue(error is CancellationError) }
        expectFalse(interaction.isWaiting); checkpoint("Interaction.waiting-question-cancels-without-hanging")
        shortcuts()
        presentedSheet()
        busySheet()
        await models()
    }
    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 { if condition() { return }; try? await Task.sleep(for:.milliseconds(10)) }
        expectTrue(condition())
    }
    private static func shortcuts() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        runCheck("Interaction.command-W-and-Escape-target-only-the-topmost-sheet") {
            let parent = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:500,height:300),styleMask:[.borderless],backing:.buffered,defer:false)
            let other = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:200,height:100),styleMask:[.borderless],backing:.buffered,defer:false)
            parent.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
            var closed = 0
            let anchor = SheetShortcuts.Anchor(close:{closed += 1}); parent.contentView = anchor
            defer { parent.endSheet(other); other.close(); parent.close() }
            @MainActor func event(_ window:NSWindow,_ flags:NSEvent.ModifierFlags = .command,_ text:String = "w",_ code:UInt16 = 13) throws -> NSEvent {
                try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code))
            }
            expectTrue(anchor.handles(try event(parent)))
            expectTrue(anchor.handles(try event(parent,[],"\u{1b}",53)))
            expectFalse(anchor.handles(try event(other)))
            expectFalse(anchor.handles(try event(parent,[.command,.shift])))
            expectFalse(anchor.handles(try event(parent,.command,"s",1)))
            let editor = NSTextView(); anchor.addSubview(editor); parent.makeFirstResponder(editor)
            editor.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            expectTrue(editor.hasMarkedText()); expectFalse(anchor.handles(try event(parent,[],"\u{1b}",53)))
            expectTrue(anchor.handles(try event(parent)))
            editor.unmarkText(); expectTrue(anchor.handles(try event(parent,[],"\u{1b}",53)))
            parent.beginSheet(other)
            expectFalse(anchor.handles(try event(parent)))
            let childAnchor = SheetShortcuts.Anchor(close:{closed += 10}); other.contentView = childAnchor
            expectTrue(childAnchor.handles(try event(other)))
            // Exercise the real local event monitor through NSApplication dispatch.
            NSApp.sendEvent(try event(other))
            expectEqual(closed,10)
            parent.endSheet(other)
            NSApp.sendEvent(try event(parent))
            expectEqual(closed,11)
        }
    }
    private static func models() async {
        let server = FixtureServer { request in
            if request.target == "/v1/models" {
                return FixtureResponse(chunks:[Data(#"{"data":[{"id":"fixture-b"},{"id":"fixture-a"},{"id":"fixture-a"}]}"#.utf8)])
            }
            return FixtureResponse(chunks:[Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        do {
            try server.start(); defer { server.stop() }
            await wait { server.port != nil }
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            let key = SymmetricKey(size:.bits256), board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            let disk = EncryptedVault(directory:root,keyProvider:{key}), store = VaultStore(disk:disk,automaticProxy:false,pasteboard:board)
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"; record.model = "fixture-a"
            record.callTemplate = ModelCallTemplate(path:"chat/completions",body:#"{"model":"fixture-a","messages":[{"role":"user","content":"Hi"}],"max_tokens":8}"#,model:"fixture-a")
            expectTrue(store.save(record)); record = try unwrap(store.selected)
            await store.verify(record,testModel:true)
            record = try unwrap(store.selected); let inference = record.check
            await store.fetchModels(record)
            record = try unwrap(store.selected)
            expectEqual(record.availableModels,["fixture-a","fixture-b"]); expectEqual(record.check,inference)
            store.copy(record.availableModels.joined(separator:"\n")); expectEqual(board.string(forType:.string),"fixture-a\nfixture-b")
            await store.verify(record,testModel:true)
            record = try unwrap(store.selected); expectEqual(record.availableModels,["fixture-a","fixture-b"])
            let reloaded = try disk.load(); expectEqual(reloaded.credentials.first?.availableModels,["fixture-a","fixture-b"])
            checkpoint("Interaction.GET-models-and-copy-work-after-Agent-inference-template-and-persist-across-verification")
            record.model = "fixture-b"; expectTrue(store.save(record)); expectEqual(store.selected?.availableModels,["fixture-a","fixture-b"])
            record = try unwrap(store.selected); record.apiKey = "sk-fixture-replaced-000000000"; expectTrue(store.save(record)); expectEqual(store.selected?.availableModels,[])
            checkpoint("Interaction.model-catalog-survives-model-edit-but-clears-on-auth-change")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Interaction.models") }
    }
    private final class Presentation: ObservableObject {
        @Published var showing = false
        @Published var busy = false
        var stops = 0
        func cancel() {
            if busy { busy = false; stops += 1 }
            else { showing = false }
        }
    }
    private struct SheetFixture: View {
        @ObservedObject var presentation: Presentation
        var usesStopAction = false
        var body: some View {
            Text("Independent shortcut fixture").frame(width:500,height:300)
                .sheet(isPresented:$presentation.showing) {
                    VStack {
                        SheetHeader(title:"独立测试弹框",subtitle:"仅验证此测试创建的窗口",onCancel:usesStopAction ? presentation.cancel : nil)
                        TextField("文本框",text:.constant("fixture"))
                        Button(presentation.busy ? "停止" : "取消", action: presentation.cancel).keyboardShortcut(.cancelAction)
                    }.frame(width:400,height:200)
                }
        }
    }
    private static func presentedSheet() {
        runCheck("Interaction.shared-sheet-header-dismisses-real-SwiftUI-sheet-with-command-W-and-Escape") {
            let presentation = Presentation()
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:SheetFixture(presentation:presentation))
            window.orderFront(nil); defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
            for shortcut in ["w","\u{1b}"] {
                presentation.showing = true
                for _ in 0..<40 { if window.attachedSheet != nil { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
                let sheet = try unwrap(window.attachedSheet)
                let event = try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shortcut == "w" ? .command : [],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:shortcut,charactersIgnoringModifiers:shortcut,isARepeat:false,keyCode:shortcut == "w" ? 13 : 53))
                NSApp.sendEvent(event)
                for _ in 0..<40 { if !presentation.showing && window.attachedSheet == nil { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
                expectFalse(presentation.showing); expectNil(window.attachedSheet)
            }
        }
    }
    private static func busySheet() {
        runCheck("Interaction.Escape-stops-busy-work-and-keeps-the-sheet-open") {
            let presentation = Presentation(); presentation.busy = true
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:SheetFixture(presentation:presentation,usesStopAction:true))
            window.orderFront(nil); defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
            presentation.showing = true
            for _ in 0..<40 { if window.attachedSheet != nil { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            let sheet = try unwrap(window.attachedSheet)
            let event = try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53))
            NSApp.sendEvent(event)
            for _ in 0..<40 { if !presentation.busy { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            expectTrue(presentation.showing); expectFalse(presentation.busy); expectEqual(presentation.stops,1)
            expectTrue(window.attachedSheet === sheet)
            // 停止后仍可再次运行；⌘W 在运行中照常关闭弹框。
            presentation.busy = true
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            let close = try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"w",charactersIgnoringModifiers:"w",isARepeat:false,keyCode:13))
            NSApp.sendEvent(close)
            for _ in 0..<40 { if !presentation.showing && window.attachedSheet == nil { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            expectFalse(presentation.showing); expectNil(window.attachedSheet); expectEqual(presentation.stops,1)
        }
    }
}
