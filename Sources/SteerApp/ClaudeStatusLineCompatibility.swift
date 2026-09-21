import Darwin
import Foundation
import SteerCore

/// Runs the bounded status-line compatibility probe at the integration boundary. Core owns the
/// result and setup policy; only the app target may launch shells and inspect process groups.
enum ClaudeStatusLineCompatibility {
    static let failureMessage = ClaudeUsageSetupStatus.compatibilityFailureMessage
    static let maximumProcessListBytes = 64 * 1024
    static let maximumProcessListRecords = 4096

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
        stdout.fileHandleForWriting.closeFile()
        let inputForwarded = writeProbeInput(input, to: stdin.fileHandleForWriting.fileDescriptor)
        stdin.fileHandleForWriting.closeFile()
        guard inputForwarded else {
            terminateAndReap(process: process, groupOwned: processGroupOwned)
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        guard wait(for: process, until: deadline) else {
            terminateAndReap(process: process, groupOwned: processGroupOwned)
            return false
        }
        if processGroupOwned, processGroupExists(process.processIdentifier) {
            _ = terminateProcessGroup(process.processIdentifier)
            return false
        }
        guard let remaining = descendants(of: process.processIdentifier) else { return false }
        guard remaining.isEmpty else {
            _ = terminateProcesses(remaining)
            return false
        }
        var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor,
                                events: Int16(POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 200) > 0, descriptor.revents & Int16(POLLHUP) != 0 else {
            return false
        }
        return true
    }

    private static func writeProbeInput(_ input: Data, to descriptor: Int32) -> Bool {
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { return false }
        var offset = 0
        while offset < input.count {
            let count = input.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return -1 }
                return write(descriptor, base.advanced(by: offset), input.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private static func wait(for process: Process, until deadline: Date) -> Bool {
        while process.isRunning {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
        return true
    }

    private static func terminateAndReap(process: Process, groupOwned: Bool) {
        let childProcesses: [pid_t]
        if groupOwned {
            childProcesses = []
            _ = kill(-process.processIdentifier, SIGTERM)
        } else if let found = descendants(of: process.processIdentifier) {
            childProcesses = found
            _ = terminateProcesses(found)
            process.terminate()
        } else {
            childProcesses = []
            process.terminate()
        }
        let graceDeadline = Date().addingTimeInterval(0.1)
        let processStopped = wait(for: process, until: graceDeadline)
        if groupOwned {
            guard processStopped && waitForProcessGroup(process.processIdentifier, until: graceDeadline) else {
                _ = kill(-process.processIdentifier, SIGKILL)
                _ = wait(for: process, until: Date().addingTimeInterval(0.2))
                _ = waitForProcessGroup(process.processIdentifier, until: Date().addingTimeInterval(0.2))
                return
            }
            return
        }
        if processStopped && childProcesses.isEmpty { return }
        _ = kill(process.processIdentifier, SIGKILL)
        _ = terminateProcesses(childProcesses, signal: SIGKILL)
        _ = wait(for: process, until: Date().addingTimeInterval(0.2))
    }

    @discardableResult
    private static func terminateProcesses(_ processes: [pid_t], signal: Int32 = SIGTERM) -> Bool {
        var succeeded = true
        for process in processes where kill(process, signal) != 0 && errno != ESRCH {
            succeeded = false
        }
        return succeeded
    }

    @discardableResult
    private static func terminateProcessGroup(_ processGroup: pid_t) -> Bool {
        _ = kill(-processGroup, SIGTERM)
        guard !waitForProcessGroup(processGroup, until: Date().addingTimeInterval(0.05)) else {
            return true
        }
        _ = kill(-processGroup, SIGKILL)
        return waitForProcessGroup(processGroup, until: Date().addingTimeInterval(0.1))
    }

    private static func waitForProcessGroup(_ processGroup: pid_t, until deadline: Date) -> Bool {
        while processGroupExists(processGroup) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
        return true
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        kill(-processGroup, 0) == 0 || errno == EPERM
    }

    private static func descendants(of root: pid_t) -> [pid_t]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        output.fileHandleForWriting.closeFile()
        guard wait(for: process, until: Date().addingTimeInterval(0.25)) else {
            terminateAndReapProcess(process)
            return nil
        }
        guard let data = boundedOutput(from: output, limit: maximumProcessListBytes) else { return nil }
        return parseProcessList(data, root: root)
    }

    private static func terminateAndReapProcess(_ process: Process) {
        process.terminate()
        guard !wait(for: process, until: Date().addingTimeInterval(0.05)) else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        _ = wait(for: process, until: Date().addingTimeInterval(0.1))
    }

    private static func boundedOutput(from output: Pipe, limit: Int) -> Data? {
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        var data = Data()
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline {
            switch readAvailable(descriptor, into: &data, limit: limit) {
            case .end:
                return data
            case .overLimit, .failed:
                return nil
            case .wouldBlock:
                var descriptorState = pollfd(fd: descriptor,
                                             events: Int16(POLLIN | POLLHUP), revents: 0)
                let remaining = max(1, Int32(min(0.01, deadline.timeIntervalSinceNow) * 1_000))
                if poll(&descriptorState, 1, remaining) < 0 && errno != EINTR { return nil }
            }
        }
        return nil
    }

    private enum ReadResult {
        case end
        case wouldBlock
        case overLimit
        case failed
    }

    private static func readAvailable(_ descriptor: Int32, into data: inout Data,
                                      limit: Int) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: min(4096, limit + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                if data.count > limit { return .overLimit }
                continue
            }
            if count == 0 { return .end }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            if errno == EINTR { continue }
            return .failed
        }
    }

    static func parseProcessList(_ data: Data, root: pid_t) -> [pid_t]? {
        guard data.count <= maximumProcessListBytes,
              let string = String(data: data, encoding: .utf8) else { return nil }
        var children: [pid_t: [pid_t]] = [:]
        var recordCount = 0
        for line in string.split(separator: "\n") {
            recordCount += 1
            guard recordCount <= maximumProcessListRecords else { return nil }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else {
                continue
            }
            children[parent, default: []].append(pid)
        }
        var pending = children[root] ?? []
        var result: [pid_t] = []
        while let pid = pending.popLast() {
            result.append(pid)
            guard result.count <= maximumProcessListRecords else { return nil }
            pending.append(contentsOf: children[pid] ?? [])
        }
        return result
    }
}
