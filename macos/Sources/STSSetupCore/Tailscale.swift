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
    case badOutput(String)

    public var description: String {
        switch self {
        case .notInstalled:
            return "Tailscale is not installed on this Mac."
        case .notRunning(let detail):
            return "Tailscale is installed but not running. \(detail)"
        case .badOutput(let detail):
            return "Tailscale answered, but not with anything readable. Details are in ~/Library/Logs/star-traders-sync/setup-app.log.\n\n\(detail)"
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
        // Some builds print a warning line before the JSON (a client and
        // daemon version mismatch does). Parse from the first brace.
        let body = data.firstIndex(of: UInt8(ascii: "{")).map { data[$0...] } ?? data
        guard let root = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            throw TailscaleError.badOutput(excerpt(data))
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

    /// Every installed binary, in preference order. The first one that
    /// answers with readable status wins, so a quirk in one install does
    /// not block setup when another works.
    public static func allBinaries(fileManager fm: FileManager = .default) -> [String] {
        [appBinary, "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale"]
            .filter { fm.isExecutableFile(atPath: $0) }
    }

    public typealias Runner = (_ binary: String, _ args: [String], _ env: [String: String]) -> CommandResult

    public static func status(binaries: [String] = allBinaries(),
                              runner: Runner = { Shell.run($0, $1, env: $2) },
                              log: (String) -> Void = { _ in }) -> Result<TailscaleStatus, TailscaleError> {
        let bins = binaries
        guard !bins.isEmpty else { return .failure(.notInstalled) }

        var firstError: TailscaleError?
        for bin in bins {
            // The app's binary is both the GUI and the CLI. Launched by a
            // GUI process rather than a shell it may not realise it is
            // being used as a CLI; TAILSCALE_BE_CLI says so explicitly.
            let r = runner(bin, ["status", "--json"], ["TAILSCALE_BE_CLI": "1"])
            log("\(bin) status --json: exit \(r.status)\n--- stdout ---\n\(excerpt(Data(r.stdout.utf8), 4000))\n--- stderr ---\n\(excerpt(Data(r.stderr.utf8), 4000))")
            if !r.stdout.isEmpty, let s = try? parseStatus(Data(r.stdout.utf8)) {
                return .success(s)
            }
            // Output that is there but unparseable is "unreadable"; no
            // stdout at all is no answer, whatever the exit code says.
            let err: TailscaleError = r.stdout.isEmpty
                ? .notRunning(r.combined)
                : .badOutput(excerpt(Data(r.combined.utf8)))
            if firstError == nil { firstError = err }
        }
        return .failure(firstError!)
    }

    static func excerpt(_ data: Data, _ limit: Int = 300) -> String {
        let s = String(decoding: data.prefix(limit), as: UTF8.self)
        if s.isEmpty { return "(no output)" }
        return data.count > limit ? s + "…" : s
    }
}
