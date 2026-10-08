import Foundation

/// What the menu bar icon says at a glance (#91).
public enum MenuBarState: Equatable {
    /// Nothing known yet: the first check has not finished.
    case checking
    case upToDate
    /// A sync, a Play or a restore is running.
    case syncing
    /// The sides differ in a way the app or Play settles by itself.
    case willSync
    /// Only the user can settle it: a choice between saves, an emptied side, or a problem.
    case needsYou

    public static func of(status: SyncStatus?, busy: Bool, problem: Bool) -> MenuBarState {
        if busy { return .syncing }
        if problem { return .needsYou }
        guard let s = status else { return .checking }
        switch s.decision {
        case .inSync:
            return .upToDate
        case .hubOnly, .firstSeed, .localOnly:
            return .willSync
        case .hubEmpty, .localEmptied, .bothChanged, .firstRunConflict, .divergedState:
            return .needsYou
        }
    }

    public var title: String {
        switch self {
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .syncing:  return "Syncing…"
        case .willSync: return "Saves to sync"
        case .needsYou: return "Needs you"
        }
    }

    /// SF Symbols, one shape per state so it reads without colour.
    public var symbol: String {
        switch self {
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle"
        case .syncing:  return "arrow.triangle.2.circlepath.circle.fill"
        case .willSync: return "arrow.up.arrow.down.circle"
        case .needsYou: return "exclamationmark.circle.fill"
        }
    }
}
