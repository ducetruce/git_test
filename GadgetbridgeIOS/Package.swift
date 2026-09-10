// swift-tools-version:5.9
import PackageDescription

// This manifest builds only `GadgetbridgeCore`, the platform-agnostic
// business-logic layer (models, BLE protocol abstractions, device
// coordinators, persistence, sync orchestration). It has no dependency on
// CoreBluetooth, SwiftUI, or UIKit, so `swift build` / `swift test` work
// without Xcode, including on Linux CI.
//
// The `GadgetbridgeApp` target (SwiftUI + CoreBluetooth) is an iOS app and
// is built via Xcode using the generated project — see project.yml and
// README.md.
let package = Package(
    name: "GadgetbridgeCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "GadgetbridgeCore", targets: ["GadgetbridgeCore"]),
    ],
    targets: [
        .target(
            name: "GadgetbridgeCore",
            path: "Sources/GadgetbridgeCore"
        ),
        .testTarget(
            name: "GadgetbridgeCoreTests",
            dependencies: ["GadgetbridgeCore"],
            path: "Tests/GadgetbridgeCoreTests"
        ),
    ]
)
