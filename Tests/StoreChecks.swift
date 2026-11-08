import Foundation
import CryptoKit

@MainActor
enum StoreChecks {
    static func run() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let disk = EncryptedVault(directory: directory, keyProvider: { key })
        let store = VaultStore(disk: disk, automaticProxy: false)
        var first = Credential(); first.name = "DeepSeek A"; first.provider = "DeepSeek"; first.baseURL = "https://api.deepseek.com"; first.apiKey = "fixture-secret-a"; first.variablePrefix = "DEEPSEEK_WORK_01"
        var second = first; second.id = UUID(); second.name = "DeepSeek B"; second.apiKey = "fixture-secret-b"; second.variablePrefix = "DEEPSEEK_WORK_02"
        expectTrue(store.save(first)); expectTrue(store.save(second)); expectEqual(store.credentials.count, 2)
        var conflicting = second; conflicting.variablePrefix = first.variablePrefix
        expectFalse(store.save(conflicting)); expectEqual(store.credentials.first { $0.id == second.id }?.variablePrefix, second.variablePrefix)
        conflicting.variablePrefix = "INVALID;PREFIX"; expectFalse(store.save(conflicting))
        store.archive([first.id]); expectTrue(store.credentials.first { $0.id == first.id }?.archived == true)
        store.archive([first.id], archived: false)
        expectEqual(store.credentials.first { $0.id == first.id }?.localBaseURL, first.localBaseURL)
        let reloaded = VaultStore(disk: disk, automaticProxy: false)
        expectEqual(reloaded.credentials.count, 2)
        expectEqual(reloaded.credentials.first { $0.id == first.id }?.localKey, first.localKey)
        expectTrue(store.restore(VaultData(credentials: [first, second]))); expectEqual(store.credentials.count, 2)
        checkpoint("Store.unique-prefixes-stable-routes-persistence-and-backup-merge")
        do {
            try Data("corrupt-test-data".utf8).write(to: disk.fileURL)
            let locked = VaultStore(disk: disk, automaticProxy: false)
            expectTrue(locked.loadError != nil); expectFalse(locked.save(first))
            expectEqual(try Data(contentsOf: disk.fileURL), Data("corrupt-test-data".utf8))
            expectTrue(locked.restore(VaultData(credentials: [first])))
            expectEqual(try disk.load().credentials.first?.apiKey, first.apiKey)
            expectTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("vault-before-recovery-") })
            checkpoint("Store.failed-load-preserves-file-and-backup-recovery")
        } catch { checkFailures.append("store recovery: " + error.localizedDescription) }
        store.proxy.stop(); reloaded.proxy.stop()
    }
}
