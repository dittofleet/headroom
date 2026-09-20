// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "headroom",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ]
)
