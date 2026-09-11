import Foundation

let arguments = CommandLine.arguments
guard let index = arguments.firstIndex(of: "--events-dir"), arguments.indices.contains(index + 1) else {
    exit(0)
}
let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
guard let input = try? FileHandle.standardInput.read(upToCount: 64 * 1024),
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let event = object["hook_event_name"] as? String,
      let session = object["session_id"] as? String else {
    exit(0)
}
var record: [String: Any] = [
    "hook_event_name": event,
    "session_id": session,
    "received_at": String(format: "%.6f", Date().timeIntervalSince1970)
]
if let turn = object["turn_id"] as? String { record["turn_id"] = turn }
guard JSONSerialization.isValidJSONObject(record),
      let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
    exit(0)
}
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let temporary = directory.appendingPathComponent(".steer-" + UUID().uuidString)
let destination = directory.appendingPathComponent(UUID().uuidString + ".json")
do {
    try data.write(to: temporary, options: .atomic)
    try FileManager.default.moveItem(at: temporary, to: destination)
} catch {
    try? FileManager.default.removeItem(at: temporary)
}
