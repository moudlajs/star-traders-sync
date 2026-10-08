import Foundation

/// The config values the setup app decides; every other line keeps the script's defaults or the user's own.
public struct SetupValues: Equatable {
    public var hubHost: String
    public var hubUser: String
    public var hubPath: String
    /// nil means this machine has no backup disk.
    public var backupVolume: String?

    public init(hubHost: String, hubUser: String, hubPath: String, backupVolume: String? = nil) {
        self.hubHost = hubHost
        self.hubUser = hubUser
        self.hubPath = hubPath
        self.backupVolume = backupVolume
    }

    public var backupDest: String? {
        backupVolume.map { "\($0)/Backups/star-traders-sync" }
    }
}

public enum ConfigFile {
    public static let defaultSavePath = "~/Library/StarTradersFrontiers"

    /// The Hub folder a new setup suggests: a path that must match existing installs exactly, lower case included.
    public static func defaultHubPath(user: String) -> String {
        "/Users/\(user)/star-traders-sync-hub"
    }

    /// Sentinel for a Mac without a backup disk: the script requires BACKUP_VOLUME everywhere (#53).
    public static let noBackupVolume = "/Volumes/sts-no-backup-disk"

    // Keys the app owns: rewritten on update, while every other line is kept exactly as it was.
    static let managedKeys = ["HUB_HOST", "HUB_USER", "HUB_PATH", "BACKUP_VOLUME", "BACKUP_DEST"]

    static let requiredDefaults: [(String, String)] = [
        ("LOCAL_SAVE_PATH", defaultSavePath),
        ("SYNC_EXCLUDE", "data.db steam_autocloud.vdf"),
        ("STEAM_APPID", "335620"),
        ("GAME_PROCESS_NAME", "StarTradersFrontiers"),
    ]

    // Only these are added to an existing config: adding SYNC_EXCLUDE would change which files a sync moves.
    static var scriptRequired: [(String, String)] {
        requiredDefaults.filter { $0.0 != "SYNC_EXCLUDE" }
    }

    static func managedValues(_ v: SetupValues) -> [(String, String)] {
        let volume = v.backupVolume ?? noBackupVolume
        let dest = v.backupDest ?? "\(noBackupVolume)/star-traders-sync"
        return [("HUB_HOST", v.hubHost), ("HUB_USER", v.hubUser), ("HUB_PATH", v.hubPath),
                ("BACKUP_VOLUME", volume), ("BACKUP_DEST", dest)]
    }

    /// Parses KEY=value the way the script does: comments skipped, values trimmed, last occurrence wins.
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out[key] = val
        }
        return out
    }

    /// A new config, in the same shape install.sh writes.
    public static func render(_ v: SetupValues, examplePath: String) -> String {
        let m = Dictionary(uniqueKeysWithValues: managedValues(v))
        let d = Dictionary(uniqueKeysWithValues: requiredDefaults)
        var s = """
        # star-traders-sync config, written by the Star Traders Sync app.
        # Every option, explained, with defaults:
        #   \(examplePath)

        HUB_HOST=\(m["HUB_HOST"]!)
        HUB_USER=\(m["HUB_USER"]!)
        HUB_PATH=\(m["HUB_PATH"]!)

        LOCAL_SAVE_PATH=\(d["LOCAL_SAVE_PATH"]!)
        SYNC_EXCLUDE=\(d["SYNC_EXCLUDE"]!)

        STEAM_APPID=\(d["STEAM_APPID"]!)
        GAME_PROCESS_NAME=\(d["GAME_PROCESS_NAME"]!)


        """
        if v.backupVolume == nil {
            s += "# No backup disk on this machine. Only the hub runs `sts backup`.\n"
        }
        s += "BACKUP_VOLUME=\(m["BACKUP_VOLUME"]!)\nBACKUP_DEST=\(m["BACKUP_DEST"]!)\n"
        return s
    }

    /// Rewrites the managed keys in place, keeping comments, order and every tunable the user set.
    public static func update(_ existing: String, with v: SetupValues) -> String {
        let managed = managedValues(v)
        let wanted = Dictionary(uniqueKeysWithValues: managed)
        var seen = Set<String>()
        var lines = existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        lines = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return line }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard let val = wanted[key] else {
                seen.insert(key)
                return line
            }
            seen.insert(key)
            return "\(key)=\(val)"
        }

        var appended: [String] = []
        for (k, val) in managed + scriptRequired where !seen.contains(k) {
            appended.append("\(k)=\(val)")
        }
        if !appended.isEmpty {
            lines.append("")
            lines.append("# added by the Star Traders Sync app")
            lines += appended
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a config back into SetupValues, for prefilling the app.
    public static func values(from text: String) -> SetupValues? {
        let c = parse(text)
        guard let host = c["HUB_HOST"], let user = c["HUB_USER"], let path = c["HUB_PATH"] else {
            return nil
        }
        // Only the app's own sentinel means "no disk"; anything else may be a real backup disk, so it is kept.
        var volume = c["BACKUP_VOLUME"]
        if volume == noBackupVolume || volume?.isEmpty == true { volume = nil }
        return SetupValues(hubHost: host, hubUser: user, hubPath: path, backupVolume: volume)
    }

    /// The checks the script's validate_config would fail on, phrased for the app.
    public static func problems(_ v: SetupValues, localSavePath: String, home: String) -> [String] {
        var out: [String] = []
        let pathChars = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@+-")
        func safe(_ s: String) -> Bool { s.unicodeScalars.allSatisfy(pathChars.contains) }

        if v.hubHost.isEmpty { out.append("Pick the Mac that holds the hub.") }
        if v.hubUser.isEmpty {
            out.append("Enter the account name on the hub Mac.")
        } else if v.hubUser.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "=" }) {
            out.append("The account name cannot contain spaces, @ or =. Use the short name (the one in /Users/...).")
        }
        if !v.hubPath.hasPrefix("/") {
            out.append("The hub folder must be a full path starting with /.")
        }
        if !safe(v.hubPath) {
            out.append("The hub folder can only use letters, digits and . _ / @ + - (no spaces).")
        }
        if let vol = v.backupVolume, !safe(vol) {
            out.append("The backup disk name \"\((vol as NSString).lastPathComponent)\" has a space or symbol in it, which the sync tool cannot handle. Rename the disk in Finder, or choose no backup disk.")
        }

        let local = expandTilde(localSavePath, home: home)
        let hub = strip(v.hubPath)
        if hub == local {
            out.append("The hub folder cannot be the game's own save folder.")
        } else if (local + "/").hasPrefix(hub + "/") {
            out.append("The game's save folder cannot be inside the hub folder.")
        } else if (hub + "/").hasPrefix(local + "/") {
            out.append("The hub folder cannot be inside the game's save folder.")
        }
        return out
    }

    public static func expandTilde(_ p: String, home: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return strip(home + "/" + p.dropFirst(2)) }
        return strip(p)
    }

    static func strip(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
