import Foundation
import AppKit
import Darwin

final class FileInstanceLock {
    private let descriptor: Int32
    init?(file: URL) throws {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw KeyDockError.message("无法创建应用锁，请检查本机目录权限。") }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno; close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw KeyDockError.message("无法锁定应用目录。")
        }
        self.descriptor = descriptor
    }
    deinit { close(descriptor) }
}

enum SingleInstance {
    static let showNotification = Notification.Name("local.keydock.show-window")
    private static var lock: FileInstanceLock?
    @MainActor static func claim() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "local.keydock.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        if !others.isEmpty { activate(others); return false }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KeyDock")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lock = try FileInstanceLock(file: directory.appendingPathComponent(".application-lock"))
            if lock == nil {
                activate(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0.processIdentifier != getpid() }); return false
            }
            return true
        } catch {
            let alert = NSAlert(); alert.messageText = "暂时无法启动 KeyDock"; alert.informativeText = error.localizedDescription; alert.runModal(); return false
        }
    }
    @MainActor private static func activate(_ apps: [NSRunningApplication]) {
        DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        apps.first?.activate(options: [.activateAllWindows])
    }
}
