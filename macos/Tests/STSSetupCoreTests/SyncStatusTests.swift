import XCTest
@testable import STSSetupCore

final class SyncStatusTests: XCTestCase {
    /// Captured from `sts status --json` on a real hub.
    static let sample = """
    {
      "version": "1.3.0", "machine": "NebulaPlex01", "is_hub": true,
      "hub": {"host": "nebulaplex01", "path": "/Users/d/star-traders-sync-hub", "endpoint_kind": "local"},
      "sides": {
        "local": {"path": "/Users/d/Library/StarTradersFrontiers", "files": 10, "campaign_saves": 2,
                  "newest": 1789844322, "fingerprint": "826e"},
        "hub":   {"path": "/Users/d/star-traders-sync-hub", "files": 11, "campaign_saves": 2,
                  "newest": 1790514297, "fingerprint": "34d0"}
      },
      "verdict": "hub_newer", "last_sync": null, "hub_lock": null, "game_running": false
    }
    """

    func testDecodesTheScriptsOutput() throws {
        let s = try SyncStatus.decode(Data(Self.sample.utf8))
        XCTAssertEqual(s.verdict, .hubNewer)
        XCTAssertTrue(s.isHub)
        XCTAssertEqual(s.hub.endpointKind, "local")
        XCTAssertEqual(s.sides.local.campaignSaves, 2)
        XCTAssertEqual(s.sides.hub.files, 11)
        XCTAssertNil(s.lastSync)
        XCTAssertNil(s.hubLock)
    }

    func testEveryVerdictTheScriptCanPrintDecodes() throws {
        for v in ["in_sync", "local_newer", "hub_newer", "hub_empty", "local_empty", "differ"] {
            let json = Self.sample.replacingOccurrences(of: "\"hub_newer\"", with: "\"\(v)\"")
            XCTAssertNoThrow(try SyncStatus.decode(Data(json.utf8)), v)
        }
    }

    func testLastSyncAndLock() throws {
        let json = Self.sample
            .replacingOccurrences(of: "\"last_sync\": null", with: "\"last_sync\": {\"host\": \"workmac\", \"at\": 1790514297}")
            .replacingOccurrences(of: "\"hub_lock\": null", with: "\"hub_lock\": \"workmac 123\"")
        let s = try SyncStatus.decode(Data(json.utf8))
        XCTAssertEqual(s.lastSync?.host, "workmac")
        XCTAssertEqual(s.hubLock, "workmac 123")
    }

    func testFetchSuccessAndRefusal() {
        let ok = StatusClient.fetch(script: "/x") { _, args in
            XCTAssertEqual(args, ["status", "--json"])
            return CommandResult(status: 0, stdout: Self.sample, stderr: "")
        }
        guard case .success = ok else { return XCTFail("\(ok)") }

        let off = StatusClient.fetch(script: "/x") { _, _ in
            CommandResult(status: 25, stdout: "", stderr: "info\nerror: hub nebulaplex01 is offline")
        }
        guard case .failure(let p) = off else { return XCTFail() }
        XCTAssertEqual(p.title, "The hub is offline")
        XCTAssertEqual(p.detail, "hub nebulaplex01 is offline")
        XCTAssertFalse(p.needsChoice)
    }

    func testAnOlderScriptWithoutJSONIsExplained() {
        // v1.2.0 rejects --json as an unknown argument (exit 2); an even
        // older or broken one could print text with exit 0.
        let r = StatusClient.fetch(script: "/x") { _, _ in CommandResult(status: 0, stdout: "star-traders-sync status", stderr: "") }
        guard case .failure(let p) = r else { return XCTFail() }
        XCTAssertEqual(p.code, -1)
    }

    func testConflictCodesNeedAChoice() {
        for c: Int32 in [60, 61, 62] { XCTAssertTrue(SyncProblem.from(code: c, stderr: "").needsChoice) }
        for c: Int32 in [25, 40, 52] { XCTAssertFalse(SyncProblem.from(code: c, stderr: "").needsChoice) }
    }

    /// Every code the script can exit with gets a real title, not the
    /// generic fallback. Reads the codes straight from the script.
    func testEveryScriptExitCodeHasAMessage() throws {
        let script = InstallerTests.repo.appendingPathComponent("bin/star-traders-sync")
        let text = try String(contentsOf: script, encoding: .utf8)
        let codes = text.split(separator: "\n")
            .filter { $0.hasPrefix("readonly EX_") }
            .compactMap { $0.split(separator: "=").last?.split(separator: " ").first.flatMap { Int32($0) } }
            .filter { $0 != 0 && $0 != 2 && $0 != 15 && $0 != 16 && $0 != 17 && $0 != 70 && $0 != 71 }
        XCTAssertFalse(codes.isEmpty)
        for c in codes {
            XCTAssertNotEqual(SyncProblem.from(code: c, stderr: "").title, "Something went wrong", "exit \(c) has no message")
        }
    }
}
