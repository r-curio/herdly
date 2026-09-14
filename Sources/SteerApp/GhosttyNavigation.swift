import Foundation
import SteerCore

/// Only called after the user enables Ghostty controls in this app launch.
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
    static func snapshot() -> GhosttySnapshot? {
        guard let data = request(["action": "snapshot"]) else { return nil }
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
    static func open(session: UUID, live: Set<UUID>) -> (opened: Bool, message: String) {
        guard let before = snapshot() else {
            return (false, "Could not read Ghostty’s tabs. Check Automation access and that Ghostty is running.")
        }
        guard let target = GhosttyMatch.target(session: session, live: live, snapshot: before) else {
            return (false, "No unique live, unsplit tab matches \(GhosttyMatch.title(session)). Keep that session open with its session-ID title enabled.")
        }
        guard let bytes = try? JSONEncoder().encode(target),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let response = request(["action": "select", "title": GhosttyMatch.title(session), "target": object]),
              let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              value["status"] as? String == "ok" else {
            return (false, "Found the tab, but selection failed or its identity changed. The reminder is retained.")
        }
        guard let after = snapshot(), after.selected == target,
              GhosttyMatch.target(session: session, live: live, snapshot: after) == target else {
            return (false, "Sent the tab selection, but could not verify the foreground tab. The reminder is retained.")
        }
        return (true, "Opened the matching Ghostty tab.")
    }
}
