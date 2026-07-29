// swift-tools-version: 6.0
import PackageDescription

// Perch — a Dynamic Island-style notch overlay that mirrors and controls
// Claude Code via HTTP hooks.
//
// Phase 0 ships only the plumbing:
//   - PerchCore : a minimal, loopback-only HTTP/1.1 server + hook event model
//   - perchd    : a headless daemon that receives Claude Code hook POSTs and logs them
//
// Later phases add a SwiftUI agent app target that imports PerchCore unchanged.
let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerchCore", targets: ["PerchCore"]),
        .executable(name: "perchd", targets: ["perchd"]),
        .executable(name: "Perch", targets: ["Perch"]),
        .executable(name: "EdgePanel", targets: ["EdgePanel"]),
    ],
    targets: [
        .target(
            name: "PerchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "perchd",
            dependencies: ["PerchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The SwiftUI agent app (Phase 1+). Embeds the same PerchCore server
        // and renders the Liquid Glass notch capsule.
        .executableTarget(
            name: "Perch",
            dependencies: ["PerchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // EdgePanel (Phase 0+). A right-edge-docked hover panel showing Claude
        // Code usage + inline permission approval. Reuses PerchCore's loopback
        // HTTP hook server and the held-open /permission contract unchanged.
        .executableTarget(
            name: "EdgePanel",
            dependencies: ["PerchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Locks down RiskEngine's command/tool risk classification — the security-critical logic
        // where the most dangerous bugs have surfaced (force-push over-grant, curl|sh, sensitive-
        // path decoys, Skill→kill false matches). Pure functions, so fast + deterministic.
        .testTarget(
            name: "PerchCoreTests",
            dependencies: ["PerchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
