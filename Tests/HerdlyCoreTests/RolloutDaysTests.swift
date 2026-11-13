import Foundation
import Testing
@testable import HerdlyCore

/// The listing as it was read before `RolloutDays` kept anything (#306): every directory listed on
/// every call, hidden entries skipped, each rollout's modification time from its resource values.
private func freshListing(root: URL, limit: Int) -> [(url: URL, modified: Date)] {
    func subdirectories(_ url: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                          options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { Int($0.lastPathComponent) != nil && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    var days: [URL] = []
    for year in subdirectories(root).prefix(3) {
        for month in subdirectories(year).prefix(3) {
            for day in subdirectories(month) {
                days.append(day)
                if days.count == CodexUsageReader.maximumDays { break }
            }
            if days.count == CodexUsageReader.maximumDays { break }
        }
        if days.count == CodexUsageReader.maximumDays { break }
    }
    var files: [(URL, Date)] = []
    for day in days {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                          options: [.skipsHiddenFiles]) else { continue }
        for url in entries where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }
    }
    return files.sorted { $0.1 == $1.1 ? $0.0.path > $1.0.path : $0.1 > $1.1 }.prefix(limit).map { (url: $0.0, modified: $0.1) }
}

/// A wall clock long after every directory here was made, so a kept listing is trusted.
private let settled = Date().timeIntervalSince1970 + 3_600

private struct Tree {
    let root: URL

    init() throws {
        // Resolved, so both listings name files by the same path.
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("herdly-rollout-days-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ path: String, _ text: String = "{}\n", modified: Double? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try setModified(path, modified) }
        return url
    }

    /// Sets the modification time to the nanosecond, as a rollout's own writes leave it.
    func setModified(_ path: String, _ time: Double) throws {
        let seconds = time.rounded(.down)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(seconds), tv_nsec: Int(((time - seconds) * 1_000_000_000).rounded()))]
        #expect(utimensat(AT_FDCWD, root.appendingPathComponent(path).path, &times, AT_SYMLINK_NOFOLLOW) == 0)
    }

    func setHidden(_ path: String, _ hidden: Bool) {
        #expect(lchflags(root.appendingPathComponent(path).path, hidden ? UInt32(UF_HIDDEN) : 0) == 0)
    }

    /// The kept listing and a fresh one agree at every limit the readers use.
    func expectSame(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        for limit in [1, CodexUsageReader.maximumFiles, SessionDiscovery.maximumFiles, ReminderReader.maximumChildProbes] {
            let kept = RolloutDays.newest(root: root, limit: limit, now: settled), fresh = freshListing(root: root, limit: limit)
            #expect(kept.map(\.url.path) == fresh.map(\.url.path), comment, sourceLocation: sourceLocation)
            #expect(kept.map(\.url) == fresh.map(\.url), comment, sourceLocation: sourceLocation)
            #expect(kept.map(\.modified) == fresh.map(\.modified), comment, sourceLocation: sourceLocation)
        }
    }
}

@Test func keptRolloutListingEqualsAFreshOneAcrossEveryKindOfChange() throws {
    let tree = try Tree()
    defer { tree.remove() }
    tree.expectSame("no tree yet")
    try FileManager.default.removeItem(at: tree.root)
    tree.expectSame("root missing")

    try tree.write("2026/11/12/a.jsonl", modified: 1_800_000_000.123456789)
    try tree.write("2026/11/12/b.jsonl", modified: 1_800_000_050.000000001)
    try tree.write("2026/11/11/c.jsonl", modified: 1_800_000_020.999999999)
    try tree.write("2026/11/11/notes.txt")
    try tree.write("2026/11/11/.hidden.jsonl")
    try tree.write("2026/11/later/d.jsonl")
    try tree.write("2026/11/13", "a file named like a day")
    try tree.write("drafts/11/12/e.jsonl")
    tree.expectSame("first read")
    tree.expectSame("unchanged")

    // Appended to (a new time and size), rewritten in place to the same size, and replaced atomically.
    try tree.write("2026/11/11/c.jsonl", "{}\n{}\n", modified: 1_800_000_100.5)
    tree.expectSame("appended")
    try tree.setModified("2026/11/12/a.jsonl", 1_800_000_200.25)
    tree.expectSame("touched")
    try Data("{\"replaced\":true}\n".utf8).write(to: tree.root.appendingPathComponent("2026/11/12/b.jsonl"), options: .atomic)
    tree.expectSame("replaced")
    // Two rollouts written in the same nanosecond are ordered by path.
    try tree.setModified("2026/11/12/a.jsonl", 1_800_000_300)
    try tree.setModified("2026/11/12/b.jsonl", 1_800_000_300)
    tree.expectSame("tied")

    try tree.write("2026/11/12/f.jsonl", modified: 1_800_000_400)
    tree.expectSame("added")
    try FileManager.default.removeItem(at: tree.root.appendingPathComponent("2026/11/12/a.jsonl"))
    tree.expectSame("removed")
    try FileManager.default.moveItem(at: tree.root.appendingPathComponent("2026/11/12/f.jsonl"),
                                     to: tree.root.appendingPathComponent("2026/11/12/g.jsonl"))
    tree.expectSame("renamed")
    try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("2026/11/12/link.jsonl"),
                                               withDestinationURL: tree.root.appendingPathComponent("2026/11/11/c.jsonl"))
    try FileManager.default.createDirectory(at: tree.root.appendingPathComponent("2026/11/12/folder.jsonl"), withIntermediateDirectories: true)
    tree.expectSame("a link and a directory named like rollouts")

    // New days, months and years, past each bound.
    try tree.write("2026/11/14/h.jsonl", modified: 1_800_000_500)
    tree.expectSame("new day")
    try tree.write("2026/12/01/i.jsonl", modified: 1_800_000_600)
    try tree.write("2027/01/02/j.jsonl", modified: 1_800_000_700)
    tree.expectSame("new month and year")
    for day in 1...20 { try tree.write(String(format: "2026/10/%02d/k.jsonl", day), modified: 1_700_000_000 + Double(day)) }
    tree.expectSame("more days than are read")
    for month in 1...9 { try tree.write(String(format: "2026/%02d/05/l.jsonl", month), modified: 1_600_000_000 + Double(month)) }
    for year in 2020...2025 { try tree.write("\(year)/06/07/m.jsonl", modified: 1_500_000_000 + Double(year)) }
    tree.expectSame("more months and years than are read")
    try FileManager.default.removeItem(at: tree.root.appendingPathComponent("2027"))
    tree.expectSame("newest year removed")
    try FileManager.default.removeItem(at: tree.root.appendingPathComponent("2026/12/01"))
    tree.expectSame("a day removed")
    try FileManager.default.removeItem(at: tree.root.appendingPathComponent("2026/11/14"))
    try tree.write("2026/11/14", "now a file")
    tree.expectSame("a day replaced by a file")
}

@Test func keptRolloutListingNoticesWhatADirectoryTimeDoesNotShow() throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.write("2026/11/12/a.jsonl", modified: 1_800_000_000)
    try tree.write("2026/11/12/b.jsonl", modified: 1_800_000_050)
    try tree.write("2026/11/11/c.jsonl", modified: 1_800_000_020)
    try tree.write("2026/10/30/d.jsonl", modified: 1_800_000_010)
    try tree.write("2025/12/31/e.jsonl", modified: 1_800_000_005)
    tree.expectSame("first read")

    // The hidden flag hides an entry from a listing without changing its directory.
    for path in ["2026/11/12/a.jsonl", "2026/11/11", "2026/10", "2026"] {
        tree.setHidden(path, true)
        tree.expectSame("\(path) hidden")
        tree.expectSame("\(path) still hidden")
        tree.setHidden(path, false)
        tree.expectSame("\(path) shown again")
    }
    // Hidden before it was ever listed, then shown.
    try tree.write("2026/11/12/f.jsonl", modified: 1_800_000_060)
    tree.setHidden("2026/11/12/f.jsonl", true)
    tree.expectSame("added hidden")
    tree.setHidden("2026/11/12/f.jsonl", false)
    tree.expectSame("shown")

    // A directory that can no longer be listed contributes nothing, and again once it can.
    let day = tree.root.appendingPathComponent("2026/11/12").path
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: day)
    tree.expectSame("day unreadable")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: day)
    tree.expectSame("day readable again")
}

@Test func anUnchangedRolloutTreeIsNotListedAgain() throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.write("2026/11/12/a.jsonl", modified: 1_800_000_000)
    try tree.write("2026/11/11/b.jsonl", modified: 1_800_000_010)
    try tree.write("2026/10/30/c.jsonl", modified: 1_800_000_020)
    func reads() -> Int { RolloutDays.directoryReads(root: tree.root) }

    _ = RolloutDays.newest(root: tree.root, limit: 24, now: settled)
    // The root, one year, two months and three days.
    #expect(reads() == 7)
    for limit in [8, 24, 200, 24] { _ = RolloutDays.newest(root: tree.root, limit: limit, now: settled) }
    #expect(reads() == 7)

    // An append changes the rollout alone: seen without listing anything.
    try tree.write("2026/11/12/a.jsonl", "{}\n{}\n", modified: 1_800_000_100)
    #expect(RolloutDays.newest(root: tree.root, limit: 24, now: settled).first?.url.lastPathComponent == "a.jsonl")
    #expect(reads() == 7)

    // A new rollout changes its day directory, which alone is listed again.
    try tree.write("2026/11/11/d.jsonl", modified: 1_800_000_200)
    #expect(RolloutDays.newest(root: tree.root, limit: 24, now: settled).first?.url.lastPathComponent == "d.jsonl")
    #expect(reads() == 8)
    // A new day changes its month.
    try tree.write("2026/11/13/e.jsonl", modified: 1_800_000_300)
    #expect(RolloutDays.newest(root: tree.root, limit: 24, now: settled).first?.url.lastPathComponent == "e.jsonl")
    #expect(reads() == 10)
    _ = RolloutDays.newest(root: tree.root, limit: 24, now: settled)
    #expect(reads() == 10)
}

@Test func aRolloutTreeThatDisappearsIsNotKept() throws {
    let tree = try Tree()
    try tree.write("2026/11/12/a.jsonl", modified: 1_800_000_000)
    #expect(RolloutDays.newest(root: tree.root, limit: 24, now: settled).count == 1)
    #expect(RolloutDays.keeps(root: tree.root))
    tree.remove()
    #expect(RolloutDays.newest(root: tree.root, limit: 24, now: settled).isEmpty)
    #expect(!RolloutDays.keeps(root: tree.root))
}

private func rolloutLines(session: UUID, turn: UUID) -> String {
    "{\"timestamp\":\"2026-09-14T02:30:01.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session.uuidString.lowercased())\","
        + "\"cwd\":\"/Users/me/project\",\"originator\":\"codex_cli_rs\",\"source\":\"cli\"}}\n"
        + "{\"timestamp\":\"2026-09-14T02:38:36.020Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\","
        + "\"turn_id\":\"\(turn.uuidString.lowercased())\"}}\n"
}

@Test func aRolloutPathThatWasALinkIsReadOnceItIsAFile() throws {
    let tree = try Tree()
    defer { tree.remove() }
    let now = 1_800_000_000.0, turn = UUID()
    let target = try tree.write("elsewhere/target.jsonl", rolloutLines(session: UUID(), turn: turn), modified: now)
    try FileManager.default.createDirectory(at: tree.root.appendingPathComponent("2026/11/12"), withIntermediateDirectories: true)
    let link = tree.root.appendingPathComponent("2026/11/12/rollout.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try tree.setModified("2026/11/12/rollout.jsonl", now)
    // A link is never read, however often it is listed.
    #expect(SessionDiscovery.candidates(root: tree.root, now: now).isEmpty)
    #expect(SessionDiscovery.candidates(root: tree.root, now: now).isEmpty)

    try FileManager.default.removeItem(at: link)
    try tree.write("2026/11/12/rollout.jsonl", rolloutLines(session: UUID(), turn: turn), modified: now)
    #expect(SessionDiscovery.candidates(root: tree.root, now: now).map(\.turn) == [turn])
    // And back: the kept listing does not keep reading through a link.
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try tree.setModified("2026/11/12/rollout.jsonl", now)
    #expect(SessionDiscovery.candidates(root: tree.root, now: now).isEmpty)
}

@Test func discoveryAgeBoundMovesWithNowOverAKeptListing() throws {
    let tree = try Tree()
    defer { tree.remove() }
    let written = 1_800_000_000.5, turn = UUID()
    try tree.write("2026/11/12/rollout.jsonl", rolloutLines(session: UUID(), turn: turn), modified: written)
    func found(_ now: Double) -> [UUID] { SessionDiscovery.candidates(root: tree.root, now: now).map(\.turn) }
    #expect(found(written) == [turn])
    #expect(found(written + SessionDiscovery.maximumAge) == [turn])
    #expect(found(written + SessionDiscovery.maximumAge + 0.001).isEmpty)
    #expect(found(written + SessionDiscovery.maximumAge) == [turn])
}

@Test func equalMarksAreTrustedOnlyOnceTheDirectoryHadBeenQuietWhenTheMarkWasTaken() throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.write("2026/11/12/a.jsonl")
    let day = tree.root.appendingPathComponent("2026/11/12")
    let mark = try #require(RolloutDays.Mark(day))
    let touched = max(mark.modifiedAt, mark.changedAt)
    func kept(markedAt: Double) -> RolloutDays.Listed { RolloutDays.Listed(mark: mark, markedAt: markedAt, visible: [], hidden: []) }
    // The same mark, young and old: a rollout made in the same clock tick as a young mark would not change it.
    #expect(!kept(markedAt: touched).reusable(for: mark))
    #expect(!kept(markedAt: touched + RolloutDays.settleTime - 0.01).reusable(for: mark))
    #expect(kept(markedAt: touched + RolloutDays.settleTime + 0.01).reusable(for: mark))
    #expect(kept(markedAt: touched + 86_400).reusable(for: mark))
    // A clock behind the directory's own times, or no clock at all, is never trusted.
    #expect(!kept(markedAt: touched - 100).reusable(for: mark))
    #expect(!kept(markedAt: .nan).reusable(for: mark))
    #expect(!kept(markedAt: -.infinity).reusable(for: mark))
    // An old mark is still only good for the same mark.
    try tree.write("2026/11/12/b.jsonl")
    #expect(!kept(markedAt: touched + 86_400).reusable(for: try #require(RolloutDays.Mark(day))))
}

@Test func aDirectoryMarkedWhileYoungIsListedAgainUntilItHasBeenQuiet() throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.write("2026/11/12/a.jsonl", modified: 1_800_000_000)
    try tree.write("2026/11/11/b.jsonl", modified: 1_800_000_010)
    func reads() -> Int { RolloutDays.directoryReads(root: tree.root) }
    func names(now: Double) -> [String] { RolloutDays.newest(root: tree.root, limit: 24, now: now).map(\.url.lastPathComponent) }
    // Just made: the root, a year, a month and two days are listed on every call.
    let young = Date().timeIntervalSince1970
    #expect(names(now: young) == ["b.jsonl", "a.jsonl"])
    #expect(reads() == 5)
    #expect(names(now: young + 1) == ["b.jsonl", "a.jsonl"])
    #expect(reads() == 10)
    // A clock that went backwards, or is no clock, lists again too.
    #expect(names(now: young - 1_000) == ["b.jsonl", "a.jsonl"])
    #expect(names(now: .nan) == ["b.jsonl", "a.jsonl"])
    #expect(reads() == 20)
    // Quiet for long enough: the marks kept so far were taken young, so one more listing, then none.
    #expect(names(now: young + 60) == ["b.jsonl", "a.jsonl"])
    #expect(reads() == 25)
    #expect(names(now: young + 62) == ["b.jsonl", "a.jsonl"])
    #expect(names(now: young + 64) == ["b.jsonl", "a.jsonl"])
    #expect(reads() == 25)
    // A new rollout makes its day young again: that day alone is listed until it has been quiet.
    try tree.write("2026/11/12/c.jsonl", modified: 1_800_000_020)
    let added = Date().timeIntervalSince1970
    #expect(names(now: added).first == "c.jsonl")
    #expect(names(now: added + 1).first == "c.jsonl")
    #expect(reads() == 27)
    #expect(names(now: young + 120).first == "c.jsonl")
    #expect(names(now: young + 122).first == "c.jsonl")
    #expect(reads() == 28)
}

@Test func aHiddenRootIsKeptLikeAnyOtherAndALinkedRootListsNothingAsBefore() throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.write("real/2026/11/12/a.jsonl", modified: 1_800_000_000)
    try tree.write("real/2026/11/11/b.jsonl", modified: 1_800_000_010)
    /// The kept listing of `root`, checked against a fresh one.
    func names(_ root: URL, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) -> [String] {
        let kept = RolloutDays.newest(root: root, limit: 24, now: settled), fresh = freshListing(root: root, limit: 24)
        #expect(kept.map(\.url) == fresh.map(\.url), comment, sourceLocation: sourceLocation)
        #expect(kept.map(\.modified) == fresh.map(\.modified), comment, sourceLocation: sourceLocation)
        return kept.map(\.url.lastPathComponent)
    }
    // A hidden root: read, and after the first call without listing anything or walking twice.
    let real = tree.root.appendingPathComponent("real")
    tree.setHidden("real", true)
    #expect(names(real, "hidden root") == ["b.jsonl", "a.jsonl"])
    #expect(RolloutDays.directoryReads(root: real) == 5)
    #expect(names(real, "hidden root, unchanged") == ["b.jsonl", "a.jsonl"])
    #expect(names(real, "hidden root, unchanged again") == ["b.jsonl", "a.jsonl"])
    #expect(RolloutDays.directoryReads(root: real) == 5)

    // A root that is a link was never listed through, and still is not: each call is one failed
    // listing, as it was, and nothing is kept.
    let link = tree.root.appendingPathComponent("sessions")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(names(link, "linked root").isEmpty)
    #expect(names(link, "linked root again").isEmpty)
    #expect(RolloutDays.directoryReads(root: link) == 2)
    #expect(!RolloutDays.keeps(root: link))
}

/// A count several threads add to.
private final class Tally: @unchecked Sendable {
    // Invariant for `@unchecked Sendable`: `total` is only touched while holding `lock`.
    private let lock = NSLock()
    private var total = 0

    func add() { lock.lock(); total += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }
}

@Test func manyReadersOfOneRootAtOnceEachGetWhatAFreshListingGives() throws {
    let tree = try Tree()
    defer { tree.remove() }
    for day in 1...16 {
        for file in 0..<4 { try tree.write(String(format: "2026/11/%02d/r%d.jsonl", day, file), modified: 1_800_000_000 + Double(day * 10 + file)) }
    }
    let expected = Dictionary(uniqueKeysWithValues: [8, 24, 200].map { ($0, freshListing(root: tree.root, limit: $0)) })
    // Readers start cold together, so some walk with nothing kept while others reuse what was just stored.
    let failures = Tally()
    DispatchQueue.concurrentPerform(iterations: 96) { index in
        let limit = [8, 24, 200][index % 3]
        let got = RolloutDays.newest(root: tree.root, limit: limit, now: index % 4 == 0 ? Date().timeIntervalSince1970 : settled)
        let want = expected[limit] ?? []
        if got.map(\.url) != want.map(\.url) || got.map(\.modified) != want.map(\.modified) { failures.add() }
    }
    #expect(failures.count == 0)
    tree.expectSame("after the readers")
}
