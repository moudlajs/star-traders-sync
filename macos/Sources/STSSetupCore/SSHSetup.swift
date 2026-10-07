import Foundation

/// The client side of "this Mac can ssh to the hub without a password".
///
/// Two rules carried over from the script: a host key is never trusted
/// without a human comparing it, and the hub password is never stored. It
/// reaches ssh-copy-id through SSH_ASKPASS reading an environment variable,
/// so it is not in argv (visible to `ps`) and not on disk.
public struct SSHSetup {
    public let home: URL
    public let user: String
    public let hub: TailscaleNode

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), user: String, hub: TailscaleNode) {
        self.home = home
        self.user = user
        self.hub = hub
    }

    var sshDir: URL { home.appendingPathComponent(".ssh") }
    public var keyPath: URL { sshDir.appendingPathComponent("id_ed25519") }
    var knownHosts: URL { sshDir.appendingPathComponent("known_hosts") }

    /// The tailnet IP always works; MagicDNS does not resolve with a
    /// Homebrew tailscaled. sts picks whichever works at run time, so both
    /// names are trusted and every connection here goes to the IP.
    public var endpoint: String { hub.ip }
    public var target: String { "\(user)@\(endpoint)" }
    var trustedNames: [String] { [hub.ip, hub.dnsName].filter { !$0.isEmpty } }

    static let sshOpts = ["-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes"]

    // MARK: key

    public var hasKey: Bool { FileManager.default.fileExists(atPath: keyPath.path) }

    public func generateKey() -> CommandResult {
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let host = Host.current().localizedName ?? "mac"
        return Shell.run("/usr/bin/ssh-keygen",
                         ["-t", "ed25519", "-N", "", "-C", "sts@\(host)", "-f", keyPath.path])
    }

    // MARK: host key

    public var hostKeyTrusted: Bool {
        trustedNames.allSatisfy {
            Shell.run("/usr/bin/ssh-keygen", ["-F", $0, "-f", knownHosts.path]).ok
        }
    }

    public struct ScannedKey {
        /// "ssh-ed25519 AAAA..." without a host name.
        public let key: String
        /// SHA256:... as `ssh-keygen -l` prints it.
        public let fingerprint: String
    }

    public enum ScanError: Error, CustomStringConvertible {
        case unreachable(String)
        public var description: String {
            switch self {
            case .unreachable(let s):
                return "The hub did not answer on the ssh port. Remote Login is probably off on the hub: System Settings > General > Sharing > Remote Login.\n\(s)"
            }
        }
    }

    public func scanHostKey() -> Result<ScannedKey, ScanError> {
        let scan = Shell.run("/usr/bin/ssh-keyscan", ["-t", "ed25519", "-T", "5", endpoint])
        guard let line = scan.stdout.split(separator: "\n").first(where: { !$0.hasPrefix("#") }) else {
            return .failure(.unreachable(scan.stderr))
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return .failure(.unreachable(String(line))) }
        let key = "\(parts[1]) \(parts[2])"
        let fp = Shell.run("/usr/bin/ssh-keygen", ["-lf", "-"], stdin: Data("\(endpoint) \(key)\n".utf8))
        let fingerprint = fp.stdout.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
        return .success(ScannedKey(key: key, fingerprint: fingerprint))
    }

    /// Adds the scanned key under the IP and the MagicDNS name. Only names
    /// that are not already known are added; a name that is known with a
    /// different key is left for ssh to refuse, loudly.
    public func trust(_ scanned: ScannedKey) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let missing = trustedNames.filter {
            !Shell.run("/usr/bin/ssh-keygen", ["-F", $0, "-f", knownHosts.path]).ok
        }
        guard !missing.isEmpty else { return }
        let lines = missing.map { "\($0) \(scanned.key)\n" }.joined()

        if !fm.fileExists(atPath: knownHosts.path) {
            fm.createFile(atPath: knownHosts.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let h = try FileHandle(forWritingTo: knownHosts)
        defer { try? h.close() }
        try h.seekToEnd()
        // known_hosts written by hand may not end in a newline.
        if let size = try? fm.attributesOfItem(atPath: knownHosts.path)[.size] as? Int, size > 0,
           let tail = try? readLastByte(knownHosts), tail != 0x0A {
            h.write(Data("\n".utf8))
        }
        h.write(Data(lines.utf8))
    }

    private func readLastByte(_ url: URL) throws -> UInt8? {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        guard end > 0 else { return nil }
        try h.seek(toOffset: end - 1)
        return h.readData(ofLength: 1).first
    }

    // MARK: login

    /// Does key-only login work? This is exactly what sts needs.
    public func keyLoginWorks() -> CommandResult {
        Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes"] + Self.sshOpts + [target, "echo STS_OK"])
    }

    /// Puts our public key in the hub's authorized_keys, using the hub
    /// account's password once.
    public func copyKey(password: String) -> CommandResult {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sts-setup-\(UUID().uuidString)")
        let askpass = dir.appendingPathComponent("askpass")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // The script holds no secret; it echoes one from its environment.
            try "#!/bin/sh\nprintf '%s\\n' \"$STS_SETUP_PASSWORD\"\n"
                .write(to: askpass, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        } catch {
            return CommandResult(status: 1, stdout: "", stderr: "could not prepare the password helper: \(error)")
        }

        return Shell.run("/usr/bin/ssh-copy-id",
                         ["-i", keyPath.path + ".pub"] + Self.sshOpts
                         + ["-o", "NumberOfPasswordPrompts=1",
                            "-o", "PreferredAuthentications=keyboard-interactive,password",
                            target],
                         env: ["SSH_ASKPASS": askpass.path,
                               "SSH_ASKPASS_REQUIRE": "force",
                               "DISPLAY": ":0",
                               "STS_SETUP_PASSWORD": password])
    }

    /// Turns ssh's stderr into what to do about it.
    public func explain(_ r: CommandResult) -> String {
        let s = r.combined
        if s.contains("Permission denied") {
            // Name the account: a wrong account name (#178) looks exactly
            // like a wrong password from here.
            return "The hub refused the password for the account \"\(user)\". Check both: it is the password of that account on the hub Mac, and the account name must be the one on the hub Mac (its home folder, /Users/name), which is often not the same as this Mac's. Go Back to change it."
        }
        if s.contains("Connection refused") {
            return "Remote Login is off on the hub. On the hub Mac: System Settings > General > Sharing > Remote Login."
        }
        if s.contains("Host key verification failed") || s.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "This Mac already knows a different key for the hub. That is either a reinstalled hub or something in the way. If the hub was reinstalled, remove the old entry in Terminal with: ssh-keygen -R \(endpoint)"
        }
        if s.contains("timed out") || s.contains("No route") {
            return "Could not reach the hub. Check it is awake and on Tailscale."
        }
        return s.isEmpty ? "ssh failed with exit code \(r.status)." : s
    }
}
