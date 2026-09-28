// swift-tools-version:5.9
//
// Star Traders Sync: the macOS app for star-traders-sync. It sets a Mac up
// on first launch, then shows sync status, for people who do not use a
// terminal. Built with `swift build`; `build-app.sh` wraps the binary into
// a .app and a .dmg.

import PackageDescription

let package = Package(
    name: "STSSetup",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that touches the filesystem, the network or a process
        // lives here, so it can be tested without a window.
        .target(name: "STSSetupCore"),
        .executableTarget(name: "STSSetup", dependencies: ["STSSetupCore"]),
        .testTarget(name: "STSSetupCoreTests", dependencies: ["STSSetupCore"]),
        // The app's own state machine (DashboardModel): what starts when,
        // with the script and clock replaced by fakes.
        .testTarget(name: "STSSetupTests", dependencies: ["STSSetup", "STSSetupCore"]),
    ]
)
