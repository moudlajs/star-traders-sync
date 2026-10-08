import ServiceManagement
import STSSetupCore
import SwiftUI

/// The menu bar popover (#91); automatic sync keeps running while only this is showing.
struct MenuBarView: View {
    @EnvironmentObject var d: DashboardModel
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var login = LoginItem()

    var state: MenuBarState { MenuBarState.of(status: d.status, busy: d.busy, problem: d.problem != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.system(size: 13, weight: .bold))
                    Text(subline).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            primary

            if let s = d.status {
                VStack(spacing: 6) {
                    side("This Mac", s.sides.local)
                    side("Hub", s.sides.hub)
                }
                .font(.system(size: 12))
            }

            Divider()

            Toggle("Sync automatically", isOn: $d.autoSync)
            Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
            if let why = login.problem {
                Text(why).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                menuLink("Open Star Traders Sync…") { showWindow() }
                menuLink("Health check") {
                    showWindow()
                    d.showingHealth = true
                    d.runDoctor()
                }
                menuLink("Quit") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 300)
        .onAppear { login.reload() }
    }

    // MARK: words

    var headline: String {
        if let r = d.run, !r.ended {
            return r.action == .play && r.progress.current == 2 ? "Playing Star Traders" : "Syncing…"
        }
        if d.problem != nil { return "Needs you" }
        return d.status?.decision.headline ?? state.title
    }

    var subline: String {
        guard let s = d.status else { return d.problem?.title ?? "Checking with the Hub…" }
        if let p = d.problem { return p.title }
        let hub = s.isHub ? "This Mac is the Hub" : "Hub: \(s.hub.host)"
        if let last = s.lastSync { return "Synced \(relative(last.date)) · \(hub)" }
        return hub
    }

    var dotColor: Color {
        switch state {
        case .upToDate: return .green
        case .syncing:  return .blue
        case .willSync: return .blue.opacity(0.6)
        case .needsYou: return .orange
        case .checking: return .secondary
        }
    }

    // MARK: the one button

    @ViewBuilder var primary: some View {
        let plan = d.status.map { SyncActions.plan(for: $0) }
        // Only a Play that runs straight away: a confirmation left pending in the window would hold every check.
        if let play = plan?.buttons.first(where: { $0.action == .play && $0.confirmation == nil }),
           plan?.blockedBecause == nil, !d.busy {
            Button { d.tapped(play) } label: {
                Label("Play Star Traders", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else if state == .needsYou {
            Button { showWindow() } label: {
                Text("Open to choose…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    func side(_ title: String, _ side: SyncStatus.Side) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(side.files == 0 ? "No saves"
                 : "\(side.campaignSaves) campaign\(side.campaignSaves == 1 ? "" : "s") · \(relative(side.newestDate))")
        }
    }

    func menuLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }

    func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The icon in the menu bar: one shape per state.
struct MenuBarIcon: View {
    @EnvironmentObject var d: DashboardModel

    var body: some View {
        let state = MenuBarState.of(status: d.status, busy: d.busy, problem: d.problem != nil)
        Image(systemName: state.symbol)
            .accessibilityLabel("Star Traders Sync: \(state.title)")
    }
}

/// Open at login via SMAppService; the system owns the setting, so it is read back, never cached.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var problem: String?

    func reload() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        problem = status == .requiresApproval
            ? "Allow it in System Settings › General › Login Items." : nil
    }

    func set(_ on: Bool) {
        var failure: String?
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            SetupLog.write("open at login \(on ? "on" : "off")")
        } catch {
            SetupLog.write("open at login: \(error.localizedDescription)")
            failure = "Could not change this: \(error.localizedDescription)"
        }
        reload()
        if let failure { problem = failure }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
