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
        /// The record is no longer the one the user was shown: something
        /// synced in the meantime. Nothing was done.
        case changed
        case io(String)

        public var description: String {
            switch self {
            case .busy(let pid):
                return "The sync tool is running on this Mac right now (pid \(pid)). Wait for it to finish, then try again."
            case .changed:
                return "The sync record changed since this was shown, so nothing was reset. Check again."
            case .io(let s):
                return s
            }
        }
    }

    public static var defaultStateDir: URL {
        stateDir(environment: ProcessInfo.processInfo.environment)
    }

    /// The script's STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$PROG",
    /// resolved the same way: an unset or empty XDG_STATE_HOME falls back.
    /// Pull, push and play inherit this environment, so reset must too, or
    /// it would lock and edit a directory the script never uses.
    public static func stateDir(environment env: [String: String],
                                home: String = NSHomeDirectory()) -> URL {
        let base = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("star-traders-sync")
    }

    /// Moves last-sync.json to last-sync.json.reset-<epoch>. Returns where
    /// it went, or nil when there was no record. Never deletes anything.
    ///
    /// `expectedEpoch` pins it to what the user saw, like --expect-decision
    /// does for pull and push: the record's epoch as status reported it
    /// (last_sync.at), or nil for no record. Checked under the lock; a
    /// different record means a sync happened since, and nothing is done.
    @discardableResult
    public static func reset(stateDir: URL = defaultStateDir, now: Date = Date(),
                             expectedEpoch: Int?? = .none,
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
        // Released the way the script's on_exit does it: the directory and
        // the pid file both.
        defer {
            try? fm.removeItem(at: lockDir)
            try? fm.removeItem(at: lockFile)
        }
        try? "\(getpid())\n".write(to: lockFile, atomically: false, encoding: .utf8)

        let record = stateDir.appendingPathComponent("last-sync.json")
        if case .some(let expected) = expectedEpoch {
            let current = (try? Data(contentsOf: record))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["epoch"] as? NSNumber)?.intValue }
            if current != expected { throw ResetError.changed }
        }
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
