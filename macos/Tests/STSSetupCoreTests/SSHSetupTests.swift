import XCTest
@testable import STSSetupCore

final class SSHSetupTests: XCTestCase {
    /// #178: a wrong account name looks exactly like a wrong password.
    func testARefusedPasswordNamesTheAccount() {
        let hub = TailscaleNode(dnsName: "nebulaplex01.t.ts.net", hostName: "NebulaPlex01",
                                ip: "100.64.0.1", os: "macOS", online: true)
        let ssh = SSHSetup(home: FileManager.default.temporaryDirectory, user: "danielczetner", hub: hub)
        let msg = ssh.explain(CommandResult(status: 1, stdout: "",
                                            stderr: "danielczetner@100.64.0.1: Permission denied (publickey,password)."))
        XCTAssertTrue(msg.contains("\"danielczetner\""), msg)
        XCTAssertTrue(msg.contains("account name"), msg)
    }
}
