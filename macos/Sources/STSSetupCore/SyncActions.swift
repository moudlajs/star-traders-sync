import Foundation

/// Something the user can ask the app to do. Each maps to exactly one
/// script invocation (or, for resetRecord, the documented manual fix), so
/// the app never does anything the CLI would not.
public enum SyncAction: String, CaseIterable, Identifiable {
    case play
    case pull
    case push
    /// pull --force=hub: this Mac takes the hub's saves.
    case keepHub
    /// push --force=local: the hub takes this Mac's saves.
    case keepLocal
    /// Diverged sync state: move this Mac's sync record aside, so the next
    /// sync is a first run and asks which saves to keep (troubleshooting
    /// row 46). No save file is touched.
    case resetRecord

    public var id: String { rawValue }

    /// Arguments for the script, pinned to the decision the user saw: the
    /// script re-checks it under the hub lock and refuses (64) if another
    /// Mac changed things in the meantime. Play has no such flag; its pull
    /// never forces, so it cannot overwrite anything unconfirmed. nil for
    /// resetRecord, which is not a script command.
    public func arguments(expecting decision: SyncStatus.Decision) -> [String]? {
        guard let base = arguments else { return nil }
        return self == .play ? base : base + ["--expect-decision=\(decision.rawValue)"]
    }

    public var arguments: [String]? {
        switch self {
        case .play:        return ["play"]
        case .pull:        return ["pull"]
        case .push:        return ["push"]
        case .keepHub:     return ["pull", "--force=hub"]
        case .keepLocal:   return ["push", "--force=local"]
        case .resetRecord: return nil
        }
    }

    /// The stages shown while it runs, in order.
    public var stages: [String] {
        switch self {
        case .play:
            return ["Get the latest saves", "Start Star Traders", "Playing", "Send your saves to the hub"]
        case .pull, .keepHub:
            return ["Check both sides", "Copy the hub's saves to this Mac"]
        case .push, .keepLocal:
            return ["Check both sides", "Send this Mac's saves to the hub"]
        case .resetRecord:
            return ["Reset this Mac's sync record"]
        }
    }
}

/// A button on the status card.
public struct ActionButton: Equatable, Identifiable {
    public let action: SyncAction
    /// The decision this button was offered for. Running it passes this as
    /// --expect-decision, so a stale choice can never run.
    public var expected: SyncStatus.Decision = .inSync
    /// For resetRecord: the record's epoch as shown (nil for none), so the
    /// reset refuses if a sync happened since.
    public var expectedRecordEpoch: Int?
    public let label: String
    public let prominent: Bool
    /// Asked before running; nil runs straight away.
    public let confirmation: Confirmation?
    public var id: String { action.rawValue + label }

    public struct Confirmation: Equatable {
        public let title: String
        public let message: String
        public let button: String
    }
}

public struct ActionPlan: Equatable {
    public var buttons: [ActionButton] = []
    /// Why the buttons are disabled right now, if they are.
    public var blockedBecause: String?
}

public enum SyncActions {
    /// The buttons for a status. Every button is one the script accepts in
    /// that state: a plain pull where pull would refuse is never offered.
    public static func plan(for s: SyncStatus) -> ActionPlan {
        var plan = ActionPlan()
        let hubName = s.isHub ? "the hub" : s.hub.host
        let local = describe(s.sides.local)
        let hub = describe(s.sides.hub)

        let keepHub = ActionButton(
            action: .keepHub, label: "Keep the hub's saves", prominent: false,
            confirmation: .init(
                title: "Replace this Mac's saves with the hub's?",
                message: "This Mac's saves (\(local)) are replaced by the hub's (\(hub)). A safety copy of this Mac's saves is kept first, so this can be undone.",
                button: "Keep the hub's saves"))
        let keepLocal = ActionButton(
            action: .keepLocal, label: "Keep this Mac's saves", prominent: false,
            confirmation: .init(
                title: "Replace the hub's saves with this Mac's?",
                message: "The hub's saves (\(hub)) are replaced by this Mac's (\(local)), and every other Mac gets them the next time it plays. A safety copy of the hub's saves is kept first, so this can be undone.",
                button: "Keep this Mac's saves"))
        let play = ActionButton(action: .play, label: "Play", prominent: true, confirmation: nil)

        switch s.decision {
        case .inSync:
            plan.buttons = [play]
        case .hubOnly, .firstSeed:
            plan.buttons = [play,
                            ActionButton(action: .pull, label: "Get the hub's saves now", prominent: false, confirmation: nil)]
        case .localOnly:
            // Play skips the fetch here (#99) and sends afterwards.
            plan.buttons = [play,
                            ActionButton(action: .push, label: "Send to \(hubName) now", prominent: false, confirmation: nil)]
        case .hubEmpty:
            plan.buttons = [ActionButton(
                action: .keepLocal, label: "Send this Mac's saves to the hub", prominent: true,
                confirmation: .init(
                    title: "Start the hub with this Mac's saves?",
                    message: "The hub is empty. This Mac's saves (\(local)) become the saves every Mac syncs from. If the hub should have had saves, check it first.",
                    button: "Send to the hub"))]
        case .localEmptied:
            plan.buttons = [ActionButton(
                action: .keepHub, label: "Restore from the hub", prominent: true,
                confirmation: .init(
                    title: "Restore this Mac's saves from the hub?",
                    message: "This Mac's save folder is empty. The hub's saves (\(hub)) are copied here.",
                    button: "Restore"))]
        case .bothChanged, .firstRunConflict:
            plan.buttons = [keepHub, keepLocal]
        case .divergedState:
            plan.buttons = [ActionButton(
                action: .resetRecord, label: "Reset this Mac's sync record", prominent: false,
                confirmation: .init(
                    title: "Reset this Mac's sync record?",
                    message: "No save is copied or deleted. The record of this Mac's last sync is moved aside, and you are then asked which saves to keep.",
                    button: "Reset"))]
        }

        for i in plan.buttons.indices {
            plan.buttons[i].expected = s.decision
            plan.buttons[i].expectedRecordEpoch = s.lastSync?.at
        }

        if s.gameRunning {
            plan.blockedBecause = "Star Traders is running. Quit it first; saves are never copied while the game has them open."
        } else if let lock = s.hubLock {
            plan.blockedBecause = "Another Mac is syncing with the hub right now (\(lock.trimmingCharacters(in: .whitespaces))). Try again in a minute."
        }
        return plan
    }

    static func describe(_ side: SyncStatus.Side) -> String {
        let n = side.campaignSaves
        let campaigns = "\(n) campaign\(n == 1 ? "" : "s")"
        guard let d = side.newestDate else { return campaigns }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "\(campaigns), last played \(f.localizedString(for: d, relativeTo: Date()))"
    }
}

/// Follows a running action's output and says which stage it is in. The
/// markers are the script's own progress lines (its say() calls).
public struct ActionProgress: Equatable {
    public let action: SyncAction
    /// Index of the stage in progress; stages before it are done.
    public private(set) var current = 0
    public private(set) var finished = false
    public private(set) var gameCrashed = false
    /// The script noticed the game is gone and is making sure it stays
    /// gone (a few seconds) before it sends the saves.
    public private(set) var gameClosed = false

    public init(action: SyncAction) {
        self.action = action
    }

    public mutating func feed(_ line: String) {
        let l = line.lowercased()
        switch action {
        case .play:
            if l.hasPrefix("launching ") { current = max(current, 1) }
            else if l.hasPrefix("game running") { current = max(current, 2); gameClosed = false }
            else if l.hasPrefix("game closed") { gameClosed = true }
            else if l.contains("the game crashed") { gameCrashed = true }
            else if l.hasPrefix("pushing after play") { current = max(current, 3) }
        case .pull, .keepHub:
            if l.hasPrefix("pulling ") || l.hasPrefix("first seed") { current = max(current, 1) }
        case .push, .keepLocal:
            if l.hasPrefix("pushing ") || l.hasPrefix("seeding the empty hub") { current = max(current, 1) }
        case .resetRecord:
            break
        }
    }

    /// Exit 0: every stage is done.
    public mutating func succeed() {
        current = action.stages.count
        finished = true
    }
}
