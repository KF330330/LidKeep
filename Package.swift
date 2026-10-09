// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LidKeep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LidKeep", targets: ["LidKeepApp"]),
        .executable(name: "lidkeep-service", targets: ["LidKeepService"])
    ],
    targets: [
        .target(name: "LidKeepCore"),
        .target(name: "LidKeepDiagnostics", dependencies: ["LidKeepCore"]),
        .executableTarget(name: "LidKeepApp", dependencies: ["LidKeepCore", "LidKeepDiagnostics"]),
        .executableTarget(name: "LidKeepService", dependencies: ["LidKeepCore"]),
        .testTarget(name: "LidKeepCoreTests", dependencies: ["LidKeepCore"]),
        .testTarget(name: "LidKeepServiceTests", dependencies: ["LidKeepService", "LidKeepCore"]),
        .testTarget(name: "LidKeepDiagnosticsTests", dependencies: ["LidKeepDiagnostics", "LidKeepCore"]),
        .testTarget(name: "LidKeepAppTests", dependencies: ["LidKeepApp", "LidKeepDiagnostics", "LidKeepCore"])
    ],
    swiftLanguageModes: [.v5]
)
