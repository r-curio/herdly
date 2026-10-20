import Foundation
import Testing
@testable import HerdlyCore

private func rolloutRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-rollout-tree-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("2026/10/20"), withIntermediateDirectories: true)
    return root
}

private func names(_ root: URL) -> [String]? {
    RolloutTree.index(root)?.files.map(\.url.lastPathComponent)
}

/// The walk as `ReminderReader.scan` first did it, kept as the reference for the cached index.
private func referenceNames(_ root: URL) -> [String] {
    var result: [String] = []
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    while let url = enumerator.nextObject() as? URL { if url.pathExtension == "jsonl" { result.append(url.lastPathComponent) } }
    return result
}

@Test func anUnchangedRolloutTreeIsReusedAndEveryKindOfChangeIsSeen() throws {
    let root = try rolloutRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("2026/10/20")
    try Data().write(to: day.appendingPathComponent("rollout-a.jsonl"))
    #expect(names(root) == ["rollout-a.jsonl"])
    #expect(names(root) == referenceNames(root))

    // An append changes the file, not its directory: the listing is unchanged either way.
    let handle = try FileHandle(forWritingTo: day.appendingPathComponent("rollout-a.jsonl"))
    try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
    #expect(names(root) == referenceNames(root))

    try Data().write(to: day.appendingPathComponent("rollout-b.jsonl"))
    #expect(Set(names(root) ?? []) == ["rollout-a.jsonl", "rollout-b.jsonl"])
    #expect(names(root) == referenceNames(root))

    // A new day directory two levels down changes only its parent's stamp.
    let next = root.appendingPathComponent("2026/10/21")
    try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
    #expect(names(root) == referenceNames(root))
    try Data().write(to: next.appendingPathComponent("rollout-c.jsonl"))
    #expect(names(root)?.contains("rollout-c.jsonl") == true)
    #expect(names(root) == referenceNames(root))

    try FileManager.default.removeItem(at: day.appendingPathComponent("rollout-a.jsonl"))
    #expect(names(root)?.contains("rollout-a.jsonl") == false)
    #expect(names(root) == referenceNames(root))
}

@Test func hiddenEntriesAreSkippedAndADirectoryNamedLikeARolloutIsStillWatched() throws {
    let root = try rolloutRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent(".hidden.jsonl"))
    let odd = root.appendingPathComponent("2026/odd.jsonl")
    try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
    #expect(names(root) == referenceNames(root))
    try Data().write(to: odd.appendingPathComponent("inside.jsonl"))
    #expect(names(root)?.contains("inside.jsonl") == true)
    #expect(names(root) == referenceNames(root))
}

@Test func aMissingRolloutRootHasNoFiles() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-missing-" + UUID().uuidString)
    #expect(RolloutTree.index(root)?.files.isEmpty ?? true)
}
