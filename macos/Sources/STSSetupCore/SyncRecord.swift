import Foundation

/// This Mac's record of its last sync (the script's STATE_FILE), and the
/// one change the app makes to it: moving it aside for a diverged state,
/// the fix documented in docs/troubleshooting.md (row 46).
///
/// The script only touches the record while holding this Mac's local lock,
/// so the app takes the very same lock, the same way (acquire_local_lock):
/// an atomic mkdir of local.lock.d with the owner's pid in local.lock, a
/// lock cleared only when its owner is gone, and a clean refusal when a
/// live sts holds it.
public enum SyncRecord {
    public enum ResetError: Error, Equatable, CustomStringConvertible {
        case busy(pid: Int32)
        case io(String)

        public var description: String {
            switch self {
            case .busy(let pid):
                return "The sync tool is running on this Mac right now (pid \(pid)). Wait for it to finish, then try again."
            case .io(let s):
                return s
            }
        }
    }

    public static var defaultStateDir: URL {
        // The app is never launched with XDG_STATE_HOME set; this is the
        // script's default for the same user.
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/star-traders-sync")
    }

    /// Moves last-sync.json to last-sync.json.reset-<epoch>. Returns where
    /// it went, or nil when there was no record. Never deletes anything.
    @discardableResult
    public static func reset(stateDir: URL = defaultStateDir, now: Date = Date(),
                             isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) throws -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let lockDir = stateDir.appendingPathComponent("local.lock.d")
        let lockFile = stateDir.appendingPathComponent("local.lock")

        if mkdir(lockDir.path, 0o755) != 0 {
            let holder = (try? String(contentsOf: lockFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let holder, isAlive(holder) {
                throw ResetError.busy(pid: holder)
            }
            // Stale: its owner is gone, exactly when the script clears it.
            try? fm.removeItem(at: lockDir)
            guard mkdir(lockDir.path, 0o755) == 0 else {
                throw ResetError.io("Could not take the sync lock at \(lockDir.path).")
            }
        }
        defer { try? fm.removeItem(at: lockDir) }
        try? "\(getpid())\n".write(to: lockFile, atomically: false, encoding: .utf8)

        let record = stateDir.appendingPathComponent("last-sync.json")
        guard fm.fileExists(atPath: record.path) else { return nil }
        let aside = stateDir.appendingPathComponent("last-sync.json.reset-\(Int(now.timeIntervalSince1970))")
        do {
            try fm.moveItem(at: record, to: aside)
        } catch {
            throw ResetError.io("Could not move \(record.path) aside: \(error.localizedDescription)")
        }
        return aside
    }
}
