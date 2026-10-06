import XCTest
@testable import STSSetupCore

final class SafetyCopyTests: XCTestCase {
    /// The shape `sts restore --json` prints (see tests/regression.sh).
    static let json = #"{"snapshots": [{"name": "2026-10-06T19:21:52Z-2", "files": 5, "campaign_saves": 1, "newest": 1791313300}, {"name": "2026-10-06T19:21:52Z", "files": 6, "campaign_saves": 2, "newest": 0}]}"#

    func testParsesTheScriptsList() throws {
        let list = try SafetyCopy.list(from: Data(Self.json.utf8))
        XCTAssertEqual(list.map(\.name), ["2026-10-06T19:21:52Z-2", "2026-10-06T19:21:52Z"])
        XCTAssertEqual(list[0].campaignSaves, 1)
        XCTAssertEqual(list[0].summary, "1 campaign, 5 files")
        XCTAssertEqual(list[1].summary, "2 campaigns, 6 files")
        XCTAssertNil(list[1].newestDate, "0 means no saves in it")
        XCTAssertEqual(try SafetyCopy.list(from: Data(#"{"snapshots": []}"#.utf8)), [])
        XCTAssertThrowsError(try SafetyCopy.list(from: Data("not json".utf8)))
    }

    func testTheTimeComesFromTheNameWithoutItsSuffix() throws {
        let list = try SafetyCopy.list(from: Data(Self.json.utf8))
        let t = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-06T19:21:52Z"))
        XCTAssertEqual(list[0].takenAt, t, "the -2 suffix is only for uniqueness")
        XCTAssertEqual(list[1].takenAt, t)
    }

    func testTheRestoreButtonRunsRestoreWithItsName() throws {
        let copy = try XCTUnwrap(SafetyCopy.list(from: Data(Self.json.utf8)).first)
        let b = SyncActions.restore(copy)
        XCTAssertEqual(b.scriptArguments, ["restore", "2026-10-06T19:21:52Z-2"])
        XCTAssertNotNil(b.confirmation, "always asked first")
        XCTAssertTrue(b.confirmation?.message.contains("can be undone") == true)
        var nameless = b
        nameless.restoreName = nil
        XCTAssertNil(nameless.scriptArguments)
        XCTAssertNil(SyncAction.restore.arguments(expecting: .inSync), "never runs without a name")
    }
}
