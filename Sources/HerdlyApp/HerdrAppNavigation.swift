import Darwin
import Foundation
import HerdlyCore

/// The Herdr app's two routes: herdr-core's own JSON-RPC socket for its terminals and replies, after the
/// trust check and with a peer check on connect (`HerdrSocket.exchange`); and Herdr.app's command line, from
/// its fixed executable, for which pane shows which terminal and for Open's focus, run only while the
/// window's socket exists. Herdly never runs `hc`, which starts a core when none runs, and never starts Herdr.
/// Called only while the Herdr app's switch is on. Blocking: call off the main actor. Nothing here creates a
/// terminal or writes anywhere but the one terminal passed in. Rules are HerdlyCore's (`HerdrApp.swift`).
enum HerdrAppNavigation {
    /// Herdr.app's executable in its fixed locations; never `PATH`.
    static func binary() -> String? {
        HerdrAppCLI.appBinaryCandidates(home: NSHomeDirectory()).first { path in
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
        }
    }

    /// Herdr.app's version from its bundle, for the card only.
    static func version() -> String? {
        guard let binary = binary() else { return nil }
        let bundle = URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Whether herdr-core is up: its socket exists. The core holds the terminals whether or not the window is open.
    static func isRunning() -> Bool {
        HerdrAppSocket.trust(at: HerdrAppCLI.coreSocketPath(home: NSHomeDirectory())) != .missing
    }

    /// One `terminal.list` read.
    static func read() -> HerdrAppRead {
        let id = UUID().uuidString
        return HerdrAppRead.inventory(exchange(id: id, method: HerdrAppCLI.listMethod, params: [:],
                                               timeout: HerdrAppCLI.timeout), id: id, tty: tty(of:))
    }

    /// The window's panes and focus: `Herdr ls`, then `Herdr status`.
    static func readWindow() -> HerdrAppWindowRead {
        let ls = run(HerdrAppCLI.ls)
        guard case .exited(0, _, _) = ls else { return HerdrAppWindowRead.from(ls: ls, status: ls) }
        return HerdrAppWindowRead.from(ls: ls, status: run(HerdrAppCLI.status))
    }

    /// The tty of `pid` from the kernel.
    static func tty(of pid: Int32) -> String? {
        guard let process = HerdrProcessTree.ancestry(of: pid).first, process.pid == pid else { return nil }
        return process.tty
    }

    /// ADR 0016's select step, sent once: Herdr shows the terminal's space and tab and focuses its pane.
    static func focus(_ plan: HerdrAppOpenPlan) -> HerdrAppCommandResult {
        run(HerdrAppCLI.focus(plan.terminal))
    }

    /// ADR 0017: one `terminal.send` into the pane's terminal, after re-reading it so the send names the same
    /// terminal on the same tty.
    static func send(_ write: TypedWrite, into pane: TypedInputPane) -> TypedInputDelivery {
        guard pane.host == .herdrApp, let request = HerdrAppInput.send(write, terminal: pane.paneID) else { return .notWritten }
        guard let terminal = read().snapshot?.terminal(pane.paneID), terminal.tty == pane.tty else { return .notWritten }
        let id = UUID().uuidString
        return HerdrAppInput.delivery(exchange(id: id, method: request.method, params: request.params,
                                               timeout: HerdrAppCLI.sendTimeout), id: id)
    }

    /// A question's digit: one `terminal.keys` into the pane's terminal, after the same re-read.
    static func sendKey(_ key: String, into pane: TypedInputPane) -> TypedInputDelivery {
        guard pane.host == .herdrApp else { return .notWritten }
        guard let terminal = read().snapshot?.terminal(pane.paneID), terminal.tty == pane.tty else { return .notWritten }
        let request = HerdrAppInput.key(key, terminal: pane.paneID)
        let id = UUID().uuidString
        return HerdrAppInput.delivery(exchange(id: id, method: request.method, params: request.params,
                                               timeout: HerdrAppCLI.sendTimeout), id: id)
    }

    /// The core's version, for diagnostics only.
    static func coreVersion() -> String? {
        let id = UUID().uuidString
        guard case .reply(let line) = exchange(id: id, method: HerdrAppCLI.statusMethod, params: [:],
                                               timeout: HerdrAppCLI.timeout) else { return nil }
        return HerdrAppCLI.version(line, id: id)
    }

    /// One request on one new connection to the core socket, within `timeout`.
    static func exchange(id: String, method: String, params: [String: Any], timeout: Double) -> HerdrAppExchange {
        let path = HerdrAppCLI.coreSocketPath(home: NSHomeDirectory())
        switch HerdrAppSocket.trust(at: path) {
        case .trusted: break
        case .missing: return .notRunning
        case .untrusted: return .notSent(.socketUntrusted)
        }
        guard let line = HerdrAppRPC.requestLine(id: id, method: method, params: params) else {
            return .notSent(.commandFailed)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        var writeAttempted = false
        switch HerdrSocket.exchange(path: path, request: line, deadline: deadline, writeAttempted: &writeAttempted) {
        case .success(let reply): return .reply(reply)
        case .failure(let reason):
            let unreadable: HerdrAppUnreadable
            switch reason {
            case .untrustedSocket: unreadable = .socketUntrusted
            case .timeout: unreadable = .timedOut
            case .malformedReply: unreadable = .malformedReply
            default: unreadable = .commandFailed
            }
            guard writeAttempted else {
                return reason == .notRunning ? .notRunning : .notSent(unreadable)
            }
            return .failed(unreadable)
        }
    }

    /// Runs Herdr.app's command line once: bounded by `HerdrAppCLI.timeout`, stdout by `HerdrAppCLI.outputLimit`,
    /// stderr by 4 KiB, only while the window's socket exists and passes the trust check. A run that passes its
    /// deadline is terminated.
    static func run(_ arguments: [String]) -> HerdrAppCommandResult {
        guard !arguments.isEmpty, let binary = binary() else { return .notRun(.appNotFound) }
        switch HerdrAppSocket.trust(at: HerdrAppCLI.appSocketPath(home: NSHomeDirectory())) {
        case .trusted: break
        case .missing: return .notRun(.noWindow)
        case .untrusted: return .notRun(.socketUntrusted)
        }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = HerdrAppCLI.environment(home: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .notRun(.appNotFound) }
        // Written by the drain blocks before `drained` is signalled and read only after both waits
        // succeed, so the semaphore orders every access.
        final class Box: @unchecked Sendable { var stdout: Data?; var stderr: Data? }
        let box = Box()
        let limit = HerdrAppCLI.outputLimit
        DispatchQueue.global(qos: .utility).async {
            box.stdout = try? output.fileHandleForReading.read(upToCount: limit + 1)
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            box.stderr = try? errors.fileHandleForReading.read(upToCount: 4096)
            drained.signal()
        }
        let deadline = DispatchTime.now() + HerdrAppCLI.timeout
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
