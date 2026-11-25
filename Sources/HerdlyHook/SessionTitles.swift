import Darwin
import Foundation
import HerdlyCore

/// Runs the helper as a detached title generator instead of a hook.
let claudeTitleGeneratorMarker = "--generate-claude-title"

/// The `UserPromptSubmit` output that sets a Haiku-written session title, or nil. Generation runs
/// in a detached helper process, and its title is applied on a later prompt. The one exception is
/// the first prompt after a `/clear` carried over a Herdly title: it waits up to
/// `ClaudeSessionTitles.carriedOverWait` and applies the new title at once when it is ready.
/// Titles are on for every configured folder (#481); any earlier opt-in marker is ignored.
/// Every failure (no `CLAUDE_PID`, unreadable or mismatched registry entry, a record
/// that cannot be saved) leaves the session's name alone.
func claudeSessionTitleOutput(_ object: [String: Any], eventsDirectory: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              now: Double = Date().timeIntervalSince1970) -> Data? {
    guard object["hook_event_name"] as? String == "UserPromptSubmit",
          let sessionID = object["session_id"] as? String,
          let pid = environment["CLAUDE_PID"].flatMap({ Int32($0) }), pid > 0 else { return nil }
    let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    let entry = ClaudeSessionTitles.registryEntryURL(configDirectory: configDirectory, pid: pid)
    let registered = SafeFile.read(entry, limit: ClaudeSessionTitles.maximumRegistryEntrySize)
        .flatMap { ClaudeSessionTitles.registeredName($0, sessionID: sessionID) }
    let record = ClaudeSessionTitles.load(sessionID: sessionID, in: eventsDirectory)
    let carriedOver = record?.status != .applied && registered?.isDerived == false
        && ClaudeSessionTitles.isCarriedOver(registered, sessionID: sessionID, in: eventsDirectory)
    switch ClaudeSessionTitles.action(prompt: object["prompt"] as? String, registered: registered,
                                      record: record, now: now, carriedOver: carriedOver) {
    case .none:
        return nil
    case let .apply(title):
        // Recorded first, so a title is offered once even if Claude ignores it.
        guard let output = ClaudeSessionTitles.hookOutput(title: title),
              ClaudeSessionTitles.save(.init(status: .applied, title: title, attempts: record?.attempts ?? 1,
                                             updatedAt: now),
                                       sessionID: sessionID, in: eventsDirectory) else { return nil }
        return output
    case let .generate(source):
        let attempts = (record?.attempts ?? 0) + 1
        guard ClaudeSessionTitles.save(.init(status: .pending, attempts: attempts, updatedAt: now),
                                       sessionID: sessionID, in: eventsDirectory) else { return nil }
        ClaudeSessionTitles.prune(in: eventsDirectory)
        guard spawnTitleGenerator(source: source, sessionID: sessionID, eventsDirectory: eventsDirectory, claudePID: pid) else {
            ClaudeSessionTitles.save(.init(status: .failed, attempts: attempts, updatedAt: now),
                                     sessionID: sessionID, in: eventsDirectory)
            return nil
        }
        // After a `/clear` the session still shows the previous conversation's title, so this one
        // prompt waits briefly for the new title rather than leaving the stale one for a whole turn.
        // A fresh session's folder placeholder is not misleading, so it never waits.
        guard carriedOver,
              let title = ClaudeSessionTitles.awaitReadyTitle(sessionID: sessionID, in: eventsDirectory),
              let output = ClaudeSessionTitles.hookOutput(title: title),
              ClaudeSessionTitles.save(.init(status: .applied, title: title, attempts: attempts,
                                             updatedAt: Date().timeIntervalSince1970),
                                       sessionID: sessionID, in: eventsDirectory) else { return nil }
        return output
    }
}

/// The running Claude executable, so the model call uses the same install and login as the session.
private func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Starts this helper in generator mode in its own session with only stdin (the prompt, through
/// a pipe) and /dev/null for output, so Claude's wait for the hook's output ends when the hook
/// exits rather than when the model replies.
private func spawnTitleGenerator(source: String, sessionID: String, eventsDirectory: URL, claudePID: Int32) -> Bool {
    guard let claude = executablePath(of: claudePID), let helper = Bundle.main.executablePath else { return false }
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { return false }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, descriptors[0], 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // CLOEXEC_DEFAULT keeps Claude's hook output pipe out of the generator.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    let argv = [helper, claudeTitleGeneratorMarker, "--events-dir", eventsDirectory.path,
                "--session-id", sessionID, "--claude", claude]
    var cArguments = argv.map { strdup($0) } + [nil]
    defer { cArguments.forEach { free($0) } }
    var child: pid_t = 0
    let spawned = posix_spawn(&child, helper, &actions, &attributes, &cArguments, environ)
    close(descriptors[0])
    guard spawned == 0 else {
        close(descriptors[1])
        return false
    }
    signal(SIGPIPE, SIG_IGN)
    let bytes = Array(source.utf8)
    let written = bytes.withUnsafeBytes { buffer in
        buffer.baseAddress.map { base in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptors[1], base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count } else if count < 0, errno == EINTR { continue } else { return false }
            }
            return true
        } ?? true
    }
    close(descriptors[1])
    return written
}

/// Generator mode: asks Haiku for a title and records it as ready, or records a failure. Writes
/// only while the session's record is still pending, so a stale generator cannot replace a newer
/// outcome.
func runClaudeTitleGenerator(_ arguments: [String]) -> Never {
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    guard let eventsPath = value(after: "--events-dir"), let sessionID = value(after: "--session-id"),
          let claude = value(after: "--claude") else { exit(0) }
    let eventsDirectory = URL(fileURLWithPath: eventsPath, isDirectory: true)
    let limit = ClaudeSessionTitles.maximumSourceLength * 4
    let source = (try? FileHandle.standardInput.read(upToCount: limit)).flatMap { String(data: $0, encoding: .utf8) }
    let title = source.flatMap { generateTitle(source: $0, claude: claude, workingDirectory: ClaudeSessionTitles.directory(in: eventsDirectory)) }
    if let record = ClaudeSessionTitles.load(sessionID: sessionID, in: eventsDirectory), record.status == .pending {
        ClaudeSessionTitles.save(.init(status: title == nil ? .failed : .ready, title: title, attempts: record.attempts,
                                       updatedAt: Date().timeIntervalSince1970),
                                 sessionID: sessionID, in: eventsDirectory)
    }
    exit(0)
}

private func generateTitle(source: String, claude: String, workingDirectory: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claude)
    process.arguments = ClaudeSessionTitles.generationArguments
    process.environment = ClaudeSessionTitles.generationEnvironment(ProcessInfo.processInfo.environment)
    process.currentDirectoryURL = workingDirectory
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return nil }
    let reply = OutputCollector()
    let readerDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        reply.set((try? output.fileHandleForReading.read(upToCount: 4 * 1024)) ?? nil)
        readerDone.signal()
    }
    try? input.fileHandleForWriting.write(contentsOf: Data(ClaudeSessionTitles.generationInput(source: source).utf8))
    try? input.fileHandleForWriting.close()
    if finished.wait(timeout: .now() + ClaudeSessionTitles.generationTimeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        return nil
    }
    guard process.terminationStatus == 0, readerDone.wait(timeout: .now() + 2) == .success,
          let data = reply.value, let text = String(data: data, encoding: .utf8) else { return nil }
    return ClaudeSessionTitles.sanitizedTitle(text)
}

/// Holds the reader thread's result for the waiting thread; the semaphore orders the accesses.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func set(_ value: Data?) { lock.withLock { data = value } }
    var value: Data? { lock.withLock { data } }
}
