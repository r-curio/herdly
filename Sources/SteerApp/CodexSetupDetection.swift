import AppKit
import Foundation
import SteerCore

enum CodexSetupDetection {
    private enum DesktopSelection {
        case none
        case selected(URL)
        case ambiguous
    }

    struct SetupSnapshot: Sendable {
        let capabilities: CodexCapabilities
        let plan: CodexSetupPlan?
        let status: CodexConnectionStatus
    }

    static func capabilities() -> CodexCapabilities {
        let runningDesktopProcesses = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let runningDesktop = runningDesktopProcesses.compactMap(\.bundleURL)
        let installedDesktop = [
            "/Applications/Codex.app", "/Applications/ChatGPT.app",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app").path,
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.path
        ].compactMap { $0 }.map(URL.init(fileURLWithPath:)).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.reduce(into: [URL]()) { result, url in
            if !result.contains(url) { result.append(url) }
        }
        let desktopSelection: DesktopSelection
        if runningDesktopProcesses.count > 1 { desktopSelection = .ambiguous }
        else if let running = runningDesktop.first { desktopSelection = .selected(running) }
        else if installedDesktop.count > 1 { desktopSelection = .ambiguous }
        else if let installed = installedDesktop.first { desktopSelection = .selected(installed) }
        else { desktopSelection = .none }
        let desktopURL: URL?
        switch desktopSelection {
        case .selected(let url): desktopURL = url
        case .none, .ambiguous: desktopURL = nil
        }
        let desktopVersion = desktopURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let desktopInstalled = desktopURL != nil || !runningDesktop.isEmpty || !installedDesktop.isEmpty
        let desktop = desktopSelectionIsSupported(desktopSelection, version: desktopVersion)

        let cliPath = executable(named: "codex", beside: desktopURL ?? URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        let cliVersion = cliPath.flatMap { version(of: $0) }
        let cliInstalled = cliPath != nil
        let cli = cliInstalled && atLeast(cliVersion, CodexSetupRequirements.minimumCLIVersion)

        let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            ?? URL(fileURLWithPath: "/Applications/Ghostty.app")
        let ghosttyVersion = Bundle(url: ghosttyURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let ghosttyInstalled = FileManager.default.fileExists(atPath: ghosttyURL.path)
        let ghostty = ghosttyInstalled && atLeast(ghosttyVersion, CodexSetupRequirements.minimumGhosttyVersion)
        var reasons: [String] = []
        if case .ambiguous = desktopSelection { reasons.append("Multiple Codex desktop instances are installed or running; close extras before setup.") }
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

    private static func desktopSelectionIsSupported(_ selection: DesktopSelection, version: String?) -> Bool {
        guard case .selected = selection else { return false }
        return atLeast(version, CodexSetupRequirements.minimumDesktopVersion)
    }

    /// Runs a tiny bundled helper check without reading or writing the user's setup.
    static func validateHelper(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        return runBounded(url, arguments: ["--self-test"])?.status == 0
    }

    static func setupSnapshot(roots: CodexSetupRoots, capabilities: CodexCapabilities) -> SetupSnapshot {
        let manager = FileManager.default
        let configData = boundedRegularData(at: roots.configURL, maximum: CodexSetupLimits.maximumFileSize)
        let hooksData = boundedRegularData(at: roots.hooksURL, maximum: CodexSetupLimits.maximumFileSize)
        let configExists = manager.fileExists(atPath: roots.configURL.path)
        let hooksExist = manager.fileExists(atPath: roots.hooksURL.path)
        let config = configData.flatMap { String(data: $0, encoding: .utf8) }
        let plan: CodexSetupPlan?
        if (configExists && config == nil) || (hooksExist && hooksData == nil) {
            plan = nil
        } else {
            plan = CodexSetupPlanner.plan(capabilities: capabilities, config: config ?? "",
                                          hooks: hooksData ?? Data("{}".utf8), helperPath: roots.helperURL,
                                          eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
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
        // A process that prints nothing (the helper self-test) is still a completed run.
        let data = (try? output.fileHandleForReading.read(upToCount: 64 * 1024)) ?? Data()
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
