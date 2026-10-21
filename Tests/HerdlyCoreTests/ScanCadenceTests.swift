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
