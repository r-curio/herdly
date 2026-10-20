import Darwin
import Foundation

/// A bundled JXA adapter for one terminal app (`Ghostty.js`, `ITerm2.js`, `TerminalApp.js`), run by
/// `osascript` after the shared `AppleEvents.js`. Each request carries the app's process id, read from
/// the kernel just before the run, and the adapter sends every Apple Event to that process only. An app
/// that quit before or during the request answers the adapter's not-running status; nothing is ever
/// launched (#270). Blocking: call off the main actor.
enum TerminalScript: String, CaseIterable, Sendable {
    case ghostty = "Ghostty"
    case iTerm2 = "ITerm2"
    case terminalApp = "TerminalApp"

    var bundleIdentifier: String {
        switch self {
        case .ghostty: GhosttyScriptingSupport.bundleIdentifier
        case .iTerm2: ITerm2Navigation.bundleIdentifier
        case .terminalApp: TerminalAppNavigation.bundleIdentifier
        }
    }

    /// The app's executable as the kernel's short command name shows it; only narrows the lookup.
    var command: String {
        switch self {
        case .ghostty: "ghostty"
        case .iTerm2: "iTerm2"
        case .terminalApp: "Terminal"
        }
    }

    /// The adapter's reply when its app is not running; Herdly answers the same when it finds no process.
    var notRunningStatus: String {
        self == .ghostty ? "unavailable" : "not_running"
    }

    /// Sends `request` to the running app; nil when the script failed, timed out, was denied or replied
    /// more than 2 MiB.
    func request(_ request: [String: Any]) -> Data? {
        run(request, pid: TerminalAppProcess.pid(bundleIdentifier: bundleIdentifier, command: command),
            resources: Bundle.main.resourceURL)
    }

    /// Runs the adapter in `resources` against process `pid` under `deadline` (five seconds; only tests
    /// under load pass more). Without a process the reply is the not-running status, and no script runs.
    func run(_ request: [String: Any], pid: pid_t?, resources: URL?, deadline: TimeInterval = 5) -> Data? {
        guard let pid else { return Data(#"{"status":"\#(notRunningStatus)"}"#.utf8) }
        guard let resources, let source = source(in: resources),
              let argument = Self.argument(request, pid: pid) else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source, argument]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + deadline) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let bytes = try? output.fileHandleForReading.read(upToCount: 2 * 1024 * 1024 + 1),
              bytes.count <= 2 * 1024 * 1024 else { return nil }
        return bytes
    }

    /// The adapter's source with the shared Apple Event layer in front; nil when either is unreadable.
    func source(in resources: URL) -> String? {
        guard let layer = try? String(contentsOf: resources.appendingPathComponent("AppleEvents.js"), encoding: .utf8),
              let adapter = try? String(contentsOf: resources.appendingPathComponent("\(rawValue).js"), encoding: .utf8)
        else { return nil }
        return layer + "\n" + adapter
    }

    /// The one JSON argument: `request` with `pid`, the process every event goes to.
    static func argument(_ request: [String: Any], pid: pid_t) -> String? {
        var value = request
        value["pid"] = Int(pid)
        guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

/// The running process of a terminal app, read from the kernel's process table rather than
/// `NSRunningApplication`, which was seen to come back empty intermittently off the main actor.
enum TerminalAppProcess {
    /// One process running an app bundle's main executable.
    struct Candidate: Equatable, Sendable {
        let pid: pid_t
        /// The enclosing app's bundle identifier; nil when the executable is not an app's.
        let bundleIdentifier: String?
        /// Start time, seconds since 1970.
        let started: Double
        /// Whether it has a controlling terminal: a command-line run of the binary (`ghostty
        /// +list-themes` in a shell) has one; the app macOS launched has none.
        let hasControllingTerminal: Bool
    }

    /// The app's own process: the earliest started process of an app with `bundleIdentifier` that has
    /// no controlling terminal. nil when there is none or the table could not be read.
    static func pid(bundleIdentifier: String, command: String) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Room for processes started between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        let name = String(command.prefix(Int(MAXCOMLEN)))
        let candidates = processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { commandName($0) == name && $0.kp_proc.p_stat != SZOMB }
            .map { process in
                Candidate(pid: process.kp_proc.p_pid,
                          bundleIdentifier: TerminalApps.appBundleIdentifier(of: process.kp_proc.p_pid),
                          started: started(process), hasControllingTerminal: process.kp_eproc.e_tdev != -1)
            }
        return choose(candidates, bundleIdentifier: bundleIdentifier)
    }

    /// The rule behind `pid`: an app process of `bundleIdentifier` without a controlling terminal, the
    /// earliest started when several are (one instance is expected).
    static func choose(_ candidates: [Candidate], bundleIdentifier: String) -> pid_t? {
        candidates.filter { $0.bundleIdentifier == bundleIdentifier && !$0.hasControllingTerminal }
            .min { $0.started < $1.started }?.pid
    }

    private static func commandName(_ process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func started(_ process: kinfo_proc) -> Double {
        let time = process.kp_proc.p_un.__p_starttime
        return Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
