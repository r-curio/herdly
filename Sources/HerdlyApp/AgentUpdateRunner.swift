import Darwin
import Foundation
import HerdlyCore

/// Runs one agent update command (`claude update`, `brew upgrade --cask codex`) to completion or
/// its time limit. Unlike the 2-second detection probes, it keeps the end of both stdout and stderr
/// for the failure reason. The child's streams are its own pipes and stdin is /dev/null, so nothing
/// reaches Herdly's own stdout and a command that asks a question fails instead of waiting.
/// The command leads its own process group, so a timeout stops everything it started, and with it
/// every holder of the pipes. It blocks the calling thread: call it off the main actor.
enum AgentUpdateRunner {
    /// How long a timed-out group gets to exit after SIGTERM before SIGKILL.
    static let terminationGrace: TimeInterval = 2

    // `nonisolated(unsafe)`: read and written only while holding `readerLock`.
    nonisolated(unsafe) private static var readerCount = 0
    private static let readerLock = NSLock()

    /// Pipe readers still running, for tests: zero once every run has returned.
    static var liveReaders: Int {
        readerLock.lock()
        defer { readerLock.unlock() }
        return readerCount
    }

    fileprivate static func readerStarted() { readerLock.lock(); readerCount += 1; readerLock.unlock() }
    fileprivate static func readerEnded() { readerLock.lock(); readerCount -= 1; readerLock.unlock() }

    static func run(_ command: AgentUpdateCommand, limit: TimeInterval = AgentUpdateRequirements.timeLimit)
        -> AgentUpdateRunResult {
        guard FileManager.default.isExecutableFile(atPath: command.executable) else { return .couldNotStart }
        var outputPipe: [Int32] = [-1, -1], errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { return .couldNotStart }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0]); close(outputPipe[1])
            return .couldNotStart
        }
        guard let pid = spawn(command, stdout: outputPipe[1], stderr: errorPipe[1]) else {
            outputPipe.forEach { close($0) }
            errorPipe.forEach { close($0) }
            return .couldNotStart
        }
        // The parent's copies of the write ends would otherwise keep the readers from seeing EOF.
        close(outputPipe[1])
        close(errorPipe[1])
        let outputTail = PipeTail(outputPipe[0])
        let errorTail = PipeTail(errorPipe[0])

        // Every exit path stops both readers, so no thread or descriptor outlives the run, even when a
        // descendant that left the group (setsid, a daemon) still holds the pipes open.
        defer {
            outputTail.stop()
            errorTail.stop()
        }
        switch waitForExit(pid, until: Date().addingTimeInterval(limit), reap: true) {
        case .exited(let status):
            // A process it left running may hold the pipes open; read what arrived, bounded.
            return .finished(status: status, output: outputTail.collect(waiting: 2), errors: errorTail.collect(waiting: 2))
        case .lost:
            return .untracked
        case .running:
            break
        }
        // The command leads its group (pgid == pid). The leader is not reaped until the group has had
        // its SIGKILL, so while these signals are sent its pid, and with it the pgid, cannot be reused
        // by an unrelated group.
        killpg(pid, SIGTERM)
        _ = waitForExit(pid, until: Date().addingTimeInterval(terminationGrace), reap: false)
        killpg(pid, SIGKILL)
        _ = waitForExit(pid, until: .distantFuture, reap: true)
        return .timedOut
    }

    private enum Wait: Equatable {
        /// Exit status; death by signal reads as 128 + signal.
        case exited(Int32)
        case running
        /// Waiting failed (such as ECHILD), so how it ended cannot be known.
        case lost
    }

    /// Starts the command as the leader of a new process group, with /dev/null as stdin, the two
    /// pipes as stdout and stderr, and every other descriptor of Herdly's closed.
    private static func spawn(_ command: AgentUpdateCommand, stdout: Int32, stderr: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderr, 2) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return nil }
        let arguments = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        let environment = environment(for: URL(fileURLWithPath: command.executable))
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, command.executable, &actions, &attributes, arguments, environment) == 0 else { return nil }
        return pid
    }

    /// Polls until `pid` exits or `deadline` passes. With `reap` false the exited leader stays a
    /// zombie (`WNOWAIT`), keeping its pid and process group reserved for a later `killpg`.
    private static func waitForExit(_ pid: pid_t, until deadline: Date, reap: Bool) -> Wait {
        while true {
            if reap {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    let signal = status & 0x7f
                    return .exited(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
                }
                if result == -1 && errno != EINTR { return .lost }
            } else {
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0 && info.si_pid == pid { return .exited(info.si_status) }
                if result == -1 && errno != EINTR { return .lost }
            }
            if Date() >= deadline { return .running }
            usleep(20_000)
        }
    }

    /// The GUI app's PATH lacks Homebrew and user installs. The updater's own folder comes first so
    /// a package-manager install finds its manager (npm, brew) beside it.
    static func environment(for executable: URL) -> [String: String] {
        // Inherited, unlike TmuxRunner's minimal one: updaters need HOME, proxy, locale and
        // package-manager settings (npm prefix, HOMEBREW_*) that a reduced environment would drop.
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let folders = [executable.deletingLastPathComponent().path, "\(home)/.local/bin", "/opt/homebrew/bin",
                       "/usr/local/bin"] + inherited + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = folders.reduce(into: [String]()) { result, folder in
            if !folder.isEmpty, !result.contains(folder) { result.append(folder) }
        }.joined(separator: ":")
        return environment
    }
}

/// Reads one pipe to EOF on a background thread, keeping only its last bytes. Owns the descriptor
/// and closes it when the reader ends: at EOF, on a read error, or within a poll interval of `stop()`.
private final class PipeTail: @unchecked Sendable {
    // `@unchecked Sendable`: `data` and `stopped`, the only mutable state, are used only under `lock`.
    private let lock = NSLock()
    private var data = Data()
    private var stopped = false
    /// Left once the reader has closed its descriptor; waiting on a group never consumes that.
    private let done = DispatchGroup()

    init(_ descriptor: Int32) {
        AgentUpdateRunner.readerStarted()
        done.enter()
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // Plain read(2) after poll: a read error ends the loop instead of raising, as
            // `FileHandle.availableData` would, and the 100 ms poll lets `stop()` end a reader whose
            // pipe a surviving descendant still holds open.
            while !isStopped {
                poller.revents = 0
                let ready = poll(&poller, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                if ready < 0 { break }
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                lock.lock()
                data.append(contentsOf: buffer[0..<count])
                if data.count > AgentUpdateRequirements.maximumOutput {
                    data = data.suffix(AgentUpdateRequirements.maximumOutput)
                }
                lock.unlock()
            }
            close(descriptor)
            AgentUpdateRunner.readerEnded()
            done.leave()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func collect(waiting seconds: TimeInterval) -> Data {
        _ = done.wait(timeout: .now() + seconds)
        lock.lock()
        defer { lock.unlock() }
        return Data(data)
    }

    /// Ends the reader and waits for it to close its descriptor.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        done.wait()
    }
}
