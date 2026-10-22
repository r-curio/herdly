import Darwin
import Foundation
import HerdlyCore

/// Herdly's only route to Zellij (#242, ADR 0014): the `zellij` binary from a fixed location, sessions
/// found by listing the default socket directory (`<user temporary directory>/zellij-<uid>/
/// contract_version_1`) directly and addressed with `--session <name>`. Herdly never runs `zellij
/// list-sessions`, never sets `ZELLIJ_SOCKET_DIR`, and passes Zellij a minimal environment whose
/// `TMPDIR` is the user temporary directory, so Zellij resolves the same default directory. Every
/// command has a bounded wait and bounded output; nothing is retried. Called only while Zellij may be
/// contacted (its switch and a terminal on). Blocking: call off the main actor. Herdly never edits
/// Zellij's configuration.
///
/// An isolated Zellij 0.45.1 run (#242) showed that any `zellij action`, like `list-sessions`, deletes a
/// socket in the directory that refuses a connection. Herdly connects to each socket itself first and runs
/// no `zellij` command at all while any socket refuses (`ZellijReader`), so reading never changes the
/// user's Zellij state.
enum ZellijRunner {
    /// Seconds any one command may run before it is terminated.
    static let timeout: Double = 2
    static let maximumStderr = 4096
    /// Socket entries read from the default directory; more is unreadable rather than partial.
    static let maximumEntries = 256

    static func binary() -> String? {
        ZellijBinary.resolve(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// The per-user temporary directory macOS gives every process of this user (`$TMPDIR` in a shell).
    static func temporaryDirectory() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func socketDirectory() -> String? {
        temporaryDirectory().flatMap { ZellijSocketDirectory.path(temporaryDirectory: $0, uid: getuid()) }
    }

    /// The effects `ZellijReader` orders: the fresh directory listing, Herdly's own socket probe, the binary,
    /// the bounded command runner and the process table.
    static var effects: ZellijEffects {
        ZellijEffects(socketDirectory: socketDirectory(), me: getuid(),
                      listing: { socketDirectory().flatMap(listing) },
                      probe: { path in
                          switch TmuxRunner.peer(path) {
                          case .refused: .refused
                          case .otherUser: .otherUser
                          case .currentUser: .currentUser
                          }
                      },
                      binaryPresent: { binary() != nil },
                      run: { run($0) },
                      processTable: { processTable() })
    }

    /// One read (`ZellijReader.read`): no `zellij` command runs unless every socket in the default
    /// directory accepts a connection.
    static func read() -> ZellijRead {
        ZellijReader.read(effects)
    }

    /// A command that types or moves focus, sent only after a fresh directory check and a re-read of the
    /// bound pane (`ZellijReader.send`).
    static func send(_ arguments: [String], to target: ZellijPaneTarget, expecting expected: ZellijServerIdentity?) -> ZellijCommandOutcome {
        ZellijReader.send(arguments, to: target, expecting: expected, effects: effects)
    }

    /// The process table, each of this user's `zellij` processes' arguments and each one's start time, from the kernel
    /// (#303): the table in `ps -axo pid=,ppid=,uid=,tty=,comm=` form, so `ZellijProcessTable.parse` reads
    /// it exactly as it read `ps`.
    static func processTable() -> ZellijProcessTable? {
        // Every own process's vector, not only `zellij`'s: `comm` is argv[0], and Zellij targeting finds
        // `codex` under a server by it, where `p_comm` can differ (the exec'd file's name, cut at 16 bytes).
        // Other users' processes are never clients or servers (ADR 0014) and show the kernel's short name.
        guard let records = KernelProcessTable.records(arguments: .owner(getuid())),
              let table = ProcessListing.pidPPIDUIDTTYComm(records, limit: ZellijListing.maximumOutput),
              let parsed = ZellijProcessTable.parse(table, owner: getuid(), arguments: [:], startTimes: [:]) else { return nil }
        var vectors: [Int32: [String]] = [:]
        for record in records { if let argv = record.arguments { vectors[record.pid] = argv } }
        var arguments: [Int32: [String]] = [:]
        var starts: [Int32: Double] = [:]
        for pid in parsed.zellijPIDs {
            if let argv = vectors[pid] { arguments[pid] = argv }
            if let started = HerdrProcessTree.startTime(of: pid) { starts[pid] = started }
        }
        return ZellijProcessTable(processes: Array(parsed.processes.values), owner: parsed.owner, arguments: arguments,
                                  startTimes: starts)
    }

    /// Runs one Zellij command. Stdout over `ZellijListing.maximumOutput` is a failure.
    static func run(_ arguments: [String]) -> ZellijCommandOutcome {
        guard let executable = binary(), let temporary = temporaryDirectory() else { return .notLaunched }
        // No ZELLIJ* variables: no inherited session or socket directory. TMPDIR makes Zellij resolve the
        // default socket directory Herdly listed.
        let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": temporary]
        return bounded(executable, arguments, environment: environment) ?? .notLaunched
    }

    /// Runs `executable` with a bounded wait, stdout and stderr drained off the calling thread. nil when it
    /// could not be started.
    private static func bounded(_ executable: String, _ arguments: [String], environment: [String: String]) -> ZellijCommandOutcome? {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // Written once by each drain block before its signal and read only after both waits succeed, so
        // the semaphore orders every access.
        final class Box: @unchecked Sendable { var bytes: Data?; var errors: Data? }
        let box = Box()
        let reader = output.fileHandleForReading, errorReader = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.bytes = try? reader.read(upToCount: ZellijListing.maximumOutput + 1)
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            box.errors = try? errorReader.read(upToCount: maximumStderr)
            drained.signal()
        }
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            return .timedOut
        }
        guard drained.wait(timeout: max(deadline, .now() + 1)) == .success,
              drained.wait(timeout: max(deadline, .now() + 1)) == .success else { return .timedOut }
        guard process.terminationStatus == 0 else {
            return .failed(stderr: String(decoding: box.errors ?? Data(), as: UTF8.self))
        }
        guard let bytes = box.bytes, bytes.count <= ZellijListing.maximumOutput else { return .failed(stderr: "") }
        return .succeeded(String(decoding: bytes, as: UTF8.self))
    }

    /// A fresh `lstat` listing of the contract directory and its parent, with each socket entry by name;
    /// entries of other kinds are never addressed. No sockets when the directory does not exist; nil when it
    /// cannot be listed or is too large.
    private static func listing(_ directory: String) -> ZellijDirectoryListing? {
        let base = facts((directory as NSString).deletingLastPathComponent)
        guard let contract = facts(directory) else { return ZellijDirectoryListing(base: base, directory: nil, sockets: [:]) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
              names.count <= maximumEntries else { return nil }
        var sockets: [String: TmuxFileFacts] = [:]
        for name in names {
            guard let entry = facts("\(directory)/\(name)") else { continue }
            if entry.kind == .socket { sockets[name] = entry }
        }
        return ZellijDirectoryListing(base: base, directory: contract, sockets: sockets)
    }

    private static func facts(_ path: String) -> TmuxFileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: TmuxFileFacts.Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFSOCK: kind = .socket
        default: kind = .other
        }
        return TmuxFileFacts(kind: kind, owner: info.st_uid, mode: UInt16(info.st_mode & 0o7777))
    }
}
