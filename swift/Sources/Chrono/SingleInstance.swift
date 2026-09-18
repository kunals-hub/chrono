import Foundation
import Darwin

/// Single-instance lock on /tmp/chrono.lock (flock NB + PID).
/// Matches chrono.py. If another instance holds the lock, this process exits(0).
/// macOS `open` re-activates the running .app, so no custom IPC is needed.
enum SingleInstance {
    static var lockFD: Int32 = -1

    static func acquireOrExit() {
        let path = "/tmp/chrono.lock"
        let fd = Darwin.open(path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { exit(0) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(fd)
            // Another instance is running — `open` already brought it forward.
            exit(0)
        }
        // Write PID for `chronokill`-style tooling.
        ftruncate(fd, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        pid.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
        lockFD = fd
        // Intentionally leave fd open for the life of the process.
    }

    static func releaseLock() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            lockFD = -1
            try? FileManager.default.removeItem(atPath: "/tmp/chrono.lock")
        }
    }
}
