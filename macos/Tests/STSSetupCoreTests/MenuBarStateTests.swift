import XCTest
@testable import STSSetupCore

final class MenuBarStateTests: XCTestCase {
    func status(_ decision: String) throws -> SyncStatus {
        let json = SyncStatusTests.sample.replacingOccurrences(of: "\"FIRSTRUN_CONFLICT\"", with: "\"\(decision)\"")
        return try SyncStatus.decode(Data(json.utf8))
    }

    func testEveryDecisionMapsToAState() throws {
        let expected: [String: MenuBarState] = [
            "INSYNC": .upToDate,
            "HUB_ONLY": .willSync, "FIRST_SEED": .willSync, "LOCAL_ONLY": .willSync,
            "HUB_EMPTY": .needsYou, "LOCAL_EMPTIED": .needsYou, "BOTH_CHANGED": .needsYou,
            "FIRSTRUN_CONFLICT": .needsYou, "DIVERGED_STATE": .needsYou,
        ]
        for (decision, state) in expected {
            XCTAssertEqual(MenuBarState.of(status: try status(decision), busy: false, problem: false), state, decision)
        }
    }

    func testARunningSyncAndAProblemWin() throws {
        let s = try status("INSYNC")
        XCTAssertEqual(MenuBarState.of(status: s, busy: true, problem: true), .syncing, "a run in progress shows first")
        XCTAssertEqual(MenuBarState.of(status: s, busy: false, problem: true), .needsYou, "a problem beats a stale up-to-date")
        XCTAssertEqual(MenuBarState.of(status: nil, busy: false, problem: false), .checking)
        XCTAssertEqual(MenuBarState.of(status: nil, busy: false, problem: true), .needsYou)
    }

    func testEachStateHasItsOwnShape() {
        let all: [MenuBarState] = [.checking, .upToDate, .syncing, .willSync, .needsYou]
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count, "told apart without colour")
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
    }
}
