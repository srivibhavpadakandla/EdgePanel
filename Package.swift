// swift-tools-version: 6.0
import PackageDescription

// EdgePanel — a macOS edge-docked hover panel for Claude Code.
//   - PerchCore : loopback HTTP/1.1 server + hook-event model (from Perch)
//   - EdgePanel : the SwiftUI menu-bar agent app
let package = Package(
    name: "EdgePanel",
    platforms: [.macOS(.v14)],
    products: [
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
    ]
)
