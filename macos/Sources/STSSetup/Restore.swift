import STSSetupCore
import SwiftUI

/// Restore previous saves (#90): this Mac's safety copies, newest first.
/// Restoring runs `sts restore NAME` like any other action, so the saves
/// here now are snapshotted first and the restore can itself be undone.
struct RestoreSheet: View {
    @EnvironmentObject var d: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var copies: [SafetyCopy]?
    @State private var problem: SyncProblem?
    @State private var chosen: SafetyCopy.ID?
    @State private var confirming: ActionButton?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore previous saves").font(.title3.weight(.semibold))
            Text("Every time this Mac's saves were replaced, a safety copy was kept first. Putting one back keeps the saves here now as a new safety copy, so this can be undone.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let problem {
                    Label(problem.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let copies {
                    if copies.isEmpty {
                        Text("No safety copies yet. One is kept each time this Mac's saves are replaced.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        List(copies, selection: $chosen) { c in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.displayDate).font(.system(size: 13, weight: .medium))
                                    Text(c.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if c.newestDate != nil {
                                    Text("played \(relative(c.newestDate))").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(minHeight: 180)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }

            HStack {
                if d.status?.gameRunning == true {
                    Text("Quit the game first.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore…") {
                    if let c = copies?.first(where: { $0.id == chosen }) { confirming = SyncActions.restore(c) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil || d.busy || d.status?.gameRunning == true)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { load() }
        .alert(confirming?.confirmation?.title ?? "",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { b in
            Button(b.confirmation?.button ?? "Restore") {
                confirming = nil
                dismiss()
                // A sync that started meanwhile would make perform drop it
                // without a word.
                if d.busy {
                    d.notice = "Restore not started: a sync was running. Try again when it is done."
                } else {
                    d.perform(b)
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { b in
            Text(b.confirmation?.message ?? "")
        }
    }

    func load() {
        let fetch = d.fetchSafetyCopies, script = d.script
        Task.detached {
            let result = fetch(script)
            await MainActor.run {
                switch result {
                case .success(let list): copies = list
                case .failure(let p):    problem = p
                }
            }
        }
    }
}
