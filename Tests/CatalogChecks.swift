import Foundation
import AppKit
import SwiftUI
import CryptoKit

@MainActor enum CatalogChecks {
    static func run() async {
        runCheck("Catalog.main-search-includes-unselected-models-and-existing-metadata") {
            var record = DeepChecks.record(); record.model = "current-model"; record.purpose = "图像研究"
            record.provider = "厂商示例"; record.tags = "工作标签"; record.notes = "研发备注"
            record.modelCatalog = ModelCatalog(models:["gemini-catalog-only","qwen-catalog-only"])
            for text in ["GEMINI-CATALOG", "qwen-catalog", "current-model", "图像研究", "厂商示例", "工作标签", "研发备注", record.baseURL] {
                expectTrue(record.searchText.localizedCaseInsensitiveContains(text))
            }
            expectFalse(record.searchText.contains(record.apiKey))
        }
        await catalogs()
        await requestSnapshot()
        await documentModels()
        disclosureClicks()
        archiveConfirmation()
        windowZoom()
    }
    private static func catalogs() async {
        let server = FixtureServer { request in
            if request.target.hasPrefix("/unavailable/") { return FixtureResponse(status:404,chunks:[Data(#"{"error":{"message":"catalog unavailable"}}"#.utf8)]) }
            return FixtureResponse(chunks:[Data(#"{"data":[{"id":"fixture-active"},{"id":"gemini-catalog-only"},{"id":"qwen-catalog-only"}]}"#.utf8)])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            try server.start(); defer { server.stop() }; await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"; record.model = "fixture-active"
            record.check = CheckResult(state:.valid,message:"actual inference already passed",requestMethod:"POST")
            let host = ImportAgentHost(original:"Key: "+record.apiKey,imageText:"",images:[],workspace:root,session:APIClient.session)
            host.candidates = [record]
            let result = await host.call("finish_import",args:["ids":[record.id.uuidString],"summary":"ready"])
            expectTrue(result["ok"] as? Bool == true); expectEqual(host.candidates[0].model,"fixture-active")
            expectEqual(host.candidates[0].availableModels,["fixture-active","gemini-catalog-only","qwen-catalog-only"])
            expectEqual(server.received.count,1); expectTrue(server.received.allSatisfy { $0.method == "GET" })
            let disk = EncryptedVault(directory:root.appendingPathComponent("vault"),keyProvider:{SymmetricKey(data:Data(repeating:7,count:32))})
            try disk.save(VaultData(credentials:host.candidates))
            let restored = try unwrap(try disk.load().credentials.first)
            expectTrue(restored.searchText.localizedCaseInsensitiveContains("QWEN-CATALOG")); expectEqual(restored.check?.state,.valid)
            checkpoint("Catalog.Agent-finish-fills-catalog-with-known-default-model-and-persists-searchable-IDs")
            let failed = ImportAgentHost(original:"Key: "+record.apiKey,imageText:"",images:[],workspace:root,session:APIClient.session)
            record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/unavailable"; failed.candidates = [record]
            _ = await failed.call("list_models",args:["id":record.id.uuidString])
            let before = server.received.count
            _ = await failed.call("finish_import",args:["ids":[record.id.uuidString],"summary":"ready"])
            expectEqual(server.received.count,before); expectTrue(failed.finished); expectNil(failed.candidates[0].modelCatalog)
            expectEqual(failed.candidates[0].model,"fixture-active"); expectEqual(failed.candidates[0].check?.state,.valid)
            expectTrue(failed.summary.contains("未获取模型列表"))
            checkpoint("Catalog.unavailable-catalog-does-not-repeat-or-erase-a-working-model-and-is-reported")
            let bounded = ImportAgentHost(original:"Key: "+record.apiKey,imageText:"",images:[],workspace:root,session:APIClient.session)
            bounded.candidates = [record]; bounded.verificationCalls = 30
            _ = await bounded.call("finish_import",args:["ids":[record.id.uuidString],"summary":"ready"])
            expectEqual(server.received.count,before); expectTrue(bounded.finished); expectTrue(bounded.summary.contains("上限"))
            checkpoint("Catalog.automatic-discovery-respects-the-existing-probe-budget")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Catalog.discovery") }
    }
    private static func requestSnapshot() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        let server = FixtureServer { _ in FixtureResponse(chunks:[Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)]) }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            try server.start(); defer { server.stop() }; await InteractionFlowChecks.wait { server.port != nil }
            var record = DeepChecks.record(); record.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/v1"; record.model = "fixture-model"
            record.apiKey = "fixture-'request-secret-12345"; record.extraHeaders = "X-Token: auxiliary-'request-secret-98765"
            record.check = await APIClient.verify(record,testModel:true)
            let snapshot = try unwrap(record.check?.request)
            expectEqual(snapshot.method,"POST"); expectTrue(snapshot.headers.values.contains("Bearer "+record.apiKey))
            let preview = snapshot.curl(redacting:record.secretValues)
            expectFalse(preview.contains("request-secret")); expectTrue(preview.contains("已隐藏"))
            let command = "curl() { /usr/bin/curl -q --noproxy '*' --silent --max-time 3 \"$@\"; }\n"+snapshot.curl
            let replay = try await WorkflowChecks.shell(command,root:root,environment:["PATH":"/usr/bin:/bin"])
            expectEqual(replay.status,0); expectEqual(server.received.last?.headers["authorization"],"Bearer "+record.apiKey)
            let disk = EncryptedVault(directory:root.appendingPathComponent("vault"),keyProvider:{SymmetricKey(data:Data(repeating:8,count:32))})
            try disk.save(VaultData(credentials:[record]))
            expectEqual(try disk.load().credentials.first?.check?.request,snapshot)
            var legacy = try unwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(try unwrap(record.check))) as? [String:Any]); legacy.removeValue(forKey:"request")
            expectNil(try JSONDecoder().decode(CheckResult.self,from:JSONSerialization.data(withJSONObject:legacy)).request)
            checkpoint("Catalog.checked-request-replays-real-auth-but-redacts-before-shell-quoting-and-supports-old-data")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Catalog.request") }
    }
    private final class DisclosureState: ObservableObject {
        @Published var expanded = false
        @Published var showing = false
        var label = CGRect.zero
    }
    private static func documentModels() async {
        let object: [String:Any] = ["data":["block_map":["page":["data":["type":"page","children":["body"]]],"body":["data":["type":"text","text":["initialAttributedTexts":["text":["0":"gemini-doc-only qwen-doc-only, quote )} and { braces"]]]]]]]]
        let json = String(decoding:try! JSONSerialization.data(withJSONObject:object),as:UTF8.self)
        let html = "<script>var productTranslation='model-not-in-doc'; window.DATA = { clientVars: Object("+json+") };</script>"
        runCheck("Catalog.public-document-evidence-excludes-product-translations-and-parses-quoted-braces") {
            let body = DocumentText.body(html)
            expectTrue(body.contains("gemini-doc-only")); expectFalse(body.contains("model-not-in-doc"))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            let offline = MockURLProtocol.session { _ in MockReply(status:404,body:Data(#"{"error":"no catalog"}"#.utf8)) }; defer { offline.invalidateAndCancel() }
            let host = ImportAgentHost(original:"API Key: sk-fixture-docmodel-123456789\nBase URL: https://example.com/v1",imageText:"",images:[],workspace:root,session:offline)
            host.documentTexts = [DocumentText.body(html)]
            let args: [String:Any] = ["api_key":"KEYDOCK_SECRET_1","base_url":"https://example.com/v1","kind":"compatible","model":"gemini-doc-only","models":["gemini-doc-only","qwen-doc-only"]]
            let value = try host.propose(args)
            _ = await host.call("finish_import",args:["ids":[value["id"]!],"summary":"ready"])
            expectEqual(host.candidates[0].availableModels,["gemini-doc-only","qwen-doc-only"]); expectEqual(host.candidates[0].modelCatalog?.source,"资料")
            expectNil(host.candidates[0].check); expectTrue(host.summary.contains("资料"))
            var invented = args; invented["models"] = ["model-not-in-doc"]
            expectThrows(try host.propose(invented))
            checkpoint("Catalog.document-backed-model-list-is-searchable-with-provenance-without-fabricated-verification")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Catalog.document-models") }
        let server = FixtureServer { request in
            if request.target == "/start" { return FixtureResponse(status:302,headers:["Location":"/guest","Set-Cookie":"doc_visitor=anonymous-fixture; Path=/"],chunks:[]) }
            if request.headers["cookie"]?.contains("doc_visitor=anonymous-fixture") == true { return FixtureResponse(headers:["Content-Type":"text/html"],chunks:[Data("<html>public-visitor-document-body</html>".utf8)]) }
            return FixtureResponse(status:403)
        }
        let docRoot = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:docRoot,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:docRoot) }
            try server.start(); defer { server.stop() }; await InteractionFlowChecks.wait { server.port != nil }
            let config = URLSessionConfiguration.ephemeral; config.httpAdditionalHeaders = ["Authorization":"Bearer fixture-api-only"]
            let api = URLSession(configuration:config,delegate:APIClient.delegate,delegateQueue:nil); defer { api.invalidateAndCancel() }
            let url = "http://127.0.0.1:\(try unwrap(server.port))/start"
            let host = ImportAgentHost(original:url,imageText:"",images:[],workspace:docRoot,session:api); host.allowLocalDocuments = true
            let result = await host.call("fetch_document",args:["url":url])
            expectTrue(result["ok"] as? Bool == true); expectTrue(host.documentTexts.joined().contains("public-visitor-document-body"))
            expectTrue(server.received.allSatisfy { $0.headers["authorization"] == nil })
            expectFalse(api.configuration.httpCookieStorage?.cookies?.contains(where: { $0.name == "doc_visitor" }) == true)
            expectEqual(api.configuration.httpAdditionalHeaders?["Authorization"] as? String,"Bearer fixture-api-only")
            checkpoint("Catalog.public-document-guest-cookies-work-without-inheriting-or-contaminating-API-authentication")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Catalog.document-cookies") }
    }
    private final class TestApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    }
    private static let applicationDelegate = TestApplicationDelegate()
    private struct DisclosureFixture: View {
        @ObservedObject var state: DisclosureState
        var body: some View {
            VStack(alignment:.leading) {
                DisclosureGroup(isExpanded:$state.expanded) { Text("Expanded content") } label: {
                    Text("点击名称展开").background(GeometryReader { geometry in Color.clear.onAppear { state.label = geometry.frame(in:.named("fixture")) } })
                }
                Spacer()
            }.padding(12).frame(width:440,height:160).coordinateSpace(name:"fixture").disclosureGroupStyle(FullRowDisclosureStyle())
        }
    }
    private struct DisclosureSheetFixture: View {
        @ObservedObject var state: DisclosureState
        var body: some View {
            Text("Independent parent").frame(width:440,height:160)
                .sheet(isPresented:$state.showing) { DisclosureFixture(state:state) }
        }
    }
    private static func disclosureClicks() {
        runCheck("Catalog.disclosure-title-and-empty-row-space-toggle-with-real-mouse-events") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApp.delegate = applicationDelegate
            for inSheet in [false,true] {
            let state = DisclosureState()
            let root = inSheet ? AnyView(DisclosureSheetFixture(state:state)) : AnyView(DisclosureFixture(state:state))
            let view = NSHostingView(rootView:root.disclosureGroupStyle(FullRowDisclosureStyle()))
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:440,height:160),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
            if inSheet { state.showing = true }
            for _ in 0..<10 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            let target = inSheet ? try unwrap(window.attachedSheet) : window
            let content = try unwrap(target.contentView)
            expectTrue(state.label.width > 0)
            for x in [state.label.midX,400] {
                let y = content.isFlipped ? state.label.midY : content.bounds.height-state.label.midY
                let point = content.convert(NSPoint(x:x,y:y),to:nil)
                let down = try unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:target.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
                let up = try unwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:0.1,windowNumber:target.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0))
                NSApp.postEvent(up,atStart:false); NSApp.sendEvent(down); NSApp.sendEvent(up)
                for _ in 0..<10 { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
                if state.expanded != (x == state.label.midX) {
                    print("Disclosure diagnostic: sheet=\(inSheet) x=\(x) label=\(state.label) content=\(content.bounds) flipped=\(content.isFlipped) point=\(point) key=\(target.isKeyWindow)")
                    if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                        content.cacheDisplay(in:content.bounds,to:bitmap)
                        try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/catalog-disclosure-debug.png"))
                    }
                }
                expectEqual(state.expanded,x == state.label.midX)
                while NSApp.nextEvent(matching:.leftMouseUp,until:Date(),inMode:.default,dequeue:true) != nil {}
            }
            }
        }
    }
    private final class ArchiveState: ObservableObject {
        @Published var showing = false
        var confirmations = 0
    }
    private struct ArchiveFixture: View {
        @ObservedObject var state: ArchiveState
        var body: some View {
            Text("Independent archive fixture").frame(width:440,height:180)
                .alert(isPresented:$state.showing) { CredentialConfirmation.archiveAlert(count:2) { state.confirmations += 1 } }
        }
    }
    private static func archiveConfirmation() {
        runCheck("Catalog.native-archive-confirmation-does-not-act-until-confirmed-and-cancel-preserves-data") {
            let state = ArchiveState()
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:440,height:180),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView:ArchiveFixture(state:state)); window.orderFront(nil)
            defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
            @MainActor func descendants(_ view:NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
            for confirm in [false,true] {
                state.showing = true
                for _ in 0..<40 { if window.attachedSheet != nil { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
                let sheet = try unwrap(window.attachedSheet)
                expectEqual(state.confirmations,0)
                let button = try unwrap(descendants(try unwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == (confirm ? "确认归档" : "取消") })
                button.performClick(nil)
                for _ in 0..<40 { if window.attachedSheet == nil { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
                expectEqual(state.confirmations,confirm ? 1 : 0)
            }
        }
    }
    private static func windowZoom() {
        runCheck("Catalog.header-double-click-fills-visible-screen-and-restores-without-fullscreen") {
            let screen = try unwrap(NSScreen.main ?? NSScreen.screens.first)
            let frame = NSRect(x:screen.visibleFrame.minX+70,y:screen.visibleFrame.minY+60,width:700,height:430)
            let window = NSWindow(contentRect:frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; defer { window.close() }
            let content = try unwrap(window.contentView), anchor = WindowZoomArea.Anchor()
            anchor.frame = NSRect(x:0,y:content.bounds.height-50,width:content.bounds.width,height:50); content.addSubview(anchor)
            let original = window.frame, visible = (window.screen ?? screen).visibleFrame
            let header = try unwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:NSPoint(x:250,y:content.bounds.height-20),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:0))
            let body = try unwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:NSPoint(x:250,y:80),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:0))
            expectTrue(anchor.handles(header)); expectFalse(anchor.handles(body)); expectNil(anchor.hitTest(.zero))
            anchor.toggleZoom(animated:false); expectEqual(window.frame,visible); expectFalse(window.styleMask.contains(.fullScreen))
            anchor.toggleZoom(animated:false); expectEqual(window.frame,original)
            if let green = window.standardWindowButton(.zoomButton) {
                let rect = green.convert(green.bounds,to:nil)
                let event = try unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:rect.midX,y:rect.midY),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:1))
                expectFalse(anchor.handles(event))
            }
            let down = try unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:header.locationInWindow,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:1))
            NSApp.sendEvent(down); NSApp.sendEvent(header)
            for _ in 0..<20 { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            expectEqual(window.frame,visible)
            NSApp.sendEvent(down); NSApp.sendEvent(header)
            for _ in 0..<20 { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            expectEqual(window.frame,original)
        }
    }
}
