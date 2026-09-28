import AppKit
import STSSetupCore
import SwiftUI

/// What the main window shows once this Mac is set up.
@MainActor
final class DashboardModel: ObservableObject {
    let layout = InstallLayout()

    @Published var status: SyncStatus?
    @Published var problem: SyncProblem?
    @Published var loading = false
    @Published var checkedAt: Date?

    let doctor = DoctorRun()

    /// The action running now, or the last one until dismissed.
    @Published var run: ActionRun?
    /// An action waiting for the user to confirm it.
    @Published var pending: ActionButton?

    var busy: Bool { run.map { !$0.ended } ?? false }

    private var timer: Timer?

    /// The app's own copy, kept current by Installer.refreshAppScript,
    /// never the ~/bin link, which may be an older repo checkout.
    var script: String { layout.installedScript.path }

    func start() {
        refresh()
        // Cheap enough to poll: status is read-only and takes about a
        // second. Once a minute keeps "last synced" honest without
        // hammering the hub.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // While sts runs it holds this Mac's lock, and status would only
        // report "a sync is already running". The run's own card says more.
        guard !loading, !busy else { return }
        loading = true
        let script = self.script
        Task.detached {
            let r = StatusClient.fetch(script: script)
            await MainActor.run {
                self.loading = false
                self.checkedAt = Date()
                switch r {
                case .success(let s):
                    self.status = s
                    self.problem = nil
                case .failure(let p):
                    self.problem = p
                    // Keep the last good status on screen for a transient
                    // refusal, such as another Mac syncing right now.
                    if ![50, 51, 52].contains(p.code) { self.status = nil }
                }
            }
        }
    }

    // MARK: actions

    func tapped(_ button: ActionButton) {
        if button.confirmation != nil {
            pending = button
        } else {
            perform(button.action)
        }
    }

    func perform(_ action: SyncAction) {
        guard !busy else { return }
        pending = nil
        let r = ActionRun(action: action)
        run = r
        let script = self.script

        guard let args = action.arguments else {
            // resetRecord: the documented manual fix for a diverged state,
            // under the same local lock the script takes.
            do {
                let aside = try SyncRecord.reset()
                SetupLog.write("action: resetRecord moved the record to \(aside?.path ?? "nowhere, there was none")")
                r.finish(status: 0, output: "")
            } catch let e as SyncRecord.ResetError {
                // 52 is the script's "another sts is running" code, so the
                // card explains it the same way.
                if case .busy = e { r.finish(status: 52, output: "error: \(e.description)") }
                else { r.finish(status: 1, output: "error: \(e.description)") }
            } catch {
                r.finish(status: 1, output: "error: \(error.localizedDescription)")
            }
            refresh()
            return
        }

        SetupLog.write("action: \(action.rawValue) (\(args.joined(separator: " ")))")
        Task.detached {
            var output: [String] = []
            let status = Shell.stream("/bin/bash", [script] + args) { line in
                output.append(line)
                Task { @MainActor in r.feed(line) }
            }
            let all = output.joined(separator: "\n")
            await MainActor.run {
                SetupLog.write("action: \(action.rawValue) exited \(status)")
                r.finish(status: status, output: all)
                self.objectWillChange.send()
                self.refresh()
            }
        }
    }

    func dismissRun() {
        guard !busy else { return }
        run = nil
    }

    func runDoctor() {
        doctor.start(script: script)
    }

    func openLogs() {
        let logs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/star-traders-sync")
        NSWorkspace.shared.open(logs)
    }
}

// MARK: - presentation

extension SyncStatus.Decision {
    var headline: String {
        switch self {
        case .inSync:           return "In sync"
        case .hubOnly:          return "The hub has newer saves"
        case .firstSeed:        return "This Mac has no saves yet"
        case .localOnly:        return "This Mac has saves the hub doesn't"
        case .hubEmpty:         return "The hub has no saves yet"
        case .bothChanged:      return "Both Macs have new saves"
        case .firstRunConflict: return "Choose which saves to keep"
        case .divergedState:    return "The saves don't match the last sync"
        case .localEmptied:     return "This Mac's saves are gone"
        }
    }

    /// Only ever says what the script will actually do.
    var explanation: String {
        switch self {
        case .inSync:
            return "This Mac and the hub have exactly the same saves."
        case .hubOnly:
            return "Another Mac played since this one last synced. Playing here copies its saves to this Mac first."
        case .firstSeed:
            return "Playing here copies your saves from the hub first."
        case .localOnly:
            return "This Mac changed since the last sync and the hub did not. Send them to the hub; until then a sync from the hub is refused, so nothing here is overwritten."
        case .hubEmpty:
            return "Send this Mac's saves to the hub to start syncing."
        case .bothChanged:
            return "This Mac and the hub both changed since the last sync. Nothing is merged or picked for you: choose which saves to keep."
        case .firstRunConflict:
            return "This Mac and the hub both have saves and have never synced. Choose which to keep. The other side is kept as a safety copy."
        case .divergedState:
            return "Neither side changed since the last sync, yet they differ. The sync tool refuses both ways until this Mac's sync record is reset: see \"diverged sync state\" in the troubleshooting guide."
        case .localEmptied:
            return "The save folder on this Mac is empty, but the hub still has your saves. Restore them from the hub; nothing is sent from this Mac until then."
        }
    }

    var symbol: String {
        switch self {
        case .inSync:                   return "checkmark.circle.fill"
        case .hubOnly, .firstSeed, .localEmptied: return "arrow.down.circle.fill"
        case .localOnly, .hubEmpty:     return "arrow.up.circle.fill"
        default:                        return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .inSync:                   return .green
        case .hubOnly, .firstSeed, .localEmptied: return .blue
        case .localOnly, .hubEmpty:     return .orange
        default:                        return .yellow
        }
    }
}

func relative(_ date: Date?) -> String {
    guard let date else { return "never" }
    if abs(date.timeIntervalSinceNow) < 45 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: Date())
}

// MARK: - views

struct DashboardView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var d: DashboardModel
    @State private var showDoctor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let p = d.problem { ProblemCard(problem: p) }
                    if let s = d.status {
                        VerdictCard(status: s)
                        if d.run == nil || d.run?.ended == true {
                            ActionButtons(plan: SyncActions.plan(for: s))
                        }
                    }
                    if let r = d.run {
                        ActivityCard(run: r)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let s = d.status {
                        HStack(alignment: .top, spacing: 16) {
                            SideCard(title: "This Mac", subtitle: s.machine, side: s.sides.local)
                            SideCard(title: s.isHub ? "Hub (this Mac)" : "Hub", subtitle: s.hub.host, side: s.sides.hub)
                        }
                        footer(s)
                    } else if d.problem == nil {
                        HStack { ProgressView().controlSize(.small); Text("Checking…") }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { d.start() }
        .onDisappear { d.stop() }
        .sheet(isPresented: $showDoctor) { DoctorSheet().environmentObject(d) }
        .alert(d.pending?.confirmation?.title ?? "",
               isPresented: Binding(get: { d.pending != nil }, set: { if !$0 { d.pending = nil } }),
               presenting: d.pending) { b in
            Button(b.confirmation?.button ?? "Continue") { d.perform(b.action) }
            Button("Cancel", role: .cancel) { d.pending = nil }
        } message: { b in
            Text(b.confirmation?.message ?? "")
        }
        .animation(.easeOut(duration: 0.25), value: d.run?.id)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Star Traders Sync").font(.title2).bold()
                if let s = d.status {
                    Text(s.isHub ? "This Mac is the hub" : "Hub: \(s.hub.host)")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 14) {
                Button { d.refresh() } label: {
                    ZStack {
                        // Same footprint either way, so nothing shifts.
                        Image(systemName: "arrow.clockwise").opacity(d.loading ? 0 : 1)
                        if d.loading { ProgressView().controlSize(.small) }
                    }
                    .frame(width: 22, height: 22)
                }
                .help("Check again")
                .disabled(d.loading)

                Menu {
                    Button("Health check…") { showDoctor = true; d.runDoctor() }
                    Button("Open logs") { d.openLogs() }
                    Divider()
                    Button("Run setup again…") { app.showSetup() }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 22, height: 22)
                }
                .menuIndicator(.hidden)
                .help("More")
            }
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .font(.system(size: 17, weight: .regular))
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    func footer(_ s: SyncStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let last = s.lastSync {
                Label("Last synced \(relative(last.date)), \(last.direction == "push" ? "sent to the hub" : "copied from the hub")",
                      systemImage: "clock")
            } else {
                Label("This Mac has not synced yet", systemImage: "clock")
            }
            if s.gameRunning {
                Label("Star Traders is running. Saves are synced when you quit it.", systemImage: "gamecontroller")
            }
            if let lock = s.hubLock {
                Label("Another Mac is syncing with the hub right now (\(lock.trimmingCharacters(in: .whitespaces))).", systemImage: "lock")
            }
            if let at = d.checkedAt {
                Text("Checked \(relative(at))").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct VerdictCard: View {
    let status: SyncStatus

    var body: some View {
        let v = status.decision
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: v.symbol)
                .font(.system(size: 34))
                .foregroundStyle(v.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(v.headline).font(.title3).bold()
                Text(v.explanation).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(v.tint.opacity(0.10)))
    }
}

struct SideCard: View {
    let title: String
    let subtitle: String
    let side: SyncStatus.Side

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if side.files == 0 {
                Text("No saves").foregroundStyle(.secondary)
            } else {
                LabeledContent("Campaigns", value: "\(side.campaignSaves)")
                LabeledContent("Last played", value: relative(side.newestDate))
                LabeledContent("Files", value: "\(side.files)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

struct ProblemCard: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var d: DashboardModel
    let problem: SyncProblem

    /// Codes whose fix is re-running setup, not waiting.
    var setupFixes: Bool { [10, 11, 12, 24, 30, 31, -1].contains(problem.code) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusRow(state: problem.needsChoice ? .warn : .fail, text: "**\(problem.title)**")
            Text(problem.advice).fixedSize(horizontal: false, vertical: true)
            if !problem.detail.isEmpty {
                DisclosureGroup("Details") {
                    Text(problem.detail)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            HStack {
                Button("Try again") { d.refresh() }
                if setupFixes { Button("Run setup again") { app.showSetup() } }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill((problem.needsChoice ? Color.orange : Color.red).opacity(0.08)))
    }
}

struct DoctorSheet: View {
    @EnvironmentObject var d: DashboardModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Health check").font(.title2).bold()
            ScrollView {
                DoctorProgressView(run: d.doctor)
                    .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button("Check again") { d.runDoctor() }.disabled(d.doctor.running)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 540)
    }
}
