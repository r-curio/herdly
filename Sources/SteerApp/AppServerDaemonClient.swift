import CryptoKit
import Darwin
import Foundation
import SteerCore

/// A second JSON-RPC client on Codex's local app-server daemon socket, used for one thing: to
/// receive `item/tool/requestUserInput` for the user's running threads and write back the answer
/// the user gave in the notch (see `AppServerQuestions.swift`). The control socket speaks
/// WebSocket over the Unix socket (an HTTP upgrade, then one JSON-RPC 2.0 message per text frame),
/// as observed from Codex's own clients on 0.154.0; a raw JSON line is closed without reply.
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
        /// The HTTP upgrade and `initialize` are in flight.
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
    /// Thread ids the daemon reported loaded at the last poll, as UUIDs. Empty when not connected.
    private(set) var loadedThreads: Set<UUID> = []
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
    /// False until the daemon's `101 Switching Protocols` arrived; bytes before that are headers.
    private var upgraded = false
    private var upgradeKey = ""
    private var fragments = Data()

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

    /// Writes one message as one masked text frame. True means the bytes were handed to the
    /// socket, not that the daemon read them.
    func send(_ message: [String: Any]) -> Bool {
        guard fd >= 0, upgraded, state == .ready || state == .connecting,
              JSONSerialization.isValidJSONObject(message),
              let bytes = try? JSONSerialization.data(withJSONObject: message) else { return false }
        return writeAll(Self.frame(opcode: 0x1, payload: bytes))
    }

    /// One client-to-server frame: FIN set, masked with four random bytes as RFC 6455 requires.
    static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            out.append(0x80 | UInt8(count))
        } else if count < 65536 {
            out.append(0x80 | 126)
            out.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xff)])
        } else {
            out.append(0x80 | 127)
            out.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (8 * UInt64($0))) & 0xff) })
        }
        var mask = [UInt8](repeating: 0, count: 4)
        for index in 0..<4 { mask[index] = UInt8.random(in: 0...255) }
        out.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for index in 0..<count { masked[index] ^= mask[index % 4] }
        out.append(contentsOf: masked)
        return out
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
        fragments = Data()
        subscribed = []
        upgraded = false
        state = .connecting
        connectingSince = now
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        source.setCancelHandler { close(socketFD) }
        reader = source
        source.resume()
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 { keyBytes[index] = UInt8.random(in: 0...255) }
        upgradeKey = Data(keyBytes).base64EncodedString()
        let upgrade = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(upgradeKey)\r\n\r\n"
        guard writeAll(Data(upgrade.utf8)) else { disconnect(reason: "could not send the WebSocket upgrade."); return }
    }

    /// The `Sec-WebSocket-Accept` value the daemon must echo for `key` (RFC 6455 §4.2.2).
    static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// The daemon switched protocols: now the JSON-RPC handshake.
    private func finishUpgrade(headers: String) {
        let lines = headers.split(separator: "\r\n").map(String.init)
        guard let status = lines.first, status.contains(" 101 ") else {
            disconnect(reason: "the daemon refused the WebSocket upgrade (\(lines.first ?? "no status")).")
            return
        }
        let accept = lines.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept" ? parts[1] : nil
        }.first
        guard accept == Self.acceptValue(for: upgradeKey) else {
            disconnect(reason: "the daemon's WebSocket accept key did not match."); return
        }
        upgraded = true
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
        fragments = Data()
        upgraded = false
        handlers = [:]
        subscribed = []
        loadedThreads = []
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

    /// Sends one JSON-RPC request the user asked for and reports what the daemon made of it:
    /// accepted, or refused with its own message. A write that never left reports as refused too.
    /// Nothing here retries; one call is one request.
    func call(_ method: String, params: [String: Any], onResult: @escaping (Bool, String?) -> Void) {
        guard isConnected else { onResult(false, "the daemon is not connected"); return }
        request(method, params: params) { result, error in
            if let error { onResult(false, error["message"] as? String) } else { onResult(result != nil, nil) }
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
            self.loadedThreads = Set(loaded.compactMap(UUID.init(uuidString:)))
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
        if !upgraded {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headers = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            finishUpgrade(headers: headers)
            guard upgraded else { return }
        }
        while let (opcode, fin, payload) = nextFrame() {
            switch opcode {
            case 0x1, 0x2, 0x0:
                fragments.append(payload)
                guard fin else { continue }
                let whole = fragments
                fragments = Data()
                guard !whole.isEmpty, let message = try? JSONSerialization.jsonObject(with: whole) as? [String: Any] else { continue }
                dispatch(message)
            case 0x8:
                disconnect(reason: "the daemon closed the connection.")
                return
            case 0x9:
                _ = writeAll(Self.frame(opcode: 0xA, payload: payload))
            default:
                break
            }
        }
    }

    /// One complete server frame from the buffer, or nil until more bytes arrive. Server frames
    /// are unmasked by the standard; a masked one is tolerated.
    private func nextFrame() -> (opcode: UInt8, fin: Bool, payload: Data)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0f
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7f)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value: UInt64 = 0
            for index in 2..<10 { value = value << 8 | UInt64(bytes[index]) }
            guard value <= UInt64(Self.maximumLine) else { disconnect(reason: "the daemon sent an oversized frame."); return nil }
            length = Int(value); offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = [UInt8](buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + 4)]); offset += 4
        }
        guard buffer.count >= offset + length else { return nil }
        var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + length)])
        if masked { for index in 0..<payload.count { payload[index] ^= mask[index % 4] } }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset + length))
        return (opcode, fin, payload)
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
