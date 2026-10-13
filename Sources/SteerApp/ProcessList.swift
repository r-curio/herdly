import Foundation

/// The running processes' ids and command lines, for `CodexCLIProcesses`. Process identity only: no
/// environment, open files, or window contents are read.
enum ProcessList {
    static let limit = 4 * 1024 * 1024

    /// `ps -axo pid=,args=` output, or nil when ps did not exit within two seconds or wrote too much.
    /// The pipe is drained on a background queue so a listing larger than the pipe buffer cannot
    /// stall ps, and the deadline applies to ps itself.
    static func listing() -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,args="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        final class Box: @unchecked Sendable { var bytes: Data? }
        let box = Box()
        DispatchQueue.global(qos: .utility).async {
            box.bytes = try? output.fileHandleForReading.read(upToCount: limit + 1)
            drained.signal()
        }
        guard exited.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0,
              let bytes = box.bytes, bytes.count <= limit else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
