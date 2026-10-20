import Foundation

/// Companion receipts start the 30-second deadline. Issued by the app's state owner, never by a reader.
public enum ApprovalReceipts {
    public static func existing(for id: UUID, in directory: URL) -> ApprovalReceiptRecord? {
        guard let bytes = SafeFile.read(ApprovalStore.receiptURL(in: directory, id: id), limit: 4096) else { return nil }
        return try? JSONDecoder().decode(ApprovalReceiptRecord.self, from: bytes)
    }

    /// Writes one receipt per request (an existing receipt is kept, never replaced) and returns the
    /// actionable queue items with the receipt's deadline.
    public static func issue(_ requests: [ApprovalRequest], in directory: URL, cliSessions: Set<UUID>,
                             now: Double) -> [AttentionRequest] {
        requests.compactMap { request in
            let created = ApprovalReceiptRecord(requestID: request.id, receivedAt: now)
            let receipt = ApprovalStore.publish(created, in: directory) ? created : existing(for: request.id, in: directory)
            guard let receipt else { return nil }
            return AttentionRequest(id: request.id, source: cliSessions.contains(request.sessionID) ? .cli : .desktop,
                                    session: request.sessionID, turn: request.turnID, arrivedAt: receipt.receivedAt,
                                    expiresAt: receipt.expiresAt, state: .actionable, details: request.details)
        }
    }
}

/// Decision records written by the companion (allow once, deny, or a no-decision handoff).
public enum ApprovalDecisions {
    public static func existing(for id: UUID, in directory: URL) -> ApprovalDecisionRecord? {
        guard let bytes = SafeFile.read(ApprovalStore.decisionURL(in: directory, id: id), limit: 4096) else { return nil }
        return try? JSONDecoder().decode(ApprovalDecisionRecord.self, from: bytes)
    }
}
