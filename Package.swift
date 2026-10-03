// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "headroom",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // For the iOS app in iOS/, which Xcode builds rather than SwiftPM.
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
        .library(name: "HeadroomAccounts", targets: ["HeadroomAccounts"]),
    ],
    targets: [
        // Every platform: the providers' endpoints and responses, and the
        // engine that decides when to fetch and keeps the numbers.
        .target(name: "HeadroomCore"),
        // Mac only: the sessions Claude Code and the Codex CLI already have,
        // updating the app, and the `headroom` command's link.
        .target(name: "HeadroomMac", dependencies: ["HeadroomCore"]),
        // Sessions of our own, signed in from the app, for where there is no
        // CLI to borrow one from: the phone.
        .target(name: "HeadroomAccounts", dependencies: ["HeadroomCore"]),

        // The menu bar app.
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore", "HeadroomMac"]),
        // Not "headroom": it would collide with "Headroom" on a
        // case-insensitive disk, both in .build and in the app bundle.
        .executableTarget(name: "headroom-cli", dependencies: ["HeadroomCore", "HeadroomMac"]),

        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomMacTests", dependencies: ["HeadroomCore", "HeadroomMac"]),
        .testTarget(name: "HeadroomAccountsTests", dependencies: ["HeadroomCore", "HeadroomAccounts"]),
    ]
)
