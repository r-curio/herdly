import Darwin
import Foundation
import SteerCore

/// A second JSON-RPC client on Codex's local app-server daemon socket, used for one thing: to
/// receive `item/tool/requestUserInput` for the user's running threads and write back the answer
/// the user gave in the notch (see `AppServerQuestions.swift`). Newline-delimited JSON-RPC 2.0,
/// the bytes `codex app-server proxy` relays to the same socket.
///
/// The client connects only to a socket owned by this user and private to them, identifies itself
/// as Steer, and subscribes (`thread/resume`) only to threads `thread/loaded/list` reports, so it
/// never loads a thread from disk into the daemon. It starts, stops and configures nothing; when
/// there is no socket there is no daemon path and the notch falls back to Ghostty or Codex itself.
/// No proof yet exists on the installed CLI that a running daemon behaves this way; see
/// `docs/user-input-requests.md`.
@MainActor
final class AppServerDaemonClient {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    nonisolated static let defaultSocketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/app-server-control/app-server-control.sock").path
    /// Seconds between checks for a socket while there is no connection.
    static let retryInterval: Double = 5
    /// Seconds between `thread/loaded/list` polls while connected, to subscribe to new threads.
    static let threadPollInterval: Double = 5
    static let maximumLine = 4 * 1024 * 1024
    /// Seconds the handshake may take before the connection is dropped and retried.
    static let handshakeTimeout: Double = 10
    /// Seconds a write may wait for the socket to drain; on the main actor, so short.
    static let writeTimeout: Double = 0.5

    let socketPath: String
    private(set) var state: State = .idle
    private(set) var problem: AppServerSocketCheck.Problem?
    private(set) var subscribed: Set<String> = []
    /// Every notification and server request the daemon sends, in order; responses to Steer's own
    /// requests are handled here and not forwarded.
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var buffer = Data()
    private var nextID = 1
    private var handlers: [Int: ([String: Any]?, [String: Any]?) -> Void] = [:]
    private var nextRetry: Double = 0
    private var nextThreadPoll: Double = 0
    private var connectingSince: Double = 0

    init(socketPath: String = AppServerDaemonClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    var isConnected: Bool { state == .ready }

    /// One sentence for the controls window.
    var statusText: String {
        switch state {
        case .ready: return "Codex daemon: connected; \(subscribed.count) thread\(subscribed.count == 1 ? "" : "s") subscribed."
        case .connecting: return "Codex daemon: connecting…"
        case .failed(let reason): return "Codex daemon: \(reason)"
        case .idle:
            switch problem {
            case nil, .missing?: return "Codex daemon: not running (no socket at \(socketPath))."
            case .notASocket?: return "Codex daemon: refusing \(socketPath); it is not a socket."
            case .notOwnedByUser?: return "Codex daemon: refusing \(socketPath); it is not owned by you."
            case .sharedPermissions?: return "Codex daemon: refusing \(socketPath); it is readable by other users."
            }
        }
    }

    /// Called every refresh: connects when a private socket appears, polls loaded threads while connected.
    func tick(now: Double) {
        switch state {
        case .ready:
            if now >= nextThreadPoll { pollLoadedThreads(now: now) }
        case .connecting:
            if now - connectingSince >= Self.handshakeTimeout { disconnect(reason: "the daemon did not answer initialize.") }
        case .idle, .failed:
            guard now >= nextRetry else { return }
            nextRetry = now + Self.retryInterval
            problem = AppServerSocketCheck.problem(at: socketPath)
            guard problem == nil else { if case .failed = state { state = .idle }; return }
            connect(now: now)
        }
    }

    /// Writes one message. True means the bytes were handed to the socket, not that the daemon read them.
    func send(_ message: [String: Any]) -> Bool {
        guard fd >= 0, state == .ready || state == .connecting,
              JSONSerialization.isValidJSONObject(message),
              var bytes = try? JSONSerialization.data(withJSONObject: message) else { return false }
        bytes.append(10)
        return writeAll(bytes)
    }

    // MARK: - Connection

    private func connect(now: Double) {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { state = .failed("could not create a socket (\(errno))."); return }
        var one: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { close(socketFD); state = .failed("socket path is too long."); return }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { raw in
                for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
                raw[pathBytes.count] = 0
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(socketFD)
            state = .failed("could not connect to \(socketPath) (\(String(cString: strerror(code)))).")
            return
        }
        _ = fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL) | O_NONBLOCK)
        fd = socketFD
        buffer = Data()
        subscribed = []
        state = .connecting
        connectingSince = now
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        source.setCancelHandler { close(socketFD) }
        reader = source
        source.resume()
        request("initialize", params: ["clientInfo": ["name": "steer", "title": "Steer", "version": Self.version],
                                       "capabilities": ["experimentalApi": true]]) { [weak self] result, error in
            guard let self else { return }
            guard result != nil, error == nil else { self.disconnect(reason: "initialize was refused."); return }
            _ = self.send(["jsonrpc": "2.0", "method": "initialized"])
            self.state = .ready
            self.pollLoadedThreads(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private func disconnect(reason: String) {
        reader?.cancel()
        reader = nil
        fd = -1
        buffer = Data()
        handlers = [:]
        subscribed = []
        state = .failed(reason)
        nextRetry = ProcessInfo.processInfo.systemUptime + Self.retryInterval
        onDisconnect?()
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        let id = nextID
        nextID += 1
        handlers[id] = completion
        guard send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
            handlers[id] = nil
            completion(nil, ["message": "write failed"])
            return
        }
    }

    /// Asks for the loaded-thread list on the next tick, e.g. when a question appears for a thread
    /// Steer has not subscribed to yet.
    func pollThreadsSoon() {
        nextThreadPoll = 0
    }

    /// Subscribes to every thread the daemon has in memory that Steer is not yet subscribed to.
    private func pollLoadedThreads(now: Double) {
        nextThreadPoll = now + Self.threadPollInterval
        request("thread/loaded/list", params: [:]) { [weak self] result, _ in
            guard let self, let loaded = result?["data"] as? [String] else { return }
            for thread in loaded where !self.subscribed.contains(thread) {
                self.request("thread/resume", params: ["threadId": thread]) { [weak self] result, _ in
                    if result != nil { self?.subscribed.insert(thread) }
                }
            }
        }
    }

    // MARK: - Reading

    private func readAvailable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if buffer.count > Self.maximumLine { disconnect(reason: "the daemon sent an oversized message."); return }
            } else if count == 0 {
                disconnect(reason: "the daemon closed the connection.")
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno == EINTR {
                continue
            } else {
                disconnect(reason: "read failed (\(String(cString: strerror(errno)))).")
                return
            }
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if message["method"] == nil, let id = message["id"] as? Int, let handler = handlers.removeValue(forKey: id) {
            handler(message["result"] as? [String: Any] ?? (message["error"] == nil ? [:] : nil), message["error"] as? [String: Any])
            return
        }
        if message["method"] as? String == "thread/closed",
           let thread = (message["params"] as? [String: Any])?["threadId"] as? String {
            subscribed.remove(thread)
        }
        onMessage?(message)
    }

    private func writeAll(_ bytes: Data) -> Bool {
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + Self.writeTimeout
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 100)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
