import Foundation
import AppKit
import CryptoKit

@MainActor enum SystemChecks {
    static func environment() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let label = "local.keydock.environment-test." + tag.lowercased()
        let domain = "gui/\(getuid())"
        var booted = false
        let manager = UserEnvironment(home: root) { args in
            // The test uses a temporary Home; never boot out the real user's agent.
            if args.first == "bootout" { return "" }
            return try UserEnvironment.launchctl(args)
        }
        defer {
            if booted { _ = try? UserEnvironment.launchctl(["bootout", domain + "/" + label]) }
            for entry in manager.entries { try? manager.remove(entry.id) }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var a = DeepChecks.record(); a.variablePrefix = "KDAUDIT_" + tag + "_A"; a.model = "fixture-model-a"
            var b = a; b.id = UUID(); b.variablePrefix = "KDAUDIT_" + tag + "_B"; b.apiKey = "fixture-other-provider-key"; b.model = "fixture-model-b"
            try manager.install(a); try manager.install(b)
            let values = manager.entries.reduce(into: [String: String]()) { $0.merge($1.values) { a, _ in a } }
            let names = values.keys.sorted()
            let output = root.appendingPathComponent("inherited.txt"), error = root.appendingPathComponent("error.txt")
            FileManager.default.createFile(atPath: output.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            FileManager.default.createFile(atPath: error.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            let script = "for keydock_probe_name in \"$@\"; do /usr/bin/printenv \"$keydock_probe_name\"; done"
            let job: [String: Any] = ["Label": label, "RunAtLoad": true, "ProgramArguments": ["/bin/sh", "-c", script, "keydock-audit"] + names, "StandardOutPath": output.path, "StandardErrorPath": error.path]
            let plist = root.appendingPathComponent("probe.plist")
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
            _ = try UserEnvironment.launchctl(["bootstrap", domain, plist.path]); booted = true
            var observed = ""
            for _ in 0..<200 {
                observed = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                if observed.split(separator: "\n").count == names.count { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let inherited = observed.split(separator: "\n").map(String.init) == names.map { values[$0]! }
            expectTrue(inherited)
            expectFalse(observed.contains(a.apiKey)); expectFalse(observed.contains(b.apiKey))
            _ = try UserEnvironment.launchctl(["bootout", domain + "/" + label]); booted = false
            try manager.remove(a.id); try manager.remove(b.id)
            expectTrue(manager.entries.isEmpty)
            for name in names { expectEqual(try UserEnvironment.launchctl(["getenv", name]), "") }
            let inheritance = inherited ? "verified" : "failed"
            print("SYSTEM ENVIRONMENT PROBE keys=2 variables=\(names.count) gui_inheritance=\(inheritance) cleaned=true")
        } catch { checkFailures.append("system environment: " + error.localizedDescription) }
        checkpoint("System.two-keys-inherited-by-real-GUI-domain-child-and-removed")
        finish("SYSTEM ENVIRONMENT")
    }
    static func clipboardTimer() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Feature-" + UUID().uuidString)
        let boards = (0..<3).map { _ in NSPasteboard.withUniqueName() }
        defer { for board in boards { board.clearContents(); board.releaseGlobally() }; try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let stores = (0..<3).map { index in VaultStore(disk: EncryptedVault(directory: root.appendingPathComponent(String(index)), keyProvider: { key }), automaticProxy: false, pasteboard: boards[index]) }
        defer { stores.forEach { $0.clearSensitiveClipboard() } }
        stores[0].copy("fixture-sensitive-timer", sensitive: true)
        stores[1].copy("fixture-sensitive-replaced", sensitive: true)
        boards[1].clearContents(); boards[1].setString("new-fake-user-copy", forType: .string)
        stores[2].copy("fixture-sensitive-then-safe", sensitive: true); stores[2].copy("safe-fake-project-config")
        do { try await Task.sleep(for: .seconds(46)) }
        catch { checkFailures.append("clipboard timer cancelled") }
        // Let already-due MainActor callbacks run before sampling AppKit state.
        await Task.yield()
        expectNil(boards[0].string(forType: .string)); checkpoint("System.real-45-second-sensitive-clipboard-expiration")
        expectEqual(boards[1].string(forType: .string), "new-fake-user-copy"); checkpoint("System.expiration-keeps-newer-user-content")
        expectEqual(boards[2].string(forType: .string), "safe-fake-project-config"); checkpoint("System.expiration-keeps-subsequent-safe-config")
        finish("CLIPBOARD TIMER")
    }
    private static func finish(_ name: String) {
        if checkFailures.isEmpty { print("ALL \(name) CHECKS PASSED (\(checkCount) scenarios)") }
        else { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
    }
}
