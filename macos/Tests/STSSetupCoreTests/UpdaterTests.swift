import CryptoKit
import XCTest
@testable import STSSetupCore

final class UpdaterTests: XCTestCase {
    static let feed = """
    {"tag_name":"v1.4.1","body":"Fixes things.","assets":[
      {"name":"star-traders-sync","size":144716,"digest":"sha256:\(String(repeating: "a", count: 64))",
       "browser_download_url":"https://example.com/star-traders-sync"},
      {"name":"Star-Traders-Sync.dmg","size":2638857,
       "digest":"sha256:3c0b12989491a664316fcc5fc9acfdf7b5c9d477e5e96de84c43c0f778198403",
       "browser_download_url":"https://github.com/moudlajs/star-traders-sync/releases/download/v1.4.1/Star-Traders-Sync.dmg"},
      {"name":"Star-Traders-Sync.dmg.sig","size":89,
       "browser_download_url":"https://github.com/moudlajs/star-traders-sync/releases/download/v1.4.1/Star-Traders-Sync.dmg.sig"}]}
    """

    func testParsesTheReleaseAndItsDigest() throws {
        let r = try UpdateFeed.parse(Data(Self.feed.utf8))
        XCTAssertEqual(r.version, "1.4.1")
        XCTAssertEqual(r.sha256, "3c0b12989491a664316fcc5fc9acfdf7b5c9d477e5e96de84c43c0f778198403")
        XCTAssertEqual(r.dmgURL.lastPathComponent, "Star-Traders-Sync.dmg")
        XCTAssertEqual(r.notes, "Fixes things.")
        XCTAssertEqual(r.signatureURL.lastPathComponent, "Star-Traders-Sync.dmg.sig")
        XCTAssertTrue(UpdateFeed.isTrustedDownload(r.signatureURL))
    }

    // #108
    func testAnUnsignedReleaseIsNotOffered() {
        let unsigned = Self.feed.replacingOccurrences(of: "\"name\":\"Star-Traders-Sync.dmg.sig\"", with: "\"name\":\"other\"")
        XCTAssertNotEqual(unsigned, Self.feed)
        XCTAssertThrowsError(try UpdateFeed.parse(Data(unsigned.utf8))) { e in
            XCTAssertEqual(e as? UpdateError, .badFeed("no Star-Traders-Sync.dmg.sig in release v1.4.1"))
        }
    }

    func testReleaseSignatureIsVerified() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.dmg")
        try Data("a release".utf8).write(to: file)

        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let sig = try key.signature(for: Data("a release".utf8)).base64EncodedString()

        XCTAssertNoThrow(try ReleaseSignature.verify(file, signatureBase64: sig + "\n", publicKeyBase64: pub),
                         "the .sig file ends in a newline")
        XCTAssertThrowsError(try ReleaseSignature.verify(file, signatureBase64: sig), "signed by another key: the embedded one")
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try ReleaseSignature.verify(file, signatureBase64: sig, publicKeyBase64: other))
        XCTAssertThrowsError(try ReleaseSignature.verify(file, signatureBase64: "not base64!", publicKeyBase64: pub))
        try Data("a release, tampered".utf8).write(to: file)
        XCTAssertThrowsError(try ReleaseSignature.verify(file, signatureBase64: sig, publicKeyBase64: pub)) { e in
            XCTAssertEqual(e as? UpdateError, .releaseSignatureInvalid)
        }
    }

    func testTheEmbeddedKeyIsAnEd25519PublicKey() throws {
        let data = try XCTUnwrap(Data(base64Encoded: ReleaseSignature.publicKeyBase64))
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: data))
    }

    func testAReleaseWithoutADigestIsNotOffered() {
        let noDigest = Self.feed.replacingOccurrences(
            of: "\"digest\":\"sha256:3c0b12989491a664316fcc5fc9acfdf7b5c9d477e5e96de84c43c0f778198403\",", with: "")
        XCTAssertThrowsError(try UpdateFeed.parse(Data(noDigest.utf8)), "unverifiable, so not installable")
        XCTAssertThrowsError(try UpdateFeed.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try UpdateFeed.parse(Data("not json".utf8)))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateFeed.isNewer("1.4.1", than: "1.4.0"))
        XCTAssertTrue(UpdateFeed.isNewer("1.10.0", than: "1.9.0"), "numeric, not text")
        XCTAssertTrue(UpdateFeed.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(UpdateFeed.isNewer("1.4.0", than: "1.4.0"))
        XCTAssertFalse(UpdateFeed.isNewer("1.3.9", than: "1.4.0"))
        XCTAssertFalse(UpdateFeed.isNewer("1.4", than: "1.4.0"), "missing parts are zero")
    }

    func testOnlyThisRepositorysDownloadsAreTrusted() {
        func ok(_ s: String) -> Bool { UpdateFeed.isTrustedDownload(URL(string: s)!) }
        XCTAssertTrue(ok("https://github.com/moudlajs/star-traders-sync/releases/download/v1.4.1/Star-Traders-Sync.dmg"))
        XCTAssertFalse(ok("http://github.com/moudlajs/star-traders-sync/releases/download/v1.4.1/Star-Traders-Sync.dmg"), "not https")
        XCTAssertFalse(ok("https://evil.example/moudlajs/star-traders-sync/releases/download/v1/x.dmg"), "other host")
        XCTAssertFalse(ok("https://github.com/someone-else/star-traders-sync/releases/download/v1/x.dmg"), "other repository")
        XCTAssertFalse(ok("https://github.com/moudlajs/star-traders-sync/raw/main/x.dmg"), "not a release download")
        XCTAssertFalse(ok("https://github.com/moudlajs/star-traders-sync/releases/download/../../../evil/x.dmg"))
        XCTAssertTrue(ok(try! UpdateFeed.parse(Data(Self.feed.utf8)).dmgURL.absoluteString), "the real feed shape passes")
    }

    func testFeedOverride() {
        XCTAssertEqual(UpdateFeed.url(environment: [:]), UpdateFeed.defaultURL)
        XCTAssertEqual(UpdateFeed.url(environment: ["STS_UPDATE_FEED": "file:///tmp/feed.json"]).path, "/tmp/feed.json")
    }

    // MARK: - a real install, from a real dmg

    var dir: URL!
    let fm = FileManager.default
    let bundleID = "com.github.moudlajs.star-traders-sync"

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("sts-updater-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    func makeApp(at url: URL, version: String, id: String? = nil) throws {
        let macos = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent("STSSetup")
        try "#!/bin/sh\necho \(version)\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let plist: [String: Any] = ["CFBundleIdentifier": id ?? bundleID, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "STSSetup", "CFBundlePackageType": "APPL"]
        try (plist as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path]).ok)
    }

    func makeDMG(version: String, id: String? = nil, tamper: Bool = false) throws -> URL {
        let stage = dir.appendingPathComponent("stage-\(UUID().uuidString)")
        let app = stage.appendingPathComponent(UpdateInstaller.appName)
        try makeApp(at: app, version: version, id: id)
        if tamper {
            try "#!/bin/sh\necho evil\n".write(to: app.appendingPathComponent("Contents/MacOS/STSSetup"),
                                               atomically: true, encoding: .utf8)
        }
        let dmg = dir.appendingPathComponent("u-\(UUID().uuidString).dmg")
        let r = Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", stage.path, "-ov", "-format", "UDZO", dmg.path])
        XCTAssertTrue(r.ok, r.combined)
        return dmg
    }

    func installedVersion(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func testInstallsAVerifiedUpdateInPlace() throws {
        let target = dir.appendingPathComponent(UpdateInstaller.appName)
        try makeApp(at: target, version: "1.4.0")
        let dmg = try makeDMG(version: "1.4.1")
        try UpdateInstaller.install(dmg: dmg, expectedVersion: "1.4.1", bundleID: bundleID, over: target)
        XCTAssertEqual(installedVersion(target), "1.4.1")
        XCTAssertTrue(Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path]).ok)
        let leftovers = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".update-") }
        XCTAssertEqual(leftovers, [], "no staged copy left behind")
    }

    func makeStage(version: String, id: String? = nil, tamper: Bool = false) throws -> URL {
        let stage = dir.appendingPathComponent("stage-\(UUID().uuidString)")
        let app = stage.appendingPathComponent(UpdateInstaller.appName)
        try makeApp(at: app, version: version, id: id)
        if tamper {
            try "#!/bin/sh\necho evil\n".write(to: app.appendingPathComponent("Contents/MacOS/STSSetup"),
                                               atomically: true, encoding: .utf8)
        }
        return stage
    }

    /// hdiutil faked through install's run seam (#124): CI's back-to-back real attaches hit EAGAIN; codesign and ditto still run.
    func fakeHdiutil(_ exe: String, _ args: [String]) -> CommandResult {
        guard exe == "/usr/bin/hdiutil" else { return Shell.run(exe, args) }
        switch args.first {
        case "attach":
            guard let i = args.firstIndex(of: "-mountpoint"), i + 1 < args.count, let src = args.last else { break }
            return Shell.run("/usr/bin/ditto", [src, args[i + 1]])
        case "detach":
            if let m = args.dropFirst().first, let items = try? fm.contentsOfDirectory(atPath: m) {
                items.forEach { try? fm.removeItem(atPath: m + "/" + $0) }
            }
            return CommandResult(status: 0, stdout: "", stderr: "")
        default: break
        }
        return CommandResult(status: 1, stdout: "", stderr: "fake hdiutil: unexpected \(args)")
    }

    func testRefusalsLeaveTheCurrentAppUntouched() throws {
        let target = dir.appendingPathComponent(UpdateInstaller.appName)
        try makeApp(at: target, version: "1.4.0")

        XCTAssertThrowsError(try UpdateInstaller.install(dmg: try makeStage(version: "1.4.2"), expectedVersion: "1.4.1",
                                                         bundleID: bundleID, over: target, run: fakeHdiutil), "not the advertised version") { e in
            guard case UpdateError.wrongApp = e else { return XCTFail("expected a version refusal, got \(e)") }
        }
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: try makeStage(version: "1.4.1", id: "com.example.other"),
                                                         expectedVersion: "1.4.1", bundleID: bundleID, over: target, run: fakeHdiutil), "not our app") { e in
            guard case UpdateError.wrongApp = e else { return XCTFail("expected a bundle-id refusal, got \(e)") }
        }
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: try makeStage(version: "1.4.1", tamper: true),
                                                         expectedVersion: "1.4.1", bundleID: bundleID, over: target, run: fakeHdiutil)) { e in
            guard case UpdateError.signatureInvalid = e else { return XCTFail("expected a signature failure, got \(e)") }
        }
        XCTAssertEqual(installedVersion(target), "1.4.0", "every refusal left the app as it was")
        XCTAssertTrue(Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path]).ok)
    }

    // #124
    func testAttachRetriesOnlyTheTransientError() {
        let eagain = CommandResult(status: 1, stdout: "", stderr: "hdiutil: attach failed - Resource temporarily unavailable")
        let mounted = CommandResult(status: 0, stdout: "/dev/disk9", stderr: "")
        let corrupt = CommandResult(status: 1, stdout: "", stderr: "hdiutil: attach failed - image not recognized")
        let dmg = URL(fileURLWithPath: "/tmp/x.dmg"), mount = URL(fileURLWithPath: "/tmp/m")

        func attach(_ answers: [CommandResult]) -> (CommandResult, calls: Int, pauses: [TimeInterval]) {
            var queue = answers, calls = 0, pauses: [TimeInterval] = []
            let r = UpdateInstaller.attachWithRetry(dmg: dmg, at: mount, run: { exe, args in
                XCTAssertEqual(exe, "/usr/bin/hdiutil"); XCTAssertEqual(args.first, "attach")
                calls += 1
                return queue.isEmpty ? eagain : queue.removeFirst()
            }, sleep: { pauses.append($0) })
            return (r, calls, pauses)
        }

        let recovered = attach([eagain, eagain, mounted])
        XCTAssertTrue(recovered.0.ok, "two transient failures, then mounted")
        XCTAssertEqual(recovered.calls, 3)
        XCTAssertEqual(recovered.pauses, [0.5, 1])

        let final = attach([corrupt, mounted])
        XCTAssertFalse(final.0.ok, "a real failure is not retried")
        XCTAssertEqual(final.calls, 1)
        XCTAssertEqual(final.pauses, [])

        let busy = attach([])
        XCTAssertFalse(busy.0.ok, "always busy: gives up")
        XCTAssertEqual(busy.calls, UpdateInstaller.attachBackoff.count + 1, "bounded")
        XCTAssertEqual(busy.pauses, UpdateInstaller.attachBackoff)
        XCTAssertGreaterThanOrEqual(UpdateInstaller.attachBackoff.reduce(0, +), 30, "outlasts the spell CI saw (#124)")
    }

    func testChecksumIsVerified() throws {
        let dmg = try makeDMG(version: "1.4.1")
        let good = try UpdateInstaller.sha256(of: dmg)
        XCTAssertNoThrow(try UpdateInstaller.verifyChecksum(dmg, expected: good))
        XCTAssertNoThrow(try UpdateInstaller.verifyChecksum(dmg, expected: good.uppercased()))
        XCTAssertThrowsError(try UpdateInstaller.verifyChecksum(dmg, expected: String(repeating: "0", count: 64)))
    }

    func testNeverFromADiskImage() {
        XCTAssertNotNil(UpdateInstaller.canReplace(URL(fileURLWithPath: "/Volumes/Star Traders Sync/Star Traders Sync.app")))
    }
}
