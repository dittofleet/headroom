// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "headroom",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"]),
        // Not "headroom": it would collide with "Headroom" on a
        // case-insensitive disk, both in .build and in the app bundle.
        .executableTarget(name: "headroom-cli", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ]
)
