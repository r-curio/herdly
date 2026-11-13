import Foundation
import Testing
@testable import HerdlyCore

@Test func theRefreshTickSlowsOnlyWhenNothingTimeSensitiveIsShowing() {
    #expect(RefreshCadence.interval(presenting: false, interacting: false, actionableApproval: false) == RefreshCadence.idle)
    #expect(RefreshCadence.interval(presenting: true, interacting: false, actionableApproval: false) == RefreshCadence.active)
    #expect(RefreshCadence.interval(presenting: false, interacting: true, actionableApproval: false) == RefreshCadence.active)
    // An approval's deadline can pass while the notch is collapsed: hand back without waiting a second.
    #expect(RefreshCadence.interval(presenting: false, interacting: false, actionableApproval: true) == RefreshCadence.active)
    #expect(RefreshCadence.active < RefreshCadence.idle)
}

@Test func oneDueHostBringsEveryEligibleHostIntoTheSharedRead() {
    let eligible = ["terminalApp": 10.0, "tmux": 11.5, "zellij": 0]
    #expect(SharedTabScan.hostsToRead(eligible: eligible, now: 9) == ["terminalApp", "tmux", "zellij"])
    #expect(SharedTabScan.hostsToRead(eligible: ["terminalApp": 10.0, "tmux": 11.5], now: 9.99) == [])
    // The due boundary is inclusive, as each host's own `uptime >= nextScan` gate was.
    #expect(SharedTabScan.hostsToRead(eligible: ["terminalApp": 10.0, "tmux": 11.5], now: 10) == ["terminalApp", "tmux"])
}

@Test func noEligibleHostTakesNoSharedRead() {
    #expect(SharedTabScan.hostsToRead(eligible: [String: Double](), now: 100).isEmpty)
}

private func listingDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-listing-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func anUnchangedEventDirectoryReusesItsListingAndAChangedOneIsListedAgain() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("a.json"), second = root.appendingPathComponent("b.json")
    try Data("{}".utf8).write(to: first)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: first.path)
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["a.json"])
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["a.json"])

    try Data("{}".utf8).write(to: second)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: second.path)
    // A new entry changes the directory's stamp: listed again, oldest first.
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["b.json", "a.json"])

    try FileManager.default.removeItem(at: second)
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["a.json"])
}

@Test func aCachedListingStillHonorsEachCallersLimit() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.json", "b.json", "c.json"] { try Data("{}".utf8).write(to: root.appendingPathComponent(name)) }
    #expect(HookEventListing.entries(in: root)?.count == 3)
    #expect(HookEventListing.entries(in: root, limit: 2) == nil)
    #expect(HookEventListing.entries(in: root, limit: 3)?.count == 3)
}

@Test func aMissingEventDirectoryIsUnavailableAndNotCached() throws {
    let root = try listingDirectory()
    try FileManager.default.removeItem(at: root)
    #expect(HookEventListing.entries(in: root) == nil)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(HookEventListing.entries(in: root) == [])
}

@Test func aRecordReplacedUnderTheSameNameIsDatedAfresh() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let early = root.appendingPathComponent("early.json"), late = root.appendingPathComponent("late.json")
    try Data("{}".utf8).write(to: early)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: early.path)
    try Data("{}".utf8).write(to: late)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: late.path)
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["early.json", "late.json"])

    // An atomic rewrite puts a new file (new inode, new creation date) under the old name.
    let replacement = root.appendingPathComponent("replacement.tmp")
    try Data("{}".utf8).write(to: replacement)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: replacement.path)
    #expect(rename(replacement.path, early.path) == 0)
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["late.json", "early.json"])
}

@Test func aListingKeepsHiddenEntriesAndMarksDirectories() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{}".utf8).write(to: root.appendingPathComponent(".hidden.json"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
    let listed = try #require(HookEventListing.entries(in: root))
    #expect(Set(listed.map(\.lastPathComponent)) == [".hidden.json", "folder"])
    #expect(listed.first { $0.lastPathComponent == "folder" }?.hasDirectoryPath == true)
}

@Test func recordsAddedAfterTheNewestAreAppendedInOrderAndRemovalsDropOut() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    func add(_ name: String, at seconds: Double) throws {
        let url = root.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }
    try add("a.json", at: 100)
    try add("b.json", at: 200)
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["a.json", "b.json"])
    try FileManager.default.removeItem(at: root.appendingPathComponent("a.json"))
    try add("d.json", at: 400)
    try add("c.json", at: 300)
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["b.json", "c.json", "d.json"])
}

@Test func anUnchangedFileIsParsedOnceAndAChangedOrReplacedOneAgain() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("state.json")
    try Data("one".utf8).write(to: file)
    let memo = StampedFileMemo<String?>()
    var reads = 0
    func read(_ url: URL) -> String? { reads += 1; return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    #expect(memo.value(of: file, read: read) == "one")
    #expect(memo.value(of: file, read: read) == "one")
    #expect(reads == 1)
    try Data("three".utf8).write(to: file)   // a rewrite changes size and time
    #expect(memo.value(of: file, read: read) == "three")
    let replacement = root.appendingPathComponent("next.tmp")
    try Data("seven".utf8).write(to: replacement)
    #expect(rename(replacement.path, file.path) == 0)   // an atomic replace changes the inode
    #expect(memo.value(of: file, read: read) == "seven")
    #expect(reads == 3)
}

@Test func aLinkOrMissingFileIsNeverKept() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
    try Data("x".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let memo = StampedFileMemo<Int>()
    var reads = 0
    _ = memo.value(of: link) { _ in reads += 1; return 0 }
    _ = memo.value(of: link) { _ in reads += 1; return 0 }
    _ = memo.value(of: root.appendingPathComponent("missing")) { _ in reads += 1; return 0 }
    #expect(reads == 3)
}

@Test func aListingsRecordsAreItsNewestJSONEntriesOldestFirst() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for (index, name) in ["a.json", "b.approval", ".json", "c.json"].enumerated() {
        let url = root.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(100 + index))], ofItemAtPath: url.path)
    }
    let listing = try #require(HookEventListing.listing(in: root))
    #expect(listing.entries.map(\.lastPathComponent) == ["a.json", "b.approval", ".json", "c.json"])
    #expect(listing.records.map(\.lastPathComponent) == ["a.json", "c.json"])
    #expect(Array(HookEventListing.newestRecords(listing.entries)) == Array(listing.records))
    // A reused listing returns the same records.
    #expect(HookEventListing.listing(in: root).map { Array($0.records) } == Array(listing.records))
}

@Test func aSharedReadingIsReusedOnlyWhenItBeganAfterTheScanAndIsFresh() {
    // Began after this scan read the frontmost app, and recent: reused.
    #expect(SharedReading.reusable(takenAt: 100.2, notBefore: 100, now: 101, maxAge: 1.5))
    #expect(SharedReading.reusable(takenAt: 100, notBefore: 100, now: 101, maxAge: 1.5))
    // Began before the frontmost reading it would be combined with: read again.
    #expect(!SharedReading.reusable(takenAt: 99.9, notBefore: 100, now: 100.1, maxAge: 1.5))
    // Too old, at the boundary too.
    #expect(!SharedReading.reusable(takenAt: 100, notBefore: 100, now: 101.5, maxAge: 1.5))
    #expect(!SharedReading.reusable(takenAt: .nan, notBefore: 100, now: 100, maxAge: 1.5))
}

@Test func restartRecheckRunsOnlyWhileARootWaitsAndAtMostEveryFiveSeconds() {
    let start = 1_000.0
    var gate = RestartRecheckGate()
    var started = gate.start(now: start, anyWaiting: false)
    #expect(!started)
    started = gate.start(now: start, anyWaiting: true)
    #expect(started)
    // Never two at once, however long the running check takes.
    started = gate.start(now: start + 60, anyWaiting: true)
    #expect(!started)
    gate.finish(now: start + 1)
    started = gate.start(now: start + 5.999, anyWaiting: true)
    #expect(!started)
    started = gate.start(now: start + 6, anyWaiting: true)
    #expect(started)
}

@Test func theHerdrScanSlowsOnlyWhileNobodyCanUseItsResult() {
    #expect(HerdrScanCadence.interval(terminalFrontmost: false, herdlyInUse: false, needsUser: false) == HerdrScanCadence.away)
    // A pane can be visited, a row can be opened, or a visit can acknowledge something: two seconds.
    #expect(HerdrScanCadence.interval(terminalFrontmost: true, herdlyInUse: false, needsUser: false) == HerdrScanCadence.near)
    #expect(HerdrScanCadence.interval(terminalFrontmost: false, herdlyInUse: true, needsUser: false) == HerdrScanCadence.near)
    #expect(HerdrScanCadence.interval(terminalFrontmost: false, herdlyInUse: false, needsUser: true) == HerdrScanCadence.near)
    #expect(HerdrScanCadence.near < HerdrScanCadence.away)
}

@Test func aHerdrScanIsDueByTheIntervalInForceNow() {
    // The first scan after the gate opens never waits.
    #expect(HerdrScanCadence.isDue(lastStartedAt: nil, now: 0, interval: HerdrScanCadence.away))
    #expect(!HerdrScanCadence.isDue(lastStartedAt: 100, now: 109.9, interval: HerdrScanCadence.away))
    #expect(HerdrScanCadence.isDue(lastStartedAt: 100, now: 110, interval: HerdrScanCadence.away))
    // Three seconds into an away wait, the terminal comes forward: due at once, not seven seconds later.
    #expect(HerdrScanCadence.isDue(lastStartedAt: 100, now: 103, interval: HerdrScanCadence.near))
    #expect(!HerdrScanCadence.isDue(lastStartedAt: 100, now: 101.9, interval: HerdrScanCadence.near))
}

@Test func aReaderKeepsOnlyWhatItChoosesUnderTheStampItTook() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("entry.json")
    try Data("one".utf8).write(to: file)
    let memo = StampedFileMemo<String>()
    let before = memo.kept(file)
    #expect(before.stamp != nil && before.value == nil)
    memo.keep("one", for: file, stamp: try #require(before.stamp))
    #expect(memo.kept(file).value == "one")
    // Rewritten after the stamp was taken: what was kept under the old stamp is not served.
    try Data("three".utf8).write(to: file)
    #expect(memo.kept(file).value == nil)
    // A link or a missing file has no stamp to keep under.
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(memo.kept(link).stamp == nil)
    #expect(memo.kept(root.appendingPathComponent("missing")).stamp == nil)
}

@Test func theBranchAndUsageReadersSeeAChangeOnTheNextRead() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = root.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    let head = git.appendingPathComponent("HEAD")
    try Data("ref: refs/heads/main\n".utf8).write(to: head)
    #expect(GitBranchReader.branch(forDirectory: root.path) == "main")
    #expect(GitBranchReader.branch(forDirectory: root.path) == "main")
    // Git replaces HEAD on a checkout.
    try Data("ref: refs/heads/fix/idle\n".utf8).write(to: head, options: .atomic)
    #expect(GitBranchReader.branch(forDirectory: root.path) == "fix/idle")
    try FileManager.default.removeItem(at: head)
    #expect(GitBranchReader.branch(forDirectory: root.path) == nil)

    let usage = root.appendingPathComponent(ClaudeUsageReader.latestRecordName)
    func record(_ used: Double) throws -> Data {
        try #require(ClaudeUsageReader.sanitizedRecord(try JSONSerialization.data(withJSONObject: [
            "session_id": "00000000-0000-4000-8000-000000000001",
            "rate_limits": ["five_hour": ["used_percentage": used, "resets_at": 5_000]]] as [String: Any]), observedAt: 100))
    }
    try record(10).write(to: usage, options: .atomic)
    #expect(ClaudeUsageReader.latest(root: root, now: 200)?.fiveHour?.usedPercentage == 10)
    #expect(ClaudeUsageReader.latest(root: root, now: 200)?.fiveHour?.usedPercentage == 10)
    try record(40).write(to: usage, options: .atomic)
    #expect(ClaudeUsageReader.latest(root: root, now: 200)?.fiveHour?.usedPercentage == 40)
    // The window's expiry still follows the clock passed in, kept record or not.
    #expect(ClaudeUsageReader.latest(root: root, now: 6_000)?.fiveHour == nil)
}

// MARK: - Hook scan schedule (#306)

private let quiet = HookScanNeeds()

/// A schedule whose last scan started at `at` with nothing pending.
private func scheduleStarted(at: Double) -> HookScanSchedule {
    var schedule = HookScanSchedule()
    do { let started = schedule.start(now: at, watchTrusted: true, needs: quiet); #expect(started) }
    return schedule
}

@Test func theFirstHookScanIsDueAtOnce() {
    var schedule = HookScanSchedule()
    #expect(schedule.isDue(now: 0, watchTrusted: true, needs: quiet))
    do { let started = schedule.start(now: 0, watchTrusted: true, needs: quiet); #expect(started) }
    #expect(!schedule.isDue(now: 0, watchTrusted: true, needs: quiet))
}

@Test func aHookDirectoryChangeAfterAQuietPeriodIsScannedOnTheNextAsk() {
    var schedule = scheduleStarted(at: 100)
    // Quiet for five seconds: nothing is due before the safety interval.
    #expect(!schedule.isDue(now: 105, watchTrusted: true, needs: quiet))
    schedule.noteChange()
    do { let started = schedule.start(now: 105, watchTrusted: true, needs: quiet); #expect(started) }
}

@Test func aBurstOfChangesWithinTheIntervalCostsOneScanAndIsNotLost() {
    var schedule = scheduleStarted(at: 100)
    schedule.noteChange()
    do { let started = schedule.start(now: 103, watchTrusted: true, needs: quiet); #expect(started) }
    // More records arrive while that scan runs, or after it listed its directories.
    for now in stride(from: 103.2, to: 105, by: 0.2) {
        schedule.noteChange()
        do { let started = schedule.start(now: now, watchTrusted: true, needs: quiet); #expect(!started) }
    }
    // The evidence waited: the next scan starts exactly one interval after the last, as the fixed clock did.
    do { let started = schedule.start(now: 103 + HookScanSchedule.interval, watchTrusted: true, needs: quiet); #expect(started) }
    // That scan took the evidence with it: nothing further is due until the safety interval.
    #expect(!schedule.isDue(now: 105 + HookScanSchedule.interval, watchTrusted: true, needs: quiet))
}

@Test func aChangeNotedAfterAScanStartedCausesAnotherScan() {
    var schedule = HookScanSchedule()
    schedule.noteChange()
    do { let started = schedule.start(now: 50, watchTrusted: true, needs: quiet); #expect(started) }
    schedule.noteChange()
    #expect(!schedule.isDue(now: 51.9, watchTrusted: true, needs: quiet))
    #expect(schedule.isDue(now: 52, watchTrusted: true, needs: quiet))
}

@Test func withNoEvidenceAndNothingPendingOnlySafetyScansRun() {
    var schedule = scheduleStarted(at: 0)
    var starts: [Double] = []
    for tick in 1...60 where schedule.start(now: Double(tick), watchTrusted: true, needs: quiet) {
        starts.append(Double(tick))
    }
    #expect(starts == [10, 20, 30, 40, 50, 60])
    #expect(HookScanSchedule.safetyInterval > HookScanSchedule.interval)
}

@Test func theSafetyBoundaryIsInclusive() {
    let schedule = scheduleStarted(at: 7)
    #expect(!schedule.isDue(now: 7 + HookScanSchedule.safetyInterval - 0.001, watchTrusted: true, needs: quiet))
    #expect(schedule.isDue(now: 7 + HookScanSchedule.safetyInterval, watchTrusted: true, needs: quiet))
}

@Test func anUntrustedWatchKeepsTheFixedCadence() {
    var schedule = scheduleStarted(at: 0)
    var starts: [Double] = []
    for tick in 1...8 where schedule.start(now: Double(tick), watchTrusted: false, needs: quiet) {
        starts.append(Double(tick))
    }
    #expect(starts == [2, 4, 6, 8])
}

@Test func eachFastCadenceNeedKeepsTheFixedCadence() {
    let each: [WritableKeyPath<HookScanNeeds, Bool>] = [
        \.nothingAppliedYet, \.rowsHeld, \.sessionsLive, \.codexMayRun, \.sourceUnwatchedOrUnreadable,
        \.timedStateDue, \.herdlyInUse,
    ]
    #expect(!quiet.fastCadence)
    for need in each {
        var needs = HookScanNeeds()
        needs[keyPath: need] = true
        #expect(needs.fastCadence)
        let schedule = scheduleStarted(at: 0)
        #expect(!schedule.isDue(now: 1.999, watchTrusted: true, needs: needs))
        // Inclusive at exactly the interval, as the former `now >= nextScan` gate was.
        #expect(schedule.isDue(now: HookScanSchedule.interval, watchTrusted: true, needs: needs))
    }
}

@Test func scansAreNeverCloserThanTheIntervalWhateverIsPending() {
    var needs = HookScanNeeds()
    needs.rowsHeld = true
    var schedule = scheduleStarted(at: 10)
    schedule.noteChange()
    #expect(!schedule.isDue(now: 11.999, watchTrusted: false, needs: needs))
    #expect(schedule.isDue(now: 12, watchTrusted: false, needs: needs))
}

@Test func aClockThatDoesNotAdvanceStartsNoSecondScan() {
    var schedule = HookScanSchedule()
    schedule.noteChange()
    do { let started = schedule.start(now: 5, watchTrusted: true, needs: quiet); #expect(started) }
    schedule.noteChange()
    for _ in 0..<5 { do { let started = schedule.start(now: 5, watchTrusted: false, needs: quiet); #expect(!started) } }
}

@Test func aClockThatCannotBeComparedScansRatherThanSkips() {
    var schedule = scheduleStarted(at: 100)
    #expect(schedule.isDue(now: 99, watchTrusted: true, needs: quiet))
    #expect(schedule.isDue(now: .nan, watchTrusted: true, needs: quiet))
    // A scan started on an unreadable clock leaves no spacing to rely on.
    do { let started = schedule.start(now: .nan, watchTrusted: true, needs: quiet); #expect(started) }
    #expect(schedule.isDue(now: 100.1, watchTrusted: true, needs: quiet))
}

@Test func anExplicitRequestIsDueWithoutWaitingForTheInterval() {
    var schedule = scheduleStarted(at: 100)
    schedule.requestNow()
    do { let started = schedule.start(now: 100.2, watchTrusted: true, needs: quiet); #expect(started) }
    #expect(!schedule.isDue(now: 100.4, watchTrusted: true, needs: quiet))
}

@Test func theFallbackCadenceIsTheIntervalTheHelpersConnectionTimeoutIsSizedAgainst() {
    #expect(HookScanSchedule.interval == ApprovalTiming.scanInterval)
    #expect(ApprovalTiming.connectionTimeout > HookScanSchedule.interval + RefreshCadence.idle)
}

@Test func watchReportsBecomeScanEvidenceOnceAndAnUnwatchedDirectoryIsUntrusted() {
    let log = HookDirectoryChangeLog()
    let watched = URL(fileURLWithPath: "/tmp/herdly-evidence-a", isDirectory: true)
    let other = URL(fileURLWithPath: "/tmp/herdly-evidence-b", isDirectory: true)
    // Nothing to watch: nothing to distrust, nothing changed.
    #expect(log.takeScanEvidence(for: []) == (false, true))
    // Not watched yet, or its stream could not start: untrusted for as long as that holds.
    #expect(log.takeScanEvidence(for: [watched]) == (false, false))
    #expect(log.takeScanEvidence(for: [watched]) == (false, false))

    log.startWatching(watched)
    // A new watch knows nothing of what came before it: one scan.
    #expect(log.takeScanEvidence(for: [watched]) == (true, true))
    #expect(log.takeScanEvidence(for: [watched]) == (false, true))
    #expect(log.takeScanEvidence(for: [watched, other]) == (false, false))

    log.report(["a.json"], in: watched)
    log.report(["b.json"], in: watched)
    #expect(log.takeScanEvidence(for: [watched]) == (true, true))
    #expect(log.takeScanEvidence(for: [watched]) == (false, true))
    // A change below the top level names nothing the listing needs, and is still evidence.
    log.report([], in: watched)
    #expect(log.takeScanEvidence(for: [watched]) == (true, true))
    // A report for a directory nobody watches is dropped.
    log.report(["c.json"], in: other)
    #expect(log.takeScanEvidence(for: [watched]) == (false, true))
}

@Test func theListingTakingItsNamesDoesNotConsumeTheScanEvidence() throws {
    let root = try listingDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    HookEventListing.changes.startWatching(root)
    defer { HookEventListing.changes.stopWatching(root) }
    _ = HookEventListing.changes.takeScanEvidence(for: [root])
    try Data("{}".utf8).write(to: root.appendingPathComponent("a.json"))
    HookEventListing.changes.report(["a.json"], in: root)
    // The scan's own listing empties the names it was told; the evidence is the schedule's to take.
    #expect(HookEventListing.entries(in: root)?.map(\.lastPathComponent) == ["a.json"])
    #expect(HookEventListing.changes.takeScanEvidence(for: [root]).changed)
}

@Test func droppedEventsAreEvidenceAndALostWatchIsUntrustedUntilItStartsAgain() {
    let log = HookDirectoryChangeLog()
    let directory = URL(fileURLWithPath: "/tmp/herdly-evidence-c", isDirectory: true)
    log.startWatching(directory)
    _ = log.takeScanEvidence(for: [directory])

    // Dropped or overflowed events: one full read covers them, and each further report asks again.
    log.reportUnknown(in: directory)
    #expect(log.takeScanEvidence(for: [directory]) == (true, true))
    log.report(Set((0...HookDirectoryChangeLog.maximumNames).map { "\($0).json" }), in: directory)
    #expect(log.takeScanEvidence(for: [directory]) == (true, true))

    // The directory moved or its volume went away: the watch may be following nothing.
    log.reportUnknown(in: directory, watchLost: true)
    #expect(log.isWatchLost(directory))
    #expect(log.takeScanEvidence(for: [directory]) == (true, false))
    #expect(log.takeScanEvidence(for: [directory]) == (false, false))
    log.startWatching(directory)
    #expect(!log.isWatchLost(directory))
    #expect(log.takeScanEvidence(for: [directory]) == (true, true))
    log.stopWatching(directory)
    #expect(log.takeScanEvidence(for: [directory]) == (false, false))
}

@Test func anAgentQueueWithNothingHeldNeedsNoFixedCadence() {
    #expect(!AgentAttentionQueue().holdsSessionState)
}
