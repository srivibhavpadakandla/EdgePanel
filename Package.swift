// swift-tools-version: 6.0
import PackageDescription

// EdgePanel (public mirror) — the shared PerchCore hook/risk engine + the EdgePanel macOS app,
// plus the PerchCore test suite. The Perch notch overlay and the perchd daemon live only in the
// private Perch build tree, so they are intentionally NOT declared here (their sources aren't in
// this repo). The iOS companion app lives under ios/ and builds via its own Xcode project.
let package = Package(
    name: "EdgePanel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerchCore", targets: ["PerchCore"]),
        .executable(name: "EdgePanel", targets: ["EdgePanel"]),
    ],
    targets: [
        .target(
            name: "PerchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EdgePanel",
            dependencies: ["PerchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Mirrors Perch's RiskEngine security suite (kept in sync by scripts/sync-mirror.sh).
        .testTarget(
            name: "PerchCoreTests",
            dependencies: ["PerchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
