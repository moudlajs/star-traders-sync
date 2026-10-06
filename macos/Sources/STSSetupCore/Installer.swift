import Foundation

/// Where things go, rooted at a home directory so tests can use a sandbox.
public struct InstallLayout {
    public let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    public var supportDir: URL { home.appendingPathComponent("Library/Application Support/star-traders-sync") }
    public var installedScript: URL { supportDir.appendingPathComponent("bin/star-traders-sync") }
    public var installedExample: URL { supportDir.appendingPathComponent("config.example") }
    public var binDir: URL { home.appendingPathComponent("bin") }
    /// The script honours XDG_CONFIG_HOME, but an app launched from Finder
    /// never has it set, and neither does a default Terminal. This is the
    /// path both of them use.
    public var configDir: URL { home.appendingPathComponent(".config/star-traders-sync") }
    public var configFile: URL { configDir.appendingPathComponent("config") }
    public var linkNames: [String] { ["star-traders-sync", "sts"] }
}

public enum InstallError: Error, CustomStringConvertible {
    case scriptRunning
    case io(String)

    public var description: String {
        switch self {
        case .scriptRunning:
            return "star-traders-sync is running right now (probably sts play). Quit the game, let it finish pushing, then try again."
        case .io(let s):
            return s
        }
    }
}

public enum Installer {
    /// Is any star-traders-sync process alive? Replacing the script under a
    /// running bash is how you make it execute garbage (see CLAUDE.md).
    /// The install below replaces by rename, which is safe for a running
    /// bash, but a user mid-`sts play` should not be reconfigured anyway.
    public static func scriptIsRunning() -> Bool {
        // Matches both names, since `sts play` shows up as .../bin/sts.
        Shell.run("/usr/bin/pgrep", ["-f", "bin/(star-traders-sync|sts)( |$)"]).ok
    }

    /// Copies the bundled script and config.example into Application
    /// Support, then links `sts` and `star-traders-sync` in ~/bin.
    /// Returns one human-readable line per thing it did.
    public static func installScript(bundledScript: URL, bundledExample: URL?,
                                     layout: InstallLayout,
                                     fileManager fm: FileManager = .default) throws -> [String] {
        try installFiles(bundledScript: bundledScript, bundledExample: bundledExample,
                         layout: layout, fileManager: fm)
            + linkCommands(layout: layout, fileManager: fm)
    }

    /// Step one: the script and config.example into Application Support.
    public static func installFiles(bundledScript: URL, bundledExample: URL?,
                                    layout: InstallLayout,
                                    fileManager fm: FileManager = .default) throws -> [String] {
        try fm.createDirectory(at: layout.installedScript.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try atomicCopy(bundledScript, to: layout.installedScript, mode: 0o755, fm: fm)
        if let ex = bundledExample {
            try atomicCopy(ex, to: layout.installedExample, mode: 0o644, fm: fm)
        }
        return ["installed in \(tilde(layout.installedScript.path, layout))"]
    }

    /// Keeps the app's own copy of the script in step with the one bundled
    /// in the app, so the app never talks to a script older than itself.
    /// `sts` in ~/bin may point at a repo checkout the user maintains; that
    /// is theirs, and the app neither follows nor replaces it.
    /// Skipped while any sts is running, and then worth retrying: the app
    /// calls it again before every status check.
    public enum RefreshResult: Equatable {
        case refreshed, unchanged, skippedWhileRunning, noBundledScript, failed(String)

        public var logText: String {
            switch self {
            case .refreshed:           return "refreshed"
            case .unchanged:           return "unchanged"
            case .skippedWhileRunning: return "not refreshed yet: sts is running, will retry"
            case .noBundledScript:     return "not refreshed: no script in the app bundle"
            case .failed(let why):     return "refresh failed: \(why)"
            }
        }
    }

    @discardableResult
    public static func refreshAppScript(bundledScript: URL?, bundledExample: URL?, layout: InstallLayout,
                                        isRunning: () -> Bool = scriptIsRunning,
                                        fileManager fm: FileManager = .default) -> RefreshResult {
        guard let bundledScript, let new = try? Data(contentsOf: bundledScript) else { return .noBundledScript }
        if let old = try? Data(contentsOf: layout.installedScript), old == new { return .unchanged }
        if isRunning() { return .skippedWhileRunning }
        do {
            _ = try installFiles(bundledScript: bundledScript, bundledExample: bundledExample,
                                 layout: layout, fileManager: fm)
            return .refreshed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Step two: `sts` and `star-traders-sync` in ~/bin.
    ///
    /// Mirrors install.sh's rules: a real file in ~/bin is never replaced.
    /// It adds one: a link that already points at a working script (a repo
    /// checkout) is left alone, so a developer's install is not hijacked.
    public static func linkCommands(layout: InstallLayout,
                                    fileManager fm: FileManager = .default) throws -> [String] {
        var report: [String] = []
        try fm.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        for name in layout.linkNames {
            let link = layout.binDir.appendingPathComponent(name)
            let shown = tilde(link.path, layout)

            if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                let resolved = URL(fileURLWithPath: target, relativeTo: layout.binDir).standardizedFileURL
                if resolved.path == layout.installedScript.standardizedFileURL.path {
                    report.append("\(shown) already points at it")
                    continue
                }
                if fm.isExecutableFile(atPath: resolved.path) {
                    report.append("kept \(shown), which points at your own copy: \(tilde(resolved.path, layout))")
                    continue
                }
                // Dangling: the repo it pointed into is gone.
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                report.append("left \(shown) alone: it is a real file, not a link, so it was not replaced")
                continue
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: layout.installedScript)
            report.append("linked \(shown)")
        }
        return report
    }

    /// Does a finished install still describe what the user has chosen?
    /// False once they go back and change the hub, the account, the hub
    /// folder, the backup disk or the role, so Install runs again rather
    /// than showing done for values that were never written.
    public static func installStillValid(installed: SetupValues?, installedAsHub: Bool?,
                                         current: SetupValues?, currentIsHub: Bool) -> Bool {
        guard let installed, let installedAsHub, let current else { return false }
        return installed == current && installedAsHub == currentIsHub
    }

    /// Writes the config. An existing one is backed up next to itself and
    /// then updated in place, so every tunable the user set survives.
    public static func writeConfig(_ values: SetupValues, layout: InstallLayout,
                                   now: Date = Date(),
                                   fileManager fm: FileManager = .default) throws -> [String] {
        try fm.createDirectory(at: layout.configDir, withIntermediateDirectories: true)
        let file = layout.configFile
        let shown = tilde(file.path, layout)

        if fm.fileExists(atPath: file.path) {
            let old = try String(contentsOf: file, encoding: .utf8)
            let new = ConfigFile.update(old, with: values)
            if new == old { return ["config already up to date: \(shown)"] }

            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let backup = layout.configDir.appendingPathComponent("config.backup-\(f.string(from: now))")
            try fm.copyItem(at: file, to: backup)
            try atomicWrite(new, to: file, mode: 0o644, fm: fm)
            return ["backed up your old config to \(tilde(backup.path, layout))",
                    "updated \(shown)"]
        }
        let text = ConfigFile.render(values, examplePath: layout.installedExample.path)
        try atomicWrite(text, to: file, mode: 0o644, fm: fm)
        return ["wrote \(shown)"]
    }

    /// Disconnect this Mac (#75): undo what setup did to this Mac's command
    /// line and config, and nothing else. The ~/bin links go only if they
    /// point at the app's own copy (never a link to a repo checkout, never
    /// a real file). The config is renamed to a dated backup, not deleted.
    /// Saves, safety copies, the sync record and the hub are not touched;
    /// running setup again brings it all back.
    public static func disconnect(layout: InstallLayout, now: Date = Date(),
                                  isRunning: () -> Bool = scriptIsRunning,
                                  fileManager fm: FileManager = .default) throws -> [String] {
        // The script reads its config as it goes: never pull it out from
        // under a running sync.
        if isRunning() { throw InstallError.scriptRunning }
        var report: [String] = []
        for name in layout.linkNames {
            let link = layout.binDir.appendingPathComponent(name)
            let shown = tilde(link.path, layout)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
                if fm.fileExists(atPath: link.path) {
                    report.append("left \(shown) alone: it is a real file, not the app's link")
                }
                continue
            }
            let resolved = URL(fileURLWithPath: target, relativeTo: layout.binDir).standardizedFileURL
            if resolved.path == layout.installedScript.standardizedFileURL.path {
                try fm.removeItem(at: link)
                report.append("removed \(shown)")
            } else {
                report.append("left \(shown) alone: it points at your own copy, \(tilde(resolved.path, layout))")
            }
        }
        if fm.fileExists(atPath: layout.configFile.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let backup = layout.configDir.appendingPathComponent("config.disconnected-\(f.string(from: now))")
            try fm.moveItem(at: layout.configFile, to: backup)
            report.append("moved your config to \(tilde(backup.path, layout))")
        }
        report.append("your saves, their safety copies and the Hub were not touched")
        return report
    }

    // MARK: - helpers

    /// Write to a temp file beside the target, then rename over it. A
    /// running bash keeps reading the old inode, so it never sees a
    /// half-written script.
    static func atomicCopy(_ src: URL, to dst: URL, mode: Int, fm: FileManager) throws {
        let data = try Data(contentsOf: src)
        try atomicWrite(data, to: dst, mode: mode, fm: fm)
    }

    static func atomicWrite(_ text: String, to dst: URL, mode: Int, fm: FileManager) throws {
        try atomicWrite(Data(text.utf8), to: dst, mode: mode, fm: fm)
    }

    static func atomicWrite(_ data: Data, to dst: URL, mode: Int, fm: FileManager) throws {
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).tmp-\(getpid())")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        if rename(tmp.path, dst.path) != 0 {
            let msg = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw InstallError.io("could not move \(tmp.path) into place: \(msg)")
        }
    }

    static func tilde(_ path: String, _ layout: InstallLayout) -> String {
        let home = layout.home.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
