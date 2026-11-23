import Darwin
import Foundation
import HerdlyCore

/// Rex's command line: `rex` from a fixed path, pinned to the local server socket after the owner-only trust
/// check, with a minimal environment and `--autostart=false`. Called only while Rex's switch is on. Blocking:
/// call off the main actor. Nothing here starts a server, creates a block, or writes anywhere but the one
/// block passed in. Rules are HerdlyCore's (`Rex.swift`).
enum RexNavigation {
    /// The first executable `rex` in its fixed locations; never `PATH`.
    static func binary() -> String? {
        RexCLI.binaryCandidates(home: NSHomeDirectory()).first { path in
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
        }
    }

    /// Whether Rex's server is up: its socket exists. Rex.app and the server run separately, and the server
    /// holds the terminals, so a server without the app still holds sessions.
    static func isRunning() -> Bool {
        RexSocket.trust(at: RexCLI.socketPath(home: NSHomeDirectory())) != .missing
    }

    /// One inventory read. A Rex with no server socket holds nothing and is not asked.
    static func read() -> RexRead {
        guard isRunning() else { return .notRunning }
        return RexRead.inventory(run(RexCLI.inventory, input: Data(RexCLI.inventoryScript.utf8)), tty: tty(of:))
    }

    /// The tty of `pid` from the kernel.
    static func tty(of pid: Int32) -> String? {
        guard let process = HerdrProcessTree.ancestry(of: pid).first, process.pid == pid else { return nil }
        return process.tty
    }

    /// ADR 0016's select step, sent once: focus the block, then, when the server holds several sessions, ask
    /// the one Rex app to show its session (refused while Remote Control is off). Returns the focus result
    /// and whether the app performed the select.
    static func focus(_ plan: RexOpenPlan) -> (RexCommandResult, selected: Bool) {
        let focused = run(RexCLI.focus(plan.block))
        guard case .exited(0, _, _) = focused, plan.needsSelect else { return (focused, false) }
        guard case .exited(0, let stdout, _) = run(RexCLI.listClients),
              let clients = RexClients.appClients(stdout), clients.count == 1 else { return (focused, false) }
        return (focused, RexOpen.selected(run(RexCLI.select(plan.block, client: clients[0]))))
    }

    /// ADR 0017: one `write` into the pane's block, after re-reading it so the write names its session.
    static func send(_ payload: String, into pane: TypedInputPane) -> RexCommandResult {
        guard pane.host == .rex else { return .notRun(.commandFailed) }
        guard let block = read().snapshot?.block(pane.paneID), block.tty == pane.tty else {
            return .exited(status: 3, stdout: Data(), stderr: "code=not_found")
        }
        return run(RexCLI.write(payload, block: block))
    }

    /// The running server's version, for the card only; nil when it can't be read.
    static func version() -> String? {
        guard isRunning(), case .exited(0, let stdout, _) = run(RexCLI.versionArguments) else { return nil }
        return RexCLI.version(stdout)
    }

    /// Runs `rex` once: bounded by `RexCLI.timeout`, stdout by `RexCLI.outputLimit`, stderr by 4 KiB. A run
    /// that passes its deadline is terminated.
    static func run(_ arguments: [String], input: Data? = nil) -> RexCommandResult {
        guard let binary = binary() else { return .notRun(.binaryNotFound) }
        let socket = RexCLI.socketPath(home: NSHomeDirectory())
        switch RexSocket.trust(at: socket) {
        case .trusted: break
        case .missing: return .notRun(.commandFailed)
        case .untrusted: return .notRun(.socketUntrusted)
        }
        return execute(binary, arguments, input: input, environment: RexCLI.environment(home: NSHomeDirectory(), socket: socket))
    }

    private static func execute(_ binary: String, _ arguments: [String], input: Data?,
                                environment: [String: String]) -> RexCommandResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        let stdin = input.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .notRun(.binaryNotFound) }
        if let stdin, let input {
            // The script is a few kilobytes, well under a pipe's buffer, so this write does not block.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        // Written by the drain blocks before `drained` is signalled and read only after both waits
        // succeed, so the semaphore orders every access.
        final class Box: @unchecked Sendable { var stdout: Data?; var stderr: Data? }
        let box = Box()
        let limit = RexCLI.outputLimit
        DispatchQueue.global(qos: .utility).async {
            box.stdout = try? output.fileHandleForReading.read(upToCount: limit + 1)
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            box.stderr = try? errors.fileHandleForReading.read(upToCount: 4096)
            drained.signal()
        }
        let deadline = DispatchTime.now() + RexCLI.timeout
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
