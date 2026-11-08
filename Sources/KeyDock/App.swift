import SwiftUI
import AppKit
import CryptoKit

enum PreviewSession {
    static var directory: URL?
    @MainActor static func store() -> VaultStore {
        if let index = CommandLine.arguments.firstIndex(of: "--qa-session"), CommandLine.arguments.indices.contains(index + 1), let id = UUID(uuidString: CommandLine.arguments[index + 1]) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-QA-" + id.uuidString)
            return VaultStore(disk: EncryptedVault(directory: root, keyProvider: { try EncryptedVault.keychainKey(service: "local.keydock.qa." + id.uuidString) }), automaticProxy: false)
        }
        guard CommandLine.arguments.contains("--preview") else {
            guard SingleInstance.claim() else { exit(0) }
            return VaultStore()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Preview-" + UUID().uuidString)
        self.directory = directory
        let key = SymmetricKey(size: .bits256)
        return VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(CommandLine.arguments.contains("--preview") ? .accessory : .regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showExistingWindow), name: SingleInstance.showNotification, object: nil)
    }
    @objc func showExistingWindow() {
        DispatchQueue.main.async {
            NSApplication.shared.windows.first { $0.title == "KeyDock" }?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let directory = PreviewSession.directory { try? FileManager.default.removeItem(at: directory) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.title == "KeyDock" }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct KeyDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = PreviewSession.store()
    var body: some Scene {
        Window("KeyDock", id: "main") {
            ContentView().environmentObject(store).frame(minWidth: 900, minHeight: 650)
                .disclosureGroupStyle(FullRowDisclosureStyle())
                .tint(Palette.accent).preferredColorScheme(.light)
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("粘贴导入…") { NotificationCenter.default.post(name: .keydockImport, object: nil) }.keyboardShortcut("i", modifiers: .command)
                Button("新增密钥…") { NotificationCenter.default.post(name: .keydockNew, object: nil) }.keyboardShortcut("n", modifiers: .command)
                Button("搜索密钥") { NotificationCenter.default.post(name: .keydockSearch, object: nil) }.keyboardShortcut("f", modifiers: .command)
            }
        }
        MenuBarExtra("KeyDock", systemImage: "key.horizontal") { TrayView().environmentObject(store) }
        Settings {
            SystemSettingsView().environmentObject(store)
                .tint(Palette.accent).preferredColorScheme(.light)
        }.windowResizability(.contentSize)
    }
}

struct TrayView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("打开 KeyDock") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Divider()
        Text("\(store.active.count) 条密钥")
        ProxyTray(proxy: store.proxy)
        Divider()
        SettingsLink { Text("系统设置…") }
        Button("退出 KeyDock（停止本机代理）") { NSApplication.shared.terminate(nil) }
    }
}

struct ProxyTray: View {
    @ObservedObject var proxy: LocalProxy
    var body: some View {
        Text(proxy.running ? "本机代理运行中 · :47831" : "本机代理已停止")
        Button(proxy.running ? "停止本机代理" : "启动本机代理") { if proxy.running { proxy.stop() } else { proxy.start() } }
    }
}

