import STSSetupCore
import SwiftUI

// The main window as designed on the canvas (board F): every state fills
// the same slots, top to bottom: face, headline, one status line, the
// action slot, and the This Mac | Hub strip. Nothing appears or vanishes;
// only what is inside a slot changes.

/// What the window is showing right now, from the run, the brief "synced"
/// moment, or the status.
enum Screen {
    case running(ActionRun)
    case justSynced(SyncAction)
    case status(SyncStatus)
}

struct MainHero: View {
    @EnvironmentObject var d: DashboardModel
    let screen: Screen

    var body: some View {
        VStack(spacing: 0) {
            FaceView(face: face)
                .frame(width: 96, height: 96)
            Text(headline)
                .font(.system(size: 21, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 30)
                .padding(.top, 12)
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 380, minHeight: 50, maxHeight: 50, alignment: .top)
                .padding(.top, 2)
            slot
                .frame(height: 48)
                .padding(.top, 8)
            if let note = d.notice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(note).lineLimit(2)
                    Button { d.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: 400)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: the face

    var face: Face {
        switch screen {
        case .running(let r):
            if r.action == .play && r.progress.current == 2 { return .playing }
            return r.action == .push || r.action == .keepLocal
                || (r.action == .play && r.progress.current >= 3) ? .sending : .fetching
        case .justSynced:
            return .tick(celebrate: true)
        case .status(let s):
            switch s.decision {
            case .inSync:                              return .tick(celebrate: false)
            case .hubOnly, .firstSeed, .localEmptied:  return .arrow(up: false)
            case .localOnly, .hubEmpty:                return .arrow(up: true)
            default:                                   return .warning
            }
        }
    }

    // MARK: words

    var headline: String {
        switch screen {
        case .running(let r):
            if r.automatic { return r.action == .pull ? "Fetching the latest saves" : "Sending your saves" }
            switch r.action {
            case .play:
                switch r.progress.current {
                case 0:  return "Getting the latest saves"
                case 1:  return "Starting Star Traders"
                case 2:  return r.progress.gameClosed ? "Game closed" : "Playing Star Traders"
                default: return "Sending your saves"
                }
            case .pull, .keepHub:  return "Fetching the Hub's saves"
            case .push, .keepLocal: return "Sending to the Hub"
            case .resetRecord:     return "Resetting"
            }
        case .justSynced:
            return "Up to date"
        case .status(let s):
            return s.decision.headline
        }
    }

    var line: String {
        switch screen {
        case .running(let r):
            if r.action == .play && r.progress.current == 2 {
                if r.progress.gameCrashed { return "The game crashed. Your saves are still sent to the Hub." }
                return r.progress.gameClosed
                    ? "Making sure the game has really closed, then your saves go to the Hub."
                    : "When you quit the game, your saves go to the Hub by themselves."
            }
            let stages = r.action.stages
            let i = min(r.progress.current, stages.count - 1)
            return "Step \(i + 1) of \(stages.count) · \(stages[i])"
        case .justSynced(let a):
            switch a {
            case .play:                     return "Played and synced. Your saves are on the Hub."
            case .push, .keepLocal:         return "Sent this Mac's saves to the Hub just now."
            case .resetRecord:              return "This Mac's sync record was reset."
            default:                        return "Copied the Hub's saves to this Mac just now."
            }
        case .status(let s):
            if let why = SyncActions.plan(for: s).blockedBecause { return why }
            return s.decision.line(for: s)
        }
    }

    // MARK: the action slot

    @ViewBuilder var slot: some View {
        switch screen {
        case .running(let r):
            if r.action == .play && r.progress.current == 2 && !r.progress.gameClosed {
                InGamePill(since: r.playStartedAt ?? Date())
            } else {
                StatusPill(kind: .busy, text: r.action == .play && r.progress.current == 1 ? "Starting…" : "Syncing…")
            }
        case .justSynced:
            StatusPill(kind: .done, text: "Synced")
        case .status(let s):
            SlotButtons(plan: SyncActions.plan(for: s))
        }
    }
}

extension SyncStatus.Decision {
    var headline: String {
        switch self {
        case .inSync:           return "Up to date"
        case .hubOnly:          return "The Hub has newer saves"
        case .firstSeed:        return "This Mac has no saves yet"
        case .localOnly:        return "This Mac has newer saves"
        case .hubEmpty:         return "The Hub has no saves yet"
        case .bothChanged:      return "Both Macs have new saves"
        case .firstRunConflict: return "Choose which saves to keep"
        case .divergedState:    return "The saves don't match"
        case .localEmptied:     return "This Mac's saves are gone"
        }
    }

    /// One or two lines; only ever what the script will actually do.
    func line(for s: SyncStatus) -> String {
        switch self {
        case .inSync:
            guard let last = s.lastSync else { return "This Mac and the Hub have the same saves." }
            return "Last synced \(relative(last.date)), \(last.direction == "push" ? "to" : "from") the Hub."
        case .hubOnly:
            return "Another Mac played since. Its saves are copied here when you play."
        case .firstSeed:
            return "Your saves are copied here from the Hub when you play."
        case .localOnly:
            return "They go to the Hub when you finish playing, or right now with Send."
        case .hubEmpty:
            return "Send this Mac's saves to the Hub to start syncing."
        case .bothChanged, .firstRunConflict:
            let hub = s.isHub ? "The Hub" : s.hub.host
            return "\(hub) played \(relative(s.sides.hub.newestDate)), this Mac \(relative(s.sides.local.newestDate)). The other side is kept as a safety copy."
        case .divergedState:
            return "Neither side changed since the last sync, yet they differ. Reset this Mac's sync record, then choose."
        case .localEmptied:
            return "The Hub still has your saves. Restore them here."
        }
    }
}

// MARK: - the pieces

/// Buttons, when there is something to do: one big main button, and at
/// most one secondary capsule beside it.
struct SlotButtons: View {
    @EnvironmentObject var d: DashboardModel
    let plan: ActionPlan

    var body: some View {
        HStack(spacing: 10) {
            ForEach(plan.buttons) { b in
                Button { d.tapped(b) } label: {
                    HStack(spacing: 7) {
                        if b.action == .play {
                            Image(systemName: "play.fill").font(.system(size: 12))
                        }
                        Text(b.action == .play ? "Play Star Traders" : b.label)
                    }
                    .font(.system(size: b.prominent ? 15 : 13, weight: b.prominent ? .semibold : .medium))
                    .padding(.horizontal, b.prominent ? 22 : 16)
                    .frame(minWidth: b.prominent && plan.buttons.count == 1 ? 240 : nil)
                    .frame(height: b.prominent ? 44 : 38)
                    .foregroundStyle(b.prominent ? Color.white : Color.primary)
                    .background(Capsule().fill(b.prominent ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().stroke(Color.secondary.opacity(b.prominent ? 0 : 0.3)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(b.action == .play ? .defaultAction : nil)
            }
        }
        .disabled(d.busy || plan.blockedBecause != nil)
        .opacity(plan.blockedBecause != nil ? 0.5 : 1)
    }
}

/// A status, not a button: something is running, or has just finished.
struct StatusPill: View {
    enum Kind { case busy, done }
    let kind: Kind
    let text: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .busy:
                ProgressView().controlSize(.small).tint(Color(red: 0.56, green: 0.75, blue: 1))
            case .done:
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(kind == .busy ? Color(red: 0.56, green: 0.75, blue: 1) : Color(red: 0.49, green: 0.9, blue: 0.6))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(kind == .busy ? Color.blue.opacity(0.18) : Color.green.opacity(0.16)))
        .scaleEffect(shown || kind == .busy ? 1 : 0.6)
        .opacity(shown || kind == .busy ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { shown = true } }
    }
}

/// "● In game · 12:04", the dot breathing, the clock ticking.
struct InGamePill: View {
    let since: Date
    @State private var breathe = false

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            HStack(spacing: 9) {
                Circle().fill(Color.green).frame(width: 9, height: 9)
                    .scaleEffect(breathe ? 0.8 : 1).opacity(breathe ? 0.45 : 1)
                Text("In game · \(Self.clock(ctx.date.timeIntervalSince(since)))").monospacedDigit()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(red: 0.49, green: 0.9, blue: 0.6))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Color.green.opacity(0.16)))
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever()) { breathe = true } }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The big symbol at the top, with its motion.
enum Face: Equatable {
    /// celebrate: the pop-and-draw entrance, only right after a sync. The
    /// quiet state shows the tick still, however often the window redraws.
    case tick(celebrate: Bool)
    case fetching, sending, playing, warning
    case arrow(up: Bool)
}

struct FaceView: View {
    let face: Face

    var body: some View {
        Group {
            switch face {
            case .tick(let c):   TickFace(celebrate: c)
            case .fetching:      RingFace(up: false)
            case .sending:       RingFace(up: true)
            case .playing:       PlayingFace()
            case .warning:       WarningFace()
            case .arrow(let up): ArrowFace(up: up)
            }
        }
        // A new identity per face, so each one's entrance plays again.
        .id(String(describing: face))
        .transition(.opacity)
    }
}

/// Pops in with a little overshoot, then the tick draws itself.
struct TickFace: View {
    let celebrate: Bool
    @State private var popped = false
    @State private var drawn: CGFloat = 0

    init(celebrate: Bool) {
        self.celebrate = celebrate
        _popped = State(initialValue: !celebrate)
        _drawn = State(initialValue: celebrate ? 0 : 1)
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.22)).frame(width: 76, height: 76)
            TickShape()
                .trim(from: 0, to: drawn)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: 34, height: 26)
        }
        .scaleEffect(popped ? 1 : 0.4)
        .opacity(popped ? 1 : 0)
        .onAppear {
            guard celebrate else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { popped = true }
            withAnimation(.easeOut(duration: 0.45).delay(0.2)) { drawn = 1 }
        }
    }
}

struct TickShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// A ring that keeps filling and an arrow that keeps moving: never looks stuck.
struct RingFace: View {
    let up: Bool
    @State private var fill: CGFloat = 0.05
    @State private var nudge = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.22), lineWidth: 5)
            Circle().trim(from: 0, to: fill)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: up ? "arrow.up" : "arrow.down")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.blue)
                .offset(y: nudge ? 4 : -4)
        }
        .frame(width: 88, height: 88)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false)) { fill = 1 }
            withAnimation(.easeInOut(duration: 1.1).repeatForever()) { nudge = true }
        }
    }
}

/// A slow, calm breath: alive, but quiet for a long session.
struct PlayingFace: View {
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle().fill(Color.blue.opacity(0.2)).frame(width: 76, height: 76)
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.blue)
        }
        .scaleEffect(breathe ? 1.08 : 1)
        .opacity(breathe ? 0.8 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever()) { breathe = true } }
    }
}

/// One short shake when it appears, to draw the eye. Never a loop.
struct WarningFace: View {
    @State private var shakes: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(Color.yellow.opacity(0.2)).frame(width: 76, height: 76)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.yellow)
        }
        .modifier(Shake(amount: shakes))
        .onAppear { withAnimation(.easeInOut(duration: 0.5)) { shakes = 2 } }
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(amount * .pi * 2), y: 0))
    }
}

/// Waiting for something to happen here or there: a still arrow.
struct ArrowFace: View {
    let up: Bool

    var body: some View {
        ZStack {
            Circle().fill((up ? Color.orange : Color.blue).opacity(0.2)).frame(width: 76, height: 76)
            Image(systemName: up ? "arrow.up" : "arrow.down")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(up ? Color.orange : Color.blue)
        }
    }
}

/// Both sides in one slim strip, with icons.
struct SidesStrip: View {
    let status: SyncStatus

    var body: some View {
        HStack(spacing: 0) {
            column(icon: "desktopcomputer", title: "This Mac", side: status.sides.local)
            Divider().padding(.vertical, 4)
            column(icon: "server.rack", title: "Hub", side: status.sides.hub)
        }
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        .fixedSize(horizontal: false, vertical: true)
    }

    func column(icon: String, title: String, side: SyncStatus.Side) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if side.files == 0 {
                    Text("No saves").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("\(side.campaignSaves) campaign\(side.campaignSaves == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("played \(relative(side.newestDate))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }
}
