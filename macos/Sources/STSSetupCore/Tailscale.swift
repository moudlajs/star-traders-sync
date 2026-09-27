import Foundation

public struct TailscaleNode: Identifiable, Hashable {
    /// Full MagicDNS name without the trailing dot, e.g. hub.tailnet.ts.net.
    public let dnsName: String
    public let hostName: String
    public let ip: String
    public let os: String
    public let online: Bool

    public var id: String { dnsName.isEmpty ? hostName : dnsName }

    /// The name to write into HUB_HOST. sts accepts the HostName, the
    /// MagicDNS short name or the full name; the short name is the one
    /// `tailscale status` prints, so it is the one a human recognises.
    public var nodeName: String {
        let short = dnsName.split(separator: ".").first.map(String.init) ?? ""
        return short.isEmpty ? hostName.lowercased() : short
    }
}

public struct TailscaleStatus {
    public let backendState: String
    public let me: TailscaleNode?
    public let peers: [TailscaleNode]

    public var running: Bool { backendState == "Running" }

    /// Machines that could host a hub: Macs first, online first.
    public var hubCandidates: [TailscaleNode] {
        peers.sorted { a, b in
            if a.online != b.online { return a.online }
            if (a.os == "macOS") != (b.os == "macOS") { return a.os == "macOS" }
            return a.nodeName < b.nodeName
        }
    }
}

public enum TailscaleError: Error, CustomStringConvertible {
    case notInstalled
    case notRunning(String)
    case badOutput

    public var description: String {
        switch self {
        case .notInstalled:
            return "Tailscale is not installed on this Mac."
        case .notRunning(let detail):
            return "Tailscale is installed but not running. \(detail)"
        case .badOutput:
            return "Tailscale answered, but not with anything readable."
        }
    }
}

public enum Tailscale {
    public static let appBinary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    /// Same preference order as the script's find_tailscale: the app first,
    /// then a PATH install. Listed explicitly because a Finder-launched app
    /// has no Homebrew on its PATH.
    public static func findBinary(fileManager fm: FileManager = .default) -> String? {
        [appBinary, "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    public static func parseStatus(_ data: Data) throws -> TailscaleStatus {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TailscaleError.badOutput
        }
        func node(_ any: Any?) -> TailscaleNode? {
            guard let d = any as? [String: Any] else { return nil }
            let ips = d["TailscaleIPs"] as? [String] ?? []
            let v4 = ips.first { !$0.contains(":") } ?? ips.first ?? ""
            var dns = d["DNSName"] as? String ?? ""
            while dns.hasSuffix(".") { dns.removeLast() }
            return TailscaleNode(dnsName: dns,
                                 hostName: d["HostName"] as? String ?? "",
                                 ip: v4,
                                 os: d["OS"] as? String ?? "",
                                 online: d["Online"] as? Bool ?? false)
        }
        // "Peer" is null, not {}, on a tailnet with one machine.
        let peerDict = root["Peer"] as? [String: Any] ?? [:]
        return TailscaleStatus(backendState: root["BackendState"] as? String ?? "",
                               me: node(root["Self"]),
                               peers: peerDict.values.compactMap(node))
    }

    public static func status() -> Result<TailscaleStatus, TailscaleError> {
        guard let bin = findBinary() else { return .failure(.notInstalled) }
        let r = Shell.run(bin, ["status", "--json"])
        guard r.ok else { return .failure(.notRunning(r.combined)) }
        do {
            return .success(try parseStatus(Data(r.stdout.utf8)))
        } catch {
            return .failure(.badOutput)
        }
    }
}
