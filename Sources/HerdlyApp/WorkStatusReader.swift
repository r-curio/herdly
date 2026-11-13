import Foundation
import HerdlyCore

/// One read-only command for work status (#417, ADR 0023): `git` in a session's folder, or `gh`.
struct WorkStatusCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: Double
}

enum WorkStatusCommandResult: Equatable, Sendable {
    case succeeded(Data)
    case failed(Int32)
    case timedOut
    /// The output passed its limit; nothing of it is used.
    case tooLarge
    case notLaunched
}

protocol WorkStatusCommandRunning: Sendable {
    func run(_ command: WorkStatusCommand) -> WorkStatusCommandResult
}

/// The switch as the off-main readers see it. Every command checks it immediately before it starts,
/// so turning the switch off stops the next command, not only the next batch.
final class WorkStatusGate: @unchecked Sendable {
    // `@unchecked Sendable`: `open` is read and written only under `lock`.
    private let lock = NSLock()
    private var open: Bool

    init(open: Bool) { self.open = open }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func set(_ value: Bool) {
        lock.lock()
        open = value
        lock.unlock()
    }
}

/// Reads how far a finished turn's work got: read-only `git` in its folder (no network) and one `gh pr
/// list` for its remembered branch. Every command has a bounded wait and is never retried here; the
/// schedule in `WorkStatusSchedule` decides when a turn is read again. Blocking: call off the main
/// actor. Herdly stores no token: `gh` uses the user's own sign-in.
struct WorkStatusReader: Sendable {
    static let gitTimeout: Double = 3
    static let ghTimeout: Double = 10
    /// `gh --version` prints locally; it never waits on the network.
    static let versionTimeout: Double = 3

    let runner: any WorkStatusCommandRunning
    let gate: WorkStatusGate
    let git: String?
    let gh: String?
    let home: String

    init(runner: any WorkStatusCommandRunning, gate: WorkStatusGate, git: String?, gh: String?,
         home: String = NSHomeDirectory()) {
        self.runner = runner
        self.gate = gate
        self.git = git
        self.gh = gh
        self.home = home
    }

    /// The installed tools, found in their usual locations.
    static func live(gate: WorkStatusGate) -> WorkStatusReader {
        let home = NSHomeDirectory()
        let executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        return WorkStatusReader(runner: ProcessWorkStatusRunner(), gate: gate,
                                git: WorkStatusTools.git(isExecutable: executable),
                                gh: WorkStatusTools.gh(home: home, isExecutable: executable), home: home)
    }

    /// The finished turn's verdict from fresh readings. Nothing runs while the gate is closed.
    func verdict(_ branch: WorkBranch) -> WorkStatus {
        switch branch {
        case .unknown, .ambiguous:
            return .noVerdict
        case .detached(let directory):
            return WorkStatusRule.verdict(branch: branch, local: local(directory), pullRequest: nil)
        case .branch(let name, let directory, let startedAt, let repository):
            let local = local(directory)
            let lookup = repository.map { pullRequest(repository: $0, branch: name, startedAt: startedAt) }
            return WorkStatusRule.verdict(branch: branch, local: local, pullRequest: lookup)
        }
    }

    /// GitHub's "owner/name" for the folder's `origin`, read once while a turn runs. No origin, another
    /// host, or a failed read all count as not on GitHub, so no GitHub call is ever made for it.
    func repository(_ directory: String) -> WorkRepository {
        guard case .succeeded(let output)? = git(directory, ["config", "--get", "remote.origin.url"]),
              let name = GitHubRepositoryName.parse(remoteURL: String(decoding: output, as: UTF8.self)) else {
            return .notOnGitHub
        }
        return .gitHub(name)
    }

    /// The folder's branch, changes and unpushed commits. Nil when it is not a work tree, or any read
    /// fails, times out or prints something unexpected.
    func local(_ directory: String) -> GitLocalReading? {
        guard case .succeeded(let output)? = git(directory, ["status", "--porcelain=v2", "--branch",
                                                            "--untracked-files=normal"]),
              var reading = GitLocalReading.parse(status: String(decoding: output, as: UTF8.self)) else { return nil }
        if reading.needsRemoteCount {
            // Count commits on no remote, but only when a remote exists to push to.
            if case .succeeded(let remotes)? = git(directory, ["remote"]),
               !String(decoding: remotes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               case .succeeded(let count)? = git(directory, ["rev-list", "--count", "HEAD", "--not", "--remotes"]) {
                reading.unpushed = GitLocalReading.parseCount(String(decoding: count, as: UTF8.self))
            }
        }
        return reading
    }

    /// The branch's pull request through `gh`. Missing, signed out, offline, rate-limited or failing
    /// all read as unavailable, which never adds to what git established.
    func pullRequest(repository: String, branch: String, startedAt: Double) -> GitHubPullRequestLookup {
        guard let gh, gate.isOpen else { return .unavailable }
        let command = WorkStatusCommand(executable: gh,
                                        arguments: GitHubPullRequestReader.arguments(repository: repository, branch: branch),
                                        environment: ghEnvironment, timeout: Self.ghTimeout)
        guard case .succeeded(let output) = runner.run(command) else { return .unavailable }
        return GitHubPullRequestReader.parse(output, branch: branch, turnStartedAt: startedAt)
    }

    /// The GitHub card's state: `gh --version`, then its github.com sign-in. Runs only while Settings ›
    /// Agents is showing or once at launch, never for a session.
    func cliStatus() -> GitHubCLIStatus {
        guard let gh else { return .notInstalled }
        guard case .succeeded(let output) = runner.run(WorkStatusCommand(executable: gh, arguments: ["--version"],
                                                                          environment: ghEnvironment, timeout: Self.versionTimeout)) else {
            return .unknown(version: nil)
        }
        let version = GitHubCLIStatus.version(String(decoding: output, as: UTF8.self))
        let auth = runner.run(WorkStatusCommand(executable: gh,
                                                arguments: ["auth", "status", "--hostname", "github.com", "--json", "hosts"],
                                                environment: ghEnvironment, timeout: Self.ghTimeout))
        guard case .succeeded(let data) = auth, let signedIn = GitHubCLIStatus.signedIn(data) else {
            return .unknown(version: version)
        }
        return signedIn ? .signedIn(version: version) : .signedOut(version: version)
    }

    /// Runs one git command in `directory`, nil while the gate is closed or without git.
    private func git(_ directory: String, _ arguments: [String]) -> WorkStatusCommandResult? {
        guard let git, gate.isOpen else { return nil }
        // No optional locks, so a read never takes the index lock a running agent may need; no
        // fsmonitor daemon is started for Herdly's read.
        let command = WorkStatusCommand(executable: git,
                                        arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", directory]
                                            + arguments,
                                        environment: gitEnvironment, timeout: Self.gitTimeout)
        return runner.run(command)
    }

    private var gitEnvironment: [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "GIT_OPTIONAL_LOCKS": "0",
         "GIT_TERMINAL_PROMPT": "0"]
    }

    /// `gh` never prompts, checks for updates, or colours its output. Its config location is passed
    /// through when the user set one, so it finds the user's own sign-in.
    private var ghEnvironment: [String: String] {
        var environment = ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8",
                           "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_SPINNER_DISABLED": "1",
                           "NO_COLOR": "1"]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["GH_CONFIG_DIR", "XDG_CONFIG_HOME", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
                    "https_proxy", "http_proxy", "no_proxy"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }
}

/// Runs a work-status command with a minimal environment, empty stdin, stderr discarded and stdout
/// bounded. Past its wait the command gets SIGTERM, then SIGKILL a second later, and the pipe reader
/// stops, so a descendant still holding stdout cannot keep a thread waiting. Nothing is retried.
struct ProcessWorkStatusRunner: WorkStatusCommandRunning {
    static let maximumOutput = 1 << 20
    /// How long a terminated command gets before SIGKILL, and how long output may trail an exit.
    static let grace: Double = 1

    func run(_ command: WorkStatusCommand) -> WorkStatusCommandResult {
        guard FileManager.default.isExecutableFile(atPath: command.executable) else { return .notLaunched }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .notLaunched }
        let reader = BoundedPipeReader(output.fileHandleForReading.fileDescriptor, limit: Self.maximumOutput)
        defer { reader.stop() }
        let deadline = DispatchTime.now() + command.timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + Self.grace) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + Self.grace)
            }
            return .timedOut
        }
        // A descendant may still hold stdout after the command exited: its output is incomplete.
        guard reader.waitForEnd(until: max(deadline, .now() + Self.grace)) else { return .timedOut }
        guard process.terminationStatus == 0 else { return .failed(process.terminationStatus) }
        let bytes = reader.bytes
        guard bytes.count <= Self.maximumOutput else { return .tooLarge }
        return .succeeded(bytes)
    }
}

/// Reads one pipe to EOF on its own thread, keeping at most `limit + 1` bytes. `poll` with a short
/// interval lets `stop()` end it even while a descendant keeps the pipe open; it never closes the
/// descriptor, which the `Pipe` owns.
private final class BoundedPipeReader: @unchecked Sendable {
    // `@unchecked Sendable`: `data`, `stopped` and `ended` are used only under `lock`.
    private let lock = NSLock()
    private var data = Data()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)
    private let finished = DispatchGroup()

    init(_ descriptor: Int32, limit: Int) {
        finished.enter()
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            var reachedEnd = false
            while !isStopped {
                poller.revents = 0
                let ready = poll(&poller, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                if ready < 0 { break }
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count == 0 { reachedEnd = true }
                if count <= 0 { break }
                lock.lock()
                data.append(contentsOf: buffer[0..<min(count, limit + 1 - data.count)])
                let full = data.count > limit
                lock.unlock()
                // Past the limit the result is `tooLarge` whatever follows.
                if full { reachedEnd = true; break }
            }
            if reachedEnd { done.signal() }
            finished.leave()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    /// Whether the pipe reached its end (or the limit) by `deadline`.
    func waitForEnd(until deadline: DispatchTime) -> Bool {
        guard done.wait(timeout: deadline) == .success else { return false }
        done.signal()
        return true
    }

    /// Ends the reader and waits for its thread, at most one poll interval.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        finished.wait()
    }
}
