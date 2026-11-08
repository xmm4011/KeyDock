import Foundation
import CryptoKit
import Security
import CommonCrypto
import Darwin

struct VaultRevision: Equatable { var digest: Data? }
struct VaultWriteConflict: Error {}

struct EncryptedVault {
    let directory: URL
    let keyProvider: () throws -> SymmetricKey
    var fileURL: URL { directory.appendingPathComponent("vault.kdv") }

    init(directory: URL? = nil, keyProvider: @escaping () throws -> SymmetricKey = { try EncryptedVault.keychainKey() }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KeyDock", isDirectory: true)
        self.keyProvider = keyProvider
    }

    func load() throws -> VaultData {
        try loadSnapshot().data
    }

    func revision() throws -> VaultRevision {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return VaultRevision() }
        return VaultRevision(digest: Data(SHA256.hash(data: try Data(contentsOf: fileURL))))
    }

    func loadSnapshot() throws -> (data: VaultData, revision: VaultRevision) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (VaultData(), VaultRevision()) }
        let data = try Data(contentsOf: fileURL)
        do {
            let key = try keyProvider()
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
            let vault = try JSONDecoder().decode(VaultData.self, from: clear)
            guard vault.version == 1 else { throw KeyDockError.message("此保险库来自较新的版本，请更新 KeyDock。") }
            guard Set(vault.credentials.map(\.id)).count == vault.credentials.count else { throw KeyDockError.message("保险库中有重复的记录编号，请从加密备份恢复。原文件未改动。") }
            return (vault, VaultRevision(digest: Data(SHA256.hash(data: data))))
        } catch let error as KeyDockError { throw error }
        catch { throw KeyDockError.message("无法解密本地保险库。请确认登录钥匙串可用，或从加密备份恢复。原文件未改动。") }
    }

    @discardableResult
    func save(_ vault: VaultData, replacing expected: VaultRevision? = nil, preservingOriginal: Bool = false) throws -> VaultRevision {
        guard vault.version == 1, Set(vault.credentials.map(\.id)).count == vault.credentials.count else { throw KeyDockError.message("记录版本或编号不正确，未覆盖原保险库。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = open(directory.appendingPathComponent(".write-lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw KeyDockError.message("无法锁定保险库，请检查目录权限。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw KeyDockError.message("另一个 KeyDock 正在保存，请稍后重试。") }
        defer { flock(descriptor, LOCK_UN) }
        if let expected, try revision() != expected { throw VaultWriteConflict() }
        let clear = try JSONEncoder().encode(vault)
        let sealed = try AES.GCM.seal(clear, using: keyProvider())
        guard let data = sealed.combined else { throw KeyDockError.message("加密失败。") }
        if preservingOriginal, FileManager.default.fileExists(atPath: fileURL.path) {
            let retained = directory.appendingPathComponent("vault-before-recovery-\(UUID().uuidString).kdv")
            try FileManager.default.copyItem(at: fileURL, to: retained)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retained.path)
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw KeyDockError.message("无法写入保险库，请检查磁盘空间。")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, fileURL.path) == 0 else { throw KeyDockError.message("保存失败，原保险库已保留。") }
        return VaultRevision(digest: Data(SHA256.hash(data: data)))
    }

    static func keychainKey(service: String = "local.keydock.vault", account: String = "master-key-v1") throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        var result: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data { return SymmetricKey(data: bytes) }
        guard status == errSecItemNotFound else {
            throw KeyDockError.message("无法访问 macOS 钥匙串（\(status)），请解锁登录钥匙串后重试。")
        }
        let key = SymmetricKey(size: .bits256)
        var entry = query
        entry[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        entry[kSecAttrLabel as String] = "KeyDock 本地保险库"
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(entry as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeyDockError.message("无法创建加密密钥（\(added)）。") }
        return key
    }
}

struct PortableBackup: Codable {
    var format = "KeyDock.Backup.v1"
    var rounds = 310_000
    var salt: Data
    var encrypted: Data

    static func create(_ vault: VaultData, password: String) throws -> Data {
        guard password.count >= 8 else { throw KeyDockError.message("备份密码至少需要 8 位。") }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw KeyDockError.message("无法生成安全随机数。") }
        let key = try derive(password, salt: salt, rounds: 310_000)
        let encrypted = try AES.GCM.seal(JSONEncoder().encode(vault), using: key).combined!
        return try JSONEncoder().encode(PortableBackup(salt: salt, encrypted: encrypted))
    }

    static func restore(_ data: Data, password: String) throws -> VaultData {
        guard !password.isEmpty else { throw KeyDockError.message("请输入备份密码。") }
        do {
            let backup = try JSONDecoder().decode(Self.self, from: data)
            guard backup.format == "KeyDock.Backup.v1", (100_000...2_000_000).contains(backup.rounds), backup.salt.count == 32 else {
                throw KeyDockError.message("不支持的备份文件。")
            }
            let key = try derive(password, salt: backup.salt, rounds: backup.rounds)
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: backup.encrypted), using: key)
            let vault = try JSONDecoder().decode(VaultData.self, from: clear)
            guard vault.version == 1 else { throw KeyDockError.message("备份版本不受支持。") }
            return vault
        } catch { throw KeyDockError.message("备份密码不正确，或文件已损坏 / 版本不受支持。") }
    }

    private static func derive(_ password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let utf8 = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = utf8.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress!.assumingMemoryBound(to: Int8.self), utf8.count,
                                    saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw KeyDockError.message("无法加密备份。") }
        return SymmetricKey(data: output)
    }
}
