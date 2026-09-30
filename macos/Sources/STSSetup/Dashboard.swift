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

    /// The health check opens inside the main window, not as a sheet.
    @Published var showingHealth = false

    /// Something worth knowing about a run that otherwise succeeded, such
    /// as the game crashing (the saves were still sent). Shown under the
    /// status until dismissed or the next action.
    @Published var notice: String?

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

    /// Brings the app's copy of the script up to date with the bundled one.
    /// At launch, and again before every status check, because a launch can
    /// land while an sts is running, when replacing it is refused.
    nonisolated static func refreshAppScript(layout: InstallLayout, when: String) {
        let bundled = WizardModel.locate("star-traders-sync", repoPath: "bin/star-traders-sync")
        let result = Installer.refreshAppScript(bundledScript: bundled,
                                                bundledExample: WizardModel.locate("config.example", repoPath: "config.example"),
                                                layout: layout)
        // Launch always logs; later checks only when something happened.
        if when == "launch" || result != .unchanged {
            SetupLog.write("\(when): app script \(result.logText) (\(bundled?.path ?? "nothing bundled"))")
        }
    }

    func refresh() {
        // While sts runs it holds this Mac's lock, and status would only
        // report "a sync is already running". The run's own card says more.
        // Nor while a confirmation is open: the dialog describes the status
        // it was opened for, and the script is pinned to that decision.
        guard !loading, !busy, pending == nil else { return }
        loading = true
        let script = self.script
        let layout = self.layout
        Task.detached {
            // Off the main thread: two file reads, and pgrep.
            DashboardModel.refreshAppScript(layout: layout, when: "check")
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
            perform(button)
        }
    }

    func perform(_ button: ActionButton) {
        let action = button.action
        guard !busy else { return }
        pending = nil
        let r = ActionRun(action: action)
        run = r
        notice = nil
        let script = self.script

        guard let args = action.arguments(expecting: button.expected) else {
            // resetRecord: the documented manual fix for a diverged state,
            // under the same local lock the script takes.
            do {
                if let aside = try SyncRecord.reset(expectedEpoch: .some(button.expectedRecordEpoch)) {
                    SetupLog.write("action: resetRecord moved the record to \(aside.path)")
                    r.finish(status: 0, output: "")
                } else {
                    // Not a success: nothing was reset, so say so rather
                    // than leave the user in the same state with a tick.
                    let path = SyncRecord.defaultStateDir.appendingPathComponent("last-sync.json").path
                    SetupLog.write("action: resetRecord found no record at \(path)")
                    r.finish(status: 1, output: "error: there is no sync record at \(path) to reset")
                }
            } catch let e as SyncRecord.ResetError {
                // 52 is the script's "another sts is running" code, so the
                // card explains it the same way.
                switch e {
                case .busy:    r.finish(status: 52, output: "error: \(e.description)")
                case .changed: r.finish(status: 64, output: "error: \(e.description)")
                default:       r.finish(status: 1, output: "error: \(e.description)")
                }
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
                // A success needs no card: the status shows the result
                // ("Last synced just now"). A refusal stays until dismissed.
                if status == 0 {
                    if r.progress.gameCrashed {
                        self.notice = "The game crashed during your last session. Your saves were still sent to the hub."
                    }
                    withAnimation(.easeOut(duration: 0.25)) { self.run = nil }
                }
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
        case .inSync:           return "Up to date"
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
            return "This Mac has the same saves as the hub. Play whenever you like."
        case .hubOnly:
            return "Another Mac played since this one last synced. Playing here copies its saves to this Mac first."
        case .firstSeed:
            return "Playing here copies your saves from the hub first."
        case .localOnly:
            return "This Mac has saves the hub doesn't have yet. They are sent when you finish playing, or right now with Send."
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

    var body: some View {
        // A fixed-size window. The centre holds the status, or while an
        // action runs, what is happening and its steps; both sides sit in
        // a strip at the bottom. The health check replaces all of it, in
        // the same window, with a Back button.
        Group {
            if d.showingHealth {
                HealthPage()
            } else {
                // Fits in the fixed window in every normal state; only an
                // unusual pile-up of problem cards scrolls.
                ViewThatFits(in: .vertical) {
                    main
                    ScrollView { main.frame(minHeight: 420) }
                }
            }
        }
        .frame(width: 480, height: 420)
        .navigationTitle("Star Traders Sync")
        .navigationSubtitle(d.status.map { $0.isHub ? "This Mac is the hub" : "Hub: \($0.hub.host)" } ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { d.refresh() } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .help("Check again")
                .disabled(d.loading || d.busy)

                Menu {
                    Button("Health check") {
                        withAnimation(.easeOut(duration: 0.2)) { d.showingHealth = true }
                        d.runDoctor()
                    }
                    Button("Open logs") { d.openLogs() }
                    Divider()
                    Button("Run setup again…") { app.showSetup() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .onAppear { d.start() }
        .onDisappear { d.stop() }
        .alert(d.pending?.confirmation?.title ?? "",
               isPresented: Binding(get: { d.pending != nil }, set: { if !$0 { d.pending = nil } }),
               presenting: d.pending) { b in
            Button(b.confirmation?.button ?? "Continue") { d.perform(b) }
            Button("Cancel", role: .cancel) { d.pending = nil }
        } message: { b in
            Text(b.confirmation?.message ?? "")
        }
        .animation(.easeOut(duration: 0.25), value: d.run?.id)
    }

    var main: some View {
        VStack(spacing: 14) {
            // A failed run keeps its own card ("Stopped, nothing was lost",
            // and how far it got). A status refusal shows too, unless it is
            // the same problem again: a Play that failed because the hub is
            // offline is followed by a status check failing the same way.
            if let r = d.run, r.ended, r.problem != nil {
                ActivityCard(run: r)
            }
            if SyncProblem.showStatusProblem(d.problem, besideRunProblem: d.run?.problem), let p = d.problem {
                ProblemCard(problem: p)
            }
            Group {
                if let r = d.run, !r.ended {
                    RunHero(run: r)
                } else if let s = d.status {
                    Hero(status: s)
                } else if d.problem == nil {
                    ProgressView().controlSize(.regular)
                }
            }
            .frame(maxHeight: .infinity)
            if let s = d.status, !d.busy {
                // Its own height, never the leftover space. Hidden while an
                // action runs, whose steps need the room more.
                SidesStrip(status: s)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .transition(.opacity)
    }
}

/// The centre of the window while an action runs: what is happening now,
/// in place of a status that is about to change.
struct RunHero: View {
    @ObservedObject var run: ActionRun

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: run.action == .play ? "gamecontroller.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 50, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .padding(.top, 8)
            Text(headline)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            StepList(run: run)
                .padding(.top, 6)
            if run.progress.gameCrashed {
                Label("The game crashed. Your saves are still sent to the hub.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
    }

    var headline: String {
        switch run.action {
        case .play:
            if run.progress.current >= 3 { return "Sending your saves" }
            return run.progress.gameClosed && run.progress.current == 2 ? "Game closed" : "Playing Star Traders"
        case .resetRecord: return "Resetting"
        default:           return "Syncing"
        }
    }

    var subtitle: String {
        switch run.action {
        case .play:
            switch run.progress.current {
            case 0:  return "Getting the latest saves from the hub first."
            case 1:  return "Starting the game."
            case 2 where run.progress.gameClosed:
                     return "Making sure the game has really closed, then your saves go to the hub. A few seconds."
            case 2:  return "Have fun. When you quit the game, your saves are sent to the hub by themselves. Keep this app open until then."
            default: return "Almost done. Your saves are on their way to the hub."
            }
        default:
            return "This takes a few seconds. Every overwrite keeps a safety copy first."
        }
    }
}

/// The centre of the window: what is going on, in one line, and the one
/// thing to do about it.
struct Hero: View {
    @EnvironmentObject var d: DashboardModel
    let status: SyncStatus

    var body: some View {
        let v = status.decision
        VStack(spacing: 12) {
            Image(systemName: v.symbol)
                .font(.system(size: 54, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(v.tint)
                .padding(.top, 8)
            Text(v.headline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(v.explanation)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            if d.run == nil || d.run?.ended == true {
                ActionButtons(plan: SyncActions.plan(for: status))
                    .padding(.top, 8)
            }

            VStack(spacing: 4) {
                if let last = status.lastSync {
                    Text("Last synced \(relative(last.date)) · \(last.direction == "push" ? "sent to the hub" : "from the hub")")
                } else {
                    Text("This Mac has not synced yet")
                }
                if status.gameRunning {
                    Label("Star Traders is running", systemImage: "gamecontroller")
                }
                if status.hubLock != nil {
                    Label("\(SyncProblem.lockHolder(status.hubLock) ?? "Another Mac") is syncing right now",
                          systemImage: "lock")
                }
                if let note = d.notice {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(note).multilineTextAlignment(.leading)
                        Button { d.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                    }
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 400)
                    .padding(.top, 4)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Both sides in one slim strip: always visible, never resizing anything.
struct SidesStrip: View {
    @EnvironmentObject var d: DashboardModel
    let status: SyncStatus

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                column(title: "This Mac", name: status.machine, side: status.sides.local)
                Divider().padding(.vertical, 4)
                column(title: status.isHub ? "Hub (this Mac)" : "Hub", name: status.hub.host, side: status.sides.hub)
            }
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
            if let at = d.checkedAt {
                Text("Checked \(relative(at))").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    func column(title: String, name: String, side: SyncStatus.Side) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            Text(name).font(.caption).foregroundStyle(.secondary)
            Group {
                if side.files == 0 {
                    Text("No saves")
                } else {
                    Text("\(side.campaignSaves) campaign\(side.campaignSaves == 1 ? "" : "s")")
                    Text("played \(relative(side.newestDate))")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
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

/// The health check, inside the main window.
struct HealthPage: View {
    @EnvironmentObject var d: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Back, title and Check again on one row.
            ZStack {
                Text("Health check").font(.headline)
                HStack {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { d.showingHealth = false }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Check again") { d.runDoctor() }
                        .controlSize(.small)
                        .disabled(d.doctor.running)
                }
            }
            // Collapsed sections are one line each, so the whole report
            // fits without scrolling; an opened problem may scroll.
            ViewThatFits(in: .vertical) {
                DoctorProgressView(run: d.doctor)
                ScrollView { DoctorProgressView(run: d.doctor).padding(.trailing, 8) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .transition(.opacity)
    }
}
