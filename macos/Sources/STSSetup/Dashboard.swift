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

    // Health check sheet
    @Published var doctorLines: [DoctorLine] = []
    @Published var doctorRunning = false
    @Published var doctorPassed: Bool?

    private var timer: Timer?

    var script: String { layout.effectiveScript.path }

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
        guard !loading else { return }
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

    func runDoctor() {
        doctorLines = []
        doctorRunning = true
        doctorPassed = nil
        let script = self.script
        Task.detached {
            let status = Shell.stream("/bin/bash", [script, "doctor", "--fix"]) { line in
                Task { @MainActor in self.doctorLines.append(DoctorLine(line)) }
            }
            await MainActor.run {
                self.doctorRunning = false
                self.doctorPassed = status == 0
            }
        }
    }

    func openLogs() {
        let logs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/star-traders-sync")
        NSWorkspace.shared.open(logs)
    }
}

// MARK: - presentation

extension SyncStatus.Verdict {
    var headline: String {
        switch self {
        case .inSync:     return "In sync"
        case .hubNewer:   return "The hub has newer saves"
        case .localNewer: return "This Mac has newer saves"
        case .hubEmpty:   return "The hub has no saves yet"
        case .localEmpty: return "This Mac has no saves yet"
        case .differ:     return "The saves differ"
        }
    }

    var explanation: String {
        switch self {
        case .inSync:     return "This Mac and the hub have exactly the same saves."
        case .hubNewer:   return "Another Mac played since this one last synced. Its saves are copied here when you next play."
        case .localEmpty: return "Your saves are copied here from the hub when you next play."
        case .localNewer: return "This Mac has saves the hub does not have yet. They are sent to the hub after you play."
        case .hubEmpty:   return "Send this Mac's saves to the hub to start syncing."
        case .differ:     return "The saves differ but were changed at the same time. Check which ones to keep."
        }
    }

    var symbol: String {
        switch self {
        case .inSync:                 return "checkmark.circle.fill"
        case .hubNewer, .localEmpty:  return "arrow.down.circle.fill"
        case .localNewer, .hubEmpty:  return "arrow.up.circle.fill"
        case .differ:                 return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .inSync:                 return .green
        case .hubNewer, .localEmpty:  return .blue
        case .localNewer, .hubEmpty:  return .orange
        case .differ:                 return .yellow
        }
    }
}

func relative(_ date: Date?) -> String {
    guard let date else { return "never" }
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
            Button { d.refresh() } label: {
                if d.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Check again")
            .disabled(d.loading)
            Menu {
                Button("Health check…") { showDoctor = true; d.runDoctor() }
                Button("Open logs") { d.openLogs() }
                Divider()
                Button("Run setup again…") { app.showSetup() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
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
        let v = status.verdict
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Health check").font(.title2).bold()
            if d.doctorRunning {
                StatusRow(state: .busy, text: "Checking…")
            } else if d.doctorPassed == true {
                StatusRow(state: .ok, text: "Everything checks out.")
            } else if d.doctorPassed == false {
                StatusRow(state: .fail, text: "Something needs fixing. Each problem below says what to do.")
            }
            ScrollView {
                DoctorOutput(lines: d.doctorLines)
            }
            HStack {
                Spacer()
                Button("Check again") { d.runDoctor() }.disabled(d.doctorRunning)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 520)
    }
}
