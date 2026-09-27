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

    func testGarbageIsAnError() {
        XCTAssertThrowsError(try Tailscale.parseStatus(Data("not json".utf8)))
    }
}
