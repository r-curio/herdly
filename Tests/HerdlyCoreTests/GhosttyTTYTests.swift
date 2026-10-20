import Foundation
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/ghostty", isDirectory: true)

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

private func inventory(_ key: String) throws -> GhosttySnapshot {
    let all = try #require(JSONSerialization.jsonObject(with: fixture("tty-inventories.json")) as? [String: Any])
    let entry = try #require(all[key])
    return try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject: entry))
}

private func dictionary(terminalProperties: String, classCode: String = "Gtrm") -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <dictionary title="Ghostty Scripting Dictionary"><suite name="Ghostty Suite" code="Ghst">
    <class name="terminal" code="\(classCode)" plural="terminals">\(terminalProperties)</class>
    </suite></dictionary>
    """.utf8)
}

@Test func ghostty131DictionaryDoesNotDeclareTTY() throws {
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: try fixture("Ghostty-1.3.1.sdef")) == .unsupported)
}

@Test func ghosttyTipDictionaryDeclaresTTY() throws {
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: try fixture("Ghostty-tip.sdef")) == .supported)
}

@Test func ttySupportRequiresTerminalClassTextPropertyCodeAndWellFormedXML() throws {
    let tty = #"<property name="tty" code="Gtty" type="text" access="r"/>"#
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: dictionary(terminalProperties: tty)) == .supported)
    // The code, not the name, decides; the property must sit directly on class Gtrm and be text.
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: dictionary(terminalProperties:
        #"<property name="tty" code="Gpid" type="text"/>"#)) == .unsupported)
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: dictionary(terminalProperties:
        #"<property name="device" code="Gtty" type="text"/>"#)) == .supported)
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: dictionary(terminalProperties:
        #"<property name="tty" code="Gtty" type="integer"/>"#)) == .unsupported)
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: dictionary(terminalProperties: tty, classCode: "Gtab")) == .unsupported)
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: dictionary(terminalProperties:
        #"<element type="x">\#(tty)</element>"#)) == .unsupported)
    // Missing, empty, truncated, oversized or non-XML dictionaries are unsupported.
    let whole = try fixture("Ghostty-tip.sdef")
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: nil) == .unsupported)
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: Data()) == .unsupported)
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: whole.prefix(whole.count / 2 + 200)) == .unsupported)
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: Data("not xml".utf8)) == .unsupported)
    var oversized = whole
    oversized.append(Data(repeating: 0x20, count: GhosttyScriptingDictionary.maximumFileSize))
    #expect(GhosttyScriptingDictionary.ttySupport(dictionary: oversized) == .unsupported)
}

@Test func scriptingDefinitionNameMustBeAPlainResourceFileName() throws {
    func plist(_ value: Any?) throws -> Data {
        var object: [String: Any] = ["CFBundleIdentifier": "com.mitchellh.ghostty"]
        if let value { object["OSAScriptingDefinition"] = value }
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
    #expect(GhosttyScriptingDictionary.definitionName(infoPlist: try plist("Ghostty.sdef")) == "Ghostty.sdef")
    let invalid: [Any?] = [nil, "", ".", "..", "../Ghostty.sdef", "/etc/Ghostty.sdef", 3]
    for value in invalid {
        #expect(GhosttyScriptingDictionary.definitionName(infoPlist: try plist(value)) == nil)
    }
    #expect(GhosttyScriptingDictionary.definitionName(infoPlist: Data("garbage".utf8)) == nil)
}

@Test func ttyNormalizationAcceptsOnlyTTYDevicePaths() {
    #expect(GhosttyTTYMatch.normalizedTTY("/dev/ttys012") == "/dev/ttys012")
    #expect(GhosttyTTYMatch.normalizedTTY("ttys012") == "/dev/ttys012")
    for value in ["", "/dev/ttys", "/dev/tty012", "/dev/ttys01a", "/dev/console", "/tmp/ttys012", " /dev/ttys012", "/dev/ttys\u{0663}"] {
        #expect(GhosttyTTYMatch.normalizedTTY(value) == nil)
    }
}

@Test func ttyJoinMatchesTheSingleUnsplitTerminalInTheCurrentWindow() throws {
    let snapshot = try inventory("matched")
    let target = GhosttyTarget(window_id: "w1", tab_id: "t1", terminal_id: "p1")
    #expect(GhosttyTTYMatch.join(clientTTY: "/dev/ttys012", support: .supported, snapshot: snapshot) == .matched(target))
    #expect(GhosttyTTYMatch.join(clientTTY: "ttys012", support: .supported, snapshot: snapshot) == .matched(target))
    // Titles are identical across herdr clients; only the TTY tells them apart.
    #expect(GhosttyTTYMatch.join(clientTTY: "/dev/ttys013", support: .supported, snapshot: snapshot)
        == .matched(GhosttyTarget(window_id: "w1", tab_id: "t2", terminal_id: "p2")))
}

@Test func ttyJoinReportsEachUnavailableReason() throws {
    func join(_ key: String, client: String = "/dev/ttys012", support: GhosttyTTYSupport = .supported) throws -> GhosttyTTYJoin {
        GhosttyTTYMatch.join(clientTTY: client, support: support, snapshot: try inventory(key))
    }
    #expect(try join("matched", support: .unsupported) == .ttyUnsupported)
    #expect(try join("1.3.1") == .ttyUnsupported)
    #expect(try join("1.3.1", support: .unsupported) == .ttyUnsupported)
    #expect(try join("inventoryUnavailable") == .inventoryUnavailable)
    #expect(try join("matched", client: "") == .invalidClientTTY)
    #expect(try join("matched", client: "/dev/console") == .invalidClientTTY)
    #expect(try join("noMatch") == .noMatch)
    #expect(try join("emptyValue") == .emptyValue)
    #expect(try join("multipleMatches") == .multipleMatches)
    #expect(try join("split") == .split)
    #expect(try join("otherWindow") == .otherWindow)
}

@Test func ttyJoinRejectsIncompleteOrWindowlessInventories() throws {
    let failed = try JSONDecoder().decode(GhosttySnapshot.self, from: Data(#"{"status":"unavailable","windows":[]}"#.utf8))
    #expect(GhosttyTTYMatch.join(clientTTY: "/dev/ttys012", support: .supported, snapshot: failed) == .inventoryUnavailable)
    let noFront = try JSONDecoder().decode(GhosttySnapshot.self, from: Data(#"""
        {"status":"ok","windows":[{"id":"w1","tabs":[{"id":"t1","terminals":[{"id":"p1","name":"herdr","tty":"/dev/ttys012"}]}]}]}
        """#.utf8))
    #expect(GhosttyTTYMatch.join(clientTTY: "/dev/ttys012", support: .supported, snapshot: noFront) == .otherWindow)
}

@Test func inventoriesWithoutTTYKeepTheirExistingTitleMatching() throws {
    // A 1.3.1 inventory decodes as before, and title targeting is unaffected by the new field.
    let snapshot = try inventory("1.3.1")
    #expect(snapshot.terminalNames == ["herdr"])
    #expect(GhosttyMatch.target(title: "herdr", live: ["herdr"], snapshot: snapshot)
        == GhosttyTarget(window_id: "w1", tab_id: "t1", terminal_id: "p1"))
}

@Test func bundleFeatureCheckReadsTheDictionaryNamedByInfoPlist() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func bundle(_ name: String, definition: String?, dictionary: String?) throws -> URL {
        let app = root.appendingPathComponent(name + ".app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.mitchellh.ghostty"]
        if let definition { info["OSAScriptingDefinition"] = definition }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let dictionary { try fixture(dictionary).write(to: resources.appendingPathComponent("Ghostty.sdef")) }
        return app
    }
    #expect(GhosttyScriptingSupport.ttySupport(bundle: try bundle("tip", definition: "Ghostty.sdef", dictionary: "Ghostty-tip.sdef")) == .supported)
    #expect(GhosttyScriptingSupport.ttySupport(bundle: try bundle("old", definition: "Ghostty.sdef", dictionary: "Ghostty-1.3.1.sdef")) == .unsupported)
    #expect(GhosttyScriptingSupport.ttySupport(bundle: try bundle("nokey", definition: nil, dictionary: "Ghostty-tip.sdef")) == .unsupported)
    #expect(GhosttyScriptingSupport.ttySupport(bundle: try bundle("nofile", definition: "Ghostty.sdef", dictionary: nil)) == .unsupported)
    #expect(GhosttyScriptingSupport.ttySupport(bundle: try bundle("escape", definition: "../Resources/Ghostty.sdef", dictionary: "Ghostty-tip.sdef")) == .unsupported)
    #expect(GhosttyScriptingSupport.ttySupport(bundle: root.appendingPathComponent("missing.app")) == .unsupported)
    #expect(GhosttyScriptingSupport.ttySupport(bundle: nil) == .unsupported)
}

// MARK: - Sole-terminal rule (Ghostty without `tty`)

private func soleInventory(windows: [[String: Any]], front: String? = "w1", surfaces: [String]?) throws -> GhosttySnapshot {
    var object: [String: Any] = ["status": "ok", "windows": windows]
    if let front { object["front_window_id"] = front }
    var snapshot = try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    snapshot.surface_ttys = surfaces
    return snapshot
}

private func window(_ id: String, tabs: [[String]]) -> [String: Any] {
    ["id": id, "tabs": tabs.enumerated().map { index, terminals in
        ["id": "\(id)-t\(index)", "terminals": terminals.map { ["id": $0, "name": "herdr"] }] as [String: Any]
    }]
}

@Test func soleTerminalJoinNeedsOneSurfaceByProcessAndByScripting() throws {
    let one = [window("w1", tabs: [["p1"]])]
    func join(_ snapshot: GhosttySnapshot, client: String = "ttys014") -> GhosttyTTYJoin {
        GhosttyTTYMatch.join(clientTTY: client, support: .unsupported, snapshot: snapshot)
    }
    let matched = GhosttyTTYJoin.matched(GhosttyTarget(window_id: "w1", tab_id: "w1-t0", terminal_id: "p1"))
    #expect(join(try soleInventory(windows: one, surfaces: ["/dev/ttys014"])) == matched)
    #expect(join(try soleInventory(windows: one, surfaces: ["ttys014"]), client: "/dev/ttys014") == matched)

    // Surfaces unread, none, several (including a quick terminal scripting omits), or not the client's.
    #expect(join(try soleInventory(windows: one, surfaces: nil)) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: one, surfaces: [])) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: one, surfaces: ["/dev/ttys014", "/dev/ttys020"])) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: one, surfaces: ["/dev/ttys014", "/dev/ttys014"])) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: one, surfaces: ["/dev/ttys020"])) == .noMatch)
    #expect(join(try soleInventory(windows: one, surfaces: [""])) == .emptyValue)
    #expect(join(try soleInventory(windows: one, surfaces: ["/dev/ttys014"]), client: "console") == .invalidClientTTY)

    // Scripting must agree: exactly one terminal, unsplit, in the front window.
    #expect(join(try soleInventory(windows: [window("w1", tabs: [["p1"], ["p2"]])], surfaces: ["/dev/ttys014"])) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: [window("w1", tabs: [["p1"]]), window("w2", tabs: [["p2"]])],
                                   surfaces: ["/dev/ttys014"])) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: [window("w1", tabs: [])], surfaces: ["/dev/ttys014"])) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: [window("w1", tabs: [["p1", "p2"]])], surfaces: ["/dev/ttys014"])) == .ttyUnsupported)
    #expect(join(try soleInventory(windows: one, front: "w9", surfaces: ["/dev/ttys014"])) == .otherWindow)
    #expect(join(try soleInventory(windows: one, front: nil, surfaces: ["/dev/ttys014"])) == .otherWindow)
    #expect(join(try soleInventory(windows: [window("", tabs: [["p1"]])], surfaces: ["/dev/ttys014"])) == .inventoryUnavailable)
}

@Test func soleTerminalJoinIsNeverUsedWithTTYSupport() throws {
    // A Ghostty with `tty` keeps the exact join, whatever `surface_ttys` says.
    let snapshot = try soleInventory(windows: [window("w1", tabs: [["p1"]])], surfaces: ["/dev/ttys014"])
    #expect(GhosttyTTYMatch.join(clientTTY: "ttys014", support: .supported, snapshot: snapshot) == .ttyUnsupported)
}
