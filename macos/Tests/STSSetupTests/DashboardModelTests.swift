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
