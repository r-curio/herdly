import Darwin
import Foundation
import SteerCore

/// Runs the bounded status-line compatibility probe at the integration boundary. Core owns the
/// result and setup policy; only the app target may launch shells and inspect process groups.
enum ClaudeStatusLineCompatibility {
    static let failureMessage = ClaudeUsageSetupStatus.compatibilityFailureMessage

    static func probe(command: String, timeout: TimeInterval = 0.75) -> Bool {
        let input = Data("{\"session_id\":\"probe\",\"rate_limits\":null}\n\u{1b}[32mprobe\u{1b}[0m\n".utf8)
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        // Process launches in its own group on the supported macOS runtime. Keep the check
        // explicit so a future launch implementation cannot accidentally signal Steer's group.
        let processGroupOwned = getpgid(process.processIdentifier) == process.processIdentifier
        stdin.fileHandleForWriting.write(input)
        stdin.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            terminate(process: process, groupOwned: processGroupOwned)
            let cancellationDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < cancellationDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if processGroupOwned {
                _ = kill(-process.processIdentifier, SIGKILL)
            } else {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                for pid in descendants(of: process.processIdentifier) { _ = kill(pid, SIGKILL) }
            }
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        if processGroupOwned, kill(-process.processIdentifier, 0) == 0 {
            _ = kill(-process.processIdentifier, SIGTERM)
            Thread.sleep(forTimeInterval: 0.05)
            _ = kill(-process.processIdentifier, SIGKILL)
            return false
        }
        let remaining = descendants(of: process.processIdentifier)
        guard remaining.isEmpty else {
            for pid in remaining { _ = kill(pid, SIGTERM) }
            Thread.sleep(forTimeInterval: 0.05)
            for pid in remaining { _ = kill(pid, SIGKILL) }
            return false
        }
        var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 200) > 0, descriptor.revents & Int16(POLLHUP) != 0 else { return false }
        return true
    }

    private static func terminate(process: Process, groupOwned: Bool) {
        if groupOwned {
            _ = kill(-process.processIdentifier, SIGTERM)
            return
        }
        for pid in descendants(of: process.processIdentifier) { _ = kill(pid, SIGTERM) }
        process.terminate()
    }

    private static func descendants(of root: pid_t) -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for line in string.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
            children[parent, default: []].append(pid)
        }
        var pending = children[root] ?? []
        var result: [pid_t] = []
        while let pid = pending.popLast() {
            result.append(pid)
            pending.append(contentsOf: children[pid] ?? [])
        }
        return result
    }
}
