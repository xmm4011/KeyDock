import Foundation
import CryptoKit
import Darwin

@MainActor enum PersistenceRegressionChecks {
    static func run() {
        runCheck("Regression.edit-preserves-a-newer-verification-and-balance") {
            try isolated { disk in
                let store = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(store.save(DeepChecks.record()))
                var editor = store.credentials[0]
                let checked = CheckResult(state: .valid, message: "new result")
                expectTrue(store.commit { data in
                    data.credentials[0].check = checked
                    data.credentials[0].balanceSummary = "USD 12"
                    data.credentials[0].balanceCheckedAt = checked.checkedAt
                    data.credentials[0].favorite = true
                })
                editor.name = "Edited name"
                expectTrue(store.save(editor))
                expectEqual(store.credentials[0].check, checked)
                expectEqual(store.credentials[0].balanceSummary, "USD 12")
                expectEqual(store.credentials[0].balanceCheckedAt, checked.checkedAt)
                expectTrue(store.credentials[0].favorite)
            }
        }
        runCheck("Regression.two-stores-never-silently-overwrite-each-other") {
            try isolated { disk in
                let first = VaultStore(disk: disk, automaticProxy: false)
                let second = VaultStore(disk: disk, automaticProxy: false)
                let a = DeepChecks.record()
                var b = DeepChecks.record(); b.apiKey = "different-test-key"
                expectTrue(first.save(a))
                expectFalse(second.save(b))
                expectEqual(try disk.load().credentials.map(\.id), [a.id])
                expectEqual(second.credentials.map(\.id), [a.id])
                expectTrue(second.save(b))
                expectEqual(Set(try disk.load().credentials.map(\.id)), [a.id, b.id])
            }
        }
        runCheck("Regression.stale-edit-cannot-revert-a-newer-edit") {
            try isolated { disk in
                let store = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(store.save(DeepChecks.record()))
                var old = store.credentials[0], current = old
                current.notes = "newer notes"; expectTrue(store.save(current))
                old.name = "stale edit"
                expectFalse(store.save(old, expectedUpdatedAt: old.updatedAt))
                expectEqual(store.credentials[0].notes, "newer notes")
            }
        }
        runCheck("Regression.deleted-record-cannot-be-resurrected-by-an-open-editor") {
            try isolated { disk in
                let store = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(store.save(DeepChecks.record()))
                var old = store.credentials[0]
                store.archive([old.id]); store.permanentlyDelete(old); old.name = "stale edit"
                expectFalse(store.save(old, expectedUpdatedAt: old.updatedAt))
                expectTrue(try disk.load().credentials.isEmpty)
            }
        }
        runCheck("Regression.external-write-lock-fails-without-changing-data") {
            try isolated { disk in
                let store = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(store.save(DeepChecks.record()))
                let before = try Data(contentsOf: disk.fileURL)
                let descriptor = open(disk.directory.appendingPathComponent(".write-lock").path, O_RDWR)
                guard descriptor >= 0 else { throw KeyDockError.message("test lock failed") }
                defer { close(descriptor) }
                expectEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
                var added = DeepChecks.record(); added.apiKey = "second-fake-key"
                expectFalse(store.save(added)); expectEqual(store.credentials.count, 1)
                expectEqual(try Data(contentsOf: disk.fileURL), before)
                flock(descriptor, LOCK_UN)
                expectTrue(store.save(added)); expectEqual(try disk.load().credentials.count, 2)
            }
        }
        runCheck("Regression.stale-recovery-cannot-overwrite-a-repaired-vault") {
            try isolated { disk in
                try FileManager.default.createDirectory(at: disk.directory, withIntermediateDirectories: true)
                try Data("corrupted".utf8).write(to: disk.fileURL)
                let stale = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(stale.loadError != nil)
                let repaired = DeepChecks.record()
                try disk.save(VaultData(credentials: [repaired]))
                expectFalse(stale.restore(VaultData()))
                expectEqual(try disk.load().credentials.first?.id, repaired.id)
                expectNil(stale.loadError); expectEqual(stale.credentials.first?.id, repaired.id)
            }
        }
        runCheck("Regression.external-corruption-blocks-subsequent-writes") {
            try isolated { disk in
                let store = VaultStore(disk: disk, automaticProxy: false)
                expectTrue(store.save(DeepChecks.record()))
                let corrupted = Data("changed-outside-KeyDock".utf8)
                try corrupted.write(to: disk.fileURL)
                expectFalse(store.commit { $0.credentials.removeAll() })
                expectTrue(store.loadError != nil)
                expectEqual(try Data(contentsOf: disk.fileURL), corrupted)
                expectFalse(store.commit { $0.credentials.removeAll() })
            }
        }
    }
    private static func isolated(_ body: (EncryptedVault) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        try body(EncryptedVault(directory: directory, keyProvider: { key }))
    }
}
