import AppKit
import STSSetupCore
import SwiftUI

/// Self update (#76); every check that decides whether to install lives in STSSetupCore.
@MainActor
final class UpdateModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case available(Release)
        case downloading(Release, Double)
        case ready(Release, URL)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Asked before quitting for an update: no restart mid-sync.
    weak var dashboard: DashboardModel?

    private var timer: Timer?
    private var session: URLSession?
    private var pending: Release?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    var bundleID: String { Bundle.main.bundleIdentifier ?? "com.github.moudlajs.star-traders-sync" }

    func start() {
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        switch state {
        case .downloading, .ready, .installing: return
        default: break
        }
        let url = UpdateFeed.url()
        let testFeed = url != UpdateFeed.defaultURL
        let current = currentVersion
        Task.detached {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let release = try? UpdateFeed.parse(data) else {
                return
            }
            guard testFeed || (UpdateFeed.isTrustedDownload(release.dmgURL)
                               && UpdateFeed.isTrustedDownload(release.signatureURL)) else {
                await MainActor.run { SetupLog.write("update: ignored \(release.version): download is not this repository's (\(release.dmgURL.absoluteString))") }
                return
            }
            await MainActor.run {
                if UpdateFeed.isNewer(release.version, than: current) {
                    if self.state == .idle || self.isFailed { self.state = .available(release) }
                    SetupLog.write("update: \(release.version) available (running \(current))")
                }
            }
        }
    }

    var isFailed: Bool { if case .failed = state { return true } else { return false } }

    func download() {
        guard case .available(let release) = state else { return }
        pending = release
        state = .downloading(release, 0)
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: release.dmgURL).resume()
        SetupLog.write("update: downloading \(release.version)")
    }

    func restart() {
        guard case .ready(let release, let dmg) = state else { return }
        if dashboard?.busy == true {
            state = .failed("A sync is running. Restart to update once it is done.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.isFailed == true { self?.state = .ready(release, dmg) }
            }
            return
        }
        state = .installing(release)
        // From here nothing may start: the app is about to restart.
        dashboard?.updating = true
        let target = Bundle.main.bundleURL
        let id = bundleID
        Task.detached {
            do {
                try UpdateInstaller.install(dmg: dmg, expectedVersion: release.version, bundleID: id, over: target)
                try? FileManager.default.removeItem(at: dmg)
                await MainActor.run {
                    // Checked again: a sync that began before the gate must finish first; the update applies on next launch.
                    if self.dashboard?.busy == true {
                        self.dashboard?.updating = false
                        self.state = .failed("Installed \(release.version). It starts the next time you open the app; a sync is running now.")
                        SetupLog.write("update: installed \(release.version), restart deferred: sync running")
                        return
                    }
                    SetupLog.write("update: installed \(release.version), relaunching")
                    Self.relaunch(target)
                }
            } catch {
                let message = (error as? UpdateError)?.description ?? error.localizedDescription
                await MainActor.run {
                    SetupLog.write("update: install failed: \(message)")
                    self.dashboard?.updating = false
                    self.state = .failed(message)
                }
            }
        }
    }

    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: URLSessionDownloadDelegate (called off the main actor)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in
            if case .downloading(let r, _) = self.state { self.state = .downloading(r, fraction) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is removed when this delegate method returns: move it now.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("Star-Traders-Sync-update-\(UUID().uuidString).dmg")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        Task { @MainActor in
            guard let release = self.pending else { return }
            guard moved else { self.state = .failed("The download could not be saved."); return }
            do {
                try UpdateInstaller.verifyChecksum(kept, expected: release.sha256)
                // The signature is checked against the built-in key (#108), never relaxed, not even for an STS_UPDATE_FEED test feed.
                let (sig, response) = try await URLSession.shared.data(from: release.signatureURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw UpdateError.io("The release's signature could not be downloaded (HTTP \(http.statusCode)). Nothing was changed.")
                }
                try ReleaseSignature.verify(kept, signatureBase64: String(decoding: sig, as: UTF8.self))
                self.state = .ready(release, kept)
                SetupLog.write("update: \(release.version) downloaded, checksum and release signature verified")
            } catch {
                try? FileManager.default.removeItem(at: kept)
                self.state = .failed((error as? UpdateError)?.description ?? error.localizedDescription)
                SetupLog.write("update: download rejected: \(error)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.state = .failed("The download failed: \(error.localizedDescription)")
        }
    }
}

/// The toolbar item: nothing while up to date, then the three steps.
struct UpdateButton: View {
    @ObservedObject var updates: UpdateModel

    var body: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .available(let r):
            Button { updates.download() } label: {
                Label("Update to \(r.version)", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .foregroundStyle(.blue)
            .help(r.notes.isEmpty ? "Version \(r.version) is available" : r.notes)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            }
            .help("Downloading the update")
        case .ready(let r, _):
            Button { updates.restart() } label: {
                Label("Restart to update", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .foregroundStyle(.blue)
            .help("Version \(r.version) is downloaded and verified")
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Button { updates.check() } label: {
                Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .foregroundStyle(.orange)
            .help(message + " Click to check again.")
        }
    }
}
