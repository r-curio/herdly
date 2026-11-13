import Foundation
import HerdlyCore

/// Work status for finished rows (#417, ADR 0023): the branch each running turn was seen on, the
/// verdict read for each finished turn, and the GitHub card's state and switch. It draws nothing in the
/// notch; `verdict(for:)` is what a row will read. Nothing here changes the queue, its counts,
/// acknowledgment, the spotlight or any deadline.
@MainActor
final class WorkStatusModel: ObservableObject {
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
        let gate = gate ?? WorkStatusGate(open: false)
        self.gate = gate
        self.reader = reader ?? WorkStatusReader.live(gate: gate)
        self.defaults = defaults
        stored = defaults?.object(forKey: WorkStatusSetting.defaultsKey) as? Bool
        if !WorkStatusSetting.mayCheckCLI(stored: stored) { cli = cardWithoutRunning }
        gate.set(isEnabled)
    }

    /// "Pull request status on finished rows": the stored choice, or on while `gh` is signed in.
    var isEnabled: Bool { WorkStatusSetting.isOn(stored: stored, cli: cli) }

    /// Whether the card may run `gh`: not once the switch is off.
    var mayCheckCLI: Bool { WorkStatusSetting.mayCheckCLI(stored: stored) }

    var showsSwitch: Bool { WorkStatusSetting.showsSwitch(stored: stored, cli: cli) }

    /// Turning the switch on checks `gh` again (the returned task); off runs nothing more and forgets
    /// what was read.
    @discardableResult
    func setEnabled(_ on: Bool) -> Task<Void, Never>? {
        stored = on
        defaults?.set(on, forKey: WorkStatusSetting.defaultsKey)
        applySwitch()
        guard on else {
            cli = cardWithoutRunning
            return nil
        }
        return refreshCLI()
    }

    /// The finished turn's verdict, `noVerdict` while the switch is off or nothing is known.
    func verdict(for turn: AgentTurnIdentity) -> WorkStatus {
        guard isEnabled else { return .noVerdict }
        return readings[turn]?.verdict ?? .noVerdict
    }

    /// Reads the GitHub card's state off the main actor: at launch while the switch's default is
    /// undecided or on, when Settings › Agents shows, and on Check Again. With the switch off no `gh`
    /// runs: the card shows the binary's presence on disk and the last remembered check. The returned
    /// task finishes when the card is updated.
    @discardableResult
    func refreshCLI() -> Task<Void, Never>? {
        guard mayCheckCLI else {
            cli = cardWithoutRunning
            return nil
        }
        guard !checkingCLI else { return nil }
        checkingCLI = true
        let reader = reader
        return Task {
            let status = await Task.detached { reader.cliStatus() }.value
            checkingCLI = false
            // A switch turned off while `gh` ran keeps the card as the switch-off rule shows it.
            guard mayCheckCLI else { return }
            if cli != status { cli = status }
            if let remembered = status.remembered { defaults?.set(remembered, forKey: WorkStatusSetting.rememberedCLIKey) }
            applySwitch()
        }
    }

    /// One scan's rows (#417): remember running turns' branches, then read the finished turns that are
    /// due at `now`. `heads` are the HEADs the scan read by folder; `directory` is each row's folder.
    /// The returned task finishes once that batch's readings are stored.
    @discardableResult
    func scanned(_ items: [AgentAttentionItem], heads: [String: GitHead], directory: (AgentAttentionItem) -> String?,
                 now: Double) -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        let sightings: [WorkBranchSighting] = items.compactMap { item in
            guard item.kind == .running, let running = item.running, let folder = directory(item) else { return nil }
            return WorkBranchSighting(turn: running.identity, startedAt: running.arrivedAt, directory: folder,
                                      head: heads[folder])
        }
        memory.observe(sightings)
        let finished = items.compactMap { item -> AgentTurnIdentity? in
            guard item.kind == .outcome || item.kind == .earlierOutcome else { return nil }
            return item.outcome?.identity
        }
        let kept = Set(sightings.map(\.turn) + finished)
        memory.retain(kept)
        var next = readings.filter { kept.contains($0.key) }
        guard !inFlight else {
            if next != readings { readings = next }
            return nil
        }
        let batch = WorkStatusBatch.plan(finished: finished, running: sightings, memory: memory, readings: next, now: now)
        for turn in batch.settledNoVerdict {
            next[turn] = WorkStatusReading(verdict: .noVerdict, readAt: now, firstReadAt: now)
        }
        if next != readings { readings = next }
        guard !batch.isEmpty else { return nil }
        inFlight = true
        let reader = reader
        return Task {
            let (repositories, verdicts) = await Task.detached {
                (batch.repositories.map { ($0.turn, reader.repository($0.directory)) },
                 batch.reads.map { ($0.turn, reader.verdict($0.branch)) })
            }.value
            inFlight = false
            // A switch turned off while the batch ran keeps nothing it read.
            guard isEnabled else { return }
            for (turn, repository) in repositories { memory.record(repository, for: turn) }
            var updated = readings
            for (turn, verdict) in verdicts {
                updated[turn] = WorkStatusReading(verdict: verdict, readAt: now,
                                                  firstReadAt: readings[turn]?.firstReadAt ?? now)
            }
            if updated != readings { readings = updated }
        }
    }

    /// The card with the switch off: not installed from the binary's presence on disk, otherwise the
    /// last remembered check, or unknown.
    private var cardWithoutRunning: GitHubCLIStatus {
        GitHubCLIStatus.withoutRunning(installed: reader.gh != nil,
                                       remembered: GitHubCLIStatus.remembered(
                                           defaults?.string(forKey: WorkStatusSetting.rememberedCLIKey)))
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
