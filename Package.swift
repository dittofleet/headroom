// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "headroom",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // For the iOS app in iOS/, which Xcode builds rather than SwiftPM.
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
    ],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"]),
        // Not "headroom": it would collide with "Headroom" on a
        // case-insensitive disk, both in .build and in the app bundle.
        .executableTarget(name: "headroom-cli", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ]
)
