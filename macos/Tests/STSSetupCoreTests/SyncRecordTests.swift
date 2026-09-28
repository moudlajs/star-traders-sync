import XCTest
@testable import STSSetupCore

final class SyncRecordTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("sts-record-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("last-sync.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    var lockDir: URL { dir.appendingPathComponent("local.lock.d") }

    func testMovesTheRecordAsideAndReleasesTheLock() throws {
        let aside = try SyncRecord.reset(stateDir: dir, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(aside?.lastPathComponent, "last-sync.json.reset-1000")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("last-sync.json").path))
        XCTAssertEqual(try String(contentsOf: aside!, encoding: .utf8), "{}", "moved, not rewritten")
        XCTAssertFalse(fm.fileExists(atPath: lockDir.path), "lock released")
    }

    func testRefusesWhileALiveStsHoldsTheLock() throws {
        try fm.createDirectory(at: lockDir, withIntermediateDirectories: false)
        try "4242\n".write(to: dir.appendingPathComponent("local.lock"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SyncRecord.reset(stateDir: dir, isAlive: { $0 == 4242 })) { e in
            XCTAssertEqual(e as? SyncRecord.ResetError, .busy(pid: 4242))
        }
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("last-sync.json").path), "untouched")
        XCTAssertTrue(fm.fileExists(atPath: lockDir.path), "someone else's lock is left alone")
    }

    func testClearsALockWhoseOwnerIsGone() throws {
        try fm.createDirectory(at: lockDir, withIntermediateDirectories: false)
        try "99999\n".write(to: dir.appendingPathComponent("local.lock"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(try SyncRecord.reset(stateDir: dir, isAlive: { _ in false }))
        XCTAssertFalse(fm.fileExists(atPath: lockDir.path))
    }

    func testNoRecordIsNotAnError() throws {
        try fm.removeItem(at: dir.appendingPathComponent("last-sync.json"))
        XCTAssertNil(try SyncRecord.reset(stateDir: dir))
    }

    /// The lock paths must be the script's, or the two would not exclude
    /// each other at all.
    func testUsesTheScriptsLockPaths() throws {
        let script = try String(contentsOf: InstallerTests.repo.appendingPathComponent("bin/star-traders-sync"), encoding: .utf8)
        XCTAssertTrue(script.contains(#"LOCAL_LOCK_FILE="$STATE_DIR/local.lock""#))
        XCTAssertTrue(script.contains(#"lockdir="$STATE_DIR/local.lock.d""#))
        XCTAssertTrue(script.contains(#"STATE_FILE="$STATE_DIR/last-sync.json""#))
        XCTAssertTrue(script.contains(#"STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$PROG""#))
    }
}
