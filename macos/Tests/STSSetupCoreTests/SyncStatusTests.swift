import XCTest
@testable import STSSetupCore

final class SyncStatusTests: XCTestCase {
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
      "verdict": "hub_newer", "decision": "FIRSTRUN_CONFLICT", "last_sync": null, "hub_lock": null, "game_running": false
    }
    """

    func testDecodesTheScriptsOutput() throws {
        let s = try SyncStatus.decode(Data(Self.sample.utf8))
        XCTAssertEqual(s.verdict, .hubNewer)
        XCTAssertEqual(s.decision, .firstRunConflict, "the real hub: newer by time, but a sync would refuse")
        XCTAssertTrue(s.decision.needsChoice)
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

    func testEveryDecisionTheScriptCanPrintDecodes() throws {
        for d in ["INSYNC", "HUB_ONLY", "LOCAL_ONLY", "BOTH_CHANGED", "FIRSTRUN_CONFLICT",
                  "FIRST_SEED", "HUB_EMPTY", "DIVERGED_STATE", "LOCAL_EMPTIED"] {
            let json = Self.sample.replacingOccurrences(of: "\"FIRSTRUN_CONFLICT\"", with: "\"\(d)\"")
            XCTAssertNoThrow(try SyncStatus.decode(Data(json.utf8)), d)
        }
    }

    /// Reads every value printed by the script's decide() and effective_decision(); an unknown one fails decoding.
    func testDecisionsMatchTheScriptsDecide() throws {
        let script = InstallerTests.repo.appendingPathComponent("bin/star-traders-sync")
        let text = try String(contentsOf: script, encoding: .utf8)
        let printed = try NSRegularExpression(pattern: "printf '([A-Z_]+)'")
        var found = Set<String>()
        for name in ["decide", "effective_decision"] {
            guard let start = text.range(of: "\n\(name)() {"),
                  let end = text.range(of: "\n}\n", range: start.upperBound..<text.endIndex) else {
                return XCTFail("\(name)() not found in the script")
            }
            let body = String(text[start.upperBound..<end.lowerBound])
            for m in printed.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let r = Range(m.range(at: 1), in: body) { found.insert(String(body[r])) }
            }
        }
        XCTAssertTrue(found.contains("INSYNC") && found.contains("LOCAL_EMPTIED"), "both functions were read")
        for d in found { XCTAssertNotNil(SyncStatus.Decision(rawValue: d), "the script prints \(d), unknown to the app") }
    }

    func testLastSyncAndLock() throws {
        let json = Self.sample
            .replacingOccurrences(of: "\"last_sync\": null", with: "\"last_sync\": {\"direction\": \"push\", \"at\": 1790514297}")
            .replacingOccurrences(of: "\"hub_lock\": null", with: "\"hub_lock\": \"workmac 123\"")
        let s = try SyncStatus.decode(Data(json.utf8))
        XCTAssertEqual(s.lastSync?.direction, "push")
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
        XCTAssertEqual(p.title, "The Hub is offline")
        XCTAssertEqual(p.detail, "hub nebulaplex01 is offline")
        XCTAssertFalse(p.needsChoice)
    }

    func testAnOlderScriptWithoutJSONIsExplained() {
        // v1.2.0 rejects --json (exit 2); an older or broken script could print text with exit 0.
        let r = StatusClient.fetch(script: "/x") { _, _ in CommandResult(status: 0, stdout: "star-traders-sync status", stderr: "") }
        guard case .failure(let p) = r else { return XCTFail() }
        XCTAssertEqual(p.code, -1)
    }

    func testAStatusProblemIsNotShownTwice() {
        let offline = SyncProblem.from(code: 25, stderr: "")
        let lock = SyncProblem.from(code: 50, stderr: "")
        XCTAssertFalse(SyncProblem.showStatusProblem(offline, besideRunProblem: offline), "the same refusal twice")
        XCTAssertTrue(SyncProblem.showStatusProblem(lock, besideRunProblem: offline), "a different one is shown")
        XCTAssertTrue(SyncProblem.showStatusProblem(offline, besideRunProblem: nil), "no failed run")
        XCTAssertFalse(SyncProblem.showStatusProblem(nil, besideRunProblem: offline))
    }

    func testLockHolderIsTheMachineName() {
        XCTAssertEqual(SyncProblem.lockHolder("workmac 4242 1790000000 "), "workmac")
        XCTAssertNil(SyncProblem.lockHolder(nil))
    }

    func testConflictCodesNeedAChoice() {
        for c: Int32 in [60, 61, 62] { XCTAssertTrue(SyncProblem.from(code: c, stderr: "").needsChoice) }
        for c: Int32 in [25, 40, 52] { XCTAssertFalse(SyncProblem.from(code: c, stderr: "").needsChoice) }
    }

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
