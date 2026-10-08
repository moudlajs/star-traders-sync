import Foundation

/// One line of `sts doctor` output, classified so the app can show one row per section.
public struct DoctorLine: Identifiable, Equatable {
    public enum Kind: Equatable { case ok, warn, fail, fixed, note, skip, section, plain }

    public let id = UUID()
    public let text: String
    public let kind: Kind

    public init(_ raw: String) {
        text = raw
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("ok ")         { kind = .ok }
        else if t.hasPrefix("warn ")  { kind = .warn }
        else if t.hasPrefix("FAIL ")  { kind = .fail }
        else if t.hasPrefix("fixed")  { kind = .fixed }
        else if t.hasPrefix("note ")  { kind = .note }
        else if t.hasPrefix("--")     { kind = .skip }
        else if Self.isSectionHeader(raw) { kind = .section }
        else                          { kind = .plain }
    }

    public static func == (a: DoctorLine, b: DoctorLine) -> Bool { a.text == b.text && a.kind == b.kind }

    // Section headers are indented two spaces and lowercase; summary lines start with a capital or digit.
    static func isSectionHeader(_ raw: String) -> Bool {
        guard raw.hasPrefix("  "), !raw.hasPrefix("   ") else { return false }
        guard let first = raw.dropFirst(2).first else { return false }
        return first.isLowercase
    }

    /// The check text without its "ok    " style prefix.
    public var message: String {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .ok, .warn, .fail, .fixed, .note:
            return t.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
        case .skip:
            return t.dropFirst(2).trimmingCharacters(in: .whitespaces)
        default:
            return t
        }
    }
}

public struct DoctorSection: Identifiable, Equatable {
    public enum Outcome: Equatable { case ok, fixed, warn, fail, skipped }

    public let title: String
    public var lines: [DoctorLine]
    public var id: String { title }

    public init(title: String, lines: [DoctorLine] = []) {
        self.title = title
        self.lines = lines
    }

    /// The worst thing in the section decides its icon.
    public var outcome: Outcome {
        let kinds = lines.map(\.kind)
        if kinds.contains(.fail) { return .fail }
        if kinds.contains(.warn) { return .warn }
        if kinds.contains(.skip) && !kinds.contains(.ok) { return .skipped }
        if kinds.contains(.fixed) { return .fixed }
        return .ok
    }

    /// One line for the collapsed row.
    public var summary: String {
        let checks = lines.filter { [.ok, .warn, .fail, .fixed].contains($0.kind) }
        switch outcome {
        case .fail, .warn:
            return lines.first { $0.kind == (outcome == .fail ? .fail : .warn) }?.message ?? ""
        case .skipped:
            return lines.first { $0.kind == .skip }?.message ?? "skipped"
        case .fixed:
            let n = lines.filter { $0.kind == .fixed }.count
            return "\(n) fixed, \(checks.count - n) passed"
        case .ok:
            return checks.count == 1 ? checks[0].message : "\(checks.count) checks passed"
        }
    }

    /// The script's section names, in words a player would use.
    public var displayTitle: String {
        switch title {
        case "environment":    return "This Mac"
        case "config":         return "Settings"
        case "state and logs": return "Logs and state"
        case "game":           return "Star Traders"
        case "tailscale":      return "Tailscale"
        case "ssh to the hub": return "Connection to the hub"
        case "everything else": return "Everything else"
        default:
            if title.hasPrefix("hub duties") { return "Hub duties" }
            return title.prefix(1).uppercased() + title.dropFirst()
        }
    }
}

public struct DoctorReport: Equatable {
    public var sections: [DoctorSection] = []
    public var summary: [String] = []

    public init() {}

    /// Folds one more output line in; a section is complete once the next starts or the run ends.
    public mutating func add(_ raw: String) {
        let line = DoctorLine(raw)
        if line.kind == .section {
            sections.append(DoctorSection(title: raw.trimmingCharacters(in: .whitespaces)))
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if raw.hasPrefix("  ") && !raw.hasPrefix("   ") && !sections.isEmpty {
            summary.append(trimmed)
        } else if !sections.isEmpty && summary.isEmpty {
            sections[sections.count - 1].lines.append(line)
        }
    }

    public static func parse(_ text: String) -> DoctorReport {
        var r = DoctorReport()
        text.split(separator: "\n", omittingEmptySubsequences: false).forEach { r.add(String($0)) }
        return r
    }
}

/// One row of the health check as drawn: every expected section is shown from the start and updates in place.
public struct DoctorRow: Identifiable, Equatable {
    public enum State: Equatable { case pending, checking, done, notChecked }
    public let title: String
    public let section: DoctorSection?
    public let state: State
    public var id: String { title }
    public var displayTitle: String { DoctorSection(title: title).displayTitle }
}

extension DoctorReport {
    /// The sections doctor prints, in its order; "hub duties" and "everything else" are appended where they occur.
    public static let expectedTitles = ["environment", "config", "state and logs", "game", "tailscale", "ssh to the hub"]

    /// The rows so far: `revealed` sections shown by the paced reveal, `finished` once the run and reveal are over.
    public func rows(revealed: Int, finished: Bool) -> [DoctorRow] {
        var titles = Self.expectedTitles
        for s in sections where !titles.contains(s.title) { titles.append(s.title) }
        let shownTitles = Set(sections.prefix(revealed).map(\.title))
        var checkingGiven = false
        return titles.map { title in
            if shownTitles.contains(title), let s = sections.first(where: { $0.title == title }) {
                return DoctorRow(title: title, section: s, state: .done)
            }
            if finished { return DoctorRow(title: title, section: nil, state: .notChecked) }
            if !checkingGiven {
                checkingGiven = true
                return DoctorRow(title: title, section: nil, state: .checking)
            }
            return DoctorRow(title: title, section: nil, state: .pending)
        }
    }
}
