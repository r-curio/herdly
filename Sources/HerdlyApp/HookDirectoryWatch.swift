import CoreServices
import Foundation
import HerdlyCore

/// Tells `HookEventListing` which names changed in Herdly's hook event directories, from macOS
/// file-system events, so a busy directory is not read in full every time a record arrives.
///
/// Reports are hints only (`HookDirectoryChangeLog`): the listing checks every name and the
/// directory's entry count itself, and reads the directory in full whenever a report is missing,
/// late or says the events cannot be trusted. Nothing here decides what a record is. If a stream
/// cannot be started the directory is simply not watched, and it is read as it always was.
///
/// The same reports are the hook scan's change evidence (#306). Nothing hops to the main actor from
/// the event callback: it records into the lock-protected `HookEventListing.changes`, and the
/// main-actor refresh tick asks that log (`takeScanEvidence`) before deciding whether to scan. A
/// directory with no running stream reads there as untrusted, which keeps the scan on its clock.
@MainActor
final class HookDirectoryWatch {
    static let shared = HookDirectoryWatch()

    private var streams: [String: HookDirectoryStream] = [:]

    /// Watches exactly `directories`: starts the new ones and stops the rest. Cheap when unchanged.
    func watch(_ directories: [URL]) {
        let wanted = Dictionary(directories.map { ($0.standardizedFileURL.path, $0) }) { first, _ in first }
        // A stream that said it may have lost its directory is replaced, like one never started.
        for (path, stream) in streams where wanted[path] == nil || HookEventListing.changes.isWatchLost(stream.directory) {
            stream.stop()
            streams.removeValue(forKey: path)
        }
        for (path, directory) in wanted where streams[path] == nil {
            // A directory that does not exist yet is tried again on the next scan.
            if let stream = HookDirectoryStream(directory) { streams[path] = stream }
        }
    }
}

/// One directory's event stream. Events arrive on `queue`; `flush` is called from whichever thread
/// lists the directory.
private final class HookDirectoryStream: @unchecked Sendable {
    /// Event flags that mean the directory itself moved or its volume changed: the stream may be
    /// following nothing, so it is replaced.
    private static let lost = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
        | kFSEventStreamEventFlagUnmount)
    /// Event flags that mean names were lost or the directory itself moved: read it in full.
    private static let untrusted = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped) | lost

    let directory: URL
    /// The directory's real path with a trailing slash, as events name it.
    private let prefix: String
    private let queue = DispatchQueue(label: "dev.rcurio.herdly.hook-directory-watch", qos: .utility)
    // Invariant for `@unchecked Sendable`: `stream` is only read or cleared while holding `lock`,
    // so a flush never uses a stream that `stop` has released.
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init?(_ directory: URL) {
        guard let resolved = realpath(directory.path, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        self.directory = directory
        prefix = real.hasSuffix("/") ? real : real + "/"
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let stream = Unmanaged<HookDirectoryStream>.fromOpaque(info).takeUnretainedValue()
            stream.handle(paths, Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, [real] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return nil }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
        // Only now: watching starts as "unknown", so the first listing is a full read taken while
        // the stream is already running.
        HookEventListing.changes.startWatching(directory) { [weak self] in self?.flush() }
    }

    /// Hands over every event that has already reached the event service, before returning.
    private func flush() {
        lock.lock()
        if let stream { FSEventStreamFlushSync(stream) }
        lock.unlock()
        // The callback runs on `queue`; wait for the ones the flush queued.
        queue.sync {}
    }

    func stop() {
        HookEventListing.changes.stopWatching(directory)
        lock.lock()
        let stopping = stream
        stream = nil
        lock.unlock()
        guard let stopping else { return }
        FSEventStreamStop(stopping)
        FSEventStreamInvalidate(stopping)
        // No callback is running or will run after this: none can touch the released stream's context.
        queue.sync {}
        FSEventStreamRelease(stopping)
    }

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        var names = Set<String>()
        for (path, flag) in zip(paths, flags) {
            // Lost events, the directory itself, or anything not under it: the names cannot be relied on.
            guard flag & Self.untrusted == 0, path.hasPrefix(prefix) else {
                HookEventListing.changes.reportUnknown(in: directory, watchLost: flags.contains { $0 & Self.lost != 0 })
                return
            }
            let name = path.dropFirst(prefix.count)
            // The listing is top-level only; what changes inside a subdirectory does not change it.
            if !name.isEmpty, !name.contains("/") { names.insert(String(name)) }
        }
        // Reported even with no top-level name: a change below still makes a scan due (#306).
        HookEventListing.changes.report(names, in: directory)
    }
}
