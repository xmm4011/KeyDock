import Foundation
import CryptoKit
import Security
import AppKit

@MainActor enum DeepStoreChecks {
    static func run() {
        runCheck("Deep.real-macOS-keychain-roundtrip-in-isolated-namespace") {
            let service = "local.keydock.test." + UUID().uuidString
            defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
            let first = try EncryptedVault.keychainKey(service: service)
            let second = try EncryptedVault.keychainKey(service: service)
            expectEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
            expectEqual(first.bitCount, 256)
        }
        runCheck("Deep.quit-clears-only-the-owned-sensitive-clipboard") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false, pasteboard: board)
            store.copy("fixture-only-secret", sensitive: true)
            expectEqual(board.string(forType: .string), "fixture-only-secret")
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            expectNil(board.string(forType: .string))
            store.copy("fixture-only-secret", sensitive: true)
            board.clearContents(); board.setString("new-user-content", forType: .string)
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            expectEqual(board.string(forType: .string), "new-user-content")
        }
        runCheck("Deep.safe-copy-replaces-sensitive-clipboard-without-clearing-user-config") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false, pasteboard: board)
            store.copy("fixture-only-secret", sensitive: true); store.copy("safe-local-config")
            store.clearSensitiveClipboard(); expectEqual(board.string(forType: .string), "safe-local-config")
        }
        runCheck("Deep.editing-key-clears-old-account-balance") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false)
            var record = DeepChecks.record(); record.balanceSummary = "USD 123"; record.balanceCheckedAt = Date()
            expectTrue(store.save(record)); record.apiKey = "replacement-fixture-key"; expectTrue(store.save(record))
            expectEqual(store.selected?.balanceSummary, ""); expectNil(store.selected?.balanceCheckedAt)
        }
        runCheck("Deep.save-rejects-control-characters-before-persistence") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false)
            var record = DeepChecks.record(); record.apiKey += "\nInjected"
            expectFalse(store.save(record)); expectTrue(store.credentials.isEmpty)
        }
        runCheck("Deep.failed-save-never-updates-UI-or-destroys-original") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256); var failing = false
            let disk = EncryptedVault(directory: directory, keyProvider: { if failing { throw KeyDockError.message("simulated keychain failure") }; return key })
            let store = VaultStore(disk: disk, automaticProxy: false)
            var record = DeepChecks.record(); expectTrue(store.save(record))
            let before = try Data(contentsOf: disk.fileURL); failing = true; record.name = "must not be saved"
            expectFalse(store.save(record)); expectNotEqual(store.selected?.name, record.name)
            expectEqual(try Data(contentsOf: disk.fileURL), before)
        }
        runCheck("Deep.restore-collisions-preserve-both-keys-and-unique-routes") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false)
            var original = DeepChecks.record(); original.variablePrefix = "SAME_ALIAS"; expectTrue(store.save(original))
            var other = original; other.apiKey = "different-restored-key"; other.name = "Restored"
            expectTrue(store.restore(VaultData(credentials: [other])))
            expectEqual(store.credentials.count, 2); expectEqual(Set(store.credentials.map(\.id)).count, 2)
            expectEqual(Set(store.credentials.map(\.envPrefix)).count, 2)
            expectEqual(Set(store.credentials.map(\.apiKey)), [original.apiKey, other.apiKey])
        }
        runCheck("Deep.restore-rejects-unknown-version-and-duplicate-IDs") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false)
            let record = DeepChecks.record()
            expectFalse(store.restore(VaultData(version: 999, credentials: [record])))
            var duplicate = record; duplicate.apiKey = "other-key"
            expectFalse(store.restore(VaultData(credentials: [record, duplicate])))
            expectTrue(store.credentials.isEmpty)
        }
        runCheck("Deep.permanent-delete-persists-and-backup-can-explicitly-restore-it") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let disk = EncryptedVault(directory: directory, keyProvider: { key })
            let store = VaultStore(disk: disk, automaticProxy: false)
            let record = DeepChecks.record(); expectTrue(store.save(record)); store.archive([record.id]); store.permanentlyDelete(record)
            expectTrue(store.credentials.isEmpty); expectTrue(try disk.load().credentials.isEmpty)
            expectTrue(store.restore(VaultData(credentials: [record]))); expectEqual(store.credentials.first?.apiKey, record.apiKey)
        }
        runCheck("Deep.restored-organizer-follows-the-restored-key-after-ID-collision") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = SymmetricKey(size: .bits256)
            let store = VaultStore(disk: EncryptedVault(directory: directory, keyProvider: { key }), automaticProxy: false)
            let first = DeepChecks.record(); expectTrue(store.save(first))
            var trusted = first; trusted.apiKey = "restored-trusted-organizer"; trusted.name = "Trusted"
            let backup = VaultData(credentials: [trusted], organizerServiceID: trusted.id, organizerModel: "fixture-model")
            expectTrue(store.restore(backup))
            expectEqual(store.credentials.first { $0.id == store.data.organizerServiceID }?.apiKey, trusted.apiKey)
        }
    }
}
