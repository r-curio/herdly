import Darwin
import Foundation
import SteerCore

/// Steer's only route to tmux (#241, ADR 0014): the `tmux` binary from a fixed location, always pointed
/// at the default socket with `-S`, never at `$TMUX` or a socket chosen with `-L`/`-S`, and with `-N` so
/// no command ever starts a server. Every command has a bounded wait and runs with a minimal
/// environment; nothing is retried. Called only while tmux may be contacted (its switch and a terminal
/// on). Blocking: call off the main actor. Steer never edits tmux's configuration.
enum TmuxClient {
    /// Seconds any one tmux command may run before it is terminated.
    static let timeout: Double = 2

    static func binary() -> String? {
        TmuxBinary.resolve(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func socketPath() -> String? {
        TmuxDefaultSocket.path(uid: getuid(), environment: ProcessInfo.processInfo.environment, resolve: realPath)
    }

    /// One read of the default server: trust first, then `list-panes -a` and `list-clients`.
    static func read() -> TmuxRead {
        guard let socket = socketPath() else { return .notRunning }
        switch TmuxSocketTrust.problem(directory: facts((socket as NSString).deletingLastPathComponent),
                                       socket: facts(socket), me: getuid()) {
        case .notRunning?: return .notRunning
        case .untrusted?: return .untrustedSocket
        case nil: break
        }
        switch peer(socket) {
        case .refused: return .notRunning
        case .otherUser: return .untrustedSocket
        case .currentUser: break
        }
        guard binary() != nil else { return .binaryNotFound }
        guard case .succeeded(let panes) = run(["list-panes", "-a", "-F", TmuxListing.paneFormat]),
              case .succeeded(let clients) = run(["list-clients", "-F", TmuxListing.clientFormat]),
              let snapshot = TmuxSnapshot.parse(panes: panes, clients: clients) else { return .unreadable }
        return .snapshot(snapshot)
    }

    /// Runs one tmux command against the default socket. Stdout over `TmuxListing.maximumOutput` is a
    /// failure; stderr is discarded.
    static func run(_ arguments: [String]) -> TmuxCommandOutcome {
        guard let executable = binary(), let socket = socketPath() else { return .notLaunched }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-S", socket, "-N"] + arguments
        // No TMUX or TMUX_TMPDIR: the socket is the one passed above. UTF-8 keeps titles intact.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .notLaunched }
        // Written once by the drain block before `drained` is signalled and read only after the wait on
        // `drained` succeeds, so the semaphore orders every access.
        final class Box: @unchecked Sendable { var bytes: Data? }
        let box = Box()
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.bytes = try? reader.read(upToCount: TmuxListing.maximumOutput + 1)
            drained.signal()
        }
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            return .timedOut
        }
        guard drained.wait(timeout: max(deadline, .now() + 1)) == .success else { return .timedOut }
        guard process.terminationStatus == 0 else { return .failed }
        guard let bytes = box.bytes, bytes.count <= TmuxListing.maximumOutput else { return .failed }
        return .succeeded(String(decoding: bytes, as: UTF8.self))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func facts(_ path: String) -> TmuxFileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: TmuxFileFacts.Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFSOCK: kind = .socket
        default: kind = .other
        }
        return TmuxFileFacts(kind: kind, owner: info.st_uid, mode: UInt16(info.st_mode & 0o7777))
    }

    private enum Peer { case refused, otherUser, currentUser }

    /// Connects to the socket, which the trust check already found owned by this user, and confirms the
    /// accepting server runs as this user (`getpeereid`), as herdr's client does. Nothing is written.
    private static func peer(_ path: String) -> Peer {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .refused }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return .otherUser }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { raw in
                for (index, byte) in bytes.enumerated() { raw[index] = byte }
                raw[bytes.count] = 0
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .refused }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return .otherUser }
        return .currentUser
    }
}
