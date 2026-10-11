// Prints the on-screen windows of one app (by bundle id) as JSON, front to back:
//   swift onscreen_windows.swift com.apple.Terminal
// Window numbers are CGWindowIDs. "name" is present only when the calling process has Screen
// Recording permission; the labs use it only to check which window is in front, never as a
// Steer identity source.
import AppKit
import CoreGraphics

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.apple.Terminal"
let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { $0.processIdentifier })
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let rows: [[String: Any]] = info.compactMap { window in
    guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid) else { return nil }
    var row: [String: Any] = ["id": window[kCGWindowNumber as String] as? Int ?? -1,
                              "layer": window[kCGWindowLayer as String] as? Int ?? -1,
                              "bounds": window[kCGWindowBounds as String] ?? [:]]
    if let name = window[kCGWindowName as String] as? String { row["name"] = name }
    return row
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
