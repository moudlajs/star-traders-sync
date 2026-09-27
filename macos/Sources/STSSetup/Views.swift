import STSSetupCore
import SwiftUI

@main
struct STSSetupApp: App {
    @StateObject private var model = WizardModel()

    init() {
        // A bare executable (swift run) starts as a background process.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Star Traders Sync Setup") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 540)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 190)
                .background(.bar)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    page
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
                Divider()
                BottomBar().padding(16)
            }
        }
    }

    @ViewBuilder var page: some View {
        switch m.step {
        case .welcome:   WelcomePage()
        case .tailscale: TailscalePage()
        case .role:      RolePage()
        case .connect:   ConnectPage()
        case .install:   InstallPage()
        case .check:     CheckPage()
        case .done:      DonePage()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Star Traders Sync")
                .font(.headline)
                .padding(.bottom, 8)
            ForEach(m.steps) { s in
                let current = s == m.step
                let passed = (m.steps.firstIndex(of: s) ?? 0) < (m.steps.firstIndex(of: m.step) ?? 0)
                HStack(spacing: 8) {
                    Image(systemName: passed ? "checkmark.circle.fill" : current ? "circle.inset.filled" : "circle")
                        .foregroundStyle(passed ? Color.green : current ? Color.accentColor : Color.secondary)
                    Text(s.title)
                        .fontWeight(current ? .semibold : .regular)
                        .foregroundStyle(current ? .primary : .secondary)
                }
            }
            Spacer()
            Text("sync tool \(m.scriptVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct BottomBar: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        HStack {
            if m.step != .welcome && m.step != .done {
                Button("Back") { m.back() }
                    .disabled(m.installBusy || m.doctorRunning || m.connectBusy)
            }
            Spacer()
            if m.step == .done {
                Button("Close") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(m.step == .welcome ? "Start" : "Continue") { m.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!m.canContinue)
            }
        }
    }
}

// MARK: - pieces

struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle).bold()
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }
}

struct StatusRow: View {
    enum State { case ok, warn, fail, busy }
    let state: State
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch state {
            case .ok:   Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .busy: ProgressView().controlSize(.small)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

struct CommandBox: View {
    @EnvironmentObject var m: WizardModel
    let command: String

    var body: some View {
        HStack {
            Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button { m.copy(command) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }
}

// MARK: - pages

struct WelcomePage: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        PageTitle(title: "Sync your Star Traders saves",
                  subtitle: "This sets up star-traders-sync on this Mac, so you can play on any of your Macs and always pick up where you left off.")
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works").font(.headline)
            Text("One Mac, the **hub**, keeps the master copy of your saves. Every time you play, the sync tool fetches the saves from the hub first and sends them back when you quit the game. Your Macs reach each other through **Tailscale**, so it works on any network.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Set up the hub Mac first, then each Mac you play on. It takes a few minutes per Mac. Nothing here touches your save files.")
                .fixedSize(horizontal: false, vertical: true)

            if let v = m.existingConfig {
                Card {
                    StatusRow(state: .ok, text: "This Mac is already set up, with the hub on **\(v.hubHost)**. Going through again keeps your settings unless you change them, and backs up the old config first.")
                }
            }
            if m.bundledScript == nil {
                StatusRow(state: .fail, text: "The sync tool is missing from this app. Download the app again.")
            }
        }
    }
}

struct TailscalePage: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        PageTitle(title: "Tailscale",
                  subtitle: "Tailscale is a free app that lets your Macs find each other securely, at home or away. Every Mac you sync needs it, logged in to the same account.")
        VStack(alignment: .leading, spacing: 14) {
            if m.tsChecking {
                StatusRow(state: .busy, text: "Checking Tailscale…")
            } else if let s = m.tsStatus, s.running, let me = s.me {
                StatusRow(state: .ok, text: "Tailscale is running. This Mac is **\(me.nodeName)**.")
                let macs = s.peers.filter { $0.os == "macOS" }
                if macs.isEmpty {
                    StatusRow(state: .warn, text: "No other Macs are on your Tailscale yet. That is fine if this will be the hub. Otherwise, set up Tailscale on the other Mac with the same account.")
                } else {
                    Text("Other Macs on your Tailscale:").foregroundStyle(.secondary)
                    ForEach(macs) { p in
                        StatusRow(state: p.online ? .ok : .warn,
                                  text: "\(p.nodeName)\(p.online ? "" : " (offline)")")
                    }
                }
            } else {
                StatusRow(state: .fail, text: m.tsError ?? "Tailscale is not ready.")
                HStack {
                    if Tailscale.findBinary() == nil {
                        Button("Get Tailscale") { m.openURL("https://tailscale.com/download/mac") }
                    } else if FileManager.default.fileExists(atPath: "/Applications/Tailscale.app") {
                        Button("Open Tailscale") { m.openURL("file:///Applications/Tailscale.app") }
                    }
                    Button("Check again") { m.checkTailscale() }
                }
            }
        }
    }
}

struct RolePage: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        PageTitle(title: "Your Macs",
                  subtitle: "Choose the hub: the Mac that is on most of the time. It keeps the master copy of your saves.")
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $m.role) {
                Text("Another Mac is the hub").tag(Role.client)
                Text("This Mac is the hub").tag(Role.hub)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: m.role) { _ in m.applyDefaultHubPath() }

            if m.role == .client { clientForm } else { hubForm }

            if !m.saveFolderExists {
                StatusRow(state: .warn, text: "Star Traders has not been started on this Mac yet, so it has no save folder. That is fine: start the game once before your first sync.")
            }
            ForEach(m.problems, id: \.self) { StatusRow(state: .fail, text: $0) }
        }
    }

    @ViewBuilder var clientForm: some View {
        Card {
            Text("Which Mac is the hub?").font(.headline)
            let candidates = m.tsStatus?.hubCandidates ?? []
            if candidates.isEmpty {
                StatusRow(state: .warn, text: "No other Macs are on your Tailscale. Set up the hub Mac first.")
            } else {
                Picker("Hub", selection: $m.selectedHubID) {
                    ForEach(candidates) { p in
                        Text("\(p.nodeName)\(p.online ? "" : " (offline)")\(p.os == "macOS" ? "" : " – \(p.os)")")
                            .tag(Optional(p.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
        }
        Card {
            Text("Your account on the hub").font(.headline)
            Text("The short account name on the hub Mac, the one its home folder is named after (/Users/**name**).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("account name", text: $m.hubUser)
                .frame(maxWidth: 320)
                .onChange(of: m.hubUser) { _ in m.applyDefaultHubPath() }
            Text("Hub folder on that Mac").font(.subheadline).padding(.top, 4)
            TextField("/Users/name/star-traders-sync-hub", text: Binding(
                get: { m.hubPath },
                set: { m.hubPath = $0; m.hubPathEdited = true }))
            .font(.system(.body, design: .monospaced))
            Text("Use the same folder the hub Mac was set up with. The default is right unless you changed it there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var hubForm: some View {
        Card {
            Text("Hub folder on this Mac").font(.headline)
            TextField("", text: Binding(get: { m.hubPath },
                                        set: { m.hubPath = $0; m.hubPathEdited = true }))
                .font(.system(.body, design: .monospaced))
            Text("The master copy of your saves lives here. The other Macs connect to this folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Card {
            Text("Let your other Macs connect").font(.headline)
            if m.remoteLoginOn {
                StatusRow(state: .ok, text: "Remote Login is on.")
            } else {
                StatusRow(state: .warn, text: "Remote Login is off. Your other Macs connect through it, so turn it on under General > Sharing > Remote Login.")
                HStack {
                    Button("Open Sharing settings") { m.openRemoteLoginSettings() }
                    Button("Check again") { m.checkRemoteLogin() }
                }
            }
        }
        Card {
            Text("Backup disk (optional)").font(.headline)
            Picker("Backup disk", selection: $m.backupVolume) {
                Text("No backup disk").tag(String?.none)
                ForEach(m.volumes, id: \.self) { v in
                    Text((v as NSString).lastPathComponent).tag(Optional(v))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            Text("The hub can copy your saves to an external disk every night. Setting up the nightly job is a Terminal step for now, see the README.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConnectPage: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        let hubName = m.selectedHub?.nodeName ?? "the hub"
        PageTitle(title: "Connect to \(hubName)",
                  subtitle: "This Mac gets a key that lets it reach the hub without a password. You need the hub account's password once.")
        VStack(alignment: .leading, spacing: 14) {
            if m.connectBusy {
                StatusRow(state: .busy, text: "Working…")
            }
            if m.loginWorks {
                StatusRow(state: .ok, text: "Connected. This Mac can reach \(hubName) without a password.")
            } else if !m.connectBusy {
                if m.keyReady { StatusRow(state: .ok, text: "This Mac has a key.") }
                hostKeyCard
                if m.hostTrusted { passwordCard }
            }
            if let msg = m.connectMessage {
                StatusRow(state: .fail, text: msg)
            }
        }
    }

    @ViewBuilder var hostKeyCard: some View {
        if m.hostTrusted {
            StatusRow(state: .ok, text: "The hub's identity is confirmed.")
        } else if let err = m.scanError {
            Card {
                StatusRow(state: .fail, text: err)
                HStack {
                    Button("Try again") { m.startConnect() }
                }
            }
        } else if let k = m.scanned {
            Card {
                Text("Confirm it is really your hub").font(.headline)
                Text("The hub introduced itself with this fingerprint:")
                CommandBox(command: k.fingerprint)
                Text("On the **hub Mac**, open Terminal and run this. It must print the same fingerprint:")
                    .fixedSize(horizontal: false, vertical: true)
                CommandBox(command: "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
                Toggle("They are the same", isOn: $m.fingerprintConfirmed)
                Button("Trust this hub") { m.trustHostKey() }
                    .disabled(!m.fingerprintConfirmed)
            }
        }
    }

    @ViewBuilder var passwordCard: some View {
        Card {
            Text("Hub password").font(.headline)
            Text("The password of **\(m.hubUser)** on the hub Mac. It is used once to install this Mac's key, and is not saved anywhere.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("password", text: $m.password)
                .frame(maxWidth: 320)
                .onSubmit { if !m.password.isEmpty { m.copyKey() } }
            Button("Connect") { m.copyKey() }
                .disabled(m.password.isEmpty || m.connectBusy)
        }
    }
}

struct InstallPage: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        PageTitle(title: "Install",
                  subtitle: "Puts the sync tool on this Mac and saves your settings.")
        VStack(alignment: .leading, spacing: 14) {
            if let v = m.values {
                Card {
                    LabeledContent("Hub", value: v.hubHost)
                    LabeledContent("Account on hub", value: v.hubUser)
                    LabeledContent("Hub folder", value: v.hubPath)
                    if m.role == .hub {
                        LabeledContent("Backup disk", value: v.backupVolume.map { ($0 as NSString).lastPathComponent } ?? "none")
                    }
                }
            }
            if !m.installed {
                Button(m.installBusy ? "Installing…" : "Install") { m.install() }
                    .controlSize(.large)
                    .disabled(m.installBusy)
            }
            ForEach(m.installLog, id: \.self) { StatusRow(state: .ok, text: $0) }
            if let e = m.installError { StatusRow(state: .fail, text: e) }
        }
    }
}

struct CheckPage: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        PageTitle(title: "Check",
                  subtitle: "Runs the sync tool's own health check and fixes what it safely can.")
        VStack(alignment: .leading, spacing: 12) {
            if m.doctorRunning {
                StatusRow(state: .busy, text: "Checking…")
            } else if m.doctorPassed == true {
                StatusRow(state: .ok, text: "Everything checks out.")
            } else if m.doctorPassed == false {
                StatusRow(state: .fail, text: "Something needs fixing. Each problem below says what to do. Fix it, then check again.")
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(m.doctorLines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(line.kind == .section ? .body : .callout, design: .monospaced))
                        .fontWeight(line.kind == .section ? .semibold : .regular)
                        .foregroundStyle(color(line.kind))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            if !m.doctorRunning {
                Button("Check again") { m.runDoctor() }
            }
        }
    }

    func color(_ k: DoctorLine.Kind) -> Color {
        switch k {
        case .ok, .fixed: return .green
        case .warn:       return .orange
        case .fail:       return .red
        case .note, .skip: return .secondary
        default:          return .primary
        }
    }
}

struct DonePage: View {
    @EnvironmentObject var m: WizardModel

    var body: some View {
        PageTitle(title: m.doctorPassed == true ? "All set" : "Almost there",
                  subtitle: m.role == .hub
                    ? "This Mac is the hub. Now run this app on each Mac you play on."
                    : "This Mac is connected to the hub.")
        VStack(alignment: .leading, spacing: 14) {
            if m.doctorPassed != true {
                StatusRow(state: .warn, text: "The check still reported problems. Go back to Check to see them.")
            }
            Text("From now on, start the game like this").font(.headline)
            Text("Open **Terminal** and type:")
            CommandBox(command: "sts play")
            Text("It fetches your saves from the hub, starts Star Traders, and sends your saves back when you quit the game. Keep the Terminal window open until it says it has pushed.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Terminal windows that were already open do not know the `sts` command yet. Open a new one.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Terminal") { m.openTerminal() }
        }
    }
}
