import Darwin
import Foundation
import HerdlyCore

/// Runs one agent update command (`claude update`, `brew upgrade --cask codex`) to completion or
/// its time limit. Unlike the 2-second detection probes, it keeps the end of both stdout and stderr
/// for the failure reason. The child's streams are its own pipes and stdin is empty, so nothing
/// reaches Herdly's own stdout and a command that asks a question fails instead of waiting.
/// It blocks the calling thread: call it off the main actor.
enum AgentUpdateRunner {
    static func run(_ command: AgentUpdateCommand, limit: TimeInterval = AgentUpdateRequirements.timeLimit)
        -> AgentUpdateRunResult {
        let executable = URL(fileURLWithPath: command.executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .couldNotStart }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = command.arguments
        process.environment = environment(for: executable)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let outputTail = PipeTail(output.fileHandleForReading)
        let errorTail = PipeTail(errors.fileHandleForReading)
        do { try process.run() } catch { return .couldNotStart }
        // The parent's copies of the write ends would otherwise keep the readers from seeing EOF.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        guard exited.wait(timeout: .now() + limit) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            return .timedOut
        }
        // A process it started in the background may hold the pipes open; read what arrived, bounded.
        return .finished(status: process.terminationStatus, output: outputTail.collect(waiting: 2),
                         errors: errorTail.collect(waiting: 2))
    }

    /// The GUI app's PATH lacks Homebrew and user installs. The updater's own folder comes first so
    /// a package-manager install finds its manager (npm, brew) beside it.
    static func environment(for executable: URL) -> [String: String] {
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

/// Reads one pipe to EOF on a background thread, keeping only its last bytes.
private final class PipeTail: @unchecked Sendable {
    // `@unchecked Sendable`: `data`, the only mutable state, is read and written only under `lock`.
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                data.append(chunk)
                if data.count > AgentUpdateRequirements.maximumOutput {
                    data = data.suffix(AgentUpdateRequirements.maximumOutput)
                }
                lock.unlock()
            }
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
