import Foundation

/// A plain log next to the script's own, so a failure on a machine nobody
/// can screen-share into can be sent back as one file.
/// Never given a password: callers log command output only.
public enum SetupLog {
    public static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/star-traders-sync/setup-app.log")
    }

    /// Tests switch this off, so a test run never writes into the user's
    /// real log.
    public static var enabled = true

    public static func write(_ message: String) {
        guard enabled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let f = ISO8601DateFormatter()
        let line = "\(f.string(from: Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            h.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
