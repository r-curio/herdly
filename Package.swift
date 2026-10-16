// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Steer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Steer", targets: ["SteerApp"]),
               .executable(name: "SteerHook", targets: ["SteerHook"])],
    targets: [
        .target(name: "SteerCore"),
        .executableTarget(name: "SteerApp", dependencies: ["SteerCore"], exclude: ["Resources/AppleEvents.js", "Resources/Ghostty.js", "Resources/ITerm2.js", "Resources/TerminalApp.js"],
                          resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "SteerHook", dependencies: ["SteerCore"]),
        .testTarget(name: "SteerCoreTests", dependencies: ["SteerCore", "SteerApp"])
    ]
)
