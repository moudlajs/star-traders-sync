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

    func testDisplayTitle() {
        XCTAssertEqual(DoctorSection(title: "ssh to the hub").displayTitle, "Connection to the hub")
        XCTAssertEqual(DoctorSection(title: "hub duties (this machine)").displayTitle, "Hub duties")
        XCTAssertEqual(DoctorSection(title: "something new").displayTitle, "Something new")
    }
}
