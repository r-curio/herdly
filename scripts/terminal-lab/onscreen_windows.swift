// Prints the on-screen windows of one app (by bundle id) as JSON, front to back:
//   swift onscreen_windows.swift com.apple.Terminal
// Window numbers are CGWindowIDs. Reading window titles would need Screen Recording permission,
// so only ids, layers and bounds are printed.
import AppKit
import CoreGraphics

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.apple.Terminal"
let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { $0.processIdentifier })
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let rows: [[String: Any]] = info.compactMap { window in
    guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid) else { return nil }
    return ["id": window[kCGWindowNumber as String] as? Int ?? -1,
            "layer": window[kCGWindowLayer as String] as? Int ?? -1,
            "bounds": window[kCGWindowBounds as String] ?? [:]]
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
