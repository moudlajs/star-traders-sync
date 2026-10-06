import Foundation

/// One of this Mac's safety copies, as `sts restore --json` lists them (#90):
/// the snapshot taken before an overwrite, named by its UTC time.
public struct SafetyCopy: Decodable, Equatable, Identifiable {
    public let name: String
    public let files: Int
    public let campaignSaves: Int
    /// The newest save inside it (epoch seconds), 0 for none.
    public let newest: Int

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, files, newest
        case campaignSaves = "campaign_saves"
    }

    /// When it was taken: its name, without a "-2" uniqueness suffix.
    public var takenAt: Date? {
        let stamp = name.split(separator: "-", maxSplits: 3).count > 3
            ? String(name[..<(name.lastIndex(of: "-") ?? name.endIndex)]) : name
        return ISO8601DateFormatter().date(from: stamp)
    }

    public var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil }

    public var displayDate: String {
        guard let d = takenAt else { return name }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    public var summary: String {
        "\(campaignSaves) campaign\(campaignSaves == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
    }

    public static func list(from data: Data) throws -> [SafetyCopy] {
        struct Root: Decodable { let snapshots: [SafetyCopy] }
        return try JSONDecoder().decode(Root.self, from: data).snapshots
    }
}
