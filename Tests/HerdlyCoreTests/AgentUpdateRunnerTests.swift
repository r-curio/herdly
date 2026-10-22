import Foundation
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

/// A disposable shell script standing in for `claude` or `brew`; no real updater ever runs.
private func script(_ body: String) throws -> (command: AgentUpdateCommand, folder: URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-update-runner-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("fake-updater")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return (AgentUpdateCommand(executable: url.path, arguments: ["update"]), folder)
}

/// Serialized so `liveReaders` counts only the run under test.
@Suite(.serialized) struct AgentUpdateRunnerTests {
    @Test func runnerKeepsStdoutAndStderrSeparatelyWithTheExitStatus() throws {
        let fake = try script("echo \"ran $1\"; echo 'Error: disk full' >&2; exit 3")
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = AgentUpdateRunner.run(fake.command, limit: 10)
        #expect(result == .finished(status: 3, output: Data("ran update\n".utf8), errors: Data("Error: disk full\n".utf8)))
        #expect(AgentUpdateFailure.reason(result, command: fake.command) == "disk full")
    }

    @Test func runnerStopsACommandPastItsLimit() throws {
        let fake = try script("sleep 30")
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let started = Date()
        #expect(AgentUpdateRunner.run(fake.command, limit: 0.3) == .timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func runnerReportsAMissingExecutableAsNotStarted() {
        let missing = AgentUpdateCommand(executable: "/nonexistent/herdly-test/brew", arguments: ["upgrade"])
        #expect(AgentUpdateRunner.run(missing, limit: 1) == .couldNotStart)
    }

    @Test func runnerGivesTheCommandEmptyStdinAndAPathWithItsOwnFolder() throws {
        let fake = try script("read answer || echo no-input; echo \"$PATH\"")
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        guard case let .finished(status, output, _) = AgentUpdateRunner.run(fake.command, limit: 10) else {
            Issue.record("expected the script to finish")
            return
        }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(status == 0)
        #expect(lines.first == "no-input")
        #expect(lines.last?.hasPrefix(fake.folder.path + ":") == true)
        #expect(lines.last?.contains("/opt/homebrew/bin") == true)
    }

    @Test func runnerStopsTheWholeProcessGroupPastItsLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-update-group-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("grandchild.pid")
        // The grandchild inherits the pipes, as a real updater's helper would. Starting it and recording
        // its pid are the script's first, builtin-only steps; the 3-second limit leaves them ample time
        // under parallel test load, where 0.5 s sometimes expired before the shell ran at all.
        let fake = try script("sleep 30 &\necho $! > '\(pidFile.path)'\nwait")
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let started = Date()
        #expect(AgentUpdateRunner.run(fake.command, limit: 3) == .timedOut)
        #expect(Date().timeIntervalSince(started) < 3 + AgentUpdateRunner.terminationGrace + 3)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try #require(pid_t(text))
        // Once killed it is reparented and reaped; until then a zombie still answers signal 0.
        let deadline = Date().addingTimeInterval(3)
        while kill(grandchild, 0) == 0, Date() < deadline { usleep(20_000) }
        #expect(kill(grandchild, 0) == -1 && errno == ESRCH)
    }

    /// A descendant that leaves the command's group (as `setsid` or a daemon does) survives the group
    /// kill and keeps the pipes open; the run must still end without leaving its readers behind.
    @Test func runnerStopsItsReadersWhenADescendantEscapesTheGroup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-update-escape-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("escaped.pid")
        let escape = "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(my $f, \">\", $ARGV[0]) or die; print $f $$; close $f; sleep 30' '\(pidFile.path)' &\nwait"
        let fake = try script(escape)
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text) { kill(pid, SIGKILL) }
        }
        #expect(AgentUpdateRunner.run(fake.command, limit: 3) == .timedOut)
        let escaped = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(escaped, 0) == 0)   // It really is still holding the pipes.
        #expect(AgentUpdateRunner.liveReaders == 0)
    }
}
