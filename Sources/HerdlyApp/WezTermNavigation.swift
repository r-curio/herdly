import Darwin
import Foundation
import HerdlyCore

/// WezTerm's command line (#240): `wezterm cli` from a fixed path, pinned to the one GUI socket that
/// passes the owner-only trust check, with a minimal environment. Called only while WezTerm's switch is
/// on. Blocking: call off the main actor. Nothing here launches WezTerm (`--no-auto-start`), creates a
/// pane, or sends text anywhere but the one pane id passed in. Rules are HerdlyCore's (`WezTerm.swift`).
enum WezTermNavigation {
    static let bundleIdentifier = "com.github.wez.wezterm"
    /// Most socket-directory entries looked at; a larger directory is unreadable rather than guessed.
    private static let maximumSocketEntries = 256

    /// The first executable `wezterm` in its fixed locations; never `PATH`.
    static func binary() -> String? {
        WezTermCLI.binaryCandidates(home: NSHomeDirectory()).first { path in
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
        }
    }

    /// The running GUI's socket after the trust check: the one `gui-sock-<pid>` whose pid runs WezTerm's
    /// app, a Unix socket owned by this user with no group or other permission bits.
    static func socket() -> Result<String, WezTermUnreadable> {
        let directory = WezTermCLI.socketDirectory(home: NSHomeDirectory())
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return .failure(.socketMissing) }
        guard names.count <= maximumSocketEntries else { return .failure(.socketMissing) }
        let candidates = names.map { name in
            WezTermSocketCandidate(name: name, runsWezTerm: WezTermSocketCandidate.pid(fromName: name).map {
                TerminalApps.appBundleIdentifier(of: $0) == bundleIdentifier
            } ?? false)
        }
        switch WezTermSocket.choose(candidates) {
        case .failure(let reason): return .failure(reason)
        case .success(let name):
            let path = (directory as NSString).appendingPathComponent(name)
            if let problem = WezTermSocket.trust(at: path) { return .failure(problem) }
            return .success(path)
        }
    }

    /// One read of a running WezTerm: `list`, and `list-clients` when `clients` is set (nil when that run
    /// failed). A WezTerm that is not running holds nothing and is not asked.
    static func read(running: Bool, clients: Bool = false) -> (WezTermRead, WezTermClients?) {
        guard running else { return (.notRunning, nil) }
        let list = WezTermRead.list(run(WezTermCLI.list))
        guard clients, list.snapshot != nil else { return (list, nil) }
        guard case .exited(0, let stdout, _) = run(WezTermCLI.listClients) else { return (list, nil) }
        return (list, WezTermClients.parse(stdout))
    }

    /// ADR 0016's select step, sent once.
    static func activate(_ target: TerminalTabTarget) -> WezTermCommandResult {
        guard let arguments = WezTermCLI.activate(pane: target.tabID) else {
            return .exited(status: 1, stdout: Data(), stderr: "no such pane")
        }
        return run(arguments)
    }

    /// ADR 0017: one `send-text --no-paste` into `pane`.
    static func send(_ payload: String, into pane: TypedInputPane) -> WezTermCommandResult {
        guard pane.host == .wezTerm, let arguments = WezTermInput.send(payload, pane: pane.paneID) else {
            return .notRun(.commandFailed)
        }
        return run(arguments)
    }

    /// Runs `wezterm` once with `arguments`: bounded by `WezTermCLI.timeout`, stdout by
    /// `WezTermCLI.outputLimit`, stderr by 4 KiB. A run that passes its deadline is terminated.
    static func run(_ arguments: [String]) -> WezTermCommandResult {
        guard let binary = binary() else { return .notRun(.binaryNotFound) }
        let socket: String
        switch self.socket() {
        case .failure(let reason): return .notRun(reason)
        case .success(let path): socket = path
        }
        return execute(binary, arguments, environment: WezTermCLI.environment(home: NSHomeDirectory(), socket: socket))
    }

    /// The installed `wezterm --version`, for the card only; nil when it can't be read. WezTerm's app
    /// bundle reports a placeholder version, so the binary is asked. Needs no socket and no running WezTerm.
    static func version() -> String? {
        guard let binary = binary(),
              case .exited(0, let stdout, _) = execute(binary, WezTermCLI.versionArguments,
                                                       environment: WezTermCLI.versionEnvironment(home: NSHomeDirectory()))
        else { return nil }
        return WezTermCLI.version(stdout)
    }

    private static func execute(_ binary: String, _ arguments: [String], environment: [String: String]) -> WezTermCommandResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .notRun(.binaryNotFound) }
        // Written by the drain blocks before `drained` is signalled and read only after both waits
        // succeed, so the semaphore orders every access.
        final class Box: @unchecked Sendable { var stdout: Data?; var stderr: Data? }
        let box = Box()
        let limit = WezTermCLI.outputLimit
        DispatchQueue.global(qos: .utility).async {
            box.stdout = try? output.fileHandleForReading.read(upToCount: limit + 1)
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            box.stderr = try? errors.fileHandleForReading.read(upToCount: 4096)
            drained.signal()
        }
        let deadline = DispatchTime.now() + WezTermCLI.timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            return .timedOut
        }
        let rest = max(deadline, .now() + 1)
        guard drained.wait(timeout: rest) == .success, drained.wait(timeout: rest) == .success else { return .timedOut }
        let stdout = box.stdout ?? Data()
        guard stdout.count <= limit else {
            return .exited(status: process.terminationStatus == 0 ? 1 : process.terminationStatus, stdout: Data(), stderr: "oversized")
        }
        return .exited(status: process.terminationStatus, stdout: stdout,
                       stderr: String(decoding: box.stderr ?? Data(), as: UTF8.self))
    }
}
