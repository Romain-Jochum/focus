// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Focus",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "FocusCore", swiftSettings: v5),
        .executableTarget(name: "Focus", dependencies: ["FocusCore"], swiftSettings: v5),
        .executableTarget(name: "FocusTests", dependencies: ["FocusCore"], path: "Tests/FocusTests", swiftSettings: v5),
    ]
)
