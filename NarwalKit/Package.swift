// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NarwalKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NarwalKit", targets: ["NarwalKit"]),
    ],
    targets: [
        .target(name: "NarwalKit"),
        .testTarget(name: "NarwalKitTests", dependencies: ["NarwalKit"]),
    ]
)
