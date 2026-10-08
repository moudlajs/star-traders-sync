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
    /// The running check was asked for (refresh, Try again); only then does the toolbar spin, self-started checks are silent.
    @Published private(set) var manualCheck = false
    @Published var checkedAt: Date?

    let doctor = DoctorRun()

    @Published var run: ActionRun?
    @Published var pending: ActionButton?

    var busy: Bool { run.map { !$0.ended } ?? false }

    @Published var justSynced: SyncAction?

    @Published var showingHealth = false
    @Published var showingRestore = false
    /// Set by a restore: nothing automatic runs until the user acts, so restored saves are not sent over the Hub; survives relaunch.
    @Published private(set) var autoHeldAfterRestore: Bool = UserDefaults.standard.bool(forKey: DashboardModel.holdKey) {
        didSet { UserDefaults.standard.set(autoHeldAfterRestore, forKey: Self.holdKey) }
    }
    nonisolated static let holdKey = "autoHeldAfterRestore"
    static let holdNotice = "Automatic sync is waiting for you: the restored saves go to the Hub when you Send or Play."

    /// Something worth knowing about a run that otherwise succeeded, e.g. the game crashing after the saves were sent.
    @Published var notice: String?

    /// #87: sync by itself only when that cannot overwrite anything unconfirmed (SyncActions.automatic).
    @Published var autoSync: Bool = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: "autoSync")
            SetupLog.write("automatic sync \(autoSync ? "on" : "off")")
            if autoSync, let s = status { considerAutoSync(s) }
        }
    }
    /// The situation an automatic sync last failed in, so it is not retried until something changes.
    private(set) var autoFailedKey: String?
    private var autoFailedAt: Date?
    static let autoRetryAfter: TimeInterval = 600

    // Seams for tests: the script calls and the clock; DashboardModelTests swap in fakes.
    var fetchStatus: (String) -> Result<SyncStatus, SyncProblem> = { StatusClient.fetch(script: $0) }
    var fetchSafetyCopies: (String) -> Result<[SafetyCopy], SyncProblem> = { script in
        let r = Shell.run("/bin/bash", [script, "restore", "--json"])
        guard r.ok else { return .failure(SyncProblem.from(code: r.status, stderr: r.stderr)) }
        do { return .success(try SafetyCopy.list(from: Data(r.stdout.utf8))) }
        catch { return .failure(SyncProblem.from(code: 1, stderr: "error: could not read the list of safety copies")) }
    }
    var runScript: (String, [String], @escaping (String) -> Void) -> Int32 = { script, args, onLine in
        Shell.stream("/bin/bash", [script] + args, onLine: onLine)
    }
    var now: () -> Date = Date.init
    /// Keeps the app's script current before each check (#101); a no-op in tests, so they never touch the real copy.
    var refreshScript: (InstallLayout) -> Void = { DashboardModel.refreshAppScript(layout: $0, when: "check") }
    /// A press made during a status check; runs when the check ends, only if the situation is still the one it was pressed for.
    private var queued: ActionButton?
    private var activeObserver: NSObjectProtocol?

    private var timer: Timer?

    /// The app's own copy, never the ~/bin link, which may be an older repo checkout.
    var script: String { layout.installedScript.path }

    func start() {
        active = true
        if autoHeldAfterRestore && notice == nil { notice = Self.holdNotice }
        refresh()
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        // Status is read-only and about a second; once a minute keeps "last synced" honest without hammering the hub.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Stops everything that could start a check or automatic sync on its own; setup calls this before rewriting the config.
    func stop() {
        active = false
        queued = nil
        pending = nil
        notice = nil
        timer?.invalidate()
        timer = nil
        if let o = activeObserver {
            NotificationCenter.default.removeObserver(o)
            activeObserver = nil
        }
    }

    /// Brings the app's script copy up to date; retried before every check, since replacing it is refused while sts runs.
    nonisolated static func refreshAppScript(layout: InstallLayout, when: String) {
        let bundled = WizardModel.locate("star-traders-sync", repoPath: "bin/star-traders-sync")
        let result = Installer.refreshAppScript(bundledScript: bundled,
                                                bundledExample: WizardModel.locate("config.example", repoPath: "config.example"),
                                                layout: layout)
        if when == "launch" || result != .unchanged {
            SetupLog.write("\(when): app script \(result.logText) (\(bundled?.path ?? "nothing bundled"))")
        }
    }

    func refresh(manual: Bool = false) {
        // Not while sts runs (it holds the lock), a confirmation is open (pinned to that status), or setup is showing.
        guard active, !loading, !busy, pending == nil else { return }
        loading = true
        manualCheck = manual
        let script = self.script
        let layout = self.layout
        // Captured here: calling the stored closures through self would run them on the main actor.
        let fetch = self.fetchStatus
        let refreshScript = self.refreshScript
        Task.detached {
            refreshScript(layout)
            let r = fetch(script)
            await MainActor.run {
                self.loading = false
                self.manualCheck = false
                self.checkedAt = Date()
                switch r {
                case .success(let s):
                    self.status = s
                    self.problem = nil
                    if let q = self.queued {
                        self.queued = nil
                        // Only if the fresh status would still offer this very button, unblocked.
                        if SyncActions.stillOffered(q, for: s) {
                            self.tapped(q)
                        } else {
                            self.notice = "\(q.label) was not started: the situation changed. Here it is now."
                        }
                    } else {
                        self.considerAutoSync(s)
                    }
                case .failure(let p):
                    if let q = self.queued {
                        // Dropping it is the safe choice; say so, rather than let the press seem to vanish.
                        self.notice = "\(q.label) was not started, because of the problem above."
                    }
                    self.queued = nil
                    self.problem = p
                    // Keep the last good status on screen for a transient refusal, such as another Mac syncing.
                    if ![50, 51, 52].contains(p.code) { self.status = nil }
                }
            }
        }
    }

    // MARK: actions

    /// False while setup is showing, so a status check already in flight cannot start a sync.
    var active = true
    /// True while an update installs: nothing may start, the app is about to restart.
    var updating = false

    func considerAutoSync(_ s: SyncStatus) {
        // !loading: a check in flight holds this Mac's lock, and a sync started now would fail and be remembered as a failure.
        guard active, !updating, autoSync, !autoHeldAfterRestore, !loading, !busy, pending == nil, run == nil,
              let b = SyncActions.automatic(for: s) else { return }
        let key = SyncActions.situationKey(s)
        if key == autoFailedKey, let at = autoFailedAt, now().timeIntervalSince(at) < Self.autoRetryAfter {
            return
        }
        SetupLog.write("automatic: \(b.action.rawValue) for \(s.decision.rawValue)")
        perform(b, automatic: true, situation: key)
    }

    func tapped(_ button: ActionButton) {
        guard active else { return }
        if loading {
            queued = button
            return
        }
        if button.confirmation != nil {
            pending = button
        } else {
            perform(button)
        }
    }

    func perform(_ button: ActionButton, automatic: Bool = false, situation: String? = nil) {
        let action = button.action
        // The one gate every action passes: nothing starts while setup is showing or an update installs.
        guard active, !updating, !busy else { return }
        pending = nil
        // A restore holds automatic sync from the moment it starts: a failed or cut-short restore may still have changed the saves.
        if action == .restore { autoHeldAfterRestore = true }
        else if !automatic { autoHeldAfterRestore = false }
        let r = ActionRun(action: action, automatic: automatic)
        run = r
        notice = nil
        justSynced = nil
        let script = self.script

        if action == .resetRecord {
            // resetRecord: the documented manual fix for a diverged state, under the script's own local lock.
            do {
                if let aside = try SyncRecord.reset(expectedEpoch: .some(button.expectedRecordEpoch)) {
                    SetupLog.write("action: resetRecord moved the record to \(aside.path)")
                    r.finish(status: 0, output: "")
                } else {
                    // Not a success: nothing was reset, so say so rather than show a tick.
                    let path = SyncRecord.defaultStateDir.appendingPathComponent("last-sync.json").path
                    SetupLog.write("action: resetRecord found no record at \(path)")
                    r.finish(status: 1, output: "error: there is no sync record at \(path) to reset")
                }
            } catch let e as SyncRecord.ResetError {
                // 52 is the script's "another sts is running" code, so the card explains it the same way.
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
        guard let args = button.scriptArguments else {
            r.finish(status: 2, output: "error: no safety copy was chosen")
            return
        }

        SetupLog.write("action: \(action.rawValue) (\(args.joined(separator: " ")))")
        let run = self.runScript
        Task.detached {
            var output: [String] = []
            let status = run(script, args) { line in
                output.append(line)
                Task { @MainActor in r.feed(line) }
            }
            let all = output.joined(separator: "\n")
            await MainActor.run {
                SetupLog.write("action: \(action.rawValue) exited \(status)")
                r.finish(status: status, output: all)
                // A success needs no card: the status shows the result; a refusal stays until dismissed.
                if automatic {
                    // Remember a failure so the same state is not retried in a loop; any change on either side clears it.
                    self.autoFailedKey = status == 0 ? nil : situation
                    self.autoFailedAt = status == 0 ? nil : self.now()
                }
                if status == 0 {
                    if action == .restore { self.notice = Self.holdNotice }
                    if r.progress.gameCrashed {
                        self.notice = "The game crashed during your last session. Your saves were still sent to the Hub."
                    }
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.run = nil
                        self.justSynced = action
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if self.justSynced == action, self.run == nil {
                            withAnimation(.easeOut(duration: 0.3)) { self.justSynced = nil }
                        }
                    }
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
    @EnvironmentObject var updates: UpdateModel
    @EnvironmentObject var d: DashboardModel
    @AppStorage(MenuBarPreference.key) private var showInMenuBar = true
    @State private var confirmingDisconnect = false

    var body: some View {
        Group {
            if d.showingHealth {
                HealthPage()
            } else {
                // Fits the fixed window in every normal state; only a pile-up of problem cards scrolls.
                ViewThatFits(in: .vertical) {
                    main
                    ScrollView { main.frame(minHeight: 420) }
                }
            }
        }
        .frame(width: 480, height: 420)
        .navigationTitle("Star Traders Sync")
        .navigationSubtitle(d.status.map { $0.isHub ? "This Mac is the Hub" : "Hub: \($0.hub.host)" } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                UpdateButton(updates: updates)
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    Text("Auto sync").font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("Auto sync", isOn: $d.autoSync)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .help(d.autoSync ? "Syncing automatically whenever it is safe" : "Automatic sync is off")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { d.refresh(manual: true) } label: {
                    if d.loading && d.manualCheck {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                }
                .help("Check again")
                .disabled(d.busy)

                Menu {
                    Text("Star Traders Sync \(updates.currentVersion)")
                    Divider()
                    Button("Health check") {
                        withAnimation(.easeOut(duration: 0.2)) { d.showingHealth = true }
                        d.runDoctor()
                    }
                    Button("Restore previous saves…") { d.showingRestore = true }
                        .disabled(d.busy)
                    Button("Open logs") { d.openLogs() }
                    Divider()
                    Toggle("Show in menu bar", isOn: $showInMenuBar)
                    Button("Change hub, account or backup disk…") { app.showSetup() }
                        .disabled(d.busy)
                    Button("Disconnect this Mac…") { confirmingDisconnect = true }
                        .disabled(d.busy)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .menuIndicator(.hidden)
                .help("Settings")
            }
        }
        // Not stopped when the window closes: with the menu bar icon the app keeps syncing without it (#91).
        .onAppear { d.start() }
        .alert(d.pending?.confirmation?.title ?? "",
               isPresented: Binding(get: { d.pending != nil }, set: { if !$0 { d.pending = nil } }),
               presenting: d.pending) { b in
            Button(b.confirmation?.button ?? "Continue") { d.perform(b) }
            Button("Cancel", role: .cancel) { d.pending = nil }
        } message: { b in
            Text(b.confirmation?.message ?? "")
        }
        .sheet(isPresented: $d.showingRestore) { RestoreSheet() }
        .alert("Disconnect this Mac?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { app.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac stops syncing. The sts command and the settings are removed (the settings are kept as a backup). Your saves, their safety copies and the Hub are not touched, and running setup again connects it back.")
        }
        .animation(.easeOut(duration: 0.25), value: d.run?.id)
    }

    var main: some View {
        VStack(spacing: 14) {
            // A failed run keeps its own card; a status refusal shows too unless it is the same problem again.
            if let r = d.run, r.ended, r.problem != nil {
                ActivityCard(run: r)
            }
            if SyncProblem.showStatusProblem(d.problem, besideRunProblem: d.run?.problem), let p = d.problem {
                ProblemCard(problem: p)
            }
            Group {
                if let r = d.run, !r.ended {
                    MainHero(screen: .running(r))
                } else if let a = d.justSynced {
                    MainHero(screen: .justSynced(a))
                } else if let s = d.status {
                    MainHero(screen: .status(s))
                } else if d.problem == nil {
                    ProgressView().controlSize(.regular)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.25), value: d.justSynced)
            if let s = d.status {
                SidesStrip(status: s)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .transition(.opacity)
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
            if let note = d.notice {
                Text(note).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Try again") { d.refresh(manual: true) }
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
