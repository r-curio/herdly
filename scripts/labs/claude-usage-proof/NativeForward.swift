// THROWAWAY PROTOTYPE: proves native status-line capture and forwarding behavior.
import Darwin
import Foundation

let data = FileHandle.standardInput.readDataToEndOfFile()
let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("snapshots")

if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let limits = payload["rate_limits"] as? [String: Any]
    let windows = ["five_hour", "seven_day", "spend_limit"].reduce(into: [String: Any]()) { result, name in
        guard let value = limits?[name] as? [String: Any] else { return }
        result[name] = [
            "keys": value.keys.sorted(),
            "used_percentage": value["used_percentage"] as Any,
            "resets_at": value["resets_at"] as Any,
        ]
    }
    let sanitized: [String: Any] = [
        "observed_at": Date().timeIntervalSince1970,
        "top_level_keys": payload.keys.sorted(),
        "version": payload["version"] as Any,
        "prompt_id_present": payload["prompt_id"] != nil,
        "rate_limits_present": payload["rate_limits"] != nil,
        "rate_limits": windows,
    ]
    if let output = try? JSONSerialization.data(withJSONObject: sanitized) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let name = "\(DispatchTime.now().uptimeNanoseconds)-\(getpid()).json"
        try? output.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
    }
}

var template = Array("/tmp/steer-claude-status.XXXXXX\0".utf8CString)
let descriptor = mkstemp(&template)
guard descriptor >= 0 else { exit(70) }
_ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
_ = lseek(descriptor, 0, SEEK_SET)
_ = unlink(template)
_ = dup2(descriptor, STDIN_FILENO)

guard CommandLine.arguments.count == 2 else { exit(64) }
var arguments: [UnsafeMutablePointer<CChar>?] = [
    strdup("sh"),
    strdup("-c"),
    strdup(CommandLine.arguments[1]),
    nil,
]
execv("/bin/sh", &arguments)
exit(71)
