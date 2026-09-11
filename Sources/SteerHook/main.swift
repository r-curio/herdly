import Foundation

let arguments = CommandLine.arguments

func writeEvent(_ object: [String: Any], to directory: URL) -> Bool {
    guard let event = object["hook_event_name"] as? String, !event.isEmpty,
          let session = object["session_id"] as? String, UUID(uuidString: session) != nil else { return false }
    var record: [String: Any] = [
        "hook_event_name": event,
        "session_id": session,
        "received_at": Date().timeIntervalSince1970
    ]
    if let turn = object["turn_id"] as? String { record["turn_id"] = turn }
    guard JSONSerialization.isValidJSONObject(record),
          let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return false }
    let temporary = directory.appendingPathComponent(".steer-" + UUID().uuidString)
    let destination = directory.appendingPathComponent(UUID().uuidString + ".json")
    do {
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return true
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        return false
    }
}

func selfTest() -> Int32 {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-hook-self-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let object: [String: Any] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString]
    guard writeEvent(object, to: directory),
          let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
          files.count == 1,
          let data = try? Data(contentsOf: files[0]),
          let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          result["received_at"] as? NSNumber != nil else { return 1 }
    return 0
}

if arguments.contains("--self-test") {
    exit(selfTest())
}

guard let index = arguments.firstIndex(of: "--events-dir"), arguments.indices.contains(index + 1) else {
    exit(0)
}
let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
guard let input = try? FileHandle.standardInput.read(upToCount: 64 * 1024),
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
    exit(0)
}
_ = writeEvent(object, to: directory)
