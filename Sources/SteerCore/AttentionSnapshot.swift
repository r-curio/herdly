import Foundation

/// The minimum attention state worth keeping across companion restarts: completions the user has
/// not dismissed and the completions they have. Requests and running work are deliberately absent;
/// both are rebuilt from current evidence so a restart can never show stale controls or activity.
public struct AttentionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    /// Version two stores source-scoped outcomes. `completions` remains as a Codex compatibility
    /// projection for the existing app and migrates old version-one files on decode.
    public let outcomes: [AgentOutcome]
    public let acknowledgedOutcomes: Set<AgentTurnIdentity>

    public var completions: [AttentionCompletion] {
        outcomes.compactMap { outcome in
            guard outcome.session.source == .codex,
                  let session = UUID(uuidString: outcome.session.session),
                  let turn = UUID(uuidString: outcome.turn) else { return nil }
            return AttentionCompletion(source: outcome.session.surface == .cli ? .cli : .desktop,
                                       session: session, turn: turn, arrivedAt: outcome.arrivedAt,
                                       uncertain: outcome.uncertain, status: outcome.status)
        }
    }

    public var acknowledged: Set<CompletionIdentity> {
        Set(acknowledgedOutcomes.compactMap { identity in
            guard identity.session.source == .codex,
                  let session = UUID(uuidString: identity.session.session),
                  let turn = UUID(uuidString: identity.turn) else { return nil }
            return CompletionIdentity(source: identity.session.surface == .cli ? .cli : .desktop,
                                      session: session, turn: turn)
        })
    }

    public init(completions: [AttentionCompletion] = [], acknowledged: Set<CompletionIdentity> = []) {
        version = Self.currentVersion
        outcomes = completions.map { CodexAttentionAdapter.outcome(from: $0) }
        acknowledgedOutcomes = Set(acknowledged.map { identity in
            AgentTurnIdentity(session: CodexAttentionAdapter.session(identity.session,
                                                                      surface: identity.source == .cli ? .cli : .desktop),
                              turn: identity.turn.uuidString)
        })
    }

    public init(outcomes: [AgentOutcome], acknowledged: Set<AgentTurnIdentity> = []) {
        version = Self.currentVersion
        self.outcomes = outcomes
        acknowledgedOutcomes = acknowledged
    }

    /// The pre-snapshot acknowledgment lists, migrated once when no snapshot file exists yet.
    public init(legacyCLI: Set<TurnIdentity>, legacyDesktop: Set<TurnIdentity>) {
        self.init(acknowledged: Set(legacyCLI.map { CompletionIdentity(source: .cli, session: $0.session, turn: $0.turn) }
            + legacyDesktop.map { CompletionIdentity(source: .desktop, session: $0.session, turn: $0.turn) }))
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case outcomes
        case completions
        case acknowledged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        switch version {
        case Self.currentVersion:
            self.init(outcomes: try container.decodeIfPresent([AgentOutcome].self, forKey: .outcomes) ?? [],
                      acknowledged: try container.decodeIfPresent(Set<AgentTurnIdentity>.self, forKey: .acknowledged) ?? [])
        case 1:
            let completions = try container.decodeIfPresent([AttentionCompletion].self, forKey: .completions) ?? []
            let acknowledged = try container.decodeIfPresent(Set<CompletionIdentity>.self, forKey: .acknowledged) ?? []
            self.init(completions: completions, acknowledged: acknowledged)
        default:
            throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                                                    debugDescription: "Unsupported attention snapshot version")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(outcomes, forKey: .outcomes)
        try container.encode(acknowledgedOutcomes, forKey: .acknowledged)
    }
}

/// Atomic, bounded snapshot persistence under Steer's own support directory. It never writes into
/// Codex's data, and any snapshot it cannot trust loads as empty so startup proceeds normally.
public enum AttentionSnapshotStore {
    public static let limit = 4 * 1024 * 1024

    /// The previous snapshot is kept beside the current one, so a save interrupted after the
    /// rename, or a corrupted file, falls back to the last good state instead of losing dismissals.
    public static func backupURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".previous")
    }

    public static func load(from file: URL) -> AttentionSnapshot {
        decode(file) ?? decode(backupURL(for: file)) ?? AttentionSnapshot(outcomes: [])
    }

    private static func decode(_ file: URL) -> AttentionSnapshot? {
        guard let bytes = SafeFile.read(file, limit: limit),
              let snapshot = try? JSONDecoder().decode(AttentionSnapshot.self, from: bytes),
              snapshot.version == AttentionSnapshot.currentVersion,
              snapshot.outcomes.allSatisfy({ $0.arrivedAt.isFinite }) else { return nil }
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
        let backup = backupURL(for: file)
        do {
            try data.write(to: temporary, options: [.atomic])
            // Keep the last good snapshot only if it is valid; a corrupt one must not shadow the new save.
            if decode(file) != nil {
                if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
                try FileManager.default.copyItem(at: file, to: backup)
            }
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
