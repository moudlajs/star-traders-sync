import STSSetupCore
import SwiftUI

/// One run of a SyncAction, observed by the activity card.
@MainActor
final class ActionRun: ObservableObject, Identifiable {
    let action: SyncAction
    /// Started by the app itself (#87), not by a button.
    let automatic: Bool
    @Published private(set) var progress: ActionProgress
    @Published private(set) var ended = false
    @Published private(set) var problem: SyncProblem?
    /// When the game started (play's third stage), for the in-game clock.
    @Published private(set) var playStartedAt: Date?

    init(action: SyncAction, automatic: Bool = false) {
        self.action = action
        self.automatic = automatic
        self.progress = ActionProgress(action: action)
    }

    func feed(_ line: String) {
        guard !ended else { return }
        let before = progress.current
        progress.feed(line)
        if action == .play, before < 2, progress.current == 2 { playStartedAt = Date() }
    }

    func finish(status: Int32, output: String) {
        if status == 0 {
            progress.succeed()
        } else {
            problem = SyncProblem.from(code: status, stderr: output)
        }
        ended = true
    }
}

/// Live progress of the running action, one row per stage, following the
/// script's own progress lines.
struct ActivityCard: View {
    @EnvironmentObject var d: DashboardModel
    @ObservedObject var run: ActionRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).foregroundStyle(run.ended ? .primary : .secondary)
                Spacer()
                if run.ended {
                    Button { withAnimation { d.dismissRun() } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }
            ForEach(Array(run.action.stages.enumerated()), id: \.offset) { i, stage in
                row(i, stage)
            }
            if let p = run.problem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.title).fontWeight(.semibold)
                    Text(p.advice).fixedSize(horizontal: false, vertical: true)
                    if p.needsChoice {
                        Text("Choose above which saves to keep.").foregroundStyle(.secondary)
                    }
                    if !p.detail.isEmpty {
                        DisclosureGroup("Details") {
                            Text(p.detail).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        .animation(.easeOut(duration: 0.2), value: run.progress)
    }

    /// This card is only shown for a run that ended with a refusal; a
    /// success clears itself and the status says the result. Every refusal
    /// in the script happens before anything is overwritten, which is what
    /// makes this title true.
    var title: String { "Stopped, nothing was lost" }

    func state(_ i: Int) -> InstallStage.State {
        if i < run.progress.current { return .done }
        if i == run.progress.current {
            if run.problem != nil { return .failed }
            return run.ended ? .done : .running
        }
        return .pending
    }

    @ViewBuilder func row(_ i: Int, _ stage: String) -> some View {
        let s = state(i)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch s {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.small)
                case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:  Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage)
                    .fontWeight(s == .running ? .semibold : .regular)
                    .foregroundStyle(s == .pending ? .secondary : .primary)
                if run.action == .play && i == 2 && run.progress.gameCrashed {
                    Text("The game crashed. Your saves are still sent to the Hub.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }
}
