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
    /// Waiting on the command failed, so how it ended cannot be known.
    case exitUnknown
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
    /// Open while the switch is on: session reads (git and `gh pr list`).
    let gate: WorkStatusGate
    /// Open unless the user turned the switch off: the card's own `gh` check.
    let cliGate: WorkStatusGate
    let git: String?
    let gh: String?
    let home: String

    init(runner: any WorkStatusCommandRunning, gate: WorkStatusGate, cliGate: WorkStatusGate = WorkStatusGate(open: true),
         git: String?, gh: String?, home: String = NSHomeDirectory()) {
        self.runner = runner
        self.gate = gate
        self.cliGate = cliGate
        self.git = git
        self.gh = gh
        self.home = home
    }

    /// The installed tools, found in their usual locations.
    static func live(gate: WorkStatusGate, cliGate: WorkStatusGate) -> WorkStatusReader {
        let home = NSHomeDirectory()
        let executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        return WorkStatusReader(runner: ProcessWorkStatusRunner(), gate: gate, cliGate: cliGate,
                                git: WorkStatusTools.git(isExecutable: executable),
                                gh: WorkStatusTools.gh(home: home, isExecutable: executable), home: home)
    }

    /// The finished turn's verdict from fresh readings. Nothing runs while the gate is closed.
    func verdict(_ branch: WorkBranch) -> WorkStatusResult {
        let local = branch.directory.flatMap(local)
        let lookup = branch.pullRequestQuery.map {
            pullRequest(repository: $0.repository, branch: $0.branch, startedAt: $0.startedAt)
        }
        return WorkStatusRule.result(branch: branch, local: local, pullRequest: lookup)
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

    /// The GitHub card's state: `gh --version`, then its github.com sign-in. Never for a session. The
    /// card gate is checked before each command, so a switch turned off between them stops the second.
    func cliStatus() -> GitHubCLIStatus {
        guard let gh else { return .notInstalled }
        guard cliGate.isOpen,
              case .succeeded(let output) = runner.run(WorkStatusCommand(executable: gh, arguments: ["--version"],
                                                                         environment: ghEnvironment,
                                                                         timeout: Self.versionTimeout)) else {
            return .unknown(version: nil)
        }
        let version = GitHubCLIStatus.version(String(decoding: output, as: UTF8.self))
        guard cliGate.isOpen else { return .unknown(version: version) }
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
/// bounded. The command leads its own process group (`AgentUpdateRunner.spawnGroup`), so past its
/// wait the whole group gets SIGTERM, then SIGKILL a second later; the pipe reader stops either way,
/// so a descendant still holding stdout cannot keep a thread waiting. Nothing is retried.
struct ProcessWorkStatusRunner: WorkStatusCommandRunning {
    static let maximumOutput = 1 << 20
    /// How long a terminated group gets before SIGKILL, and how long output may trail an exit.
    static let grace: Double = 1

    func run(_ command: WorkStatusCommand) -> WorkStatusCommandResult {
        guard FileManager.default.isExecutableFile(atPath: command.executable) else { return .notLaunched }
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { return .notLaunched }
        // Close-on-exec, so a process another thread starts meanwhile (Foundation's `Process` keeps
        // inherited descriptors) cannot hold this pipe open; the spawn dup2s the write end onto stdout.
        pipeEnds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        // The child inherits Herdly's working directory; that is safe because git always gets `-C <folder>`
        // and gh always gets `--repo owner/name`, so neither reads where it was started.
        guard let pid = AgentUpdateRunner.spawnGroup(executable: command.executable, arguments: command.arguments,
                                                     environment: command.environment, stdout: pipeEnds[1], stderr: nil)
        else {
            pipeEnds.forEach { close($0) }
            return .notLaunched
        }
        // The parent's write end would otherwise keep the reader from seeing EOF.
        close(pipeEnds[1])
        // This run owns the read end: it is closed only after the reader has stopped, so the number
        // cannot be reused while the reader polls it.
        let reader = BoundedPipeReader(pipeEnds[0], limit: Self.maximumOutput)
        defer {
            reader.stop()
            close(pipeEnds[0])
        }
        switch AgentUpdateRunner.waitForExit(pid, until: Date().addingTimeInterval(command.timeout), reap: true) {
        case .exited(let status):
            // A descendant may still hold stdout after the command exited: its output is incomplete,
            // and the descendant is still in the group, so the group id is still its own to signal.
            guard reader.waitForEnd(until: .now() + Self.grace) else {
                killpg(pid, SIGKILL)
                return .timedOut
            }
            guard status == 0 else { return .failed(status) }
            let bytes = reader.bytes
            guard bytes.count <= Self.maximumOutput else { return .tooLarge }
            return .succeeded(bytes)
        case .lost:
            return .exitUnknown
        case .running:
            // The leader is not reaped until its group has had SIGKILL, so its pid, and with it the
            // group id, cannot be reused by an unrelated group while these are sent.
            killpg(pid, SIGTERM)
            _ = AgentUpdateRunner.waitForExit(pid, until: Date().addingTimeInterval(Self.grace), reap: false)
            killpg(pid, SIGKILL)
            _ = AgentUpdateRunner.waitForExit(pid, until: .distantFuture, reap: true)
            return .timedOut
        }
    }
}

/// Reads one pipe to EOF on its own thread, keeping at most `limit + 1` bytes. `poll` with a short
/// interval lets `stop()` end it even while a descendant keeps the pipe open. It never closes the
/// descriptor: the runner owns it and closes it after `stop()` returns.
private final class BoundedPipeReader: @unchecked Sendable {
    // `@unchecked Sendable`: `data` and `stopped` are used only under `lock`; `done` and `finished`
    // are thread-safe semaphores.
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
