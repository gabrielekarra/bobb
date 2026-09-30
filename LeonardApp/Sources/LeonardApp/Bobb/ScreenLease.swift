import Foundation
import Darwin

/// One shared desktop, including foreground requests and background jobs.
@MainActor
final class ScreenLease {
    static let shared = ScreenLease()
    private(set) var owner: String?
    private var descriptor: Int32 = -1
    func acquire(_ id: String) -> Bool {
        guard owner == nil || owner == id else { return false }
        if descriptor < 0 {
            try? FileManager.default.createDirectory(at: AppPaths.dataDirectory, withIntermediateDirectories: true)
            let fd = open(AppPaths.dataDirectory.appendingPathComponent("screen.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return false }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
            descriptor = fd
        }
        owner = id; return true
    }
    func release(_ id: String) {
        guard owner == id else { return }
        owner = nil
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }
}
