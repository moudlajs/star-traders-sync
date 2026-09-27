import AppKit
import Foundation
import STSSetupCore

enum Step: Int, CaseIterable, Identifiable {
    case welcome, tailscale, role, connect, install, check, done
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:   return "Welcome"
        case .tailscale: return "Tailscale"
        case .role:      return "Your Macs"
        case .connect:   return "Connect to hub"
        case .install:   return "Install"
        case .check:     return "Check"
        case .done:      return "Done"
        }
    }
}

enum Role: String, CaseIterable, Identifiable {
    case client, hub
    var id: String { rawValue }
}

struct InstallStage: Identifiable {
    enum State { case pending, running, done, failed }
    enum Kind { case files, commands, settings, hubFolder }

    let kind: Kind
    var state: State = .pending
    var details: [String] = []
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .files:     return "Install the sync tool"
        case .commands:  return "Add the sts command"
        case .settings:  return "Save your settings"
        case .hubFolder: return "Create the hub folder"
        }
    }
}

struct DoctorLine: Identifiable {
    enum Kind { case ok, warn, fail, fixed, note, skip, section, plain }
    let id = UUID()
    let text: String
    let kind: Kind

    init(_ raw: String) {
        text = raw
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("ok ")        { kind = .ok }
        else if t.hasPrefix("warn ") { kind = .warn }
        else if t.hasPrefix("FAIL ") { kind = .fail }
        else if t.hasPrefix("fixed") { kind = .fixed }
        else if t.hasPrefix("note ") { kind = .note }
        else if t.hasPrefix("--")    { kind = .skip }
        else if raw.hasPrefix("  ") && !raw.hasPrefix("    ") && !t.isEmpty { kind = .section }
        else                         { kind = .plain }
    }
}

@MainActor
final class WizardModel: ObservableObject {
    let layout = InstallLayout()
    let bundledScript: URL?
    let bundledExample: URL?
    let scriptVersion: String

    @Published var step: Step = .welcome
    @Published var existingConfig: SetupValues?
    /// The save folder sts will actually use: the existing config's
    /// LOCAL_SAVE_PATH if it has one, else the default a new config gets.
    var localSavePath = ConfigFile.defaultSavePath

    // Tailscale
    @Published var tsStatus: TailscaleStatus?
    @Published var tsError: String?
    @Published var tsChecking = false

    // Role
    @Published var role: Role = .client
    @Published var selectedHubID: String?
    @Published var hubUser = NSUserName()
    @Published var hubPath = ""
    @Published var hubPathEdited = false
    @Published var backupVolume: String?          // nil = no backup disk
    @Published var volumes: [String] = []
    @Published var remoteLoginOn = false

    // Connect
    @Published var keyReady = false
    @Published var scanned: SSHSetup.ScannedKey?
    @Published var scanError: String?
    @Published var fingerprintConfirmed = false
    @Published var hostTrusted = false
    @Published var password = ""
    @Published var loginWorks = false
    @Published var connectMessage: String?
    @Published var connectBusy = false

    // Install / check
    @Published var stages: [InstallStage] = []
    @Published var installError: String?
    @Published var installed = false
    /// What was installed, so going back and changing anything makes
    /// Install run again instead of keeping a stale "done".
    var installedValues: SetupValues?
    var installedRole: Role?
    @Published var installBusy = false
    @Published var doctorLines: [DoctorLine] = []
    @Published var doctorRunning = false
    @Published var doctorPassed: Bool?

    init() {
        bundledScript = Self.locate("star-traders-sync", repoPath: "bin/star-traders-sync")
        bundledExample = Self.locate("config.example", repoPath: "config.example")
        scriptVersion = bundledScript.flatMap(Self.readVersion) ?? "?"

        if let text = try? String(contentsOf: layout.configFile, encoding: .utf8),
           let v = ConfigFile.values(from: text) {
            if let p = ConfigFile.parse(text)["LOCAL_SAVE_PATH"], !p.isEmpty { localSavePath = p }
            existingConfig = v
            hubUser = v.hubUser
            hubPath = v.hubPath
            hubPathEdited = true
            backupVolume = v.backupVolume
        }
        refreshVolumes()
    }

    // MARK: resources

    /// In the .app the script is a bundle resource. Run with `swift run`
    /// from the repo, it is found relative to this source file.
    static func locate(_ name: String, repoPath: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) { return url }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent(repoPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func readVersion(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("readonly STS_VERSION=") {
            return line.split(separator: "\"").dropFirst().first.map(String.init)
        }
        return nil
    }

    // MARK: navigation

    var steps: [Step] {
        role == .hub ? Step.allCases.filter { $0 != .connect } : Step.allCases
    }

    var canContinue: Bool {
        switch step {
        case .welcome:   return bundledScript != nil
        case .tailscale: return tsStatus?.running == true && tsStatus?.me != nil
        case .role:      return problems.isEmpty
        case .connect:   return loginWorks
        case .install:   return installed
        case .check:     return !doctorRunning
        case .done:      return false
        }
    }

    func next() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        go(steps[i + 1])
    }

    func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        step = steps[i - 1]
    }

    private func go(_ s: Step) {
        step = s
        switch s {
        case .tailscale: if tsStatus == nil { checkTailscale() }
        case .role:      refreshVolumes(); checkRemoteLogin(); applyDefaultHubPath()
        case .connect:   startConnect()
        case .install:
            if installed && !Installer.installStillValid(
                installed: installedValues, installedAsHub: installedRole.map { $0 == .hub },
                current: values, currentIsHub: role == .hub) {
                installed = false
            }
            if !installed { resetStages() }
        case .check:     runDoctor()
        default: break
        }
    }

    // MARK: tailscale

    func checkTailscale() {
        tsChecking = true
        Task.detached {
            let r = Tailscale.status(log: SetupLog.write)
            await MainActor.run {
                self.tsChecking = false
                switch r {
                case .success(let s):
                    self.tsStatus = s
                    self.tsError = s.running ? nil : "Tailscale is \(s.backendState.isEmpty ? "not connected" : s.backendState). Open it and log in."
                    self.preselectHub(s)
                case .failure(let e):
                    self.tsStatus = nil
                    self.tsError = e.description
                }
            }
        }
    }

    private func preselectHub(_ s: TailscaleStatus) {
        guard selectedHubID == nil else { return }
        if let host = existingConfig?.hubHost.lowercased() {
            if let me = s.me, [me.nodeName, me.hostName.lowercased()].contains(host) {
                role = .hub
                return
            }
            if let peer = s.peers.first(where: { [$0.nodeName, $0.hostName.lowercased(), $0.dnsName].contains(host) }) {
                role = .client
                selectedHubID = peer.id
                return
            }
        }
        selectedHubID = s.hubCandidates.first(where: { $0.online && $0.os == "macOS" })?.id
    }

    var selectedHub: TailscaleNode? {
        tsStatus?.peers.first { $0.id == selectedHubID }
    }

    // MARK: role

    func applyDefaultHubPath() {
        guard !hubPathEdited else { return }
        let user = role == .hub ? NSUserName() : hubUser
        hubPath = "/Users/\(user)/star-traders-sync-hub"
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.volumeIsRootFileSystem == true { return nil }
            guard u.path.hasPrefix("/Volumes/") else { return nil }
            return u.path
        }
    }

    /// Mounted volumes plus the configured one, so a backup disk that is
    /// unplugged right now still shows as selected instead of vanishing.
    var volumeChoices: [String] {
        guard let current = backupVolume, !volumes.contains(current) else { return volumes }
        return [current] + volumes
    }

    func checkRemoteLogin() {
        Task.detached {
            let on = Shell.run("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", "22"]).ok
            await MainActor.run { self.remoteLoginOn = on }
        }
    }

    var values: SetupValues? {
        switch role {
        case .hub:
            guard let me = tsStatus?.me else { return nil }
            return SetupValues(hubHost: me.nodeName, hubUser: NSUserName(),
                               hubPath: hubPath, backupVolume: backupVolume)
        case .client:
            guard let hub = selectedHub else { return nil }
            // A client never backs up, but a disk already configured here is
            // kept rather than overwritten with the sentinel: it costs
            // nothing, and the machine may be switched back to hub later.
            return SetupValues(hubHost: hub.nodeName, hubUser: hubUser,
                               hubPath: hubPath, backupVolume: existingConfig?.backupVolume)
        }
    }

    var problems: [String] {
        guard let v = values else {
            return [role == .hub ? "Tailscale has not reported this Mac's name." : "Pick the Mac that holds the hub."]
        }
        return ConfigFile.problems(v, localSavePath: localSavePath, home: NSHomeDirectory())
    }

    var saveFolderExists: Bool {
        FileManager.default.fileExists(atPath: ConfigFile.expandTilde(localSavePath, home: NSHomeDirectory()))
    }

    // MARK: connect

    var ssh: SSHSetup? {
        selectedHub.map { SSHSetup(user: hubUser, hub: $0) }
    }

    func startConnect() {
        guard let ssh else { return }
        connectMessage = nil
        scanned = nil
        scanError = nil
        fingerprintConfirmed = false
        connectBusy = true
        Task.detached {
            var keyErr: String?
            if !ssh.hasKey {
                let r = ssh.generateKey()
                if !r.ok { keyErr = "Could not create an ssh key: \(r.combined)" }
            }
            let trusted = ssh.hostKeyTrusted
            let works = trusted && ssh.keyLoginWorks().ok
            let scan = trusted ? nil : ssh.scanHostKey()
            let keyError = keyErr
            await MainActor.run {
                self.connectBusy = false
                self.keyReady = keyError == nil
                self.connectMessage = keyError
                self.hostTrusted = trusted
                self.loginWorks = works
                switch scan {
                case .success(let k): self.scanned = k
                case .failure(let e): self.scanError = e.description
                case nil: break
                }
            }
        }
    }

    func trustHostKey() {
        guard let ssh, let scanned else { return }
        do {
            try ssh.trust(scanned)
            hostTrusted = true
            connectMessage = nil
        } catch {
            connectMessage = "Could not update ~/.ssh/known_hosts: \(error.localizedDescription)"
        }
    }

    func copyKey() {
        guard let ssh else { return }
        let pw = password
        connectBusy = true
        connectMessage = nil
        Task.detached {
            let copy = ssh.copyKey(password: pw)
            let test = ssh.keyLoginWorks()
            await MainActor.run {
                self.password = ""
                self.connectBusy = false
                self.loginWorks = test.ok
                if !test.ok {
                    self.connectMessage = ssh.explain(copy.ok ? test : copy)
                }
            }
        }
    }

    // MARK: install

    func resetStages() {
        var kinds: [InstallStage.Kind] = [.files, .commands, .settings]
        if role == .hub { kinds.append(.hubFolder) }
        stages = kinds.map { InstallStage(kind: $0) }
        installError = nil
    }

    /// Runs the stages in order, one visibly after another. The work is
    /// real; each stage is only held on screen for a moment so the
    /// sequence can be followed instead of arriving as one block.
    func install() {
        guard let script = bundledScript, let v = values else { return }
        resetStages()
        installBusy = true
        let layout = self.layout, example = bundledExample, hubPath = self.hubPath
        let kinds = stages.map(\.kind)
        let installingRole = role

        Task.detached {
            if Installer.scriptIsRunning() {
                await MainActor.run {
                    self.installError = InstallError.scriptRunning.description
                    self.installBusy = false
                }
                return
            }
            for (i, kind) in kinds.enumerated() {
                await MainActor.run { self.stages[i].state = .running }
                let started = Date()
                var details: [String] = []
                var failure: String?
                do {
                    switch kind {
                    case .files:
                        details = try Installer.installFiles(bundledScript: script, bundledExample: example, layout: layout)
                    case .commands:
                        details = try Installer.linkCommands(layout: layout)
                    case .settings:
                        details = try Installer.writeConfig(v, layout: layout)
                    case .hubFolder:
                        // What doctor --fix would do; doing it here means
                        // the check step starts green.
                        if FileManager.default.fileExists(atPath: hubPath) {
                            details = ["\(hubPath) already exists"]
                        } else {
                            try FileManager.default.createDirectory(atPath: hubPath, withIntermediateDirectories: true)
                            details = ["created \(hubPath)"]
                        }
                    }
                } catch let e as InstallError {
                    failure = e.description
                } catch {
                    failure = error.localizedDescription
                }
                let remaining = 0.45 - Date().timeIntervalSince(started)
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }

                let shown = details, err = failure
                await MainActor.run {
                    self.stages[i].details = shown
                    self.stages[i].state = err == nil ? .done : .failed
                    if let err { self.installError = err }
                }
                if failure != nil { break }
            }
            await MainActor.run {
                self.installed = self.stages.allSatisfy { $0.state == .done }
                if self.installed {
                    self.installedValues = v
                    self.installedRole = installingRole
                }
                self.installBusy = false
            }
        }
    }

    // MARK: check

    func runDoctor() {
        doctorLines = []
        doctorRunning = true
        doctorPassed = nil
        let script = layout.effectiveScript.path
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

    // MARK: system

    func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    func openRemoteLoginSettings() {
        openURL("x-apple.systempreferences:com.apple.Sharing-Settings.extension")
    }

    func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
