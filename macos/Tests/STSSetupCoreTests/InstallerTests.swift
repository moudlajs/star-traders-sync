import XCTest
@testable import STSSetupCore

/// Every test runs in a throwaway home directory. None of them may touch
/// the real ~/bin, ~/.config or anything holding saves.
final class InstallerTests: XCTestCase {
    var home: URL!
    var layout: InstallLayout!
    var script: URL!
    var example: URL!
    let fm = FileManager.default

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        // Resolve symlinks: /var is one on macOS, and path comparisons
        // against resolved link targets would otherwise disagree.
        home = fm.temporaryDirectory.appendingPathComponent("sts-setup-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        home = home.resolvingSymlinksInPath()
        layout = InstallLayout(home: home)
        script = Self.repo.appendingPathComponent("bin/star-traders-sync")
        example = Self.repo.appendingPathComponent("config.example")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    func install() throws -> [String] {
        try Installer.installScript(bundledScript: script, bundledExample: example, layout: layout)
    }

    func testFreshInstallCopiesAndLinks() throws {
        _ = try install()
        XCTAssertTrue(fm.isExecutableFile(atPath: layout.installedScript.path))
        XCTAssertEqual(try Data(contentsOf: layout.installedScript), try Data(contentsOf: script))
        for name in ["sts", "star-traders-sync"] {
            let link = layout.binDir.appendingPathComponent(name).path
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), layout.installedScript.path)
        }
    }

    func testReinstallIsIdempotent() throws {
        _ = try install()
        let second = try install()
        XCTAssertTrue(second.contains { $0.contains("already points at it") })
    }

    func testWorkingLinkToARepoCheckoutIsKept() throws {
        try fm.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        let link = layout.binDir.appendingPathComponent("sts")
        try fm.createSymbolicLink(at: link, withDestinationURL: script)
        let report = try install()
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), script.path)
        XCTAssertTrue(report.contains { $0.contains("kept ~/bin/sts") })
    }

    func testDanglingLinkIsReplaced() throws {
        try fm.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        let link = layout.binDir.appendingPathComponent("sts")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/star-traders-sync")
        _ = try install()
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), layout.installedScript.path)
    }

    func testAppScriptIsRefreshedOnlyWhenItDiffers() throws {
        XCTAssertEqual(Installer.refreshAppScript(bundledScript: script, bundledExample: example,
                                                  layout: layout, isRunning: { false }), .refreshed, "missing: copied")
        XCTAssertEqual(Installer.refreshAppScript(bundledScript: script, bundledExample: example,
                                                  layout: layout, isRunning: { false }), .unchanged, "identical: left alone")
        try "old\n".write(to: layout.installedScript, atomically: true, encoding: .utf8)
        XCTAssertEqual(Installer.refreshAppScript(bundledScript: script, bundledExample: example,
                                                  layout: layout, isRunning: { true }), .skippedWhileRunning,
                       "sts running: never replaced, and not reported as unchanged")
        XCTAssertEqual(try String(contentsOf: layout.installedScript, encoding: .utf8), "old\n")
        XCTAssertEqual(Installer.refreshAppScript(bundledScript: script, bundledExample: example,
                                                  layout: layout, isRunning: { false }), .refreshed, "retried later: replaced")
        XCTAssertEqual(try Data(contentsOf: layout.installedScript), try Data(contentsOf: script))
        XCTAssertEqual(Installer.refreshAppScript(bundledScript: nil, bundledExample: nil, layout: layout), .noBundledScript)
    }

    func testAppScriptRefreshLeavesARepoLinkAlone() throws {
        try fm.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        let link = layout.binDir.appendingPathComponent("sts")
        try fm.createSymbolicLink(at: link, withDestinationURL: script)
        Installer.refreshAppScript(bundledScript: script, bundledExample: example, layout: layout, isRunning: { false })
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), script.path)
    }

    func testRealFileIsNeverReplaced() throws {
        try fm.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        let file = layout.binDir.appendingPathComponent("sts")
        try "#!/bin/sh\necho mine\n".write(to: file, atomically: true, encoding: .utf8)
        let report = try install()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "#!/bin/sh\necho mine\n")
        XCTAssertTrue(report.contains { $0.contains("left ~/bin/sts alone") })
    }

    func testExistingConfigIsBackedUpThenUpdated() throws {
        try fm.createDirectory(at: layout.configDir, withIntermediateDirectories: true)
        let old = "HUB_HOST=old\nHUB_USER=u\nHUB_PATH=/Users/u/hub\nSNAPSHOT_KEEP=25\n"
        try old.write(to: layout.configFile, atomically: true, encoding: .utf8)

        let v = SetupValues(hubHost: "new", hubUser: "u", hubPath: "/Users/u/hub")
        _ = try Installer.writeConfig(v, layout: layout, now: Date(timeIntervalSince1970: 0))

        let backups = try fm.contentsOfDirectory(atPath: layout.configDir.path).filter { $0.hasPrefix("config.backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: layout.configDir.appendingPathComponent(backups[0]), encoding: .utf8), old)
        let now = try String(contentsOf: layout.configFile, encoding: .utf8)
        XCTAssertTrue(now.contains("HUB_HOST=new"))
        XCTAssertTrue(now.contains("SNAPSHOT_KEEP=25"))

        // Same values again: nothing to do, no second backup.
        let report = try Installer.writeConfig(v, layout: layout, now: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.configDir.path)
                        .filter { $0.hasPrefix("config.backup-") }.count, 1)
    }

    func testInstallGoesStaleWhenAnythingChosenChanges() {
        let v = SetupValues(hubHost: "h", hubUser: "u", hubPath: "/Users/u/hub", backupVolume: "/Volumes/T9")
        func valid(_ c: SetupValues?, hub: Bool = true) -> Bool {
            Installer.installStillValid(installed: v, installedAsHub: true, current: c, currentIsHub: hub)
        }
        XCTAssertTrue(valid(v), "same values and role stay installed")
        var c = v; c.hubHost = "other";           XCTAssertFalse(valid(c))
        c = v; c.hubUser = "other";               XCTAssertFalse(valid(c))
        c = v; c.hubPath = "/Users/u/other";      XCTAssertFalse(valid(c))
        c = v; c.backupVolume = nil;              XCTAssertFalse(valid(c))
        XCTAssertFalse(valid(v, hub: false), "switching role re-runs install")
        XCTAssertFalse(valid(nil), "no current values: nothing can be valid")
        XCTAssertFalse(Installer.installStillValid(installed: nil, installedAsHub: nil,
                                                   current: v, currentIsHub: true),
                       "never installed")
    }

    /// The strongest check available offline: the real script's own
    /// parser and validator accept what the app writes. Runs `doctor`
    /// (read-only without --fix) against the sandbox and looks for the
    /// line that says the config passed validate_config.
    func testTheScriptAcceptsTheConfigTheAppWrites() throws {
        _ = try install()
        let saves = home.appendingPathComponent("Library/StarTradersFrontiers")
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)

        let cases = [
            SetupValues(hubHost: "some-hub", hubUser: "dan", hubPath: home.path + "/hub"),
            SetupValues(hubHost: "some-hub", hubUser: "dan", hubPath: home.path + "/hub",
                        backupVolume: "/Volumes/T9"),
        ]
        for v in cases {
            try? fm.removeItem(at: layout.configFile)
            _ = try Installer.writeConfig(v, layout: layout)
            let r = Shell.run("/bin/bash", [layout.installedScript.path, "doctor"],
                              env: ["HOME": home.path,
                                    "XDG_CONFIG_HOME": home.path + "/.config",
                                    "XDG_STATE_HOME": home.path + "/.local/state"])
            XCTAssertTrue(r.stdout.contains("config passes every validation rule"),
                          "backup=\(v.backupVolume ?? "none")\n\(r.combined)")
            XCTAssertFalse(r.stdout.contains("placeholders"), r.stdout)
        }
    }
}
