import Foundation
import Testing

private let ghosttyScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/HerdlyApp/Resources/Ghostty.js")

// The smoke test never runs the bundled JXA script, so a syntax error would only surface as every
// Ghostty request failing at runtime. Compiling it catches that without sending any Apple Events.
@Test func bundledGhosttyScriptCompiles() throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("ghostty-\(UUID().uuidString).scpt")
    defer { try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
    process.arguments = ["-l", "JavaScript", "-o", output.path, ghosttyScript.path]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(message)")
}
