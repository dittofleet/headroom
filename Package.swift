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
        // Mac and Linux: the sessions Claude Code and the Codex CLI already
        // have.
        .target(name: "HeadroomBorrow", dependencies: ["HeadroomCore"]),
        // Mac only: updating the app, and the `headroom` command's link.
        .target(name: "HeadroomMac", dependencies: ["HeadroomCore", "HeadroomBorrow"]),
        // Sessions of our own, signed in from the app, for where there is no
        // CLI to borrow one from (the phone), or on the Mac when asked to.
        .target(name: "HeadroomAccounts", dependencies: ["HeadroomCore"]),

        // The menu bar app.
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore", "HeadroomBorrow", "HeadroomMac", "HeadroomAccounts"]),
        // The `headroom` command, inside the app on a Mac and on its own on
        // Linux. Not "headroom": it would collide with "Headroom" on a
        // case-insensitive disk, both in .build and in the app bundle.
        .executableTarget(name: "headroom-cli", dependencies: ["HeadroomCore", "HeadroomBorrow"]),

        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomBorrowTests", dependencies: ["HeadroomCore", "HeadroomBorrow"]),
        .testTarget(name: "HeadroomMacTests", dependencies: ["HeadroomBorrow", "HeadroomMac"]),
        .testTarget(name: "HeadroomAccountsTests", dependencies: ["HeadroomCore", "HeadroomAccounts"]),
    ]
)

#if os(Linux)
// Only the command, which borrows the CLIs' sessions: the rest needs AppKit,
// or Apple's frameworks for logins of our own.
let linux: Set = ["HeadroomCore", "HeadroomBorrow", "headroom-cli", "HeadroomCoreTests", "HeadroomBorrowTests"]
package.targets.removeAll { !linux.contains($0.name) }
package.products.removeAll { $0.name == "HeadroomAccounts" }
#endif
