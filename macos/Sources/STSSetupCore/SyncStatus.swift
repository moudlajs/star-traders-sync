import Foundation

/// `sts status --json`, decoded. Field names follow the script's output.
public struct SyncStatus: Decodable, Equatable {
    public struct Hub: Decodable, Equatable {
        public let host: String
        public let path: String
        public let endpointKind: String
    }

    public struct Side: Decodable, Equatable {
        public let path: String
        public let files: Int
        public let campaignSaves: Int
        /// Epoch seconds of the newest file, 0 when there are none.
        public let newest: Int
        public let fingerprint: String

        public var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil }
    }

    public struct Sides: Decodable, Equatable {
        public let local: Side
        public let hub: Side
    }

    public struct LastSync: Decodable, Equatable {
        /// "push" or "pull": which way this Mac last synced. The script
        /// records the direction, not which machine was on the other end.
        public let direction: String
        public let at: Int
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(at)) }
    }

    public enum Verdict: String, Decodable {
        case inSync = "in_sync"
        case localNewer = "local_newer"
        case hubNewer = "hub_newer"
        case hubEmpty = "hub_empty"
        case localEmpty = "local_empty"
        case differ
    }

    /// What pull and push would do, from the script's decide(). This, not
    /// the timestamp verdict, is what the app acts on and promises.
    public enum Decision: String, Decodable {
        case inSync = "INSYNC"
        case hubOnly = "HUB_ONLY"
        case localOnly = "LOCAL_ONLY"
        case bothChanged = "BOTH_CHANGED"
        case firstRunConflict = "FIRSTRUN_CONFLICT"
        case firstSeed = "FIRST_SEED"
        case hubEmpty = "HUB_EMPTY"
        case divergedState = "DIVERGED_STATE"
        /// This Mac was emptied after a sync; the hub still has saves.
        case localEmptied = "LOCAL_EMPTIED"

        /// Needs the user to pick a side (#74).
        public var needsChoice: Bool { [.bothChanged, .firstRunConflict, .divergedState].contains(self) }
    }

    public let version: String
    public let machine: String
    public let isHub: Bool
    public let hub: Hub
    public let sides: Sides
    public let verdict: Verdict
    public let decision: Decision
    public let lastSync: LastSync?
    public let hubLock: String?
    public let gameRunning: Bool

    public static func decode(_ data: Data) throws -> SyncStatus {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SyncStatus.self, from: data)
    }
}

/// What a refusal means to someone who has never seen an exit code.
/// The codes are the script's (docs/troubleshooting.md); the wording is
/// for the app. Anything unmapped falls back to the script's own message.
public struct SyncProblem: Error, Equatable {
    public let code: Int32
    public let title: String
    public let advice: String
    /// The script's last "error:" line, for the details disclosure.
    public let detail: String

    public static func from(code: Int32, stderr: String) -> SyncProblem {
        let detail = stderr.split(separator: "\n")
            .last(where: { $0.hasPrefix("error:") })
            .map { String($0.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces) }
            ?? stderr.split(separator: "\n").last.map(String.init) ?? ""

        let (title, advice): (String, String)
        switch code {
        case 10, 11, 12:
            (title, advice) = ("This Mac is not set up yet", "Run the setup again.")
        case 13:
            (title, advice) = ("The game's save folder is missing", "Start Star Traders once on this Mac so it creates its save folder.")
        case 14:
            (title, advice) = ("The hub folder is missing", "The hub has no save folder yet. Run the setup again, or check the hub Mac.")
        case 20, 21, 22, 23:
            (title, advice) = ("Tailscale is not connected", "Open Tailscale and make sure it is connected, then try again.")
        case 24:
            (title, advice) = ("The hub is not on your Tailscale", "The hub Mac is not on this Tailscale account. Run the setup again to pick the right one.")
        case 25, 26:
            (title, advice) = ("The hub is offline", "Wake the hub Mac, or check that Tailscale is running on it.")
        case 30, 31:
            (title, advice) = ("Cannot log in to the hub", "Run the setup again to reconnect this Mac to the hub.")
        case 32:
            (title, advice) = ("No access to the hub folder", "The hub account cannot read or write the hub folder.")
        case 33, 34:
            (title, advice) = ("Copying failed", "The transfer failed or a disk is full. Nothing was overwritten.")
        case 40:
            (title, advice) = ("The game is running", "Quit Star Traders first. Saves are never copied while the game has them open.")
        case 41:
            (title, advice) = ("The game did not start", "Check that Star Traders is installed in Steam and that Steam is running.")
        case 50, 51:
            (title, advice) = ("Another Mac is syncing", "Another Mac is syncing with the hub right now. Try again in a minute.")
        case 52:
            (title, advice) = ("A sync is already running on this Mac", "Wait for it to finish.")
        case 60:
            (title, advice) = ("Both Macs have new saves", "Both this Mac and the hub changed since the last sync. Choose which saves to keep.")
        case 61:
            (title, advice) = ("Choose which saves to keep", "This Mac and the hub both have saves, and they have never synced. Choose which to keep.")
        case 62:
            (title, advice) = ("The hub has no saves yet", "Send this Mac's saves to the hub to start.")
        case 63:
            (title, advice) = ("Safety copy failed", "The safety copy taken before overwriting failed, so nothing was overwritten.")
        default:
            (title, advice) = ("Something went wrong", detail.isEmpty ? "The sync tool stopped with code \(code)." : detail)
        }
        return SyncProblem(code: code, title: title, advice: advice, detail: detail)
    }

    /// Refusals the user resolves by choosing a side (#74).
    public var needsChoice: Bool { [60, 61, 62].contains(code) }
}

public enum StatusClient {
    public typealias Runner = (_ script: String, _ args: [String]) -> CommandResult

    public static func fetch(script: String,
                             runner: Runner = { Shell.run("/bin/bash", [$0] + $1) })
        -> Result<SyncStatus, SyncProblem> {
        let r = runner(script, ["status", "--json"])
        guard r.ok else { return .failure(.from(code: r.status, stderr: r.stderr)) }
        do {
            return .success(try SyncStatus.decode(Data(r.stdout.utf8)))
        } catch {
            return .failure(SyncProblem(code: -1, title: "Could not read the sync status",
                                        advice: "The sync tool on this Mac may be older than the app. Run the setup again to update it.",
                                        detail: String(r.stdout.prefix(300))))
        }
    }
}
