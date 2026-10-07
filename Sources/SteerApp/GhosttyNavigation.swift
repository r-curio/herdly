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
    static func snapshot() -> GhosttySnapshot? {
        var value: [String: Any] = ["action": "snapshot"]
        if GhosttyScriptingSupport.ttySupport() == .supported { value["tty"] = true }
        guard let data = request(value) else { return nil }
        return try? JSONDecoder().decode(GhosttySnapshot.self, from: data)
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
    static func selectHerdrTab(target: GhosttyTarget, tty: String) -> Bool {
        guard let bytes = try? JSONEncoder().encode(target),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let response = request(["action": "select_tty", "tty": tty, "target": object]),
              let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return false }
        return value["status"] as? String == "ok"
    }
    static func open(session: UUID, live: Set<UUID>) -> (opened: Bool, message: String) {
        open(title: GhosttyMatch.title(session), live: live.map(GhosttyMatch.title), unavailable: "No unique live, unsplit tab matches \(GhosttyMatch.title(session)). Keep that session open with its session-ID title enabled.", sameWindowOnly: false)
    }
    static func openClaude(sessionID: String, live: [String]) -> (opened: Bool, message: String) {
        guard let title = GhosttyMatch.claudeTitle(sessionID) else {
            return (false, "The exact Claude tab is unavailable because its session identity is not canonical.")
        }
        return open(title: title, live: live.compactMap(GhosttyMatch.claudeTitle), unavailable: "No unique live, unsplit tab matches \(title). Keep Claude open with its exact session title enabled.", sameWindowOnly: true)
    }
    private static func open(title: String, live: [String], unavailable: String, sameWindowOnly: Bool) -> (opened: Bool, message: String) {
        guard let before = snapshot() else {
            return (false, "Could not read Ghostty’s tabs. Check Automation access and that Ghostty is running.")
        }
        guard let target = GhosttyMatch.target(title: title, live: live, snapshot: before) else {
            return (false, unavailable)
        }
        guard !sameWindowOnly || GhosttyMatch.isInCurrentWindow(target, snapshot: before) else {
            return (false, "The exact tab is in another Ghostty window; Steer cannot raise that window safely.")
        }
        guard let bytes = try? JSONEncoder().encode(target),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let response = request(["action": "select", "title": title, "target": object, "same_window_only": sameWindowOnly]),
              let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              value["status"] as? String == "ok" else {
            return (false, "Found the tab, but selection failed or its identity changed. The reminder is retained.")
        }
        guard let after = snapshot(), (!sameWindowOnly || GhosttyMatch.isInCurrentWindow(target, snapshot: after)),
              after.selected == target,
              GhosttyMatch.target(title: title, live: live, snapshot: after) == target else {
            return (false, "Sent the tab selection, but could not verify the foreground tab. The reminder is retained.")
        }
        return (true, "Opened the matching Ghostty tab.")
    }
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
