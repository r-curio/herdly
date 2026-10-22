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

@Test func requestArgumentCarriesTheProcessIDAndDeadlineAlongsideTheRequest() throws {
    let argument = try #require(TerminalScript.argument(["action": "select", "session": "w0t0p0"], pid: 4321, deadline: 812.5))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(argument.utf8)) as? [String: Any])
    #expect(object["pid"] as? Int == 4321)
    #expect(object["deadline"] as? Double == 812.5)
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

// MARK: - In-process scripts (#303)

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// A script that counts its runs in a global, so a second run that sees the count proves the compiled
/// script was kept and reused.
private let counting = """
    ObjC.import('Foundation');
    let runs = 0;
    function run(argv) {
        runs += 1;
        const request = JSON.parse(argv[0]);
        if (request.sleep) $.NSThread.sleepForTimeInterval(request.sleep);
        return JSON.stringify({runs: runs, echo: request.echo === undefined ? null : request.echo, argc: argv.length});
    }
    """

private func reply(_ text: String?) -> [String: Any]? {
    text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

@Suite(.serialized) struct InProcessScriptTests {
    @Test func aScriptRunsInProcessWithItsArgumentAndIsCompiledOnce() throws {
        let key = "counting-\(UUID().uuidString)"
        let first = try #require(reply(AppleEventScripts.shared.run(key: key, source: { counting }, argument: #"{"echo":"a"}"#,
                                                                    until: uptime() + 30)))
        let second = try #require(reply(AppleEventScripts.shared.run(key: key, source: { nil }, argument: #"{"echo":"b"}"#,
                                                                     until: uptime() + 30)))
        #expect(first["echo"] as? String == "a")
        #expect(first["argc"] as? Int == 1)
        #expect(first["runs"] as? Int == 1)
        // No source the second time: the compiled script was reused, with its state.
        #expect(second["echo"] as? String == "b")
        #expect(second["runs"] as? Int == 2)
    }

    @Test func callersOnManyThreadsEachGetTheirOwnReply() async {
        let key = "concurrent-\(UUID().uuidString)"
        let echoes = await withTaskGroup(of: String?.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let text = AppleEventScripts.shared.run(key: key, source: { counting }, argument: #"{"echo":"\#(index)"}"#,
                                                            until: uptime() + 30)
                    return reply(text)?["echo"] as? String
                }
            }
            var all: [String] = []
            for await echo in group { if let echo { all.append(echo) } }
            return all
        }
        #expect(Set(echoes) == Set((0..<8).map(String.init)))
    }

    @Test func aScriptThatOutlivesItsDeadlineIsAbandonedAndAQueuedRequestPastItsDeadlineNeverStarts() throws {
        let key = "late-\(UUID().uuidString)"
        let started = uptime()
        // Sleeps four seconds against a one-second deadline: the caller gives up after the deadline and grace.
        #expect(AppleEventScripts.shared.run(key: key, source: { counting }, argument: #"{"sleep":4}"#, until: started + 1) == nil)
        let waited = uptime() - started
        #expect(waited >= 1 && waited < 1 + AppleEventScripts.grace + 1)
        // Queued behind the sleeping script; its deadline passes before it could start.
        #expect(AppleEventScripts.shared.run(key: key, source: { counting }, argument: #"{"echo":"skipped"}"#,
                                             until: uptime() + 0.2) == nil)
        let next = try #require(reply(AppleEventScripts.shared.run(key: key, source: { counting }, argument: #"{"echo":"next"}"#,
                                                                   until: uptime() + 30)))
        #expect(next["echo"] as? String == "next")
        // The sleeping run and this one; the skipped request never ran.
        #expect(next["runs"] as? Int == 2)
    }

    @Test func aScriptThatThrowsOrDoesNotCompileIsNil() {
        let throwing = "function run(argv) { throw new Error('no'); }"
        #expect(AppleEventScripts.shared.run(key: "throws-\(UUID().uuidString)", source: { throwing }, argument: "{}",
                                             until: uptime() + 30) == nil)
        #expect(AppleEventScripts.shared.run(key: "broken-\(UUID().uuidString)", source: { "function run(argv) {" },
                                             argument: "{}", until: uptime() + 30) == nil)
        #expect(AppleEventScripts.shared.run(key: "missing-\(UUID().uuidString)", source: { nil }, argument: "{}",
                                             until: uptime() + 30) == nil)
    }

    /// The Apple Event layer itself, against a process id nothing has: no event is sent once the deadline
    /// has passed, and a request without a deadline fails instead of waiting unbounded.
    @Test func theAppleEventLayerSendsNothingPastTheDeadlineAndRequiresOne() throws {
        let layer = try String(contentsOf: resources.appendingPathComponent("AppleEvents.js"), encoding: .utf8)
        let probe = layer + """

            function run(argv) {
                const request = JSON.parse(argv[0]);
                return AppleEvents.run(request.pid, request.deadline, {status: 'gone'},
                                       app => app.get(AppleEvents.property(null, 'pnam')));
            }
            """
        let key = "layer-\(UUID().uuidString)"
        func send(_ deadline: Double?) -> String? {
            var request: [String: Any] = ["pid": Int(absentPID)]
            if let deadline { request["deadline"] = deadline }
            let argument = String(decoding: try! JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            return AppleEventScripts.shared.run(key: key, source: { probe }, argument: argument, until: uptime() + 60)
        }
        // In time, the event reaches no process: gone.
        #expect(status(send(uptime() + 30).map { Data($0.utf8) }) == "gone")
        // Past the deadline the request fails; it is not reported as gone.
        #expect(send(uptime() - 1) == nil)
        #expect(send(nil) == nil)
    }

    @Test func aReplyOverTwoMebibytesIsAFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "const Layer = {};".write(to: directory.appendingPathComponent("AppleEvents.js"), atomically: true, encoding: .utf8)
        try """
            function run(argv) {
                const request = JSON.parse(argv[0]);
                if (request.size) return 'x'.repeat(request.size);
                return JSON.stringify({status: 'ok', pid: request.pid, deadline: request.deadline});
            }
            """.write(to: directory.appendingPathComponent("Ghostty.js"), atomically: true, encoding: .utf8)
        let before = uptime()
        let echoed = try #require(reply(TerminalScript.ghostty.run(["action": "snapshot"], pid: 4321, resources: directory)
            .map { String(decoding: $0, as: UTF8.self) }))
        #expect(echoed["pid"] as? Int == 4321)
        let deadline = try #require(echoed["deadline"] as? Double)
        #expect(deadline >= before + 5 && deadline <= uptime() + 5)
        #expect(TerminalScript.ghostty.run(["size": TerminalScript.maximumReply], pid: 4321, resources: directory)?.count
                    == TerminalScript.maximumReply)
        #expect(TerminalScript.ghostty.run(["size": TerminalScript.maximumReply + 1], pid: 4321, resources: directory) == nil)
    }
}
