import Foundation

/// The Codex desktop app's own unread flags, read from the private file it persists them in.
///
/// The desktop app keeps one boolean per thread, `hasUnreadTurn`. It raises the flag when a turn
/// completes or a request arrives, and clears it only when that thread is the selected view in a
/// focused Codex window (or the user marks it read, or archives or deletes it). It persists the set
/// of flagged thread ids under `electron-persisted-atom-state` → `unread-thread-ids-by-host-v1`
/// in `~/.codex/.codex-global-state.json`, debounced by about half a second and written by
/// temp-file rename, so a reader never sees a partial file. See docs/desktop-read-state.md.
///
/// This is a private, build-specific format (observed in desktop 26.901.51231). The reader fails
/// closed: anything it cannot fully parse is "no evidence", never "read".
public struct DesktopReadStateSnapshot: Equatable, Sendable {
    /// Thread ids the desktop app currently flags as unread on the local host.
    public let unread: Set<UUID>
    /// When the file was last written, in seconds since 1970. The set is exactly the app's state at
    /// that moment; the file is rewritten for many unrelated reasons, so this advances constantly.
    public let modifiedAt: Double

    public init(unread: Set<UUID>, modifiedAt: Double) {
        self.unread = unread
        self.modifiedAt = modifiedAt
    }
}

public enum DesktopReadStateReader {
    public static let limit = CodexSetupLimits.maximumFileSize
    public static let fileName = ".codex-global-state.json"
    static let atomStateKey = "electron-persisted-atom-state"
    static let unreadKey = "unread-thread-ids-by-host-v1"
    static let localHost = "local"

    public static func defaultURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent(fileName)
    }

    /// Nil whenever the file is missing, not a regular file, over the size bound, not JSON, or lacks
    /// the exact key path down to the local host's array. An empty array is a valid snapshot.
    public static func read(_ url: URL) -> DesktopReadStateSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let bytes = SafeFile.read(url, limit: limit) else { return nil }
        return parse(bytes, modifiedAt: modified.timeIntervalSince1970)
    }

    public static func parse(_ bytes: Data, modifiedAt: Double) -> DesktopReadStateSnapshot? {
        guard modifiedAt.isFinite,
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let atoms = root[atomStateKey] as? [String: Any],
              let byHost = atoms[unreadKey] as? [String: Any],
              let local = byHost[localHost] as? [Any] else { return nil }
        var unread: Set<UUID> = []
        for entry in local {
            // Any entry that is not a thread id means the format moved; refuse the whole snapshot.
            guard let text = entry as? String, let id = UUID(uuidString: text) else { return nil }
            unread.insert(id)
        }
        return DesktopReadStateSnapshot(unread: unread, modifiedAt: modifiedAt)
    }
}

/// Turns a desktop read-state snapshot into completion acknowledgments.
///
/// Rule: a desktop completion is acknowledged when the desktop app's unread set, as written at
/// least `settleMargin` seconds after the completion arrived, does not contain its session. The
/// margin covers the app's persistence debounce so a file written before the flag was raised is
/// never mistaken for a cleared flag. A session still in the set is unread; a snapshot older than
/// the margin is no evidence either way. CLI completions are never touched: the desktop app does
/// not own those threads.
///
/// Because the flag is per thread, absence means the user had that thread selected in a focused
/// Codex window after its latest completion or request, or archived or deleted it, or the app chose
/// not to flag the turn at all (heartbeat and failed-runs-only automation turns). It never proves
/// the user scrolled to the result. It can only move a completion to acknowledged, never back.
public enum DesktopReadAcknowledgment {
    public static let settleMargin: Double = 3

    public static func acknowledged(_ completions: [AttentionCompletion],
                                    snapshot: DesktopReadStateSnapshot) -> [CompletionIdentity] {
        completions.filter { completion in
            completion.source == .desktop
                && completion.arrivedAt.isFinite
                && snapshot.modifiedAt >= completion.arrivedAt + settleMargin
                && !snapshot.unread.contains(completion.session)
        }.map(\.id)
    }
}
