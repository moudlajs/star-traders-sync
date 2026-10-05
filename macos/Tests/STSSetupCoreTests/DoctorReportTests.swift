import XCTest
@testable import STSSetupCore

final class DoctorReportTests: XCTestCase {
    /// Shape copied from a real `sts doctor --fix` run.
    static let sample = """
    star-traders-sync 1.3.0 - checking this machine
    (--fix: safe repairs will be applied)

      environment
        ok    bash 3.2
        ok    rsync, ssh, python3, shasum, cpio
        note  rsync is openrsync (macOS built-in)
        ok    ~/bin is on PATH

      config
        ok    /Users/d/.config/star-traders-sync/config
        ok    config passes every validation rule

      tailscale
        FAIL  hub 'x' is not in this tailnet at all
              check HUB_HOST against the node names in:

      ssh to the hub
        --    skipped, needs: a working tailscale

      state and logs
        warn  a stale local lock is present (owner 1 is gone)
        fixed clear the stale local lock

      1 problem(s), 1 warning(s), 1 fixed
      Nothing above was changed except where it says "fixed".
    """

    func testGroupsLinesIntoSections() {
        let r = DoctorReport.parse(Self.sample)
        XCTAssertEqual(r.sections.map(\.title), ["environment", "config", "tailscale", "ssh to the hub", "state and logs"])
        XCTAssertEqual(r.sections[0].lines.count, 4)
        XCTAssertEqual(r.summary.first, "1 problem(s), 1 warning(s), 1 fixed")
        XCTAssertEqual(r.summary.count, 2, "the summary is not folded into the last section")
    }

    func testOutcomesAndSummaries() {
        let r = DoctorReport.parse(Self.sample)
        XCTAssertEqual(r.sections[0].outcome, .ok)
        XCTAssertEqual(r.sections[0].summary, "3 checks passed", "notes are not counted as checks")
        XCTAssertEqual(r.sections[2].outcome, .fail)
        XCTAssertEqual(r.sections[2].summary, "hub 'x' is not in this tailnet at all")
        XCTAssertEqual(r.sections[3].outcome, .skipped)
        XCTAssertEqual(r.sections[3].summary, "skipped, needs: a working tailscale")
        XCTAssertEqual(r.sections[4].outcome, .warn, "a warning outranks a fix")
    }

    func testEverythingPassesSummary() {
        let r = DoctorReport.parse("x\n\n  game\n    ok    save directory, 10 files\n\n  Everything checks out. Try:  sts status\n")
        XCTAssertEqual(r.sections.count, 1)
        XCTAssertEqual(r.sections[0].summary, "save directory, 10 files")
        XCTAssertEqual(r.summary, ["Everything checks out. Try:  sts status"])
    }

    func testAllRowsAreDrawnFromTheStart() {
        let rows = DoctorReport().rows(revealed: 0, finished: false)
        XCTAssertEqual(rows.map(\.title), DoctorReport.expectedTitles)
        XCTAssertEqual(rows.map(\.state), [.checking] + Array(repeating: .pending, count: 5))
    }

    func testRowsChangeInPlaceAsTheRunReachesThem() {
        let r = DoctorReport.parse(Self.sample)
        let mid = r.rows(revealed: 2, finished: false)
        XCTAssertEqual(mid.prefix(2).map(\.state), [.done, .done])
        XCTAssertEqual(mid[2].state, .checking, "the next one, in place")
        XCTAssertEqual(mid.count, 6, "no row appears or vanishes mid-run")
        let end = r.rows(revealed: r.sections.count, finished: true)
        XCTAssertEqual(end.filter { $0.state == .notChecked }.map(\.title), ["game"], "the sample has no game section")
        XCTAssertEqual(end.filter { $0.state == .done }.count, 5)
    }

    func testSectionsThatNeverRanEndAsNotChecked() {
        // A broken config: doctor prints "everything else" and stops.
        let r = DoctorReport.parse("x\n\n  environment\n    ok    bash\n\n  config\n    FAIL  no config\n\n  everything else\n    --    skipped, needs: a valid config\n\n  1 problem(s)\n")
        let end = r.rows(revealed: r.sections.count, finished: true)
        XCTAssertEqual(end.map(\.title), DoctorReport.expectedTitles + ["everything else"])
        XCTAssertEqual(end.filter { $0.state == .notChecked }.map(\.title), ["state and logs", "game", "tailscale", "ssh to the hub"])
    }

    func testTheHubsOwnSectionIsAppended() {
        let r = DoctorReport.parse(Self.sample + "\n  hub duties (this machine)\n    ok    hub directory, 11 files\n")
        let rows = r.rows(revealed: 99, finished: true)
        XCTAssertEqual(rows.last?.title, "hub duties (this machine)", "appended after the expected ones")
        XCTAssertEqual(rows.last?.state, .done)
    }

    func testDisplayTitle() {
        XCTAssertEqual(DoctorSection(title: "ssh to the hub").displayTitle, "Connection to the hub")
        XCTAssertEqual(DoctorSection(title: "hub duties (this machine)").displayTitle, "Hub duties")
        XCTAssertEqual(DoctorSection(title: "something new").displayTitle, "Something new")
    }
}
