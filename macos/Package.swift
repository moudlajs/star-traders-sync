// swift-tools-version:5.9
// Star Traders Sync: the macOS setup and menu-bar app for star-traders-sync.

import PackageDescription

let package = Package(
    name: "STSSetup",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that touches the filesystem, the network or a process, testable without a window.
        .target(name: "STSSetupCore"),
        .executableTarget(name: "STSSetup", dependencies: ["STSSetupCore"]),
        .testTarget(name: "STSSetupCoreTests", dependencies: ["STSSetupCore"]),
        .testTarget(name: "STSSetupTests", dependencies: ["STSSetup", "STSSetupCore"]),
    ]
)
