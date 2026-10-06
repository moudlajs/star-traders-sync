import XCTest
@testable import STSSetup
@testable import STSSetupCore

/// DashboardModel's state machine: what starts, and what must not, with
/// the script and the clock replaced by fakes. Each case is one of the
/// timing bugs found in review of #95, so it cannot come back unnoticed.
@MainActor
final class DashboardModelTests: XCTestCase {
    /// Records every script call. Called from a background task.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[String]] = []
        func add(_ args: [String]) { lock.lock(); list.append(args); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return list }
    }

    static func status(_ decision: String, game: Bool = false) throws -> SyncStatus {
        let json = """
        {"version":"1.3.0","machine":"m","is_hub":false,
         "hub":{"host":"hub","path":"/h","endpoint_kind":"magicdns"},
         "sides":{"local":{"path":"/l","files":10,"campaign_saves":2,"newest":1790000000,"fingerprint":"aa"},
                  "hub":{"path":"/h","files":11,"campaign_saves":2,"newest":1790000100,"fingerprint":"bb"}},
         "verdict":"hub_newer","decision":"\(decision)","last_sync":null,"hub_lock":null,"game_running":\(game)}
        """
        return try SyncStatus.decode(Data(json.utf8))
    }

    var calls: Calls!
    var d: DashboardModel!
    var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        SetupLog.enabled = false
        calls = Calls()
        d = DashboardModel()
        d.autoSync = true
        d.now = { [unowned self] in self.clock }
        d.refreshScript = { _ in }   // never the real Application Support copy
    }

    override func tearDown() async throws {
        d.stop()
        UserDefaults.standard.removeObject(forKey: DashboardModel.holdKey)
        SetupLog.enabled = true
    }

    /// Feeds these statuses to successive checks (the last repeats), and
    /// answers every script call with `exit`.
    func fake(_ statuses: [SyncStatus], exit: Int32 = 0) {
        var queue = statuses
        let lock = NSLock()
        d.fetchStatus = { _ in
            lock.lock(); defer { lock.unlock() }
            return .success(queue.count > 1 ? queue.removeFirst() : queue[0])
        }
        let calls = self.calls!
        d.runScript = { _, args, _ in calls.add(args); return exit }
    }

    func settle(_ timeout: TimeInterval = 3, until done: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testFetchesByItselfWhenOnlyTheHubChangedPinnedAndUnforced() async throws {
        fake([try Self.status("HUB_ONLY"), try Self.status("INSYNC")])
        d.refresh()
        await settle { !self.calls.all.isEmpty && !self.d.busy && !self.d.loading }
        XCTAssertEqual(calls.all, [["pull", "--expect-decision=HUB_ONLY"]])
    }

    func testNeverSyncsByItselfOnAConflict() async throws {
        fake([try Self.status("BOTH_CHANGED")])
        d.refresh()
        await settle { self.d.status != nil && !self.d.loading }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testNothingAutomaticWhenSwitchedOff() async throws {
        d.autoSync = false
        fake([try Self.status("HUB_ONLY")])
        d.refresh()
        await settle { self.d.status != nil && !self.d.loading }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testNeverWhileTheGameRuns() async throws {
        fake([try Self.status("HUB_ONLY", game: true)])
        d.refresh()
        await settle { self.d.status != nil && !self.d.loading }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(calls.all.isEmpty)
    }

    /// A failure is not retried against the same situation in a loop, but
    /// is retried once enough time has passed (a network blip heals).
    func testAFailedAutomaticSyncIsNotRetriedUntilItExpires() async throws {
        fake([try Self.status("HUB_ONLY")], exit: 25)
        d.refresh()
        await settle { self.calls.all.count == 1 && !self.d.busy && !self.d.loading }
        d.refresh()
        await settle { !self.d.loading }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(calls.all.count, 1, "same situation, not retried")
        XCTAssertNotNil(d.autoFailedKey)

        clock = clock.addingTimeInterval(DashboardModel.autoRetryAfter + 1)
        d.dismissRun()
        d.refresh()
        await settle { self.calls.all.count == 2 }
        XCTAssertEqual(calls.all.count, 2, "retried after the back-off")
    }

    /// The #95 review sequence: a press queued during a check, then setup
    /// opens (stop) before the check returns. Nothing may start.
    /// #90: a restore runs exactly `sts restore NAME`, and a restore with
    /// no copy chosen runs nothing - never the reset-record path.
    func testARestoreRunsTheScriptWithTheChosenCopy() async throws {
        fake([try Self.status("INSYNC")])
        d.start()
        await settle { !self.d.loading && self.d.status != nil }
        let copy = try XCTUnwrap(SafetyCopy.list(from: Data(#"{"snapshots":[{"name":"2026-10-06T12:00:00Z","files":5,"campaign_saves":1,"newest":1790000000}]}"#.utf8)).first)
        d.perform(SyncActions.restore(copy))
        await settle { self.d.run?.ended == true || self.d.justSynced != nil }
        XCTAssertEqual(calls.all.last, ["restore", "2026-10-06T12:00:00Z"])

        let before = calls.all.count
        var nameless = SyncActions.restore(copy)
        nameless.restoreName = nil
        await settle { !self.d.busy }
        d.perform(nameless)
        await settle { self.d.run?.ended == true }
        XCTAssertEqual(calls.all.count, before, "no script call without a chosen copy")
        XCTAssertEqual(d.run?.problem?.code, 2)
    }

    /// #143 review: after a restore the saves differ from the Hub
    /// (LOCAL_ONLY), and automatic sync must not send them on its own.
    /// It waits until the user does something themselves.
    func testAutomaticSyncWaitsForTheUserAfterARestore() async throws {
        fake([try Self.status("INSYNC"), try Self.status("LOCAL_ONLY")])
        d.start()
        await settle { !self.d.loading && self.d.status != nil }
        let copy = try XCTUnwrap(SafetyCopy.list(from: Data(#"{"snapshots":[{"name":"2026-10-06T12:00:00Z","files":5,"campaign_saves":1,"newest":1790000000}]}"#.utf8)).first)
        d.perform(SyncActions.restore(copy))
        await settle { self.d.status?.decision == .localOnly && !self.d.loading && !self.d.busy }
        d.refresh()
        await settle(1) { false }
        XCTAssertEqual(calls.all, [["restore", "2026-10-06T12:00:00Z"]], "no automatic push of the restored saves")
        XCTAssertTrue(d.autoHeldAfterRestore)
        XCTAssertNotNil(d.notice)

        let send = try XCTUnwrap(SyncActions.plan(for: try Self.status("LOCAL_ONLY")).buttons.first { $0.action == .push })
        d.perform(send)
        await settle { self.calls.all.count == 2 }
        XCTAssertEqual(calls.all.last?.first, "push", "the user's own Send runs")
        XCTAssertFalse(d.autoHeldAfterRestore, "and ends the hold")
    }

    /// #143 review: a restore that fails still holds automatic sync; it
    /// may have changed the saves before it stopped.
    func testAFailedRestoreStillHoldsAutomaticSync() async throws {
        fake([try Self.status("INSYNC"), try Self.status("LOCAL_ONLY")], exit: 63)
        d.start()
        await settle { !self.d.loading && self.d.status != nil }
        let copy = try XCTUnwrap(SafetyCopy.list(from: Data(#"{"snapshots":[{"name":"2026-10-06T12:00:00Z","files":5,"campaign_saves":1,"newest":1790000000}]}"#.utf8)).first)
        d.perform(SyncActions.restore(copy))
        await settle { self.d.run?.ended == true && !self.d.loading }
        d.refresh()
        await settle(1) { false }
        XCTAssertTrue(d.autoHeldAfterRestore)
        XCTAssertEqual(calls.all, [["restore", "2026-10-06T12:00:00Z"]], "nothing automatic after the failure")
    }

    /// #143 review: the hold survives a relaunch (or a launch at login).
    func testTheHoldAfterARestoreSurvivesARelaunch() async throws {
        UserDefaults.standard.removeObject(forKey: DashboardModel.holdKey)
        fake([try Self.status("INSYNC"), try Self.status("LOCAL_ONLY")])
        d.start()
        await settle { !self.d.loading && self.d.status != nil }
        let copy = try XCTUnwrap(SafetyCopy.list(from: Data(#"{"snapshots":[{"name":"2026-10-06T12:00:00Z","files":5,"campaign_saves":1,"newest":1790000000}]}"#.utf8)).first)
        d.perform(SyncActions.restore(copy))
        await settle { self.d.autoHeldAfterRestore }
        d.stop()

        // A fresh app: same defaults, a LOCAL_ONLY status, auto sync on.
        let fresh = DashboardModel()
        fresh.autoSync = true
        fresh.refreshScript = { _ in }
        let after = Calls()
        fresh.fetchStatus = { _ in .success(try! Self.status("LOCAL_ONLY")) }
        fresh.runScript = { _, args, _ in after.add(args); return 0 }
        fresh.start()
        await settle(1) { false }
        XCTAssertTrue(after.all.isEmpty, "no automatic push after the relaunch")
        XCTAssertTrue(fresh.autoHeldAfterRestore)
        XCTAssertNotNil(fresh.notice, "and it says why")
        fresh.stop()
    }

    /// Restore is only ever started from the sheet: never planned, never
    /// automatic, whatever the situation.
    func testRestoreIsNeverOfferedOrAutomatic() throws {
        for decision in ["INSYNC", "HUB_ONLY", "LOCAL_ONLY", "BOTH_CHANGED", "FIRSTRUN_CONFLICT",
                         "FIRST_SEED", "HUB_EMPTY", "DIVERGED_STATE", "LOCAL_EMPTIED"] {
            let s = try Self.status(decision)
            XCTAssertFalse(SyncActions.plan(for: s).buttons.contains { $0.action == .restore }, decision)
            XCTAssertNotEqual(SyncActions.automatic(for: s)?.action, .restore, decision)
        }
    }

    func testStopDropsAQueuedPressAndBlocksEveryAction() async throws {
        fake([try Self.status("HUB_ONLY")])
        let play = try XCTUnwrap(SyncActions.plan(for: try Self.status("HUB_ONLY")).buttons.first { $0.action == .play })
        d.loading = true
        d.tapped(play)
        d.stop()
        d.loading = false
        d.refresh()
        d.perform(play)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(calls.all.isEmpty, "nothing starts while setup is showing")
        XCTAssertNil(d.run)
    }

    /// #107 review: while an update installs, the app is about to restart,
    /// so nothing may start, automatic or pressed.
    func testNothingStartsWhileAnUpdateInstalls() async throws {
        // Two checks see the hub ahead (one while updating, one after);
        // once fetched, the hub and this Mac agree.
        fake([try Self.status("HUB_ONLY"), try Self.status("HUB_ONLY"), try Self.status("INSYNC")])
        d.updating = true
        d.refresh()
        await settle { self.d.status != nil && !self.d.loading }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(calls.all.isEmpty, "no automatic sync while updating")
        let pull = try XCTUnwrap(SyncActions.plan(for: try Self.status("HUB_ONLY")).buttons.first { $0.action == .pull })
        d.perform(pull)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(calls.all.isEmpty, "no pressed action either")
        d.updating = false
        d.refresh()
        await settle { !self.calls.all.isEmpty }
        XCTAssertEqual(calls.all.count, 1, "and it resumes afterwards")
    }

    /// #119: the checks the app starts itself show no spinner; only a
    /// check the user asked for does.
    func testOnlyARequestedCheckShowsTheSpinner() async throws {
        let gate = DispatchSemaphore(value: 0)
        d.autoSync = false
        d.fetchStatus = { _ in gate.wait(); return .success(try! Self.status("INSYNC")) }
        d.refresh()
        XCTAssertTrue(d.loading)
        XCTAssertFalse(d.manualCheck, "a background check is silent")
        gate.signal()
        await settle { !self.d.loading }
        d.refresh(manual: true)
        XCTAssertTrue(d.manualCheck, "the refresh button's check shows the spinner")
        gate.signal()
        await settle { !self.d.loading }
        XCTAssertFalse(d.manualCheck, "and it clears when the check ends")
    }

    func testAPressDuringACheckRunsAfterItIfStillOffered() async throws {
        fake([try Self.status("HUB_ONLY")])
        d.autoSync = false
        let pull = try XCTUnwrap(SyncActions.plan(for: try Self.status("HUB_ONLY")).buttons.first { $0.action == .pull })
        d.loading = true
        d.tapped(pull)
        XCTAssertTrue(calls.all.isEmpty, "queued, not run, while checking")
        d.loading = false
        d.refresh()
        await settle { !self.calls.all.isEmpty }
        XCTAssertEqual(calls.all, [["pull", "--expect-decision=HUB_ONLY"]])
    }

    func testAPressDuringACheckIsDroppedWithANoticeIfTheSituationChanged() async throws {
        fake([try Self.status("INSYNC")])
        d.autoSync = false
        let pull = try XCTUnwrap(SyncActions.plan(for: try Self.status("HUB_ONLY")).buttons.first { $0.action == .pull })
        d.loading = true
        d.tapped(pull)
        d.loading = false
        d.refresh()
        await settle { self.d.status != nil && !self.d.loading }
        XCTAssertTrue(calls.all.isEmpty)
        XCTAssertNotNil(d.notice)
    }
}
