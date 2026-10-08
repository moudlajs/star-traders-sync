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
    /// The XDG_CONFIG_HOME default path: a Finder-launched app never has XDG_CONFIG_HOME set, nor does Terminal.
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
    /// Is any star-traders-sync process alive? Never reconfigure while sts is running.
    public static func scriptIsRunning() -> Bool {
        // Matches both names, since `sts play` shows up as .../bin/sts.
        Shell.run("/usr/bin/pgrep", ["-f", "bin/(star-traders-sync|sts)( |$)"]).ok
    }

    /// Installs the bundled tool into Application Support and links `sts` in ~/bin; returns one line per step.
    public static func installScript(bundledScript: URL, bundledExample: URL?,
                                     layout: InstallLayout,
                                     fileManager fm: FileManager = .default) throws -> [String] {
        try installFiles(bundledScript: bundledScript, bundledExample: bundledExample,
                         layout: layout, fileManager: fm)
            + linkCommands(layout: layout, fileManager: fm)
    }

    /// The engines the bundled tool runs (#175), installed beside it when the bundle has them.
    public static let engineNames = ["star-traders-sync.bash", "star-traders-sync-go"]

    // Engines first, shim last, so the shim never points at an engine not yet in place.
    static func toolFiles(bundledScript: URL, layout: InstallLayout,
                          fm: FileManager) -> [(src: URL, dst: URL)] {
        let dir = layout.installedScript.deletingLastPathComponent()
        var files: [(src: URL, dst: URL)] = []
        for name in engineNames {
            let src = bundledScript.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                files.append((src, dir.appendingPathComponent(name)))
            }
        }
        return files + [(bundledScript, layout.installedScript)]
    }

    /// Step one: the tool and config.example into Application Support.
    public static func installFiles(bundledScript: URL, bundledExample: URL?,
                                    layout: InstallLayout,
                                    fileManager fm: FileManager = .default) throws -> [String] {
        try fm.createDirectory(at: layout.installedScript.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        for f in toolFiles(bundledScript: bundledScript, layout: layout, fm: fm) {
            try atomicCopy(f.src, to: f.dst, mode: 0o755, fm: fm)
        }
        if let ex = bundledExample {
            try atomicCopy(ex, to: layout.installedExample, mode: 0o644, fm: fm)
        }
        return ["installed in \(tilde(layout.installedScript.path, layout))"]
    }

    /// Result of refreshAppScript, which keeps the app's tool copy in step with the bundle; skipped while sts runs.
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
        guard let bundledScript, fm.fileExists(atPath: bundledScript.path) else { return .noBundledScript }
        // Any of the files: an engine can change while the shim does not.
        let current = toolFiles(bundledScript: bundledScript, layout: layout, fm: fm).allSatisfy { f in
            guard let new = try? Data(contentsOf: f.src), let old = try? Data(contentsOf: f.dst) else { return false }
            return old == new
        }
        if current { return .unchanged }
        if isRunning() { return .skippedWhileRunning }
        do {
            _ = try installFiles(bundledScript: bundledScript, bundledExample: bundledExample,
                                 layout: layout, fileManager: fm)
            return .refreshed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Links `sts` and `star-traders-sync` in ~/bin; never replaces a real file or a link to a working checkout.
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

    /// Does a finished install still match what the user has chosen? False once any installed value changes.
    public static func installStillValid(installed: SetupValues?, installedAsHub: Bool?,
                                         current: SetupValues?, currentIsHub: Bool) -> Bool {
        guard let installed, let installedAsHub, let current else { return false }
        return installed == current && installedAsHub == currentIsHub
    }

    /// Writes the config; an existing one is backed up beside itself, then updated in place.
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

    /// Disconnect this Mac (#75): remove the app's own ~/bin links and set the config aside; saves are never touched.
    public static func disconnect(layout: InstallLayout, now: Date = Date(),
                                  isRunning: () -> Bool = scriptIsRunning,
                                  fileManager fm: FileManager = .default) throws -> [String] {
        // Never pull the config out from under a running sync.
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

    // Temp file then rename: a running bash keeps reading the old inode, never a half-written script.
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
