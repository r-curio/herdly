import Foundation
import SteerCore

/// Only called after the user enables Ghostty controls in this app launch.
/// No input text, keystrokes, or approval actions are supported.
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
    static func open(session: UUID, live: Set<UUID>) -> Bool {
        guard let before = snapshot(), let target = GhosttyMatch.target(session: session, live: live, snapshot: before),
              let bytes = try? JSONEncoder().encode(target),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let response = request(["action": "select", "title": GhosttyMatch.title(session), "target": object]),
              let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              value["status"] as? String == "ok", let after = snapshot() else { return false }
        return after.selected == target && GhosttyMatch.target(session: session, live: live, snapshot: after) == target
    }
}
