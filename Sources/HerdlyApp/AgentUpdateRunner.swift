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

        guard let status = waitForExit(pid, until: Date().addingTimeInterval(limit)) else {
            // The command leads its group (pgid == pid): stop it and anything it started.
            killpg(pid, SIGTERM)
            if waitForExit(pid, until: Date().addingTimeInterval(terminationGrace)) == nil {
                killpg(pid, SIGKILL)
                _ = waitForExit(pid, until: .distantFuture)
            }
            killpg(pid, SIGKILL)  // Members that outlived the leader's own exit.
            return .timedOut
        }
        // A process it left running may hold the pipes open; read what arrived, bounded.
        return .finished(status: status, output: outputTail.collect(waiting: 2), errors: errorTail.collect(waiting: 2))
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

    /// The exit status once `pid` ends, or nil at `deadline`. Death by signal reads as 128 + signal.
    private static func waitForExit(_ pid: pid_t, until deadline: Date) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                let signal = status & 0x7f
                return signal == 0 ? (status >> 8) & 0xff : 128 + signal
            }
            if result == -1 && errno != EINTR { return -1 }
            if Date() >= deadline { return nil }
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

/// Reads one pipe to EOF on a background thread, keeping only its last bytes. Owns the descriptor.
private final class PipeTail: @unchecked Sendable {
    // `@unchecked Sendable`: `data`, the only mutable state, is read and written only under `lock`.
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ descriptor: Int32) {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        Thread.detachNewThread { [self] in
            // `read(upToCount:)` throws on a read error, where `availableData` would raise.
            while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                lock.lock()
                data.append(chunk)
                if data.count > AgentUpdateRequirements.maximumOutput {
                    data = data.suffix(AgentUpdateRequirements.maximumOutput)
                }
                lock.unlock()
            }
            try? handle.close()
            done.signal()
        }
    }

    func collect(waiting seconds: TimeInterval) -> Data {
        _ = done.wait(timeout: .now() + seconds)
        lock.lock()
        defer { lock.unlock() }
        return Data(data)
    }
}
