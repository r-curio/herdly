import Darwin
import Foundation
import OSAKit

/// A bundled JXA adapter for one terminal app (`Ghostty.js`, `ITerm2.js`, `TerminalApp.js`), compiled once
/// with the shared `AppleEvents.js` in front and run inside Herdly by `AppleEventScripts` (#303). Each
/// request carries the app's process id, read from the kernel just before the run, and the adapter sends
/// every Apple Event to that process only. An app that quit before or during the request answers the
/// adapter's not-running status; nothing is ever launched (#270). Blocking: call off the main actor.
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

    /// The largest reply accepted; a longer one is a failure, never a truncated inventory.
    static let maximumReply = 2 * 1024 * 1024

    /// Sends `request` to the running app; nil when the script failed, timed out, was denied or replied
    /// more than 2 MiB.
    func request(_ request: [String: Any]) -> Data? {
        run(request, pid: TerminalAppProcess.pid(bundleIdentifier: bundleIdentifier, command: command),
            resources: Bundle.main.resourceURL)
    }

    /// Runs the adapter in `resources` against process `pid` within `deadline` seconds (five; only tests
    /// under load pass more). The request carries the deadline, and every Apple Event the adapter sends
    /// waits at most the time left (`AppleEvents.js`): no event is sent after 5 s, and the caller waits at
    /// most 5.5 s (`AppleEventScripts.grace`). Without a process the reply is the not-running status, and
    /// no script runs.
    func run(_ request: [String: Any], pid: pid_t?, resources: URL?, deadline: TimeInterval = 5) -> Data? {
        guard let pid else { return Data(#"{"status":"\#(notRunningStatus)"}"#.utf8) }
        guard let resources else { return nil }
        let ends = ProcessInfo.processInfo.systemUptime + deadline
        guard let argument = Self.argument(request, pid: pid, deadline: ends) else { return nil }
        let key = resources.appendingPathComponent("\(rawValue).js").path
        guard let reply = AppleEventScripts.shared.run(key: key, source: { source(in: resources) }, argument: argument,
                                                       until: ends),
              reply.utf8.count <= Self.maximumReply else { return nil }
        return Data(reply.utf8)
    }

    /// The adapter's source with the shared Apple Event layer in front; nil when either is unreadable.
    func source(in resources: URL) -> String? {
        guard let layer = try? String(contentsOf: resources.appendingPathComponent("AppleEvents.js"), encoding: .utf8),
              let adapter = try? String(contentsOf: resources.appendingPathComponent("\(rawValue).js"), encoding: .utf8)
        else { return nil }
        return layer + "\n" + adapter
    }

    /// The one JSON argument: `request` with `pid`, the process every event goes to, and `deadline`, when
    /// the request ends in seconds of system uptime.
    static func argument(_ request: [String: Any], pid: pid_t, deadline: TimeInterval) -> String? {
        var value = request
        value["pid"] = Int(pid)
        value["deadline"] = deadline
        guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

/// Runs JXA scripts inside Herdly on one dedicated thread (#303), replacing an `osascript` per request.
/// OSA components are not safe to use from several threads at once, so every compile and run happens on
/// that thread, one at a time; each script is compiled the first time it is asked for and its `run(argv)`
/// handler is called for every request after.
///
/// A running script cannot be cancelled. Callers wait until the request's deadline plus `grace` and then
/// give up with nil; a late script runs on, but its Apple Events never wait past the deadline the request
/// carries, no event is sent after it, and a request still queued at its deadline never starts. So the
/// window for side effects is the one `osascript` had: terminating it never recalled an event already
/// sent either. Requests queue behind each other, so one slow app can make another app's read time out
/// (unreadable, never partial).
final class AppleEventScripts: @unchecked Sendable {
    /// The one runner the app uses; tests make their own so a slow test script delays nothing else.
    static let shared = AppleEventScripts()

    /// How long past the deadline a caller waits for the script to return its reply.
    static let grace: TimeInterval = 0.5

    // Invariant for `@unchecked Sendable`: `jobs` and `thread` are only read or written while holding
    // `condition` (`thread` is set once, by the first `enqueue`). `compiled`, and every `OSAScript` in it,
    // is only touched by jobs, which run one at a time on `thread`; no other thread ever reaches it.
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var compiled: [String: OSAScript] = [:]
    private var thread: Thread?

    /// A runner with its own thread, started on its first request and kept for the process's life.
    init() {}

    /// The string `run(argv)` returned for `argument` from the script `source` gives (compiled once per
    /// `key`); nil when it could not be compiled, threw, returned no string, or did not finish by `until`
    /// (system uptime) plus `grace`.
    func run(key: String, source: @escaping @Sendable () -> String?, argument: String, until deadline: TimeInterval) -> String? {
        let reply = Reply()
        enqueue { [self] in
            // A request that waited out its deadline in the queue is never started.
            guard ProcessInfo.processInfo.systemUptime < deadline else { return reply.finish(nil) }
            reply.finish(execute(key: key, source: source, argument: argument))
        }
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime) + Self.grace
        return reply.wait(seconds: wait)
    }

    /// On `thread` only.
    private func execute(key: String, source: () -> String?, argument: String) -> String? {
        let script: OSAScript
        if let known = compiled[key] {
            script = known
        } else {
            guard let text = source(), let language = OSALanguage(forName: "JavaScript") else { return nil }
            let fresh = OSAScript(source: text, language: language)
            var error: NSDictionary?
            guard fresh.compileAndReturnError(&error) else { return nil }
            compiled[key] = fresh
            script = fresh
        }
        var error: NSDictionary?
        // One argument list, as `osascript` passes `argv`.
        let result = script.executeHandler(withName: "run", arguments: [[argument]], error: &error)
        guard error == nil, let result, result.descriptorType != typeNull else { return nil }
        return result.stringValue
    }

    private func enqueue(_ job: @escaping @Sendable () -> Void) {
        condition.lock(); defer { condition.unlock() }
        if thread == nil {
            let worker = Thread { [self] in loop() }
            worker.name = "Herdly Apple Events"
            worker.qualityOfService = .userInitiated
            worker.start()
            thread = worker
        }
        jobs.append(job)
        condition.signal()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }

    /// One request's reply, written once on the script thread and read by the waiting caller.
    private final class Reply: @unchecked Sendable {
        // Invariant for `@unchecked Sendable`: `value` is only touched while holding `lock`.
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var value: String?

        func finish(_ reply: String?) {
            lock.lock(); value = reply; lock.unlock()
            done.signal()
        }

        func wait(seconds: TimeInterval) -> String? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return value
        }
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
        guard let processes = KernelProcessTable.kinfo(), !processes.isEmpty else { return nil }
        let name = String(command.prefix(Int(MAXCOMLEN)))
        let candidates = processes
            .filter { KernelProcessTable.shortName($0) == name && $0.kp_proc.p_stat != SZOMB }
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

    private static func started(_ process: kinfo_proc) -> Double {
        let time = process.kp_proc.p_un.__p_starttime
        return Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
