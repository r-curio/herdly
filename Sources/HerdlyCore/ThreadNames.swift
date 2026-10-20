import Foundation

/// The names Codex gives its threads, read from the index file Codex keeps next to its rollouts.
///
/// Codex desktop names a thread shortly after its first prompt and shows that name in its sidebar.
/// It appends one JSON line per naming event to `~/.codex/session_index.jsonl`:
/// `{"id":"<thread id>","thread_name":"…","updated_at":"…"}`. A rename appends another line for
/// the same id, so the last line for an id is the current name. Thread ids equal Codex session ids.
/// CLI threads are not named, so they never appear here. See docs/thread-names.md.
///
/// This is a private, build-specific format (observed with CLI 0.153.4 and desktop 26.901.51231).
/// The reader fails soft: a line it cannot read is skipped, and a file it cannot read means no
/// names, so the label falls back to the session identifier instead of showing a wrong name.
public enum ThreadNameReader {
    public static let limit = CodexSetupLimits.maximumFileSize
    public static let fileName = "session_index.jsonl"
    static let idKey = "id"
    static let nameKey = "thread_name"

    public static func defaultURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent(fileName)
    }

    /// Nil whenever the file is missing, not a regular file, a symlink, or over the size bound.
    public static func read(_ url: URL) -> [UUID: String]? {
        guard let bytes = SafeFile.read(url, limit: limit) else { return nil }
        return parse(bytes)
    }

    /// Session id to its latest non-empty name. Lines that are not a JSON object with a UUID `id`
    /// and a string `thread_name` are skipped, including a partial last line mid-append.
    public static func parse(_ bytes: Data) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for line in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let idText = object[idKey] as? String, let id = UUID(uuidString: idText),
                  let name = object[nameKey] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            names[id] = trimmed
        }
        return names
    }
}
