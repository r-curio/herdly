import AppKit
import Foundation
import SteerCore

/// Only called while the user has Ghostty controls enabled (remembered across launches).
/// Besides tab selection it relays one user-chosen digit for a Codex question to the exact
/// matched terminal (ADR 0006). No text input and no approval keystrokes are supported.
enum GhosttyNavigation {
    static func request(_ value: [String: Any]) -> Data? {
        guard let script = Bundle.main.url(forResource: "Ghostty", withExtension: "js"),
              let bytes = try? JSONSerialization.data(withJSONObject: value),
              let argument = String(data: bytes, encoding: .utf8) else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path, argument]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let bytes = try? output.fileHandleForReading.read(upToCount: 2 * 1024 * 1024 + 1),
              bytes.count <= 2 * 1024 * 1024 else { return nil }
        return bytes
    }
    /// Takes a fresh inventory. Each terminal's `tty` is read only when the installed Ghostty's
    /// dictionary declares it, so a Ghostty without it gets exactly the same request as before.
    /// Without it, the surfaces' TTYs are read from Ghostty's child processes for the sole-terminal
    /// rule (ADR 0011), after the inventory so a surface opened in between is still counted.
    static func snapshot() -> GhosttySnapshot? {
        var value: [String: Any] = ["action": "snapshot"]
        let supported = GhosttyScriptingSupport.ttySupport() == .supported
        if supported { value["tty"] = true }
        guard let data = request(value), var snapshot = try? JSONDecoder().decode(GhosttySnapshot.self, from: data) else {
            return nil
        }
        if !supported { snapshot.surface_ttys = GhosttySurfaces.ttys() }
        return snapshot
    }
    /// Sends the given key names (digits, optionally Enter) to the session's unique unsplit terminal
    /// without activating it. Confirmation is the rollout's recorded answer, not this result.
    static func answer(session: UUID, live: Set<UUID>, keys: [String]) -> (sent: Bool, message: String) {
        guard let snapshot = snapshot() else {
            return (false, "Could not read Ghostty’s tabs; nothing was sent. Check Automation access and that Ghostty is running.")
        }
        guard let target = GhosttyMatch.target(session: session, live: live, snapshot: snapshot) else {
            return (false, "No unique live, unsplit tab matches \(GhosttyMatch.title(session)); nothing was sent. Answer in Codex.")
        }
        guard let bytes = try? JSONEncoder().encode(target),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let response = request(["action": "answer", "title": GhosttyMatch.title(session), "target": object, "keys": keys]),
              let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              value["status"] as? String == "ok" else {
            return (false, "Found the tab, but Ghostty did not accept the key or its identity changed; nothing was sent.")
        }
        return (true, "Sent \(keys.joined(separator: " ")) to the Ghostty tab.")
    }
    /// Selects the herdr client's Ghostty tab for an Open (ADR 0011, step 4): Ghostty rechecks that
    /// exactly one terminal reports `tty`, alone in its tab in the front window, and that it is still
    /// `target`, then selects it and activates Ghostty. True only when Ghostty reported ok; the caller
    /// verifies the result with a fresh inventory. Sends no input.
    ///
    /// Without `tty` (ADR 0011's sole-terminal rule) Ghostty's child processes must still hold exactly
    /// the one surface with `tty`, and Ghostty rechecks that `target` is its only scripted terminal.
    static func selectHerdrTab(target: GhosttyTarget, tty: String) -> Bool {
        let supported = GhosttyScriptingSupport.ttySupport() == .supported
        if !supported {
            guard let surfaces = GhosttySurfaces.ttys(), surfaces.count == 1,
                  GhosttyTTYMatch.normalizedTTY(surfaces[0]) == GhosttyTTYMatch.normalizedTTY(tty) else { return false }
        }
        guard let bytes = try? JSONEncoder().encode(target),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let response = request(supported ? ["action": "select_tty", "tty": tty, "target": object]
                                               : ["action": "select_sole", "target": object]),
              let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return false }
        return value["status"] as? String == "ok"
    }
    /// Open for a Codex CLI session's tab: `.opened` only when the exact tab was selected and
    /// verified; otherwise the miss as ADR 0015 classifies it. Sends no input and
    /// never raises Ghostty for a miss; the caller decides the fallback.
    ///
    /// - Parameter running: whether Ghostty is running, read on the main actor. A Ghostty that is not
    ///   running is an empty inventory (ADR 0013) and is not asked anything.
    static func open(session: UUID, live: Set<UUID>, running: Bool) -> GhosttyTitleOutcome {
        open(title: GhosttyMatch.title(session), live: live.map(GhosttyMatch.title), running: running, sameWindowOnly: false)
    }
    /// The same for a Claude tab, by its full Claude title, limited to the front window.
    static func openClaude(sessionID: String, live: [String], running: Bool) -> GhosttyTitleOutcome {
        guard let title = GhosttyMatch.claudeTitle(sessionID) else {
            // A non-canonical session id has no title any tab can carry.
            return .miss(.fallBack(.noUniqueTarget, candidates: 0))
        }
        return open(title: title, live: live.compactMap(GhosttyMatch.claudeTitle), running: running, sameWindowOnly: true)
    }
    private static func open(title: String, live: [String], running: Bool, sameWindowOnly: Bool) -> GhosttyTitleOutcome {
        let before = running ? snapshot() : nil
        let target: GhosttyTarget
        switch GhosttyTitleOpen.revalidate(title: title, live: live, ghostty: before, running: running,
                                           sameWindowOnly: sameWindowOnly) {
        case .exact(let exact): target = exact
        case .miss(let miss): return .miss(miss)
        }
        var status: String?
        if let bytes = try? JSONEncoder().encode(target),
           let object = try? JSONSerialization.jsonObject(with: bytes),
           let response = request(["action": "select", "title": title, "target": object, "same_window_only": sameWindowOnly]),
           let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
            status = value["status"] as? String ?? ""
        }
        if let miss = GhosttyTitleOpen.selection(status: status) { return .miss(miss) }
        if let miss = GhosttyTitleOpen.verify(target, title: title, live: live, after: snapshot(),
                                              sameWindowOnly: sameWindowOnly) {
            return .miss(miss)
        }
        return .opened
    }
}

/// What a Ghostty title Open did: the exact tab verified, or a miss for the caller to resolve under
/// ADR 0015 (fall back to raising the app, or unavailable). A miss has no exact case.
enum GhosttyTitleOutcome: Equatable, Sendable {
    case opened
    case miss(OpenMiss)
}

/// Reads the scripting dictionary of the Ghostty bundle Steer drives, without Apple Events or a
/// version comparison (ADR 0011). Read fresh each time, so an update while Steer runs is noticed;
/// any unreadable or malformed file counts as unsupported.
enum GhosttyScriptingSupport {
    static let bundleIdentifier = "com.mitchellh.ghostty"

    /// The running Ghostty's bundle, falling back to the one Launch Services would open.
    static func bundleURL() -> URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func ttySupport(bundle: URL? = bundleURL()) -> GhosttyTTYSupport {
        guard let bundle else { return .unsupported }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let plist = SafeFile.read(contents.appendingPathComponent("Info.plist"), limit: GhosttyScriptingDictionary.maximumFileSize),
              let name = GhosttyScriptingDictionary.definitionName(infoPlist: plist) else { return .unsupported }
        let dictionary = SafeFile.read(contents.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(name),
                                       limit: GhosttyScriptingDictionary.maximumFileSize)
        return GhosttyScriptingDictionary.ttySupport(dictionary: dictionary)
    }
}

/// The TTYs of the running Ghostty's terminal surfaces, read from its child processes (ADR 0011's
/// sole-terminal rule). Ghostty starts each surface's command (normally `/usr/bin/login`) as a
/// direct child holding that surface's TTY, so this counts every surface, including the quick
/// terminal that scripting may not list. Read-only: it inspects the process table and sends nothing.
///
/// Ghostty's own process is found in the same table, by its executable's enclosing bundle
/// identifier, not through `NSRunningApplication`: snapshots run off the main thread, where that
/// list was observed to come back empty intermittently.
enum GhosttySurfaces {
    /// Each surface TTY as `/dev/ttysNNN`, one entry per child holding a terminal; nil when Ghostty is
    /// not running or the process table could not be read.
    static func ttys() -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Room for processes started between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        let table = processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
        // The short process name narrows the path lookups; the bundle identifier decides.
        let parents = Set(table.filter { commandName($0) == "ghostty" }.map(\.kp_proc.p_pid).filter(isGhostty))
        guard !parents.isEmpty else { return nil }
        var result: [String] = []
        for process in table where parents.contains(process.kp_eproc.e_ppid) {
            let device = process.kp_eproc.e_tdev
            guard device != -1 else { continue }
            // `devname_r`: snapshots run from several tasks at once, and `devname` shares one buffer.
            var buffer = [CChar](repeating: 0, count: 64)
            guard devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
            result.append("/dev/" + String(cString: buffer))
        }
        return result
    }

    private static func commandName(_ process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Whether `pid` runs the executable of an app bundle whose identifier is Ghostty's.
    private static func isGhostty(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let executable = URL(fileURLWithPath: String(cString: buffer))
        let macOS = executable.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" else {
            return false
        }
        let bundle = macOS.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: bundle)?.bundleIdentifier == GhosttyScriptingSupport.bundleIdentifier
    }
}
