import STSSetupCore
import SwiftUI

/// One run of a SyncAction, observed by the activity card.
@MainActor
final class ActionRun: ObservableObject, Identifiable {
    let action: SyncAction
    @Published private(set) var progress: ActionProgress
    @Published private(set) var ended = false
    @Published private(set) var problem: SyncProblem?

    init(action: SyncAction) {
        self.action = action
        self.progress = ActionProgress(action: action)
    }

    func feed(_ line: String) {
        guard !ended else { return }
        progress.feed(line)
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

/// The buttons under the status card. Only what the script accepts in the
/// current state is offered (SyncActions.plan).
struct ActionButtons: View {
    @EnvironmentObject var d: DashboardModel
    let plan: ActionPlan

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach(plan.buttons) { b in
                    if b.prominent {
                        Button { d.tapped(b) } label: {
                            Label(b.label, systemImage: b.action == .play ? "play.fill" : "arrow.triangle.2.circlepath")
                                .labelStyle(.titleAndIcon)
                                .frame(minWidth: 150)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(b.action == .play ? .defaultAction : nil)
                    } else {
                        Button { d.tapped(b) } label: {
                            Text(b.label).padding(.vertical, 3)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.large)
            .disabled(d.busy || plan.blockedBecause != nil || d.loading)
            if let why = plan.blockedBecause {
                Text(why).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Live progress of the running action, one row per stage, following the
/// script's own progress lines.
struct ActivityCard: View {
    @EnvironmentObject var d: DashboardModel
    @ObservedObject var run: ActionRun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

    var title: String {
        // Every refusal in the script happens before anything is
        // overwritten, which is what makes this promise true.
        if run.problem != nil { return "Stopped, nothing was lost" }
        if run.ended { return run.action == .play ? "Played and synced" : "Done" }
        return "Steps"
    }

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
                    Text("The game crashed. Your saves are still sent to the hub.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }
}
