import Foundation

/// The minimum attention state worth keeping across companion restarts: completions the user has
/// not dismissed and the completions they have. Requests and running work are deliberately absent;
/// both are rebuilt from current evidence so a restart can never show stale controls or activity.
public struct AttentionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var completions: [AttentionCompletion]
    public var acknowledged: Set<CompletionIdentity>

    public init(completions: [AttentionCompletion] = [], acknowledged: Set<CompletionIdentity> = []) {
        version = Self.currentVersion
        self.completions = completions
        self.acknowledged = acknowledged
    }
}

/// Atomic, bounded snapshot persistence under Steer's own support directory. It never writes into
/// Codex's data, and any snapshot it cannot trust loads as empty so startup proceeds normally.
public enum AttentionSnapshotStore {
    public static let limit = 4 * 1024 * 1024

    public static func load(from file: URL) -> AttentionSnapshot {
        guard let bytes = SafeFile.read(file, limit: limit),
              let snapshot = try? JSONDecoder().decode(AttentionSnapshot.self, from: bytes),
              snapshot.version == AttentionSnapshot.currentVersion,
              snapshot.completions.allSatisfy({ $0.arrivedAt.isFinite }) else { return AttentionSnapshot() }
        return snapshot
    }

    /// Writes to a sibling temporary file and renames it over the destination, so an interrupted
    /// save leaves the previous snapshot intact and at most one stray temporary file. Only a
    /// missing path or a regular file is ever replaced; a directory or symlink there is left alone.
    @discardableResult
    public static func save(_ snapshot: AttentionSnapshot, to file: URL) -> Bool {
        let directory = file.deletingLastPathComponent()
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= limit,
              (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              isReplaceable(file) else { return false }
        let temporary = directory.appendingPathComponent("." + file.lastPathComponent + ".steer-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    private static func isReplaceable(_ file: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return !FileManager.default.fileExists(atPath: file.path) // missing is fine; unreadable is not
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
}
