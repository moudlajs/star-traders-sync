import XCTest
@testable import STSSetupCore

final class TailscaleTests: XCTestCase {
    func testParsesSelfAndPeers() throws {
        let json = """
        {"BackendState":"Running",
         "Self":{"HostName":"NebulaPlex01","DNSName":"nebulaplex01.tail1.ts.net.","OS":"macOS",
                 "TailscaleIPs":["fd7a::1","100.1.1.1"],"Online":true},
         "Peer":{
           "a":{"HostName":"iPhone","DNSName":"iphone15.tail1.ts.net.","OS":"iOS","TailscaleIPs":["100.1.1.2"],"Online":true},
           "b":{"HostName":"WorkMac","DNSName":"workmac.tail1.ts.net.","OS":"macOS","TailscaleIPs":["100.1.1.3"],"Online":false},
           "c":{"HostName":"Studio","DNSName":"studio.tail1.ts.net.","OS":"macOS","TailscaleIPs":["100.1.1.4"],"Online":true}
         }}
        """
        let s = try Tailscale.parseStatus(Data(json.utf8))
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.me?.nodeName, "nebulaplex01")
        XCTAssertEqual(s.me?.ip, "100.1.1.1", "IPv4 preferred, as the script does")
        XCTAssertEqual(s.me?.dnsName, "nebulaplex01.tail1.ts.net", "trailing dot stripped")
        XCTAssertEqual(s.hubCandidates.map(\.nodeName), ["studio", "iphone15", "workmac"],
                       "online first, then Macs first")
    }

    func testNullPeerOnSingleMachineTailnet() throws {
        let s = try Tailscale.parseStatus(Data(#"{"BackendState":"Stopped","Self":{"HostName":"x"},"Peer":null}"#.utf8))
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.peers.count, 0)
        XCTAssertEqual(s.me?.nodeName, "x", "falls back to the lowercased HostName without MagicDNS")
    }

    func testWarningBeforeTheJSONIsSkipped() throws {
        let out = "Warning: client version \"1.94.1\" != tailscaled server version \"1.102.4\"\n"
            + #"{"BackendState":"Running","Self":{"HostName":"a","DNSName":"a.t.ts.net."},"Peer":{}}"#
        XCTAssertTrue(try Tailscale.parseStatus(Data(out.utf8)).running)
    }

    static let good = #"{"BackendState":"Running","Self":{"HostName":"a","DNSName":"a.t.ts.net."},"Peer":{}}"#

    func fake(_ answers: [String: CommandResult]) -> (Tailscale.Runner, () -> [(String, [String: String])]) {
        var calls: [(String, [String: String])] = []
        let runner: Tailscale.Runner = { bin, _, env in
            calls.append((bin, env))
            return answers[bin] ?? CommandResult(status: 1, stdout: "", stderr: "")
        }
        return (runner, { calls })
    }

    func testFallsBackToTheNextBinaryWhenTheFirstIsUnreadable() {
        let (runner, calls) = fake([
            "/app": CommandResult(status: 0, stdout: "garbage", stderr: ""),
            "/brew": CommandResult(status: 0, stdout: Self.good, stderr: ""),
        ])
        var logged: [String] = []
        let r = Tailscale.status(binaries: ["/app", "/brew"], runner: runner, log: { logged.append($0) })
        guard case .success(let st) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(st.running)
        XCTAssertEqual(calls().map(\.0), ["/app", "/brew"])
        XCTAssertTrue(calls().allSatisfy { $0.1["TAILSCALE_BE_CLI"] == "1" })
        XCTAssertEqual(logged.count, 2, "every attempt is logged")
    }

    func testStopsAtTheFirstBinaryThatWorks() {
        let (runner, calls) = fake(["/app": CommandResult(status: 0, stdout: Self.good, stderr: "")])
        _ = Tailscale.status(binaries: ["/app", "/brew"], runner: runner)
        XCTAssertEqual(calls().map(\.0), ["/app"])
    }

    func testReportsTheFirstBinarysError() {
        let (runner, _) = fake([
            "/app": CommandResult(status: 0, stdout: "garbage", stderr: ""),
            "/brew": CommandResult(status: 1, stdout: "", stderr: "daemon not running"),
        ])
        guard case .failure(.badOutput(let d)) = Tailscale.status(binaries: ["/app", "/brew"], runner: runner)
        else { return XCTFail("expected badOutput from the first binary") }
        XCTAssertTrue(d.contains("garbage"))
    }

    func testNoOutputAtAllIsNotRunningEvenWithExitZero() {
        let (runner, _) = fake(["/app": CommandResult(status: 0, stdout: "", stderr: "")])
        guard case .failure(.notRunning) = Tailscale.status(binaries: ["/app"], runner: runner)
        else { return XCTFail("empty output is no answer, not an unreadable one") }
    }

    func testNoBinariesIsNotInstalled() {
        guard case .failure(.notInstalled) = Tailscale.status(binaries: [], runner: { _, _, _ in fatalError() })
        else { return XCTFail() }
    }

    func testGarbageIsAnError() {
        XCTAssertThrowsError(try Tailscale.parseStatus(Data("not json".utf8)))
    }
}
