// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unfold",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UnfoldEngine"),
        .target(
            name: "UnfoldMac",
            dependencies: ["UnfoldEngine"]
        ),
        .executableTarget(
            name: "Unfold",
            dependencies: ["UnfoldEngine", "UnfoldMac"]
        ),
        .executableTarget(
            name: "UnfoldCTL",
            dependencies: ["UnfoldEngine"]
        ),
        .testTarget(
            name: "UnfoldEngineTests",
            dependencies: ["UnfoldEngine"]
        ),
        .testTarget(
            name: "UnfoldMacTests",
            dependencies: ["UnfoldMac", "UnfoldEngine"]
        ),
    ],
    // Language mode 5 is deliberate: CGEventTap callbacks are C function pointers and
    // would need @convention(c) isolation work under Swift 6 strict concurrency.
    swiftLanguageModes: [.v5]
)
