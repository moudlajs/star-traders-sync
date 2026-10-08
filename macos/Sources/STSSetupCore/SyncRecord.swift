import Foundation

/// This Mac's sync record (STATE_FILE), moved aside only under the script's own local lock, never beside a live sts.
public enum SyncRecord {
    public enum ResetError: Error, Equatable, CustomStringConvertible {
        case busy(pid: Int32)
        /// The record is no longer the one the user was shown; nothing was done.
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

    /// The script's STATE_DIR resolved the same way, so reset locks the directory the script uses.
    public static func stateDir(environment env: [String: String],
                                home: String = NSHomeDirectory()) -> URL {
        let base = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("star-traders-sync")
    }

    /// Moves last-sync.json aside (never deletes); does nothing if it is not the record the user saw.
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
        // Released the way the script's on_exit does: the directory and the pid file both.
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
