import Foundation
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

// #270: Herdly's terminal scripts address the process Herdly read, never the app by bundle id, so an
// app that quit is reported as not running instead of being launched again.

private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/HerdlyApp/Resources", isDirectory: true)

/// Above the kernel's highest process id (99 999), so no process ever has it and nothing can answer.
private let absentPID: pid_t = 99_999_999

private func status(_ data: Data?) -> String? {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["status"] as? String
}

@Test func requestArgumentCarriesTheProcessIDAlongsideTheRequest() throws {
    let argument = try #require(TerminalScript.argument(["action": "select", "session": "w0t0p0"], pid: 4321))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(argument.utf8)) as? [String: Any])
    #expect(object["pid"] as? Int == 4321)
    #expect(object["action"] as? String == "select")
    #expect(object["session"] as? String == "w0t0p0")
}

@Test func noScriptBuildsAnApplicationObjectThatCouldLaunchItsApp() throws {
    for script in TerminalScript.allCases {
        let source = try #require(script.source(in: resources))
        // JXA's `Application(...)` launches a quit app on its next event, even one built from a pid.
        #expect(!source.contains("Application("), "\(script.rawValue)")
        #expect(source.contains("descriptorWithProcessIdentifier"), "\(script.rawValue)")
    }
}

@Test func everyScriptCompilesWithTheAppleEventLayer() throws {
    for script in TerminalScript.allCases {
        let source = try #require(script.source(in: resources))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(script.rawValue)-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-l", "JavaScript", "-o", output.path, "-e", source]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(script.rawValue): \(message)")
    }
}

/// Runs the bundled script for real against a process id nothing has. Only after the source check
/// passes, so a script that could still address an app by bundle id is never run here.
@Test func aProcessThatIsGoneAnswersNotRunningForEveryAction() throws {
    let requests: [TerminalScript: [[String: Any]]] = [
        .iTerm2: [["action": "snapshot"], ["action": "select", "session": "S", "tty": "/dev/ttys001"]],
        .terminalApp: [["action": "snapshot"], ["action": "raise", "window": 1, "tty": "/dev/ttys001"],
                       ["action": "type", "window": 1, "tty": "/dev/ttys001", "text": "hello"]],
        .ghostty: [["action": "snapshot"], ["action": "select_sole",
                                             "target": ["window_id": "1", "tab_id": "1", "terminal_id": "1"]]],
    ]
    for script in TerminalScript.allCases {
        let source = try #require(script.source(in: resources))
        try #require(!source.contains("Application("))
        for request in requests[script] ?? [] {
            let reply = script.run(request, pid: absentPID, resources: resources, deadline: 60)
            #expect(status(reply) == script.notRunningStatus, "\(script.rawValue) \(request["action"] ?? "")")
        }
    }
}

@Test func noProcessAnswersNotRunningWithoutRunningTheScript() {
    for script in TerminalScript.allCases {
        // No resources: the reply cannot have come from the script.
        #expect(status(script.run(["action": "snapshot"], pid: nil, resources: nil)) == script.notRunningStatus)
    }
}

@Test func aNotRunningReplyReadsAsNotRunningOnEveryHost() {
    let iTerm2 = TerminalScript.iTerm2.run(["action": "snapshot"], pid: nil, resources: nil)
    #expect(ITerm2Navigation.inventory(iTerm2.flatMap(ITerm2Reading.parse)) == .notRunning)
    let terminal = TerminalScript.terminalApp.run(["action": "snapshot"], pid: nil, resources: nil)
    #expect(TerminalAppNavigation.read(terminal.map(TerminalAppScriptResult.reply) ?? .failed) == .notRunning)
    // Ghostty's not-running reply is no inventory, as before.
    let ghostty = TerminalScript.ghostty.run(["action": "snapshot"], pid: nil, resources: nil)
    #expect(ghostty.flatMap { try? JSONDecoder().decode(GhosttySnapshot.self, from: $0) } == nil)
}

@Test func onlyTheAppsOwnGUIProcessIsAddressedNeverACommandLineRunOfItsBinary() {
    typealias Candidate = TerminalAppProcess.Candidate
    let ghostty = "com.mitchellh.ghostty"
    // `ghostty +list-themes` run from a terminal started earlier than the app: it has a controlling tty.
    let cli = Candidate(pid: 100, bundleIdentifier: ghostty, started: 10, hasControllingTerminal: true)
    let app = Candidate(pid: 200, bundleIdentifier: ghostty, started: 20, hasControllingTerminal: false)
    let laterApp = Candidate(pid: 300, bundleIdentifier: ghostty, started: 30, hasControllingTerminal: false)
    let other = Candidate(pid: 50, bundleIdentifier: "com.googlecode.iterm2", started: 1, hasControllingTerminal: false)
    let unknown = Candidate(pid: 40, bundleIdentifier: nil, started: 2, hasControllingTerminal: false)
    #expect(TerminalAppProcess.choose([cli, laterApp, app, other, unknown], bundleIdentifier: ghostty) == 200)
    #expect(TerminalAppProcess.choose([cli], bundleIdentifier: ghostty) == nil)
    #expect(TerminalAppProcess.choose([other, unknown], bundleIdentifier: ghostty) == nil)
    #expect(TerminalAppProcess.choose([], bundleIdentifier: ghostty) == nil)
}

@Test func terminalAppTypingIntoAQuitTerminalWroteNothing() {
    // The script answers `not_running` only when no `do script` event reached Terminal.
    let reply = TerminalAppScriptResult.reply(Data(#"{"status":"not_running"}"#.utf8))
    #expect(TerminalAppInput.delivery(reply) == .notWritten)
}
