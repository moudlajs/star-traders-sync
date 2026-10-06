import CryptoKit
import Foundation

/// A release the app could update to, from the GitHub releases API.
public struct Release: Equatable {
    public let version: String
    public let notes: String
    public let dmgURL: URL
    public let size: Int
    /// Hex SHA-256 of the dmg, from GitHub's own asset digest.
    public let sha256: String
    /// The dmg's Ed25519 signature, a separate release asset (#108).
    public let signatureURL: URL
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case badFeed(String)
    case checksumMismatch(expected: String, got: String)
    case mountFailed(String)
    case appNotFound
    case wrongApp(String)
    case signatureInvalid(String)
    case releaseSignatureInvalid
    case notWritable(String)
    case io(String)

    public var description: String {
        switch self {
        case .badFeed(let s):          return "The release information could not be read: \(s)"
        case .checksumMismatch:        return "The download does not match the release. Nothing was changed."
        case .mountFailed(let s):      return "The update could not be opened: \(s)"
        case .appNotFound:             return "The update does not contain Star Traders Sync."
        case .wrongApp(let s):         return "The update is not the expected app: \(s). Nothing was changed."
        case .signatureInvalid(let s): return "The update failed its signature check, so it was not installed: \(s)"
        case .releaseSignatureInvalid: return "The download is not signed by this project's release key, so it was not installed. Nothing was changed."
        case .notWritable(let s):      return "This copy of the app cannot update itself here (\(s)). Drag the new version to Applications instead."
        case .io(let s):               return s
        }
    }
}

public enum UpdateFeed {
    public static let defaultURL = URL(string: "https://api.github.com/repos/moudlajs/star-traders-sync/releases/latest")!
    public static let dmgName = "Star-Traders-Sync.dmg"
    public static let signatureName = "Star-Traders-Sync.dmg.sig"

    /// The feed to use: STS_UPDATE_FEED if set (tests, or trying an update
    /// against a local feed), else GitHub.
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["STS_UPDATE_FEED"].flatMap(URL.init(string:)) ?? defaultURL
    }

    /// Parses a releases/latest response. The dmg must carry a sha256
    /// digest: without one there is nothing to verify the download
    /// against, and an unverifiable update is not installed.
    public static func parse(_ data: Data) throws -> Release {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.badFeed("not JSON")
        }
        guard let tag = root["tag_name"] as? String else { throw UpdateError.badFeed("no tag_name") }
        let assets = root["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { $0["name"] as? String == dmgName }) else {
            throw UpdateError.badFeed("no \(dmgName) in release \(tag)")
        }
        guard let urlString = dmg["browser_download_url"] as? String, let url = URL(string: urlString) else {
            throw UpdateError.badFeed("no download URL")
        }
        guard let digest = dmg["digest"] as? String, digest.hasPrefix("sha256:"),
              digest.count == "sha256:".count + 64 else {
            throw UpdateError.badFeed("no sha256 digest for \(dmgName)")
        }
        // Unsigned releases (everything before #108) are not offered: the
        // signature is the check that does not rest on the GitHub account.
        guard let sig = assets.first(where: { $0["name"] as? String == signatureName }),
              let sigString = sig["browser_download_url"] as? String, let sigURL = URL(string: sigString) else {
            throw UpdateError.badFeed("no \(signatureName) in release \(tag)")
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       notes: root["body"] as? String ?? "",
                       dmgURL: url,
                       size: dmg["size"] as? Int ?? 0,
                       sha256: String(digest.dropFirst("sha256:".count)).lowercased(),
                       signatureURL: sigURL)
    }

    /// The only place a real update may come from: this repository's own
    /// release downloads, over HTTPS. With ad-hoc signing there is no team
    /// identity to pin (#61), so the root of trust is the repository and
    /// TLS; a feed pointing anywhere else is not followed. A test feed set
    /// through STS_UPDATE_FEED may use local files.
    public static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host == "github.com"
            && url.path.hasPrefix("/moudlajs/star-traders-sync/releases/download/")
            && !url.path.contains("/../")
    }

    /// Numeric dotted comparison: 1.10.0 is newer than 1.9.0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Ed25519 release signatures (#108). release.yml signs the dmg with a key
/// held only as a CI secret; the app checks it against this public key.
/// Unlike the sha256 digest, which comes from the same API as the file, a
/// valid signature cannot be made by someone who only controls the GitHub
/// account or the download. Signed with macos/scripts/release-sign.swift.
public enum ReleaseSignature {
    public static let publicKeyBase64 = "poTNTzOoOIh0yTrGPkkn3BjRWAmCbK6nnWjmO41Xw0M="

    public static func verify(_ file: URL, signatureBase64: String,
                              publicKeyBase64: String = ReleaseSignature.publicKeyBase64) throws {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              key.isValidSignature(signature, for: data) else {
            throw UpdateError.releaseSignatureInvalid
        }
    }
}

public enum UpdateInstaller {
    public static let appName = "Star Traders Sync.app"

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyChecksum(_ file: URL, expected: String) throws {
        let got = try sha256(of: file)
        guard got == expected.lowercased() else { throw UpdateError.checksumMismatch(expected: expected, got: got) }
    }

    /// Whether the app at `bundle` can be replaced in place: its folder is
    /// writable, and it is not running from a mounted disk image.
    public static func canReplace(_ bundle: URL) -> String? {
        let parent = bundle.deletingLastPathComponent().path
        if parent.hasPrefix("/Volumes/") { return "it is running from a disk image" }
        if !FileManager.default.isWritableFile(atPath: parent) { return "\(parent) is not writable" }
        return nil
    }

    /// Mounts the dmg read-only, checks the app inside, and swaps it in for
    /// `target` atomically. Nothing at `target` changes unless every check
    /// passes; a failure leaves the current app exactly as it was.
    public static func install(dmg: URL, expectedVersion: String, bundleID: String, over target: URL,
                               run: (String, [String]) -> CommandResult = { Shell.run($0, $1) }) throws {
        if let why = canReplace(target) { throw UpdateError.notWritable(why) }
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("sts-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                              "-mountpoint", mount.path, dmg.path])
        guard attach.ok else { throw UpdateError.mountFailed(attach.combined) }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }

        let new = mount.appendingPathComponent(appName)
        guard fm.fileExists(atPath: new.path) else { throw UpdateError.appNotFound }
        let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError.wrongApp("bundle id \(info["CFBundleIdentifier"] as? String ?? "missing")")
        }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError.wrongApp("version \(info["CFBundleShortVersionString"] as? String ?? "missing"), expected \(expectedVersion)")
        }
        try verifySignature(new, run: run)

        // Copy beside the target first (same volume, so the swap is a
        // rename), check the copy, then swap.
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(appName).update-\(getpid())")
        try? fm.removeItem(at: staged)
        let copy = run("/usr/bin/ditto", [new.path, staged.path])
        guard copy.ok else { throw UpdateError.io("Could not copy the update: \(copy.combined)") }
        do {
            try verifySignature(staged, run: run)
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw (error as? UpdateError) ?? UpdateError.io("Could not swap in the update: \(error.localizedDescription)")
        }
    }

    static func verifySignature(_ app: URL, run: (String, [String]) -> CommandResult) throws {
        let check = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.ok else { throw UpdateError.signatureInvalid(check.combined) }
    }
}
