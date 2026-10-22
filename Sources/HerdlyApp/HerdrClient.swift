import Darwin
import Foundation
import HerdlyCore

/// Herdly's only route to herdr (ADR 0009): one short connection to herdr's default JSON socket per
/// request, plus two subprocesses, `herdr integration status` (for Claude Code) and `lsof`. Every call blocks for at
/// most its deadline and must run off the main actor. Nothing here retries: a failed read waits for
/// the next scan, and a focus or key is sent at most once because a retried key could answer twice.
/// Herdly never starts, stops or configures herdr and sends no credential.
struct HerdrClient: Sendable {
    struct Configuration: Sendable {
        /// The user's home; herdr's socket and `~/.local/bin` resolve against it.
        var home: URL
        /// Directories searched for `herdr`, in order. Never `PATH`.
        var herdrDirectories: [URL]
        /// Seconds from connect to the newline-terminated reply.
        var requestTimeout: Double = 1
        /// Seconds a subprocess may run before it is terminated.
        var subprocessTimeout: Double = 2
        var lsofPath = "/usr/sbin/lsof"

        init(home: URL = FileManager.default.homeDirectoryForCurrentUser, herdrDirectories: [URL]? = nil) {
            self.home = home
            self.herdrDirectories = herdrDirectories ?? [
                home.appendingPathComponent(".local/bin", isDirectory: true),
                URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            ]
        }

        /// herdr's default JSON socket. Named sessions are not targeted (ADR 0008).
        var socketPath: String { home.appendingPathComponent(".config/herdr/herdr.sock").path }
        /// The TUI client socket whose peers are the attached clients.
        var clientSocketPath: String { home.appendingPathComponent(".config/herdr/herdr-client.sock").path }
    }

    /// Runs `executable` with `arguments` and returns its stdout on a zero exit, `.timeout` past the
    /// deadline, and `.malformedReply` on any other exit or when stdout exceeds `limit` bytes.
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: Double,
                                  _ limit: Int) -> Result<String, HerdrUnavailableReason>

    let configuration: Configuration
    private let run: Runner
    private let ancestry: @Sendable (Int32) -> [HerdrProcessAncestor]
    private let startTime: @Sendable (Int32) -> Double?

    init(configuration: Configuration = Configuration(),
         run: @escaping Runner = HerdrSubprocess.run(executable:arguments:timeout:limit:),
         ancestry: @escaping @Sendable (Int32) -> [HerdrProcessAncestor] = HerdrProcessTree.ancestry(of:),
         startTime: @escaping @Sendable (Int32) -> Double? = HerdrProcessTree.startTime(of:)) {
        self.configuration = configuration
        self.run = run
        self.ancestry = ancestry
        self.startTime = startTime
    }

    // MARK: - Socket requests

    func ping() -> Result<HerdrReply, HerdrUnavailableReason> {
        request(method: "ping", params: [:])
    }

    func snapshot() -> Result<HerdrSnapshot, HerdrUnavailableReason> {
        request(method: "session.snapshot", params: [:]).flatMap { reply in
            if case .snapshot(let snapshot) = reply { return .success(snapshot) }
            return .failure(.malformedReply)
        }
    }

    /// `pane.process_info` for one pane: its foreground processes as herdr reads them from the
    /// pane's terminal (ADR 0012). A reply about another pane is malformed.
    func processInfo(paneID: String) -> Result<HerdrProcessInfo, HerdrUnavailableReason> {
        request(method: "pane.process_info", params: ["pane_id": paneID]).flatMap { reply in
            if case .processInfo(let info) = reply, info.paneID == paneID { return .success(info) }
            return .failure(.malformedReply)
        }
    }

    /// `agent.focus` on a live agent name or pane ID, sent once. Success means herdr accepted the
    /// request; the caller must confirm the result with a fresh snapshot (ADR 0011).
    func focusAgent(target: String) -> Result<HerdrReply, HerdrUnavailableReason> {
        request(method: "agent.focus", params: ["target": target])
    }

    /// `agent.send_keys`, sent once and never retried. Success means herdr queued the bytes, not
    /// that the agent read them. Callers own every check ADR 0010 requires before this.
    func sendKeys(target: String, keys: [String]) -> Result<HerdrReply, HerdrUnavailableReason> {
        trackedRequest(method: "agent.send_keys", params: ["target": target, "keys": keys]).result
    }

    /// `sendKeys` classified for ADR 0010: a failure after the write began counts as possibly sent.
    func sendKeysOnce(target: String, keys: [String]) -> HerdrKeyDelivery {
        let outcome = trackedRequest(method: "agent.send_keys", params: ["target": target, "keys": keys])
        return HerdrKeyDelivery.classify(outcome.result, writeAttempted: outcome.writeAttempted)
    }

    /// One request on one new connection: the socket trust check, connect, one request line, and
    /// one reply line with the matching id, all within `requestTimeout`.
    func request(method: String, params: [String: Any]) -> Result<HerdrReply, HerdrUnavailableReason> {
        trackedRequest(method: method, params: params).result
    }

    /// `request`, also reporting whether any byte of the request line could have been written.
    private func trackedRequest(method: String, params: [String: Any])
        -> (result: Result<HerdrReply, HerdrUnavailableReason>, writeAttempted: Bool) {
        let path = configuration.socketPath
        if let reason = HerdrSocketTrust.reason(at: path) { return (.failure(reason), false) }
        let id = UUID().uuidString
        guard let line = HerdrWire.requestLine(id: id, method: method, params: params) else {
            return (.failure(.malformedReply), false)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, configuration.requestTimeout) * 1_000_000_000)
        var writeAttempted = false
        let result = HerdrSocket.exchange(path: path, request: line, deadline: deadline,
                                          writeAttempted: &writeAttempted).flatMap {
            HerdrWire.decodeReply($0, expectedID: id)
        }
        return (result, writeAttempted)
    }

    // MARK: - Subprocesses

    /// The first executable `herdr` in the fixed directories.
    func herdrExecutable() -> String? {
        configuration.herdrDirectories
            .map { $0.appendingPathComponent("herdr").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func integrationStatus() -> Result<HerdrIntegrationReport, HerdrUnavailableReason> {
        guard let herdr = herdrExecutable() else { return .failure(.herdrNotFound) }
        return run(herdr, ["integration", "status"], configuration.subprocessTimeout,
                   HerdrIntegrationReport.maximumOutput).map(HerdrIntegrationReport.init(parsing:))
    }

    /// Lists unix sockets with lsof and applies the client verdict. A failed or unreadable lsof is a
    /// scan failure; a wrong count or non-Ghostty client is a verdict.
    func attachedClient() -> Result<Result<HerdrAttachedClient, HerdrUnavailableReason>, HerdrUnavailableReason> {
        clientListing().map { HerdrAttachedClient.verdict(listing: $0, ancestry: ancestry) }
    }

    private func clientListing() -> Result<HerdrClientListing, HerdrUnavailableReason> {
        run(configuration.lsofPath, ["-nP", "-U", "-F", "pfdn"], configuration.subprocessTimeout,
            HerdrClientListing.maximumOutput).flatMap { output in
            guard let listing = HerdrClientListing.parse(lsof: output, clientSocketPath: configuration.clientSocketPath)
            else { return .failure(.malformedReply) }
            return .success(listing)
        }
    }

    /// The start time of the listing's one server process, the server identity for ADR 0008's
    /// restart check; nil for zero or several server processes.
    private func serverStartedAt(_ listing: HerdrClientListing) -> Double? {
        guard listing.serverPIDs.count == 1, let pid = listing.serverPIDs.first else { return nil }
        return startTime(pid)
    }

    // MARK: - Scan

    /// One full read: socket trust, `ping` and its protocol, a snapshot, integration status when
    /// `request` asks for it, then the attached clients and the server's start time, then
    /// `pane.process_info` for the panes `request` selects, and last, when any of those panes carried
    /// a Codex title, a second snapshot that must show the same titles. The first scan-wide failure
    /// stops the scan and is its one reason; a failed `pane.process_info`, or a title that changed
    /// meanwhile, is kept as that pane's reason.
    func scan(_ request: HerdrScanRequest = HerdrScanRequest()) -> HerdrScanOutcome {
        if case .failure(let reason) = ping() { return .unavailable(reason) }
        let snapshot: HerdrSnapshot
        switch self.snapshot() {
        case .success(let value): snapshot = value
        case .failure(let reason): return .unavailable(reason)
        }
        var integration = HerdrIntegrationReport(states: [:])
        if request.includeIntegration {
            switch integrationStatus() {
            case .success(let value): integration = value
            case .failure(let reason): return .unavailable(reason)
            }
        }
        let listing: HerdrClientListing
        switch clientListing() {
        case .success(let value): listing = value
        case .failure(let reason): return .unavailable(reason)
        }
        var processInfo: [String: Result<HerdrProcessInfo, HerdrUnavailableReason>] = [:]
        for paneID in request.processInfoPanes(in: snapshot) { processInfo[paneID] = self.processInfo(paneID: paneID) }
        if snapshot.panes.contains(where: {
            processInfo[$0.paneID] != nil && $0.terminalTitle.map(request.processInfoTitles.contains) == true
        }) {
            // ADR 0012: a Codex title and its pane's foreground process must describe one pane state.
            switch self.snapshot() {
            case .success(let after): processInfo = request.confirmingTitles(processInfo, before: snapshot, after: after)
            case .failure(let reason): return .unavailable(reason)
            }
        }
        return .available(HerdrScan(snapshot: snapshot, integration: integration,
                                    client: HerdrAttachedClient.verdict(listing: listing, ancestry: ancestry,
                                                                        hostCommands: request.clientHostCommands),
                                    serverStartedAt: serverStartedAt(listing), processInfo: processInfo,
                                    clientPIDs: listing.clientPIDs))
    }
}

// MARK: - Socket exchange

/// Blocking non-blocking-socket I/O bounded by one absolute deadline.
enum HerdrSocket {
    /// Connects to `path`, writes `request`, and returns the reply line without its newline.
    /// A refused or vanished socket is `notRunning`; the deadline is `timeout`; a reply over the
    /// limit, or a connection closed before the newline, is `malformedReply`. A socket whose accepting
    /// process runs as another user is `untrustedSocket`, and nothing is written to it.
    static func exchange(path: String, request: Data, deadline: UInt64) -> Result<Data, HerdrUnavailableReason> {
        var writeAttempted = false
        return exchange(path: path, request: request, deadline: deadline, writeAttempted: &writeAttempted)
    }

    /// `exchange`, setting `writeAttempted` once the first `write` is issued: from then on a
    /// failure cannot rule out that herdr received some or all of the request.
    static func exchange(path: String, request: Data, deadline: UInt64,
                         writeAttempted: inout Bool) -> Result<Data, HerdrUnavailableReason> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.notRunning) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return .failure(.untrustedSocket) }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { raw in
                for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
                raw[pathBytes.count] = 0
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            switch errno {
            case EINPROGRESS, EAGAIN:
                guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return .failure(.timeout) }
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 else {
                    return .failure(.notRunning)
                }
            default:
                return .failure(.notRunning)
            }
        }
        // The socket's owner was checked before connecting; confirm the accepting process is this user's.
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { return .failure(.untrustedSocket) }

        var offset = 0
        while offset < request.count {
            writeAttempted = true
            let written = request.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), request.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return .failure(.timeout) }
            } else {
                return .failure(.notRunning)
            }
        }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                    reply.append(contentsOf: chunk[0..<newline])
                    return reply.count <= HerdrWire.maximumReply ? .success(reply) : .failure(.malformedReply)
                }
                reply.append(contentsOf: chunk[0..<count])
                guard reply.count <= HerdrWire.maximumReply else { return .failure(.malformedReply) }
            } else if count == 0 {
                return .failure(.malformedReply)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                guard wait(fd, for: Int16(POLLIN), until: deadline) else { return .failure(.timeout) }
            } else {
                return .failure(.malformedReply)
            }
        }
    }

    /// Polls `fd` for `events` until the absolute `deadline` (`DispatchTime` nanoseconds). False on
    /// timeout; true when the descriptor is ready or reports an error the next call will surface.
    private static func wait(_ fd: Int32, for events: Int16, until deadline: UInt64) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let milliseconds = Int32(min(UInt64(Int32.max), max(1, (deadline - now) / 1_000_000)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            if ready > 0 { return true }
            if ready < 0, errno != EINTR { return true }
        }
    }
}

// MARK: - Subprocesses

enum HerdrSubprocess {
    /// The `HerdrClient.Runner` used in the app: stderr is discarded, stdout is drained on a
    /// background queue so a large listing cannot stall the child, and the deadline applies to the
    /// child itself, which is terminated when it passes.
    @Sendable static func run(executable: String, arguments: [String], timeout: Double,
                              limit: Int) -> Result<String, HerdrUnavailableReason> {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure(.herdrNotFound) }
        // Written once by the drain block before `drained` is signalled and read only after the
        // wait on `drained` succeeds, so the semaphore orders every access.
        final class Box: @unchecked Sendable { var bytes: Data? }
        let box = Box()
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.bytes = try? reader.read(upToCount: limit + 1)
            drained.signal()
        }
        let deadline = DispatchTime.now() + max(0, timeout)
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            return .failure(.timeout)
        }
        // The drain runs at utility priority, which heavy load can starve after the child exits, so it
        // may use what is left of the deadline, and at least one second.
        guard drained.wait(timeout: max(deadline, .now() + 1)) == .success else { return .failure(.timeout) }
        guard process.terminationStatus == 0, let bytes = box.bytes,
              bytes.count <= limit else { return .failure(.malformedReply) }
        return .success(String(decoding: bytes, as: UTF8.self))
    }
}

/// A process's ancestry from the kernel's process table, without a subprocess.
enum HerdrProcessTree {
    static let maximumDepth = 16

    /// `pid` first, then each parent up to launchd or `maximumDepth`. Stops early when a process
    /// has exited or cannot be read.
    @Sendable static func ancestry(of pid: Int32) -> [HerdrProcessAncestor] {
        var chain: [HerdrProcessAncestor] = []
        var current = pid
        while current > 1, chain.count < maximumDepth {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { break }
            chain.append(HerdrProcessAncestor(pid: current, command: command(of: current, info: info),
                                              tty: tty(info.kp_eproc.e_tdev)))
            let parent = info.kp_eproc.e_ppid
            guard parent != current else { break }
            current = parent
        }
        return chain
    }

    /// When `pid` started, in seconds since 1970; nil when the process cannot be read.
    @Sendable static func startTime(of pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    private static func command(of pid: Int32, info: kinfo_proc) -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
        }
        var name = info.kp_proc.p_comm
        return withUnsafeBytes(of: &name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Cached device names (#301), shared with the kernel process table.
    private static func tty(_ device: dev_t) -> String? {
        KernelProcessTable.ttyName(device)
    }
}
