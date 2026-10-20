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
