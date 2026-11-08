import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Vision

// Renders newly constructed test views only. No existing app, user clipboard,
// production vault, screenshot API, or external service is accessed.
@MainActor enum LayoutChecks {
    private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    }
    private static let delegate = ApplicationDelegate()
    static var outputDirectory: URL?
    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        audit()
        runCheck("Layout.incomplete-connection-explains-why-copy-is-disabled") {
            try withFixture { store, original in
                var record = original; record.apiKey = ""
                try render(CredentialDetail(record: record, edit: {}).environmentObject(store), size: NSSize(width:700,height:660)) { view in
                    let text = try recognizedText(capture(view,name:"incomplete-connection-copy-reason"))
                    expectTrue(text.contains("API Key")); expectTrue(text.contains("补充"))
                }
            }
        }
        runCheck("Layout.settings-and-preview-share-readable-model-selection") {
            try withFixture { store, record in
                try render(ModelSelectionField(service:record,model:.constant(record.model)).padding(24).environmentObject(store),size:NSSize(width:620,height:120)) { view in
                    let text = try recognizedText(capture(view,name:"shared-model-selection"))
                    expectTrue(text.contains("模型列表")); expectTrue(text.contains("deepseek"))
                    let field = try unwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.stringValue == record.model })
                    expectTrue(field.frame.width > 300)
                }
                let interaction = AgentInteraction()
                interaction.fail("服务连接意外中断。当前结果仍保留。",recovery:AgentImportResult(records:[record],summary:"已有一条核验结果",activity:[]))
                try render(AgentQuestionView(interaction:interaction),size:NSSize(width:780,height:465)) { view in
                    let text = try recognizedText(capture(view,name:"agent-recoverable-failure"))
                    expectTrue(text.contains("整理未完成")); expectTrue(text.contains("结果仍保留"))
                }
            }
        }
        runCheck("Layout.command-F-focuses-search-without-stealing-focus-from-a-sheet") {
            try withFixture { store, _ in
                let host = NSHostingView(rootView:ContentView().environmentObject(store))
                let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1080,height:760),styleMask:[.titled],backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
                defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
                settle(host)
                NotificationCenter.default.post(name:.keydockSearch,object:nil); settle(host)
                let field = try unwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "搜索名称、厂商、模型、用途" })
                expectTrue(field.currentEditor() != nil)
                NotificationCenter.default.post(name:.keydockNew,object:nil)
                for _ in 0..<30 { if window.attachedSheet != nil { break }; RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
                let sheet = try unwrap(window.attachedSheet), responder = sheet.firstResponder
                NotificationCenter.default.post(name:.keydockSearch,object:nil); settle(host)
                expectTrue(window.attachedSheet === sheet); expectTrue(sheet.firstResponder === responder)
            }
        }
        runCheck("Layout.Agent-reply-and-inline-rich-reply-input-remain-readable") {
            let interaction = AgentInteraction()
            interaction.question = AgentQuestion(question:"已读取接口文档，但实际调用返回 model_not_found，当前配置还没有验证通过。",reason:"已尝试文档中的模型名称，网关可能使用独立的部署 ID。",items:["请确认控制台中的实际模型或推理接入点 ID"],example:"可以直接粘贴配置或控制台截图",canContinueWithoutReply:true,canReview:true)
            interaction.document = ImportDocument(ImportPaste(text:"这个项目使用的是工作环境的模型接入点。",images:[try documentImage()]))
            try render(AgentQuestionView(interaction:interaction),size:NSSize(width:780,height:465)) { view in
                let editor = try unwrap(descendants(view).compactMap { $0 as? ImportTextEditor.PasteTextView }.first)
                expectTrue(editor.enclosingScrollView?.frame.width ?? 0 > 650)
                expectTrue(editor.enclosingScrollView?.frame.height ?? 0 > 140)
                let text = try recognizedText(capture(view,name:"agent-reply-and-inline-composer"))
                expectTrue(text.contains("Agent")); expectTrue(text.contains("model_not_found")); expectTrue(text.contains("控制台"))
            }
        }
        runCheck("Layout.unreadable-vault-opens-recovery-instead-of-empty-export") {
            try withFixture { store, _ in
                let folder = store.disk.directory.appendingPathComponent("recovery-ui")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("unreadable-test-vault".utf8).write(to: folder.appendingPathComponent("vault.kdv"))
                let recovering = VaultStore(disk: EncryptedVault(directory: folder, keyProvider: store.disk.keyProvider), automaticProxy: false)
                expectTrue(recovering.loadError != nil)
                try render(BackupView().environmentObject(recovering), size: NSSize(width: 650, height: 420)) { view in
                    let text = try recognizedText(capture(view, name: "backup-recovery"))
                    expectTrue(text.contains("选择备份")); expectFalse(text.contains("导出加密备份"))
                    expectTrue(text.contains("原保险库文件会保留")); expectFalse(text.contains("恢复会合并"))
                }
            }
        }
        runCheck("Layout.native-tabs-separate-use-records-and-private-info") {
            try withFixture { store, record in
                try render(CredentialDetail(record: record, edit: {}).environmentObject(store), size: NSSize(width: 700, height: 660)) { view in
                    let picker = try detailPicker(view)
                    expectEqual(picker.selectedSegment, 0)
                    let use = try capture(view, name: "detail-use")
                    let useText = try recognizedText(use)
                    expectTrue(useText.contains("复制使用")); expectFalse(useText.contains("API Key"))
                    try select(1, in: view)
                    let activity = try capture(view, name: "detail-records")
                    let activityText = try recognizedText(activity)
                    expectTrue(activityText.contains("Token")); expectFalse(activityText.contains("复制使用"))
                    try select(2, in: view)
                    let info = try capture(view, name: "detail-info")
                    let infoText = try recognizedText(info)
                    expectTrue(infoText.contains("API Key")); expectFalse(infoText.contains(record.apiKey)); expectFalse(infoText.contains("显示密钥"))
                    try select(0, in: view)
                    expectTrue(try recognizedText(capture(view, name: nil)).contains("复制使用"))
                    expectFalse(store.proxy.running)
                }
            }
        }
        runCheck("Layout.long-notes-use-a-wide-left-aligned-multiline-editor") {
            try withFixture { store, original in
                var record = original
                record.notes = "用于模型开发与接口联调。\n请求路径：/v1/messages、/v1/chat/completions、/v1/responses。\n文档中的鉴权、地域和参数需要逐项核对。\n" + String(repeating:"长备注应该自然换行，并保持从左侧阅读。",count:8)
                try render(CredentialEditor(record:record,moreInfo:true).environmentObject(store),size:NSSize(width:680,height:640)) { view in
                    let editor = try unwrap(descendants(view).compactMap { $0 as? NSTextView }.first { $0.string == record.notes })
                    expectTrue(editor.alignment == .left || editor.alignment == .natural)
                    expectTrue(editor.enclosingScrollView?.frame.width ?? 0 > 500)
                    expectTrue(editor.enclosingScrollView?.frame.height ?? 0 >= 110)
                    let outer = descendants(view).compactMap { $0 as? NSScrollView }.first { $0.documentView != nil && $0 !== editor.enclosingScrollView }
                    if let outer, let document = outer.documentView {
                        let target = editor.convert(editor.bounds,to:document)
                        document.scroll(NSPoint(x:0,y:max(0,target.minY-40))); outer.reflectScrolledClipView(outer.contentView); settle(view)
                    }
                    _ = try capture(view,name:"editor-long-notes")
                }
            }
        }
        runCheck("Layout.add-model-is-a-small-sheet-and-extra-models-remain-editable-without-losing-newlines") {
            try withFixture { store, original in
                var record = original; record.manualModels = ["fixture-a", "fixture-b"]
                try render(AddModelView(record: record).environmentObject(store), size: NSSize(width: 460, height: 270)) { view in
                    let text = try recognizedText(capture(view, name: "add-model"))
                    expectTrue(text.contains("添加模型")); expectTrue(text.contains("已有模型会保留"))
                }
                try render(CredentialEditor(record: record, moreInfo: true).environmentObject(store), size: NSSize(width: 680, height: 640)) { view in
                    let editor = try unwrap(descendants(view).compactMap { $0 as? NSTextView }.first { $0.string == "fixture-a\nfixture-b" })
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                    editor.insertText("\n", replacementRange: editor.selectedRange()); settle(view)
                    expectEqual(editor.string, "fixture-a\nfixture-b\n")
                    editor.insertText("fixture-c", replacementRange: editor.selectedRange()); settle(view)
                    expectEqual(editor.string, "fixture-a\nfixture-b\nfixture-c")
                    _ = try capture(view, name: "editor-saved-models")
                }
            }
        }
        runCheck("Layout.editor-fields-have-consistent-breathing-room-and-protocol-menus-fit") {
            try withFixture { store, original in
                var record = original; record.docsURL = "https://docs.fixture.invalid/guide"; record.tags = "fixture-tags"
                try render(CredentialEditor(record: record, advanced: true, moreInfo: true).environmentObject(store), size: NSSize(width: 680, height: 640)) { view in
                    let fields = descendants(view).compactMap { $0 as? NSTextField }
                    let docs = try unwrap(fields.first { $0.stringValue == record.docsURL }), tags = try unwrap(fields.first { $0.stringValue == record.tags })
                    let a = docs.convert(docs.bounds, to: view), b = tags.convert(tags.bounds, to: view)
                    expectTrue(abs(a.midY - b.midY) >= 32)
                    expectTrue(abs(a.midY - b.midY) - max(a.height, b.height) >= 10)
                    _ = try capture(view, name: "editor-roomy-fields")
                    let verification = try unwrap(fields.first { $0.placeholderString == "留空使用默认验证接口" })
                    if let outer = descendants(view).compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView != nil && $0.documentView?.bounds.height ?? 0 > 640 }), let document = outer.documentView {
                        let target = verification.convert(verification.bounds, to: document)
                        document.scroll(NSPoint(x: 0, y: max(0, target.minY - 100))); outer.reflectScrolledClipView(outer.contentView); settle(view)
                    }
                    _ = try capture(view, name: "editor-roomy-advanced")
                }
                try render(CredentialDetail(record: record, edit: {}).environmentObject(store), size: NSSize(width: 610, height: 840)) { view in
                    let text = try recognizedText(capture(view, name: "detail-protocol-selector"))
                    expectTrue(text.contains("chat/completions")); expectTrue(text.contains("调用模型"))
                    expectFalse(text.contains("收起请求")); expectFalse(text.contains("收起详情"))
                }
            }
        }
        runCheck("Layout.passed-inference-and-a-later-unsupported-connection-check-remain-understandable") {
            try withFixture { store, original in
                var record = original; record.modelCatalog = nil
                record.check = CheckResult(state: .valid, message: "当前模型调用验证通过，已产生少量用量。", httpStatus: 200, endpoint: record.baseURL + "/chat/completions", requestMethod: "POST")
                record.connectionCheck = CheckResult(state: .uncertain, message: "此接口不支持模型列表检查。", checkedAt: Date().addingTimeInterval(1), httpStatus: 404, endpoint: record.baseURL + "/models", requestMethod: "GET")
                try render(CredentialDetail(record: record, edit: {}).environmentObject(store), size: NSSize(width: 700, height: 740)) { view in
                    let text = try recognizedText(capture(view, name: "passed-call-with-unsupported-directory"))
                    expectTrue(text.contains("调用通过")); expectTrue(text.contains("保留上次模型调用结果"))
                }
            }
        }
        runCheck("Layout.local-logs-display-original-values-when-globally-enabled") {
            try withFixture { store, record in
                expectTrue(store.setShowFullContent(true))
                var entry = log(record)
                entry.bodiesCaptured = true
                entry.requestBody = "{\"echo\":\"" + record.apiKey + "\"}"
                entry.responseBody = record.apiKey
                try render(ProxyLogView(entry: entry).environmentObject(store), size: NSSize(width: 760, height: 650)) { view in
                    let request = try recognizedText(capture(view, name: nil))
                    expectFalse(request.contains("已隐藏")); expectTrue(request.contains(record.apiKey))
                    let control = try unwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first)
                    control.selectedSegment = 1; _ = control.sendAction(control.action, to: control.target); settle(view)
                    let response = try recognizedText(capture(view, name: nil))
                    expectFalse(response.contains("已隐藏")); expectTrue(response.contains(record.apiKey))
                }
            }
        }
        runCheck("Layout.minimum-default-and-wide-main-window-controls-fit") {
            try withFixture { store, _ in
                for (name, size) in [("main-minimum", NSSize(width: 900, height: 650)), ("main-default", NSSize(width: 1080, height: 760)), ("main-wide", NSSize(width: 1280, height: 850))] {
                    try render(ContentView().environmentObject(store), size: size) { view in
                        let picker = try detailPicker(view)
                        let frame = picker.convert(picker.bounds, to: view)
                        expectTrue(frame.minX >= 0 && frame.maxX <= size.width)
                        expectTrue(frame.minY >= 0 && frame.maxY <= size.height)
                        let zoom = try unwrap(descendants(view).compactMap { $0 as? WindowZoomArea.Anchor }.first)
                        expectTrue(zoom.bounds.height >= 30)
                        _ = try capture(view, name: name)
                        if name == "main-minimum" { expectTrue(try recognizedText(capture(view, name: nil)).contains("复制使用")) }
                    }
                }
            }
        }
        runCheck("Layout.saving-a-new-key-from-favorites-reveals-the-saved-key") {
            try withFixture { store, original in
                store.toggleFavorite(original)
                try render(ContentView().environmentObject(store),size:NSSize(width:1080,height:760)) { view in
                    let shelves = try shelfPicker(view); shelves.selectedSegment = 1; _ = shelves.sendAction(shelves.action,to:shelves.target); settle(view)
                    var added = original; added.id = UUID(); added.name = "新保存的工作 Key"; added.apiKey = "fixture-filter-added-key"; added.variablePrefix = ""; added.favorite = false; added.check = nil
                    expectTrue(store.save(added)); settle(view)
                    expectEqual(try shelfPicker(view).selectedSegment,0); expectEqual(store.selectedID,added.id)
                    expectTrue(try recognizedText(capture(view,name:"saved-key-clears-hidden-filter")).contains(added.name))
                }
            }
        }
        runCheck("Layout.archiving-the-last-active-key-shows-an-accurate-recovery-path") {
            try withFixture { store, _ in
                try render(ContentView().environmentObject(store),size:NSSize(width:1080,height:760)) { view in
                    store.archive(Set(store.credentials.map(\.id))); settle(view)
                    let text = try recognizedText(capture(view,name:"all-keys-archived"))
                    expectTrue(text.contains("查看归档")); expectFalse(text.contains("点选一条"))
                    let shelves = try shelfPicker(view); shelves.selectedSegment = 2; _ = shelves.sendAction(shelves.action,to:shelves.target); settle(view)
                    expectTrue(store.selected?.archived == true)
                    expectTrue(try recognizedText(capture(view,name:"archived-key-detail")).contains("已归档"))
                }
            }
        }
        runCheck("Layout.empty-long-content-import-editor-and-log-views-render") {
            try withFixture { store, record in
                try render(ContentView().environmentObject(store), size: NSSize(width: 1080, height: 760)) { view in
                    store.selectedID = nil; settle(view); _ = try capture(view, name: "main-empty-selection")
                }
                var long = record
                long.name = "工作项目 / 同一厂商的多个账户与环境 · " + String(repeating: "长名称测试", count: 6)
                long.baseURL = "https://gateway.example.com/" + String(repeating: "workspace-prefix/", count: 15) + "v1"
                long.notes = String(repeating: "这是需要保留的中文备注。长资料应自然换行，详情可以纵向滚动。\n", count: 20)
                try render(CredentialDetail(record: long, initialTab: .info, edit: {}).environmentObject(store), size: NSSize(width: 590, height: 620)) { view in
                    let image = try capture(view, name: "detail-long-info")
                    let visible = try recognizedText(image)
                    expectTrue(visible.contains("gateway.example.com")); expectTrue(visible.contains("prefix/v1"))
                    expectTrue(try detailPicker(view).frame.width <= 590)
                }
                store.history.clear(record.id)
                try render(CredentialDetail(record: record, initialTab: .activity, edit: {}).environmentObject(store), size: NSSize(width: 590, height: 620)) { view in
                    _ = try capture(view, name: "records-empty")
                }
                let picture = try documentImage()
                let paste = ImportPaste(text: "工作项目的模型配置，帮我整理一下。\nBase URL: https://api.example.com/v1\nAPI Key: fixture-for-layout-only", images: [picture])
                try render(ImportView(initialPaste: paste).environmentObject(store), size: NSSize(width: 780, height: 650)) { view in
                    _ = try capture(view, name: "import-with-image")
                }
                try render(ImportImagePreview(image:picture),size:NSSize(width:850,height:640)) { view in
                    _ = try capture(view,name:"image-preview")
                }
                try render(CredentialEditor(record: record).environmentObject(store), size: NSSize(width: 680, height: 640)) { view in
                    let fields = descendants(view).compactMap { $0 as? NSTextField }
                    let base = try unwrap(fields.first { $0.stringValue == record.baseURL })
                    let secret = try unwrap(fields.first { $0.stringValue == record.apiKey })
                    expectTrue(abs(base.convert(base.bounds, to: view).minX - secret.convert(secret.bounds, to: view).minX) < 2)
                    _ = try capture(view, name: "editor")
                }
                var entry = log(record)
                entry.bodiesCaptured = true; entry.requestBody = "{\n  \"model\": \"deepseek-chat\",\n  \"messages\": [{\"role\": \"user\", \"content\": \"你好\"}]\n}"
                entry.responseBody = "{\"choices\":[{\"message\":{\"content\":\"你好！\"}}]}"
                try render(ProxyLogView(entry: entry).environmentObject(store), size: NSSize(width: 760, height: 650)) { view in
                    _ = try capture(view, name: "log-request")
                    let control = try unwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first)
                    control.selectedSegment = 1; _ = control.sendAction(control.action, to: control.target); settle(view)
                    _ = try capture(view, name: "log-response")
                }
                expectTrue(store.commit { $0.credentials = [] }); store.selectedID = nil; store.toast = nil
                try render(ContentView().environmentObject(store), size: NSSize(width: 900, height: 650)) { view in
                    _ = try capture(view, name: "main-empty-library")
                }
                store.history.flush()
            }
        }
    }
    static func audit() {
        NSApplication.shared.setActivationPolicy(.prohibited); NSApp.delegate = delegate
        runCheck("Layout.system-settings-toggles-apply-globally-and-are-readable") {
            try withFixture { store, _ in
                try render(SystemSettingsView().environmentObject(store), size: NSSize(width: 560, height: 470)) { view in
                    let window = try unwrap(view.window); window.styleMask = [.titled]; window.makeKeyAndOrderFront(nil); settle(view)
                    let before = try recognizedText(capture(view, name: "system-settings-default"))
                    expectTrue(before.contains("系统设置")); expectTrue(before.contains("智能整理")); expectTrue(before.contains("显示完整密钥与请求内容"))
                    expectFalse(store.showFullContent); expectFalse(store.recordAllBodies)
                    try clickText("显示完整密钥与请求内容", in: view); expectTrue(store.showFullContent)
                    try clickText("为所有 Key 记录请求与响应", in: view); expectTrue(store.recordAllBodies)
                    _ = try capture(view, name: "system-settings-enabled")
                    try clickText("显示完整密钥与请求内容", in: view); expectFalse(store.showFullContent); expectTrue(store.recordAllBodies)
                }
            }
        }
        runCheck("Layout.raw-request-and-edit-field-show-original-Key-when-globally-enabled") {
            try withFixture { store, original in
                expectTrue(store.setShowFullContent(true))
                var record = original; record.apiKey = "fixture-raw-visible-key"
                let request = CheckedRequest(try APIClient.modelRequest(for: record))
                let result = CheckResult(state: .valid, message: "passed", httpStatus: 200, request: request)
                try render(VerificationEvidenceView(result: result, request: request).environmentObject(store).padding(20), size: NSSize(width: 760, height: 370)) { view in
                    let text = try recognizedText(capture(view, name: "raw-verification-request"))
                    expectTrue(text.contains(record.apiKey)); expectFalse(text.contains("已隐藏"))
                }
                try render(CredentialEditor(record: record).environmentObject(store), size: NSSize(width: 800, height: 760)) { view in
                    let fields = descendants(view).compactMap { $0 as? NSTextField }
                    expectTrue(fields.contains { $0.stringValue == record.apiKey && !($0 is NSSecureTextField) })
                    expectFalse(fields.contains { $0 is NSSecureTextField })
                    let text = try recognizedText(capture(view, name: "raw-key-editor"))
                    expectTrue(text.contains(record.apiKey))
                }
            }
        }
        runCheck("Layout.remembered-protocol-and-model-remain-visible-at-minimum-width") {
            try withFixture { store, original in
                var record = original; record.model = "messages-model"
                record = record.selectingProtocol(.anthropic).selectingModel("chat-model").selectingModel("messages-model")
                try render(CredentialDetail(record: record, edit: {}).environmentObject(store), size: NSSize(width: 610, height: 780)) { view in
                    let text = try recognizedText(capture(view, name: "remembered-model-protocol"))
                    expectTrue(text.contains("messages-model")); expectTrue(text.contains("messages")); expectTrue(text.contains("复制使用"))
                }
            }
        }
        runCheck("Layout.incomplete-model-output-keeps-passed-state-and-displays-the-actual-explanation") {
            try withFixture { store, original in
                var record = original; record.kind = .responses
                let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/v1/responses")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                record.check = AgentVerification.classify(Data(OutputLimitChecks.partial.utf8), response: response, record: record, method: "POST", endpoint: response.url!.absoluteString)
                try render(CredentialDetail(record: record, edit: {}).environmentObject(store), size: NSSize(width: 700, height: 840)) { view in
                    let text = try recognizedText(capture(view, name: "responses-incomplete-passed"))
                    expectTrue(text.contains("调用通过")); expectTrue(text.contains("未完整结束"))
                }
            }
        }
        runCheck("Layout.audit-global-commands-respect-child-sheets-outside-the-main-sheet-binding") {
            try withFixture { store, record in
                let view = NSHostingView(rootView: ContentView().environmentObject(store))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1080, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil); settle(view)
                let child = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 460, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
                child.isReleasedWhenClosed = false; child.contentView = NSHostingView(rootView: AddModelView(record: record).environmentObject(store))
                defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; child.close(); window.close() }
                window.beginSheet(child); child.makeKeyAndOrderFront(nil); settle(view)
                expectTrue(window.attachedSheet === child)
                let responder = child.firstResponder
                for name in [Notification.Name.keydockSearch, .keydockNew, .keydockImport] { NotificationCenter.default.post(name: name, object: nil); settle(view) }
                expectTrue(child.firstResponder === responder); expectTrue(window.attachedSheet === child)
                window.endSheet(child); settle(view)
                expectNil(window.attachedSheet)
                let anchor = try unwrap(descendants(view).compactMap { $0 as? WindowCommandAnchor.Anchor }.first)
                window.close(); expectFalse(anchor.owner.allowsMainCommands)
            }
        }
        runCheck("Layout.audit-editor-native-picker-opens-with-the-actual-legacy-template-protocol") {
            try withFixture { store, original in
                var record = original
                record.callTemplate = ModelCallTemplate(path: "responses", body: #"{"model":"deepseek-chat","input":"Hi"}"#, model: record.model)
                record.manualModels = ["fixture-a", "fixture-b"]
                try render(CredentialEditor(record: record, moreInfo: true).environmentObject(store), size: NSSize(width: 680, height: 640)) { view in
                    let editor = try unwrap(descendants(view).compactMap { $0 as? NSTextView }.first { $0.string == "fixture-a\nfixture-b" })
                    let outer = try unwrap(descendants(view).compactMap { $0 as? NSScrollView }.first { $0.documentView?.bounds.height ?? 0 > 640 })
                    let document = try unwrap(outer.documentView), target = editor.convert(editor.bounds, to: try unwrap(outer.documentView))
                    document.scroll(NSPoint(x: 0, y: max(0, target.minY - 190))); outer.reflectScrolledClipView(outer.contentView); settle(view)
                    let text = try recognizedText(capture(view, name: "audit-editor-protocol"))
                    expectTrue(text.localizedCaseInsensitiveContains("responses")); expectFalse(text.contains("chat/completions"))
                }
            }
        }
        runCheck("Layout.audit-duplicate-import-opens-archive-and-restoring-keeps-the-key-visible") {
            try withFixture { store, record in
                store.archive([record.id]); store.selectedID = store.active.first?.id
                try render(ContentView().environmentObject(store), size: NSSize(width: 1080, height: 760)) { view in
                    let initialShelf = try shelfPicker(view)
                    initialShelf.selectedSegment = 2; _ = initialShelf.sendAction(initialShelf.action, to: initialShelf.target); settle(view)
                    expectEqual(try shelfPicker(view).selectedSegment, 2); expectEqual(store.selectedID, record.id)
                    initialShelf.selectedSegment = 0; _ = initialShelf.sendAction(initialShelf.action, to: initialShelf.target); settle(view)
                    expectEqual(try shelfPicker(view).selectedSegment, 0)
                    var duplicate = record; duplicate.id = UUID(); expectTrue(store.importRecords([duplicate])); settle(view)
                    let shelf = try unwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 && $0.label(forSegment: 2) == "归档" })
                    expectEqual(shelf.selectedSegment, 2); expectEqual(store.selectedID, record.id)
                    _ = try capture(view, name: "audit-existing-archived-key")
                    store.archive([record.id], archived: false); settle(view)
                    expectEqual(shelf.selectedSegment, 0); expectEqual(store.selectedID, record.id)
                    expectTrue(try recognizedText(capture(view, name: "audit-restored-key")).contains("复制使用"))
                }
            }
        }
        runCheck("Layout.audit-verification-response-displays-and-copies-original-values-on-private-clipboard") {
            try NewFeatureChecks.isolated { root in
                let key = SymmetricKey(size: .bits256), board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false, pasteboard: board)
                var record = DeepChecks.record(); record.model = "fixture-model"; record.apiKey = "fixture-visible-key"; expectTrue(store.save(record)); expectTrue(store.setShowFullContent(true))
                let data = try JSONSerialization.data(withJSONObject: ["error": ["message": "fixture deployment unavailable; " + record.apiKey]])
                let http = HTTPURLResponse(url: URL(string: record.baseURL)!, statusCode: 400, httpVersion: nil, headerFields: ["X-Request-ID": "fixture-trace-001", "Set-Cookie": "private-test-session"])!
                var result = APIClient.classify(status: 400, data: data, record: record, testModel: true)
                result.response = CheckedResponse(data, response: http, record: record)
                try render(VerificationEvidenceView(result: result, request: nil, showingResponse: true).environmentObject(store).padding(20), size: NSSize(width: 610, height: 400)) { view in
                    let window = try unwrap(view.window); window.styleMask = [.titled]; window.makeKeyAndOrderFront(nil); settle(view)
                    let text = try recognizedText(capture(view, name: "audit-verification-response"))
                    expectTrue(text.contains("fixture-trace-001")); expectTrue(text.contains(record.apiKey))
                    try clickText("复制响应", in: view)
                    guard let copied = board.string(forType: .string) else { throw KeyDockError.message("Native response copy did not write to the private clipboard") }
                    expectTrue(copied.contains("fixture deployment unavailable")); expectTrue(copied.contains(record.apiKey)); expectTrue(copied.contains("private-test-session")); expectEqual(copied, result.response?.text)
                }
            }
        }
        runCheck("Layout.audit-long-model-and-provider-labels-keep-main-actions-and-protocol-visible") {
            try withFixture { store, original in
                var record = original; record.name = String(repeating: "很长的项目名称", count: 12)
                record.model = "deployment-" + String(repeating: "long-model-", count: 16)
                try render(CredentialDetail(record: record, edit: {}).environmentObject(store), size: NSSize(width: 610, height: 780)) { view in
                    let text = try recognizedText(capture(view, name: "audit-long-model-minimum-window"))
                    expectTrue(text.contains("chat/completions")); expectTrue(text.contains("复制使用")); expectTrue(text.contains("编辑"))
                }
            }
        }
    }
    private static func clickText(_ title: String, in view: NSView) throws {
        let window = try unwrap(view.window), bitmap = try capture(view, name: nil)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try unwrap(bitmap.cgImage)).perform([request])
        let observation = try unwrap(request.results?.first { $0.topCandidates(1).first?.string == title })
        let box = observation.boundingBox
        let point = view.convert(NSPoint(x: box.midX * view.bounds.width, y: (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height), to: nil)
        let down = try unwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try unwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down); NSApp.sendEvent(up)
        while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
        settle(view)
    }
    private static func withFixture(_ work: (VaultStore, Credential) throws -> Void) throws {
        try NewFeatureChecks.isolated { root in
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            var record = DeepChecks.record()
            record.name = "DeepSeek · 日常开发"; record.provider = "DeepSeek"; record.model = "deepseek-chat"
            record.baseURL = "https://api.deepseek.com"; record.apiKey = "fixture-layout-not-a-real-key-7788"; record.purpose = "个人项目与日常开发"
            record.notes = "这是独立渲染使用的虚构记录。"; record.docsURL = "https://api-docs.deepseek.com/"
            record.check = CheckResult(state: .valid, message: "模型列表查询成功，此次连接正常。", httpStatus: 200, models: ["deepseek-chat", "deepseek-reasoner"], endpoint: "https://api.deepseek.com/models", requestMethod: "GET")
            expectTrue(store.save(record))
            for (index, provider) in ["通义千问", "豆包", "Kimi"].enumerated() {
                var extra = record; extra.id = UUID(); extra.name = provider + " · 工作项目"; extra.provider = provider
                extra.apiKey = "fixture-layout-other-\(index)"; extra.variablePrefix = "LAYOUT_\(index)"; extra.check = nil
                expectTrue(store.save(extra))
            }
            store.selectedID = record.id; store.toast = nil
            for index in 0..<4 { var entry = log(record); entry.duration += Double(index) * 0.1; store.history.append(entry) }
            store.history.flush()
            try work(store, record)
        }
    }
    private static func documentImage() throws -> ImportImage {
        let image = NSImage(size:NSSize(width:720,height:380)); image.lockFocus()
        NSColor(srgbRed:0.92,green:0.94,blue:1,alpha:1).setFill(); NSRect(x:0,y:0,width:720,height:380).fill()
        let text = NSAttributedString(string:"API DOCUMENTATION\n\nBase URL: https://api.example.com/v1\nModel: fixture-chat\n\nPOST /chat/completions",attributes:[.font:NSFont.monospacedSystemFont(ofSize:23,weight:.medium),.foregroundColor:NSColor.darkGray])
        text.draw(in:NSRect(x:32,y:32,width:656,height:310)); image.unlockFocus()
        return try ImportImage(data:try unwrap(image.tiffRepresentation),name:"接口文档示例")
    }
    private static func log(_ record: Credential) -> ProxyLogEntry {
        var entry = ProxyLogEntry(credentialID: record.id, method: "POST", model: record.model, status: 200, inputTokens: 48, outputTokens: 126, requestURL: record.baseURL + "/chat/completions")
        entry.duration = 1.24; entry.requestHeaders = "Content-Type: application/json\nAuthorization: Bearer " + record.apiKey
        entry.responseHeaders = "Content-Type: application/json"; return entry
    }
    private static func render<V: View>(_ root: V, size: NSSize, _ work: (NSHostingView<AnyView>) throws -> Void) throws {
        let view = NSHostingView(rootView: AnyView(root.disclosureGroupStyle(FullRowDisclosureStyle()).tint(Palette.accent).preferredColorScheme(.light).environment(\.controlActiveState, .key).background(Color.white)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.setContentSize(size); defer { window.close() }
        settle(view); try work(view)
    }
    private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        view.layoutSubtreeIfNeeded(); view.display()
    }
    private static func detailPicker(_ view: NSView) throws -> NSSegmentedControl {
        let controls = descendants(view).compactMap { $0 as? NSSegmentedControl }
        return try unwrap(controls.first { $0.segmentCount == 3 && $0.label(forSegment: 0) == "使用" })
    }
    private static func shelfPicker(_ view: NSView) throws -> NSSegmentedControl {
        try unwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 && $0.label(forSegment:0) == "全部" })
    }
    private static func select(_ segment: Int, in view: NSView) throws {
        let control = try detailPicker(view); control.selectedSegment = segment
        _ = control.sendAction(control.action, to: control.target); settle(view)
        expectEqual(try detailPicker(view).selectedSegment, segment)
    }
    private static func capture(_ view: NSView, name: String?) throws -> NSBitmapImageRep {
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        expectTrue(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let outputDirectory, let name {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let data = try unwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: outputDirectory.appendingPathComponent(name + ".png"))
        }
        return bitmap
    }
    private static func recognizedText(_ bitmap: NSBitmapImageRep) throws -> String {
        let image = try unwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
