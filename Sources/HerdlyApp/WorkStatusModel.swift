import Foundation
import HerdlyCore

/// Work status for finished rows (#417, ADR 0023): the branch each running turn was seen on, the
/// verdict read for each finished turn, and the GitHub card's state and switch. It draws nothing in the
/// notch; `verdict(for:)` is what a row will read. Nothing here changes the queue, its counts,
/// acknowledgment, the spotlight or any deadline.
@MainActor
final class WorkStatusModel: ObservableObject {
    /// Most turns read in one batch, so a long queue cannot start a burst of commands.
    static let batchLimit = 6

    @Published private(set) var cli: GitHubCLIStatus = .checking
    @Published private(set) var stored: Bool?
    @Published private(set) var readings: [AgentTurnIdentity: WorkStatusReading] = [:]
    private(set) var memory = WorkBranchMemory()
    private var inFlight = false
    private var checkingCLI = false
    private let gate: WorkStatusGate
    private let reader: WorkStatusReader
    private let defaults: UserDefaults?

    init(reader: WorkStatusReader? = nil, gate: WorkStatusGate? = nil, defaults: UserDefaults? = .standard) {
        let stored = defaults?.object(forKey: WorkStatusSetting.defaultsKey) as? Bool
        let gate = gate ?? WorkStatusGate(open: false)
        self.gate = gate
        self.reader = reader ?? WorkStatusReader.live(gate: gate)
        self.defaults = defaults
        self.stored = stored
        gate.set(isEnabled)
    }

    /// "Pull request status on finished rows": the stored choice, or on while `gh` is signed in.
    var isEnabled: Bool { WorkStatusSetting.isOn(stored: stored, cli: cli) }

    func setEnabled(_ on: Bool) {
        stored = on
        defaults?.set(on, forKey: WorkStatusSetting.defaultsKey)
        applySwitch()
    }

    /// The finished turn's verdict, `none` while the switch is off or nothing is known.
    func verdict(for turn: AgentTurnIdentity) -> WorkStatus {
        guard isEnabled else { return .none }
        return readings[turn]?.verdict ?? .none
    }

    /// Reads the GitHub card's state off the main actor. At launch only when the switch's default
    /// depends on it; otherwise when Settings › Agents shows.
    func refreshCLI(launch: Bool = false) {
        if launch && stored != nil { return }
        guard !checkingCLI else { return }
        checkingCLI = true
        let reader = reader
        Task {
            let status = await Task.detached { reader.cliStatus() }.value
            checkingCLI = false
            if cli != status { cli = status }
            applySwitch()
        }
    }

    /// One scan's rows (#417): remember running turns' branches, then read the finished turns that are
    /// due. `heads` are the HEADs the scan read by folder; `directory` is each row's folder.
    func scanned(_ items: [AgentAttentionItem], heads: [String: GitHead], directory: (AgentAttentionItem) -> String?,
                 now: Double) {
        guard isEnabled else { return }
        let sightings: [WorkBranchSighting] = items.compactMap { item in
            guard item.kind == .running, let running = item.running, let folder = directory(item) else { return nil }
            return WorkBranchSighting(turn: running.identity, startedAt: running.arrivedAt, directory: folder,
                                      head: heads[folder])
        }
        memory.observe(sightings)
        let finished = items.compactMap { item -> (turn: AgentTurnIdentity, earlier: Bool)? in
            guard item.kind == .outcome || item.kind == .earlierOutcome, let outcome = item.outcome else { return nil }
            return (outcome.identity, item.kind == .earlierOutcome)
        }
        let kept = Set(sightings.map(\.turn) + finished.map(\.turn))
        memory.retain(kept)
        let retained = readings.filter { kept.contains($0.key) }
        if retained.count != readings.count { readings = retained }
        guard !inFlight else { return }

        let repositories = Array(memory.unreadRepositories.prefix(Self.batchLimit))
        var due: [(turn: AgentTurnIdentity, branch: WorkBranch)] = []
        for (turn, earlier) in finished {
            let branch = memory.branch(for: turn)
            switch branch {
            case .unknown, .ambiguous:
                // Nothing to read: the verdict is none without running anything.
                if readings[turn] == nil {
                    readings[turn] = WorkStatusReading(verdict: .none, readAt: now, firstReadAt: now)
                }
                continue
            case .detached(let folder), .branch(_, let folder, _, _):
                guard !WorkBranchMemory.busy(folder, turn: turn, running: sightings),
                      !memory.unreadRepositories.contains(where: { $0.turn == turn }) else { continue }
            }
            guard WorkStatusSchedule.isDue(readings[turn], isEarlier: earlier, now: now) else { continue }
            due.append((turn, branch))
            if due.count + repositories.count >= Self.batchLimit { break }
        }
        guard !repositories.isEmpty || !due.isEmpty else { return }
        inFlight = true
        let reader = reader, toRead = due
        Task {
            let result = await Task.detached {
                (repositories.map { ($0.turn, reader.repository($0.directory)) },
                 toRead.map { ($0.turn, reader.verdict($0.branch)) })
            }.value
            inFlight = false
            // A switch turned off while the batch ran keeps nothing it read.
            guard isEnabled else { return }
            for (turn, repository) in result.0 { memory.record(repository, for: turn) }
            let readAt = Date().timeIntervalSince1970
            var next = readings
            for (turn, verdict) in result.1 {
                next[turn] = WorkStatusReading(verdict: verdict, readAt: readAt,
                                               firstReadAt: readings[turn]?.firstReadAt ?? readAt)
            }
            if next != readings { readings = next }
        }
    }

    /// Opens or closes the gate to match the switch. Off forgets everything read, so turning it back
    /// on starts clean.
    private func applySwitch() {
        gate.set(isEnabled)
        guard !isEnabled else { return }
        memory = WorkBranchMemory()
        if !readings.isEmpty { readings = [:] }
    }
}
