// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Herdly",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Herdly", targets: ["HerdlyApp"]),
               .executable(name: "HerdlyHook", targets: ["HerdlyHook"])],
    targets: [
        .target(name: "HerdlyCore"),
        .executableTarget(name: "HerdlyApp", dependencies: ["HerdlyCore"], exclude: ["Resources/AppleEvents.js", "Resources/Ghostty.js", "Resources/ITerm2.js", "Resources/TerminalApp.js"],
                          resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "HerdlyHook", dependencies: ["HerdlyCore"]),
        .testTarget(name: "HerdlyCoreTests", dependencies: ["HerdlyCore", "HerdlyApp"])
    ]
)
