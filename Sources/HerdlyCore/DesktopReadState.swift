import Foundation

/// The Codex desktop app's own unread flags, read from the private file it persists them in.
///
/// The desktop app keeps one boolean per thread, `hasUnreadTurn`. It raises the flag when a turn
/// completes or a request arrives, and clears it only when that thread is the selected view in a
/// focused Codex window (or the user marks it read, or archives or deletes it). It persists the set
/// of flagged thread ids in `~/.codex/.codex-global-state.json`, debounced by about half a second
/// and written by temp-file rename, so a reader never sees a partial file. Two layouts are known:
///
/// - Desktop 26.930.61225 keeps them under `electron-thread-read-state-v1` → `unreadByIdentity`
///   → a signed-in identity key → an execution host key such as `local:<hash>`. Both keys are
///   hashes Herdly cannot recompute, so it requires exactly one `local:` host in each identity
///   and treats a thread as unread when any identity flags it.
/// - Desktop 26.901.51231 kept them under `electron-persisted-atom-state` →
///   `unread-thread-ids-by-host-v1` → `local`. Newer builds migrate and delete this key.
///
/// See docs/desktop-read-state.md. This is a private, build-specific format. The reader fails
/// closed: anything it cannot fully parse, or cannot attribute to the one local host, is
/// "no evidence", never "read".
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
    static let readStateKey = "electron-thread-read-state-v1"
    static let readStateVersion = 1
    static let unreadByIdentityKey = "unreadByIdentity"
    static let localHostKeyPrefix = "local:"
    static let atomStateKey = "electron-persisted-atom-state"
    static let legacyUnreadKey = "unread-thread-ids-by-host-v1"
    static let legacyLocalHost = "local"

    public static func defaultURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent(fileName)
    }

    /// Nil whenever the file is missing, not a regular file, over the size bound, not JSON, or holds
    /// neither layout exactly down to one local host's array. An empty array is a valid snapshot.
    /// `read` is called on every scan; the file is parsed again only when it changes (#302).
    public static func read(_ url: URL) -> DesktopReadStateSnapshot? {
        memo.value(of: url, read: readUncached)
    }

    private static let memo = StampedFileMemo<DesktopReadStateSnapshot?>()

    private static func readUncached(_ url: URL) -> DesktopReadStateSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let bytes = SafeFile.read(url, limit: limit) else { return nil }
        return parse(bytes, modifiedAt: modified.timeIntervalSince1970)
    }

    public static func parse(_ bytes: Data, modifiedAt: Double) -> DesktopReadStateSnapshot? {
        guard modifiedAt.isFinite,
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        // The current layout wins when present: the app deletes the legacy key once it migrates,
        // and any legacy copy left beside the current one is stale.
        let local: [Any]?
        if let state = root[readStateKey] {
            local = localUnread(readState: state)
        } else {
            local = ((root[atomStateKey] as? [String: Any])?[legacyUnreadKey] as? [String: Any])?[legacyLocalHost] as? [Any]
        }
        guard let local, let unread = threadIDs(local) else { return nil }
        return DesktopReadStateSnapshot(unread: unread, modifiedAt: modifiedAt)
    }

    /// The local host's ids in the per-identity layout, merged across signed-in identities. Herdly
    /// cannot tell which identity is current, but a thread unread under any of them stays unread, so
    /// the merge can only keep completions queued, never clear one the current account still flags.
    /// No identity, an identity without exactly one `local:` host (Herdly cannot tell which is this
    /// Mac), or an unexpected version or shape returns nil.
    private static func localUnread(readState: Any) -> [Any]? {
        guard let state = readState as? [String: Any],
              (state["version"] as? NSNumber)?.intValue == readStateVersion,
              let identities = state[unreadByIdentityKey] as? [String: Any],
              !identities.isEmpty else { return nil }
        var merged: [Any] = []
        for identity in identities.values {
            guard let hosts = identity as? [String: Any] else { return nil }
            let local = hosts.filter { $0.key.hasPrefix(localHostKeyPrefix) }
            guard local.count == 1, let ids = local.first?.value as? [Any] else { return nil }
            merged += ids
        }
        return merged
    }

    /// Any entry that is not a thread id means the format moved; refuse the whole snapshot.
    private static func threadIDs(_ entries: [Any]) -> Set<UUID>? {
        var unread: Set<UUID> = []
        for entry in entries {
            guard let text = entry as? String, let id = UUID(uuidString: text) else { return nil }
            unread.insert(id)
        }
        return unread
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

    /// `desktopThreads` are the sessions whose rollout names the desktop app as originator
    /// (`ReminderScan.desktopOriginatedSessions`). A daemon-run terminal session can be labelled
    /// desktop until Herdly proves it CLI, but the desktop app never flags its thread unread, so
    /// absence from the set says nothing about it (#284).
    public static func acknowledged(_ completions: [AttentionCompletion], snapshot: DesktopReadStateSnapshot,
                                    desktopThreads: Set<UUID>) -> [CompletionIdentity] {
        completions.filter { completion in
            completion.source == .desktop
                && desktopThreads.contains(completion.session)
                && completion.arrivedAt.isFinite
                && snapshot.modifiedAt >= completion.arrivedAt + settleMargin
                && !snapshot.unread.contains(completion.session)
        }.map(\.id)
    }
}
