// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "HinterHind",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "HinterCore"),
        .executableTarget(name: "HinterHind", dependencies: ["HinterCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]), // AppKit/SCK callbacks; strict mode adds noise, not safety here
        .testTarget(name: "HinterCoreTests", dependencies: ["HinterCore"]),
    ]
)
