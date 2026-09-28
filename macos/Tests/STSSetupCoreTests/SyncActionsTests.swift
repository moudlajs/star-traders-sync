import XCTest
@testable import STSSetupCore

final class SyncActionsTests: XCTestCase {
    func status(_ decision: String, game: Bool = false, lock: String? = nil) throws -> SyncStatus {
        var json = SyncStatusTests.sample.replacingOccurrences(of: "\"FIRSTRUN_CONFLICT\"", with: "\"\(decision)\"")
        if game { json = json.replacingOccurrences(of: "\"game_running\": false", with: "\"game_running\": true") }
        if let lock { json = json.replacingOccurrences(of: "\"hub_lock\": null", with: "\"hub_lock\": \"\(lock)\"") }
        return try SyncStatus.decode(Data(json.utf8))
    }

    func actions(_ decision: String) throws -> [SyncAction] {
        SyncActions.plan(for: try status(decision)).buttons.map(\.action)
    }

    /// The core guarantee: a button is only offered where the script would
    /// accept that command. These pairs are the script's own rules (see
    /// cmd_pull, cmd_push and the regression cases for each decision).
    func testOnlyOffersWhatTheScriptAccepts() throws {
        XCTAssertEqual(try actions("INSYNC"), [.play])
        XCTAssertEqual(try actions("HUB_ONLY"), [.play, .pull])
        XCTAssertEqual(try actions("FIRST_SEED"), [.play, .pull])
        XCTAssertEqual(try actions("LOCAL_ONLY"), [.push], "pull, so play, refuses LOCAL_ONLY")
        XCTAssertEqual(try actions("HUB_EMPTY"), [.keepLocal], "plain push refuses an empty hub")
        XCTAssertEqual(try actions("LOCAL_EMPTIED"), [.keepHub], "plain pull refuses; push always refuses")
        XCTAssertEqual(try actions("BOTH_CHANGED"), [.keepHub, .keepLocal])
        XCTAssertEqual(try actions("FIRSTRUN_CONFLICT"), [.keepHub, .keepLocal])
        XCTAssertEqual(try actions("DIVERGED_STATE"), [.resetRecord], "--force does not override it")
    }

    func testEveryDecisionHasAtLeastOneButton() throws {
        for d in ["INSYNC", "HUB_ONLY", "LOCAL_ONLY", "BOTH_CHANGED", "FIRSTRUN_CONFLICT",
                  "FIRST_SEED", "HUB_EMPTY", "DIVERGED_STATE", "LOCAL_EMPTIED"] {
            XCTAssertFalse(try actions(d).isEmpty, "\(d) would be a statement without an action")
        }
    }

    func testOverwritingActionsAlwaysAskFirst() throws {
        for d in ["HUB_EMPTY", "LOCAL_EMPTIED", "BOTH_CHANGED", "FIRSTRUN_CONFLICT", "DIVERGED_STATE"] {
            for b in SyncActions.plan(for: try status(d)).buttons where [.keepHub, .keepLocal, .resetRecord].contains(b.action) {
                XCTAssertNotNil(b.confirmation, "\(d): \(b.label) overwrites without asking")
            }
        }
    }

    func testConflictConfirmationsNameBothSidesAndTheSafetyCopy() throws {
        let b = SyncActions.plan(for: try status("FIRSTRUN_CONFLICT")).buttons
        let hub = try XCTUnwrap(b.first { $0.action == .keepHub }?.confirmation)
        XCTAssertTrue(hub.message.contains("2 campaigns"))
        XCTAssertTrue(hub.message.contains("safety copy"))
    }

    func testBlockedWhileTheGameRunsOrAnotherMacSyncs() throws {
        XCTAssertNotNil(SyncActions.plan(for: try status("INSYNC", game: true)).blockedBecause)
        XCTAssertNotNil(SyncActions.plan(for: try status("INSYNC", lock: "workmac 1")).blockedBecause)
        XCTAssertNil(SyncActions.plan(for: try status("INSYNC")).blockedBecause)
    }

    func testEveryScriptActionIsPinnedToTheDecisionItWasShownFor() throws {
        for d in ["HUB_ONLY", "LOCAL_ONLY", "HUB_EMPTY", "LOCAL_EMPTIED", "FIRSTRUN_CONFLICT", "BOTH_CHANGED"] {
            for b in SyncActions.plan(for: try status(d)).buttons {
                XCTAssertEqual(b.expected.rawValue, d)
                guard let args = b.action.arguments(expecting: b.expected), b.action != .play else { continue }
                XCTAssertEqual(args.last, "--expect-decision=\(d)", "\(d): \(b.label) could run against a changed state")
            }
        }
        XCTAssertEqual(SyncAction.play.arguments(expecting: .inSync), ["play"], "play takes no expectation")
    }

    /// The app must never send a flag its bundled script does not accept:
    /// that fails every action button with exit 2. Every flag the actions
    /// can pass is checked against the script's parse_args.
    func testTheScriptAcceptsEveryFlagTheAppSends() throws {
        let script = try String(contentsOf: InstallerTests.repo.appendingPathComponent("bin/star-traders-sync"), encoding: .utf8)
        var flags = Set<String>()
        for a in SyncAction.allCases {
            for arg in a.arguments(expecting: .hubOnly) ?? [] where arg.hasPrefix("--") {
                flags.insert(arg.contains("=") && arg.hasPrefix("--expect-decision") ? "--expect-decision=*)" : arg + ")")
            }
        }
        XCTAssertTrue(flags.contains("--expect-decision=*)"))
        for f in flags {
            XCTAssertTrue(script.contains(f), "the script does not accept \(f.dropLast()), which the app sends")
        }
    }

    func testArgumentsAreTheCLIs() {
        XCTAssertEqual(SyncAction.keepHub.arguments, ["pull", "--force=hub"])
        XCTAssertEqual(SyncAction.keepLocal.arguments, ["push", "--force=local"])
        XCTAssertEqual(SyncAction.play.arguments, ["play"])
        XCTAssertNil(SyncAction.resetRecord.arguments)
    }

    /// Lines are the script's real say() output for a play session.
    func testPlayProgressFollowsTheScript() {
        var p = ActionProgress(action: .play)
        XCTAssertEqual(p.current, 0)
        p.feed("pulling before launch...")
        p.feed("pulling nebulaplex01:/Users/d/hub -> /Users/d/Library/StarTradersFrontiers")
        XCTAssertEqual(p.current, 0, "the inner pull line is still the first stage")
        p.feed("launching Star Traders: Frontiers (appid 335620)...")
        XCTAssertEqual(p.current, 1)
        p.feed("game running (pid 4242) - waiting for it to exit. Ctrl-C here does not stop the game.")
        XCTAssertEqual(p.current, 2)
        p.feed("warning: the game crashed (report: /x.ips) - pushing the save anyway")
        XCTAssertTrue(p.gameCrashed)
        p.feed("pushing after play...")
        XCTAssertEqual(p.current, 3)
        p.feed("launching again?")
        XCTAssertEqual(p.current, 3, "never goes backwards")
        p.succeed()
        XCTAssertTrue(p.finished)
        XCTAssertEqual(p.current, 4)
    }

    func testPullAndPushProgress() {
        var pull = ActionProgress(action: .keepHub)
        pull.feed("warning: --force=hub: overwriting this machine's 10 files with the hub's 11")
        XCTAssertEqual(pull.current, 0)
        pull.feed("pulling hub:/x -> /y")
        XCTAssertEqual(pull.current, 1)

        var seed = ActionProgress(action: .keepLocal)
        seed.feed("seeding the empty hub with 10 files from this machine")
        XCTAssertEqual(seed.current, 1)
    }
}
