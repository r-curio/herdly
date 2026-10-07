import Darwin
import Foundation
import Testing
@testable import SteerCore
@testable import SteerApp

// A fake herdr JSON socket in a temporary home. Nothing here contacts the user's herdr: every
// path is under a fresh `mkdtemp` directory, `herdr` is a shell script in that home's
// `.local/bin`, and lsof output is supplied by the test.

/// What the fake server does with one request line.
enum FakeHerdrResponse: Sendable {
    case line(String)
    /// Holds the connection open without replying until the server stops.
    case silent
    /// Writes these bytes and closes without a newline.
    case closeAfter(String)
}

/// One listening socket served on a background queue. The listener and connection descriptors are
/// touched only on `queue` and in `stop()`, which runs after the test's requests have completed;
/// `lock` guards the recorded requests, so the class is safe to share across those two contexts.
final class FakeHerdrServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "fake-herdr")
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    private var open: [Int32] = []
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)
    private let respond: @Sendable (_ method: String, _ id: String, _ params: [String: Any]) -> FakeHerdrResponse

    init(path: String, mode: mode_t = 0o600,
         respond: @escaping @Sendable (_ method: String, _ id: String, _ params: [String: Any]) -> FakeHerdrResponse) throws {
        self.path = path
        self.respond = respond
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, FakeHerdrServer.bind(listener, to: path), listen(listener, 8) == 0,
              chmod(path, mode) == 0 else { throw POSIXError(.EADDRINUSE) }
        queue.async { [self] in acceptLoop() }
    }

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Ends the accept loop before closing the listener, so its descriptor cannot be reused by
    /// another test while this loop still polls it.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        finished.wait()
        close(listener)
        lock.lock()
        let connections = open
        open = []
        lock.unlock()
        for fd in connections { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    static func bind(_ fd: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { raw in
                for (index, byte) in bytes.enumerated() { raw[index] = byte }
                raw[bytes.count] = 0
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop() {
        defer { finished.signal() }
        while !isStopped {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 20) > 0 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock(); open.append(fd); lock.unlock()
            serve(fd)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
        let line = buffer.prefix { $0 != 0x0A }
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = request["method"] as? String, let id = request["id"] as? String else { return }
        lock.lock(); recorded.append(request); lock.unlock()
        switch respond(method, id, request["params"] as? [String: Any] ?? [:]) {
        case .line(let text): write(fd, text + "\n")
        case .silent: return
        case .closeAfter(let text): write(fd, text)
        }
        lock.lock(); open.removeAll { $0 == fd }; lock.unlock()
        close(fd)
    }

    private func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }
}

/// A temporary home with herdr's directory layout. The path is kept short because Unix socket
/// paths are limited to 104 bytes.
struct HerdrLab {
    let home: URL
    var socketPath: String { home.appendingPathComponent(".config/herdr/herdr.sock").path }
    var bin: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }

    init() throws {
        var template = Array("/tmp/steer-herdr.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw POSIXError(.EIO) }
        home = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/herdr"), withIntermediateDirectories: true)
        // herdr creates its config directory 0755; the socket's own mode is what Steer checks.
        chmod(home.appendingPathComponent(".config/herdr").path, 0o755)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    /// Installs a fake `herdr` that prints `integration` for `integration status`.
    func installHerdr(integration: String, delaySeconds: Int = 0) throws {
        let script = """
        #!/bin/sh
        [ "$1 $2" = "integration status" ] || exit 2
        \(delaySeconds > 0 ? "sleep \(delaySeconds)" : "")
        cat <<'OUT'
        \(integration)
        OUT
        """
        let url = bin.appendingPathComponent("herdr")
        try script.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    /// Deadlines default far above ADR 0009's 1 s and 2 s so a loaded test machine cannot turn a
    /// test about something else into a timeout; deadline tests pass their own.
    func client(requestTimeout: Double = 10, subprocessTimeout: Double = 20, lsofClients: [Int32] = [93954],
                ancestry: @escaping @Sendable (Int32) -> [HerdrProcessAncestor] = { pid in
                    [HerdrProcessAncestor(pid: pid, command: "herdr", tty: "ttys015"),
                     HerdrProcessAncestor(pid: 828, command: "ghostty", tty: nil)]
                }) -> HerdrClient {
        var configuration = HerdrClient.Configuration(home: home, herdrDirectories: [bin])
        configuration.requestTimeout = requestTimeout
        configuration.subprocessTimeout = subprocessTimeout
        let clientSocket = configuration.clientSocketPath
        let lsofPath = configuration.lsofPath
        let lsof = herdrLsofOutput(clients: lsofClients).replacingOccurrences(of: herdrClientSocket, with: clientSocket)
        return HerdrClient(configuration: configuration, run: { executable, arguments, timeout, limit in
            if executable == lsofPath { return .success(lsof) }
            return HerdrSubprocess.run(executable: executable, arguments: arguments, timeout: timeout, limit: limit)
        }, ancestry: ancestry)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

let currentIntegrations = """
claude: current (v10) (/home/.claude/hooks/herdr-agent-state.sh)
codex: current (v8) (/home/.codex/herdr-agent-state.sh)
"""

/// A fake herdr 0.9.3 that answers `ping` and `session.snapshot`.
@Sendable func healthyHerdr(method: String, id: String, params: [String: Any]) -> FakeHerdrResponse {
    switch method {
    case "ping": return .line(herdrPongReply(id: id))
    case "session.snapshot": return .line(herdrSnapshotReply(id: id))
    default: return .line(#"{"id":"\#(id)","error":{"code":"unknown_method","message":"no"}}"#)
    }
}

@Test func herdrScanReadsSnapshotIntegrationAndTheOneGhosttyClient() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations)
    let server = try FakeHerdrServer(path: lab.socketPath, respond: healthyHerdr)
    defer { server.stop() }

    let outcome = lab.client().scan()
    let scan = try #require(outcome.scan)
    #expect(scan.snapshot.pane("w1:p1")?.agentSession?.value == herdrCodexSession)
    #expect(scan.integration.states == [.claude: .current(version: 10), .codex: .current(version: 8)])
    #expect(scan.client == .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)))
    #expect(outcome.targetReason(for: .codex) == nil)
    // One connection per request: ping first, then the snapshot.
    #expect(server.requests.map { $0["method"] as? String } == ["ping", "session.snapshot"])
}

@Test func herdrNotRunningWhenThereIsNoSocketOrNoListener() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations)
    #expect(lab.client().scan() == .unavailable(.notRunning))

    // A stale socket file left by an exited server refuses connections.
    let stale = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(FakeHerdrServer.bind(stale, to: lab.socketPath))
    close(stale)
    chmod(lab.socketPath, 0o600)
    #expect(lab.client().scan() == .unavailable(.notRunning))
}

@Test func herdrUntrustedSocketIsNeverContacted() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations)
    let server = try FakeHerdrServer(path: lab.socketPath, mode: 0o666, respond: healthyHerdr)
    defer { server.stop() }
    #expect(lab.client().scan() == .unavailable(.untrustedSocket))
    chmod(lab.socketPath, 0o640)
    #expect(lab.client().scan() == .unavailable(.untrustedSocket))
    #expect(server.requests.isEmpty)

    let regular = try HerdrLab()
    defer { regular.remove() }
    try Data().write(to: URL(fileURLWithPath: regular.socketPath))
    chmod(regular.socketPath, 0o600)
    #expect(regular.client().scan() == .unavailable(.untrustedSocket))
}

@Test func herdrUnsupportedProtocolStopsBeforeTheSnapshot() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations)
    let server = try FakeHerdrServer(path: lab.socketPath) { method, id, _ in
        method == "ping" ? .line(herdrPongReply(id: id, protocolVersion: 23)) : .line(herdrSnapshotReply(id: id))
    }
    defer { server.stop() }
    #expect(lab.client().scan() == .unavailable(.unsupportedProtocol(23)))
    #expect(server.requests.map { $0["method"] as? String } == ["ping"])
}

@Test func herdrSilentServerTimesOutWithinTheRequestDeadline() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations)
    let server = try FakeHerdrServer(path: lab.socketPath) { _, _, _ in .silent }
    defer { server.stop() }
    let started = DispatchTime.now().uptimeNanoseconds
    #expect(lab.client(requestTimeout: 0.2).scan() == .unavailable(.timeout))
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    #expect(elapsed >= 0.15 && elapsed < 1.5)
    // Not retried: one silent ping is the whole scan.
    #expect(server.requests.count == 1)
}

@Test func herdrMalformedRepliesAreUnavailable() throws {
    let replies: [@Sendable (String) -> FakeHerdrResponse] = [
        { _ in .line("not json") },
        { _ in .line(herdrPongReply(id: "someone-else")) },
        { id in .closeAfter(herdrPongReply(id: id)) },
        { id in .line(#"{"id":"\#(id)","result":{"type":"pong","version":"0.9.3"}}"#) },
    ]
    for reply in replies {
        let lab = try HerdrLab()
        defer { lab.remove() }
        try lab.installHerdr(integration: currentIntegrations)
        let server = try FakeHerdrServer(path: lab.socketPath) { _, id, _ in reply(id) }
        defer { server.stop() }
        #expect(lab.client().scan() == .unavailable(.malformedReply))
    }

    // A snapshot reply to the snapshot request that is missing a relied-on field.
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations)
    let server = try FakeHerdrServer(path: lab.socketPath) { method, id, _ in
        method == "ping" ? .line(herdrPongReply(id: id))
            : .line(#"{"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.9.3","protocol":22,"tabs":[]}}}"#)
    }
    defer { server.stop() }
    #expect(lab.client().scan() == .unavailable(.malformedReply))
}

@Test func herdrIntegrationNotCurrentIsReportedForThatAgentOnly() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: """
    claude: current (v10) (/home/.claude/hooks/herdr-agent-state.sh)
    codex: outdated (v7 < v8) (/home/.codex/herdr-agent-state.sh)
    """)
    let server = try FakeHerdrServer(path: lab.socketPath, respond: healthyHerdr)
    defer { server.stop() }
    let outcome = lab.client().scan()
    #expect(outcome.scan != nil)
    #expect(outcome.targetReason(for: .codex) == .integrationNotCurrent(.codex))
    #expect(outcome.targetReason(for: .claude) == nil)
}

@Test func herdrMissingFromTheFixedLocationsIsNotFound() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    let server = try FakeHerdrServer(path: lab.socketPath, respond: healthyHerdr)
    defer { server.stop() }
    #expect(lab.client().herdrExecutable() == nil)
    #expect(lab.client().scan() == .unavailable(.herdrNotFound))
    #expect(HerdrClient.Configuration(home: lab.home).herdrDirectories.map(\.path)
            == [lab.bin.path, "/opt/homebrew/bin", "/usr/local/bin"])
}

@Test func herdrSubprocessPastItsDeadlineIsTerminatedAsTimeout() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations, delaySeconds: 5)
    let server = try FakeHerdrServer(path: lab.socketPath, respond: healthyHerdr)
    defer { server.stop() }
    let started = DispatchTime.now().uptimeNanoseconds
    #expect(lab.client(subprocessTimeout: 0.3).scan() == .unavailable(.timeout))
    #expect(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 < 3)
}

@Test func herdrSubprocessFailureOrOversizedOutputIsMalformed() {
    #expect(HerdrSubprocess.run(executable: "/bin/sh", arguments: ["-c", "exit 3"], timeout: 20, limit: 100) == .failure(.malformedReply))
    #expect(HerdrSubprocess.run(executable: "/bin/sh", arguments: ["-c", "printf 0123456789"], timeout: 20, limit: 5)
            == .failure(.malformedReply))
    #expect(HerdrSubprocess.run(executable: "/bin/sh", arguments: ["-c", "printf ok"], timeout: 20, limit: 5) == .success("ok"))
}

@Test func herdrClientCountAndAncestryComeFromTheVerdict() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    try lab.installHerdr(integration: currentIntegrations)
    let server = try FakeHerdrServer(path: lab.socketPath, respond: healthyHerdr)
    defer { server.stop() }
    #expect(lab.client(lsofClients: [1, 2]).scan().targetReason(for: .codex) == .wrongClientCount(2))
    #expect(lab.client(lsofClients: []).scan().targetReason(for: .codex) == .wrongClientCount(0))
    let terminal = lab.client(ancestry: { pid in [HerdrProcessAncestor(pid: pid, command: "herdr", tty: "ttys002"),
                                                  HerdrProcessAncestor(pid: 1, command: "Terminal", tty: nil)] })
    #expect(terminal.scan().targetReason(for: .codex) == .nonGhosttyClient)
}

@Test func herdrKeysAreSentOnceAndRefusalsAreTyped() throws {
    let lab = try HerdrLab()
    defer { lab.remove() }
    let server = try FakeHerdrServer(path: lab.socketPath) { method, id, _ in
        method == "agent.send_keys" ? .line(#"{"id":"\#(id)","error":{"code":"agent_send_keys_failed","message":"full"}}"#)
            : .line(#"{"id":"\#(id)","result":{"type":"agent_info","agent":{}}}"#)
    }
    defer { server.stop() }
    let client = lab.client()
    #expect(client.sendKeys(target: "w1:p1", keys: ["2"]) == .failure(.requestRefused(code: "agent_send_keys_failed")))
    #expect(client.focusAgent(target: "w1:p1") == .success(.accepted(type: "agent_info")))
    let requests = server.requests
    #expect(requests.map { $0["method"] as? String } == ["agent.send_keys", "agent.focus"])
    #expect((requests[0]["params"] as? [String: Any])?["keys"] as? [String] == ["2"])
    #expect((requests[1]["params"] as? [String: Any])?["target"] as? String == "w1:p1")
}

// MARK: - Monitor

/// Counts scans; guarded by its lock so the detached scan and the test can both touch it.
final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor @Test func herdrMonitorScansOnlyInsideTheGateOnTheTwoSecondScan() async {
    let counter = ScanCounter()
    let monitor = HerdrMonitor { counter.increment(); return .unavailable(.notRunning) }
    var delivered: [HerdrScanOutcome] = []
    monitor.onScan = { delivered.append($0) }

    #expect(monitor.tick(now: 0, ghosttyControlsEnabled: false, herdrPaneIDs: ["w1:p1"]) == nil)
    #expect(monitor.tick(now: 0, ghosttyControlsEnabled: true, herdrPaneIDs: []) == nil)
    #expect(await monitor.revalidate() == nil)
    #expect(counter.count == 0)

    await monitor.tick(now: 10, ghosttyControlsEnabled: true, herdrPaneIDs: ["w1:p1"])?.value
    #expect(counter.count == 1)
    #expect(monitor.latest == .unavailable(.notRunning))
    #expect(monitor.latestStartedAt == 10)
    #expect(delivered == [.unavailable(.notRunning)])

    #expect(monitor.tick(now: 11.9, ghosttyControlsEnabled: true, herdrPaneIDs: ["w1:p1"]) == nil)
    await monitor.tick(now: 12, ghosttyControlsEnabled: true, herdrPaneIDs: ["w1:p1"])?.value
    #expect(counter.count == 2)

    #expect(await monitor.revalidate() == .unavailable(.notRunning))
    #expect(counter.count == 3)

    #expect(monitor.tick(now: 20, ghosttyControlsEnabled: false, herdrPaneIDs: ["w1:p1"]) == nil)
    #expect(monitor.latest == nil)
    #expect(counter.count == 3)
    // Reopening the gate scans at once rather than waiting out the old interval.
    await monitor.tick(now: 20.5, ghosttyControlsEnabled: true, herdrPaneIDs: ["w2:p1"])?.value
    #expect(counter.count == 4)
}

@MainActor @Test func herdrMonitorDropsAScanThatFinishesAfterTheGateCloses() async {
    let gate = DispatchSemaphore(value: 0)
    let monitor = HerdrMonitor { gate.wait(); return .unavailable(.timeout) }
    let task = monitor.tick(now: 0, ghosttyControlsEnabled: true, herdrPaneIDs: ["w1:p1"])
    #expect(task != nil)
    // While one scan is in flight no second scan starts.
    #expect(monitor.tick(now: 5, ghosttyControlsEnabled: true, herdrPaneIDs: ["w1:p1"]) == nil)
    monitor.tick(now: 6, ghosttyControlsEnabled: false, herdrPaneIDs: [])
    gate.signal()
    await task?.value
    #expect(monitor.latest == nil)
}

@Test func herdrProcessTreeReadsAncestryWithoutASubprocess() throws {
    let chain = HerdrProcessTree.ancestry(of: getpid())
    let first = try #require(chain.first)
    #expect(first.pid == getpid())
    #expect(!first.command.isEmpty)
    #expect(chain.count <= HerdrProcessTree.maximumDepth)
    #expect(Set(chain.map(\.pid)).count == chain.count)
    #expect(HerdrProcessTree.ancestry(of: 0).isEmpty)
}
