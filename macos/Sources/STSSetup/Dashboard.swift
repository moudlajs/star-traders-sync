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
    /// The check now running was asked for (the refresh button, Try
    /// again). Only then does the toolbar show a spinner: the checks the
    /// app starts itself, on coming forward and every minute, are silent.
    @Published private(set) var manualCheck = false
    @Published var checkedAt: Date?

    let doctor = DoctorRun()

    /// The action running now, or the last one until dismissed.
    @Published var run: ActionRun?
    /// An action waiting for the user to confirm it.
    @Published var pending: ActionButton?

    var busy: Bool { run.map { !$0.ended } ?? false }

    /// The green "Synced" moment after a successful action, before Play
    /// comes back (board F).
    @Published var justSynced: SyncAction?

    /// The health check opens inside the main window, not as a sheet.
    @Published var showingHealth = false

    /// Something worth knowing about a run that otherwise succeeded, such
    /// as the game crashing (the saves were still sent). Shown under the
    /// status until dismissed or the next action.
    @Published var notice: String?

    /// #87: sync by itself when that cannot overwrite anything
    /// unconfirmed (SyncActions.automatic). On unless switched off.
    @Published var autoSync: Bool = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: "autoSync")
            SetupLog.write("automatic sync \(autoSync ? "on" : "off")")
            if autoSync, let s = status { considerAutoSync(s) }
        }
    }
    /// The situation an automatic sync last failed in, so it is not
    /// retried against the very same state until something changes.
    private(set) var autoFailedKey: String?
    private var autoFailedAt: Date?
    /// A failed automatic sync is not retried against the same situation
    /// for this long; a network blip then heals on its own.
    static let autoRetryAfter: TimeInterval = 600

    // Seams for tests: the script calls and the clock. The app uses the
    // defaults; DashboardModelTests swap in fakes.
    var fetchStatus: (String) -> Result<SyncStatus, SyncProblem> = { StatusClient.fetch(script: $0) }
    var runScript: (String, [String], @escaping (String) -> Void) -> Int32 = { script, args, onLine in
        Shell.stream("/bin/bash", [script] + args, onLine: onLine)
    }
    var now: () -> Date = Date.init
    /// Keeps the app's script current before each check (#101). Tests make
    /// it a no-op, so they never touch the real Application Support copy.
    var refreshScript: (InstallLayout) -> Void = { DashboardModel.refreshAppScript(layout: $0, when: "check") }
    /// A button pressed while a status check was running. Status and every
    /// action share this Mac's lock, so it runs as soon as the check ends,
    /// and only if the situation is still the one it was pressed for.
    private var queued: ActionButton?
    private var activeObserver: NSObjectProtocol?

    private var timer: Timer?

    /// The app's own copy, kept current by Installer.refreshAppScript,
    /// never the ~/bin link, which may be an older repo checkout.
    var script: String { layout.installedScript.path }

    func start() {
        active = true
        refresh()
        // Coming back to the app is when the user wants to see, and have,
        // the latest; do not wait for the next minute tick.
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        // Cheap enough to poll: status is read-only and takes about a
        // second. Once a minute keeps "last synced" honest without
        // hammering the hub.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Stops everything that could start a check, or an automatic sync, on
    /// its own: the minute timer and the came-to-front observer. Setup
    /// calls this before it rewrites the config and script.
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

    func refresh(manual: Bool = false) {
        // While sts runs it holds this Mac's lock, and status would only
        // report "a sync is already running". The run's own card says more.
        // Nor while a confirmation is open: the dialog describes the status
        // it was opened for, and the script is pinned to that decision.
        // And never while setup is showing (stop() clears active): a run
        // finishing then must not check a config setup is rewriting.
        guard active, !loading, !busy, pending == nil else { return }
        loading = true
        manualCheck = manual
        let script = self.script
        let layout = self.layout
        // Taken here, called in the detached task: calling the stored
        // closures through self would run them on the main actor.
        let fetch = self.fetchStatus
        let refreshScript = self.refreshScript
        Task.detached {
            // Off the main thread: two file reads, and pgrep.
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
                        // Only if the fresh status would still offer this very
                        // button, unblocked: same decision, and no game or
                        // other Mac in the way now.
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
                        // Dropping it is the safe choice; say so, rather than
                        // let the press seem to vanish.
                        self.notice = "\(q.label) was not started, because of the problem above."
                    }
                    self.queued = nil
                    self.problem = p
                    // Keep the last good status on screen for a transient
                    // refusal, such as another Mac syncing right now.
                    if ![50, 51, 52].contains(p.code) { self.status = nil }
                }
            }
        }
    }

    // MARK: actions

    /// False while setup is showing (AppModel sets it), so a status check
    /// already in flight when setup opened cannot start a sync.
    var active = true
    /// True while an update installs: nothing may start, because the app
    /// is about to restart (UpdateModel sets and clears it).
    var updating = false

    func considerAutoSync(_ s: SyncStatus) {
        // !loading: a check in flight holds this Mac's lock, and a sync
        // started now would fail on it and be remembered as a failure.
        guard active, !updating, autoSync, !loading, !busy, pending == nil, run == nil,
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
        // The one gate every action passes: nothing starts while setup is
        // showing, whatever path led here (a queued press, an automatic
        // sync, a confirmation answered late).
        guard active, !updating, !busy else { return }
        pending = nil
        let r = ActionRun(action: action, automatic: automatic)
        run = r
        notice = nil
        justSynced = nil
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
                // A success needs no card: the status shows the result
                // ("Last synced just now"). A refusal stays until dismissed.
                if automatic {
                    // Remember a failure so the same state is not retried in
                    // a loop; any change in either side clears it.
                    self.autoFailedKey = status == 0 ? nil : situation
                    self.autoFailedAt = status == 0 ? nil : self.now()
                }
                if status == 0 {
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
        .navigationSubtitle(d.status.map { $0.isHub ? "This Mac is the Hub" : "Hub: \($0.hub.host)" } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                UpdateButton(updates: updates)
            }
            ToolbarItem(placement: .primaryAction) {
                // One control for automatic sync, always in view, state
                // readable at a glance, like Tailscale's switch (#119).
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
                    Button("Open logs") { d.openLogs() }
                    Divider()
                    Toggle("Show in menu bar", isOn: $showInMenuBar)
                    Button("Run setup again…") { app.showSetup() }
                        .disabled(d.busy)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .menuIndicator(.hidden)
                .help("Settings")
            }
        }
        // Started here, and not stopped when the window closes: with the
        // menu bar icon the app keeps checking and syncing without it
        // (#91). Setup stops it (AppModel.showSetup).
        .onAppear { d.start() }
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
