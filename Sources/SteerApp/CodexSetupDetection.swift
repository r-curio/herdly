import AppKit
import Foundation
import SteerCore

enum CodexSetupDetection {
    struct SetupSnapshot: Sendable {
        let capabilities: CodexCapabilities
        let plan: CodexSetupPlan?
        let status: CodexConnectionStatus
    }

    static func capabilities() -> CodexCapabilities {
        let desktopURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let desktopVersion = Bundle(url: desktopURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let desktopInstalled = FileManager.default.fileExists(atPath: desktopURL.path)
        let desktop = desktopInstalled && atLeast(desktopVersion, CodexSetupRequirements.minimumDesktopVersion)

        let cliPath = executable(named: "codex", beside: desktopURL)
        let cliVersion = cliPath.flatMap { version(of: $0) }
        let cliInstalled = cliPath != nil
        let cli = cliInstalled && atLeast(cliVersion, CodexSetupRequirements.minimumCLIVersion)

        let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            ?? URL(fileURLWithPath: "/Applications/Ghostty.app")
        let ghosttyVersion = Bundle(url: ghosttyURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let ghosttyInstalled = FileManager.default.fileExists(atPath: ghosttyURL.path)
        let ghostty = ghosttyInstalled && atLeast(ghosttyVersion, CodexSetupRequirements.minimumGhosttyVersion)
        var reasons: [String] = []
        if desktopInstalled && !desktop { reasons.append("Codex desktop \(desktopVersion ?? "version unknown") is older than the tested minimum \(CodexSetupRequirements.minimumDesktopVersion).") }
        if cliInstalled && !cli { reasons.append("Codex CLI \(cliVersion ?? "version unknown") is older than the tested minimum \(CodexSetupRequirements.minimumCLIVersion).") }
        if !desktopInstalled && !cliInstalled { reasons.append("No supported Codex desktop app or CLI was detected.") }
        if ghosttyInstalled && !ghostty { reasons.append("Ghostty \(ghosttyVersion ?? "version unknown") is older than the tested minimum \(CodexSetupRequirements.minimumGhosttyVersion).") }
        return CodexCapabilities(cli: cli, desktop: desktop, ghostty: ghostty, supported: cli || desktop,
                                 unsupportedReason: reasons.joined(separator: " "), cliVersion: cliVersion,
                                 desktopVersion: desktopVersion, ghosttyVersion: ghosttyVersion,
                                 cliInstalled: cliInstalled, desktopInstalled: desktopInstalled,
                                 ghosttyInstalled: ghosttyInstalled)
    }

    /// Runs a tiny bundled helper check without reading or writing the user's setup.
    static func validateHelper(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        return runBounded(url, arguments: ["--self-test"])?.status == 0
    }

    static func setupSnapshot(roots: CodexSetupRoots, capabilities: CodexCapabilities) -> SetupSnapshot {
        let manager = FileManager.default
        let configData = boundedRegularData(at: roots.configURL, maximum: 1_048_576)
        let hooksData = boundedRegularData(at: roots.hooksURL, maximum: 1_048_576)
        let configExists = manager.fileExists(atPath: roots.configURL.path)
        let hooksExist = manager.fileExists(atPath: roots.hooksURL.path)
        let config = configData.flatMap { String(data: $0, encoding: .utf8) }
        let plan: CodexSetupPlan?
        if (configExists && config == nil) || (hooksExist && hooksData == nil) {
            plan = nil
        } else {
            plan = CodexSetupPlanner.plan(capabilities: capabilities, config: config ?? "",
                                          hooks: hooksData ?? Data("{}".utf8), helperPath: roots.helperURL,
                                          eventsPath: roots.eventsDirectory)
        }
        let status: CodexConnectionStatus
        if configExists && config == nil {
            status = .malformed("Codex config.toml is unreadable or too large; Steer will not change it.")
        } else if hooksExist && hooksData == nil {
            status = .malformed("Codex hooks.json is unreadable or too large; Steer will not change it.")
        } else {
            status = CodexSetupInstaller().status(roots: roots, capabilities: capabilities)
        }
        return SetupSnapshot(capabilities: capabilities, plan: plan, status: status)
    }

    static func boundedRegularData(at url: URL, maximum: Int) -> Data? {
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
              let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: maximum + 1) else { return nil }
        try? handle.close()
        return data.count <= maximum ? data : nil
    }

    private static func executable(named name: String, beside app: URL) -> URL? {
        var paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
                     app.appendingPathComponent("Contents/MacOS/\(name)").path,
                     app.appendingPathComponent("Contents/Resources/\(name)").path]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/\(name)" }
        }
        return paths.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func version(of url: URL) -> String? {
        guard let result = runBounded(url, arguments: ["--version"]), result.status == 0,
              let text = String(data: result.output, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .first(where: { $0.first?.isNumber == true && $0.contains(".") })
            .map(String.init)
    }

    private static func runBounded(_ url: URL, arguments: [String], timeout: TimeInterval = 2) -> (status: Int32, output: Data)? {
        let process = Process(), output = Pipe()
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        guard let data = try? output.fileHandleForReading.read(upToCount: 64 * 1024) else { return nil }
        return (process.terminationStatus, data)
    }

    private static func atLeast(_ value: String?, _ minimum: String) -> Bool {
        guard let value else { return false }
        func parts(_ input: String) -> [Int] {
            var result = input.split(separator: ".").map { Int($0) ?? 0 }
            while result.count < 3 { result.append(0) }
            return Array(result.prefix(3))
        }
        return !parts(value).lexicographicallyPrecedes(parts(minimum))
    }
}
