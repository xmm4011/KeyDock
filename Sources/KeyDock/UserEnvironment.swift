import Foundation

struct EnvironmentEntry: Codable, Equatable {
    var id: UUID
    var prefix: String
    var values: [String: String]
    init(_ record: Credential) {
        id = record.id; prefix = record.envPrefix
        values = [prefix + "_BASE_URL": record.localBaseURL, prefix + "_API_KEY": record.localKey]
        if !record.model.isEmpty {
            let secrets = Set(ImportParser.keys(in: record.model) + record.secretValues)
            values[prefix + "_MODEL"] = record.model.replacingSecrets(Dictionary(uniqueKeysWithValues: secrets.map { ($0, "[已隐藏]") }))
        }
    }
}

final class UserEnvironment {
    private struct Registry: Codable {
        var entries: [EnvironmentEntry]
        var createdProfiles: Set<String>
    }
    typealias Command = ([String]) throws -> String
    let home: URL
    let command: Command
    private(set) var entries: [EnvironmentEntry] = []
    private var loadError: String?
    private var createdProfiles = Set<String>()
    var directory: URL { home.appendingPathComponent(".config/keydock", isDirectory: true) }
    var registry: URL { directory.appendingPathComponent("environment.json") }
    var shellFile: URL { directory.appendingPathComponent("environment.sh") }
    var startupFile: URL { directory.appendingPathComponent("apply-environment.sh") }
    var agent: URL { home.appendingPathComponent("Library/LaunchAgents/local.keydock.environment.plist") }
    var profileLine: String { "[ -f " + Credential.shellQuote(shellFile.path) + " ] && source " + Credential.shellQuote(shellFile.path) + " # KeyDock managed" }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, command: @escaping Command = UserEnvironment.launchctl) {
        self.home = home; self.command = command
        if FileManager.default.fileExists(atPath: registry.path) {
            do {
                let bytes = try Data(contentsOf: registry)
                if let saved = try? JSONDecoder().decode(Registry.self, from: bytes) { entries = saved.entries; createdProfiles = saved.createdProfiles }
                else { entries = try JSONDecoder().decode([EnvironmentEntry].self, from: bytes) }
            }
            catch { loadError = "系统变量配置无法读取，请先检查 ~/.config/keydock/environment.json，未覆盖原文件。" }
        }
    }
    func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }
    func install(_ record: Credential) throws {
        guard record.envPrefix.range(of: #"^[A-Z][A-Z0-9_]{1,55}$"#, options: .regularExpression) != nil else { throw KeyDockError.message("变量前缀不正确。") }
        var next = entries.filter { $0.id != record.id }
        guard !next.contains(where: { $0.prefix == record.envPrefix }) else { throw KeyDockError.message("系统变量里已有相同前缀，请修改此 Key 的变量前缀。") }
        next.append(EnvironmentEntry(record)); try apply(next)
    }
    func remove(_ id: UUID) throws { try apply(entries.filter { $0.id != id }) }
    func synchronize(_ records: [Credential]) throws {
        let next = entries.compactMap { entry in records.first { $0.id == entry.id }.map(EnvironmentEntry.init) }
        if next != entries { try apply(next) }
    }
    private func apply(_ next: [EnvironmentEntry]) throws {
        if let loadError { throw KeyDockError.message(loadError) }
        let previousValues = entries.reduce(into: [String: String]()) { $0.merge($1.values) { a, _ in a } }
        let values = next.reduce(into: [String: String]()) { $0.merge($1.values) { a, _ in a } }
        var existing: [String: String] = [:]
        for name in Set(previousValues.keys).union(values.keys) {
            existing[name] = try command(["getenv", name]).trimmingCharacters(in: .newlines)
            if let target = values[name], let current = existing[name], !current.isEmpty, current != target, current != previousValues[name] {
                throw KeyDockError.message("系统已有同名变量 \(name)，未覆盖。请更换此条目的变量前缀。")
            }
        }
        var files: [URL: Data?] = [:]
        let exports = values.sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + Credential.shellQuote($0.value) }.joined(separator: "\n") + "\n"
        files[shellFile] = next.isEmpty ? .some(nil) : .some(Data(exports.utf8))
        let startup = "#!/bin/sh\n" + values.sorted { $0.key < $1.key }.map { "/bin/launchctl setenv " + Credential.shellQuote($0.key) + " " + Credential.shellQuote($0.value) }.joined(separator: "\n") + "\n"
        files[startupFile] = next.isEmpty ? .some(nil) : .some(Data(startup.utf8))
        let plist: [String: Any] = ["Label": "local.keydock.environment", "RunAtLoad": true, "ProgramArguments": ["/bin/sh", startupFile.path]]
        files[agent] = next.isEmpty ? .some(nil) : .some(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        let loginCandidates = [".bash_profile", ".bash_login", ".profile"]
        let bashLogin = loginCandidates.first { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) } ?? ".bash_profile"
        let profiles = Set([".zshrc", ".zprofile", ".bashrc", bashLogin] + loginCandidates.filter { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) })
        var nextCreatedProfiles = createdProfiles
        for name in profiles {
            let file = home.appendingPathComponent(name).resolvingSymlinksInPath()
            let existed = FileManager.default.fileExists(atPath: file.path)
            let old = existed ? try String(contentsOf: file, encoding: .utf8) : ""
            var lines = old.components(separatedBy: "\n").filter { $0 != profileLine }
            if !next.isEmpty && [".zshrc", ".zprofile", ".bashrc", bashLogin].contains(name) {
                if !existed { nextCreatedProfiles.insert(file.path) }
                if lines.last == "" { lines.removeLast() }; lines.append(profileLine); lines.append("")
            }
            let content = lines.joined(separator: "\n")
            if next.isEmpty && content.trimmed.isEmpty && nextCreatedProfiles.contains(file.path) { files[file] = .some(nil); nextCreatedProfiles.remove(file.path) }
            else if content != old { files[file] = .some(Data(content.utf8)) }
        }
        files[registry] = next.isEmpty ? .some(nil) : .some(try JSONEncoder().encode(Registry(entries: next, createdProfiles: nextCreatedProfiles)))
        var snapshots: [URL: Data?] = [:], permissions: [URL: Int] = [:]
        for file in files.keys {
            let exists = FileManager.default.fileExists(atPath: file.path)
            snapshots[file] = exists ? .some(try Data(contentsOf: file)) : .some(nil)
            permissions[file] = exists ? ((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0o600) : 0o600
        }
        do {
            for (file, data) in files { try write(data, to: file, mode: permissions[file] ?? 0o600) }
            for (name, value) in values { _ = try command(["setenv", name, value]) }
            for (name, value) in previousValues where values[name] == nil && existing[name] == value { _ = try command(["unsetenv", name]) }
            entries = next
            createdProfiles = nextCreatedProfiles
            if next.isEmpty { _ = try? command(["bootout", "gui/\(getuid())/local.keydock.environment"]) }
        } catch {
            for (file, data) in snapshots { try? write(data, to: file, mode: permissions[file] ?? 0o600) }
            for (name, value) in existing { _ = try? command(value.isEmpty ? ["unsetenv", name] : ["setenv", name, value]) }
            throw error
        }
    }
    private func write(_ data: Data?, to url: URL, mode: Int) throws {
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.deletingLastPathComponent() == directory { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 || arguments.first == "getenv" else { throw KeyDockError.message("macOS 未能更新当前用户的系统变量，已撤回此次修改。") }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
