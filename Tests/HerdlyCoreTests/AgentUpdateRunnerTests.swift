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
    // The grandchild inherits the pipes, as a real updater's helper would.
    let fake = try script("sleep 30 &\necho $! > '\(pidFile.path)'\nwait")
    defer { try? FileManager.default.removeItem(at: fake.folder) }
    let started = Date()
    #expect(AgentUpdateRunner.run(fake.command, limit: 0.5) == .timedOut)
    #expect(Date().timeIntervalSince(started) < 5)
    let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let grandchild = try #require(pid_t(text))
    // Once killed it is reparented and reaped; until then a zombie still answers signal 0.
    let deadline = Date().addingTimeInterval(3)
    while kill(grandchild, 0) == 0, Date() < deadline { usleep(20_000) }
    #expect(kill(grandchild, 0) == -1 && errno == ESRCH)
}
