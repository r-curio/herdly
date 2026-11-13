import Foundation

/// The rollouts in the newest day directories of a Codex sessions tree
/// (`<root>/<year>/<month>/<day>/*.jsonl`), newest modification first: what `CodexUsageReader`,
/// `SessionDiscovery` and `CodexSubagentReader` each ask for on every scan.
///
/// Each of the three listed about thirty directories every two seconds, which was most of their cost
/// (#306). Adding, removing or renaming an entry changes its directory's modification time, so a
/// directory is listed again only when its own `lstat` differs from the one taken before it was last
/// listed. A rollout's modification time changes with every append and does not touch its directory,
/// so every listed rollout is still `lstat`'ed on every call: an unchanged tree costs one `lstat` per
/// visited directory and rollout, and no directory is opened.
///
/// What a directory's modification time does not show is covered separately: its status-change time
/// is compared too (a permission change), and the hidden flag, which hides an entry from the listing
/// without touching its parent, is read from each entry's own `lstat`. A listing that could not be
/// read, or whose directory could not be `lstat`'ed first, is never kept.
///
/// Equal marks prove nothing while a directory is still young. A volume with coarse timestamps
/// (exFAT, SMB, NFS: one or two seconds) gives a rollout created just after a listing the same
/// directory times that listing saw. So, as git does for its index, a kept listing is trusted only
/// when its mark was taken at least `settleTime` after the directory's last change; until then the
/// directory is listed again on every call, as it was before anything was kept.
enum RolloutDays {
    /// Roots kept at once; the least recently walked is dropped past it. The app reads one.
    static let maximumRoots = 16
    /// How long after a directory's last change its mark must have been taken to be trusted: past
    /// the two seconds of the coarsest timestamps in use (FAT), with a second to spare.
    static let settleTime: Double = 3

    /// At most `limit` rollouts from the newest `CodexUsageReader.maximumDays` day directories under
    /// `root`, looking at no more than the three newest years and their three newest months.
    ///
    /// `now` is the wall clock in seconds since 1970, the clock directory times are written in: each
    /// mark taken during this call is dated with it (`settleTime`). A clock that has gone backwards
    /// or is not a number only makes marks untrusted, so directories are listed again.
    static func newest(root: URL, limit: Int, now: Double) -> [(url: URL, modified: Date)] {
        let key = root.standardizedFileURL.path
        var walk = Walk(root: root, previous: cache.walk(key), now: now)
        var reads = walk.reads
        // A kept listing named something that is gone or hidden now: read the tree with nothing reused.
        if walk.stale {
            walk = Walk(root: root, previous: nil, now: now)
            reads += walk.reads
        }
        cache.store(walk.directories.isEmpty ? nil : walk, reads: reads, for: key)
        return walk.sorted.prefix(limit).map { entry in
            // A kept URL would otherwise answer later resource-value questions (is it a symbolic
            // link?) from what it was asked on an earlier scan.
            var url = entry.url
            url.removeAllCachedResourceValues()
            return (url: url, modified: entry.modified)
        }
    }

    /// How many directories under `root` were listed since it was first walked, for tests.
    static func directoryReads(root: URL) -> Int {
        cache.reads(root.standardizedFileURL.path)
    }

    /// Whether a walk of `root` is held, for tests.
    static func keeps(root: URL) -> Bool {
        cache.walk(root.standardizedFileURL.path) != nil
    }

    /// What `lstat` says of one path. For a directory, equal marks mean the same entries.
    struct Mark: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let mode: UInt16
        /// The Finder's hidden flag (`UF_HIDDEN`), which a listing that skips hidden files honours.
        let hidden: Bool

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        /// The modification and status-change times as seconds since 1970.
        var modifiedAt: Double { Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000 }
        var changedAt: Double { Double(changedSeconds) + Double(changedNanoseconds) / 1_000_000_000 }

        /// The modification time as `URLResourceValues.contentModificationDate` gives it.
        var modified: Date {
            Date(timeIntervalSinceReferenceDate: Double(modifiedSeconds) - Date.timeIntervalBetween1970AndReferenceDate
                + Double(modifiedNanoseconds) * 1.0e-9)
        }

        init?(_ url: URL) {
            var info = stat()
            let status = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &info) } ?? -1 }
            guard status == 0 else { return nil }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = Int(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
            changedSeconds = Int(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int(info.st_ctimespec.tv_nsec)
            mode = UInt16(info.st_mode)
            hidden = info.st_flags & UInt32(UF_HIDDEN) != 0
        }
    }

    /// One directory as last listed, under the mark taken before listing it.
    struct Listed: Sendable {
        let mark: Mark
        /// The wall clock when `mark` was taken.
        let markedAt: Double

        /// Whether this listing still stands for a directory whose mark is now `current`: the same
        /// mark, taken once the directory had been unchanged for `settleTime`. False when the clock
        /// that dated the mark was behind the directory's own times or was not a number.
        func reusable(for current: Mark) -> Bool {
            mark == current && markedAt - max(mark.modifiedAt, mark.changedAt) >= RolloutDays.settleTime
        }
        /// The entries the walk uses: numbered directories, newest first, or rollouts.
        let visible: [URL]
        /// Entries that would be used but for their hidden flag; one that loses it must be noticed.
        let hidden: [URL]
    }

    private enum Kind {
        /// The root, read for its numbered directories. No kept listing named it, so it cannot
        /// contradict one: a hidden root is read like any other, and a root that is a link lists
        /// nothing (`FileManager` does not list through a final link) and so keeps nothing.
        case root
        case numberedDirectories, rollouts
    }

    /// One walk of a root, and what the next walk may reuse of it.
    struct Walk: Sendable {
        var directories: [String: Listed] = [:]
        /// Every rollout in the visited day directories, in the order visited.
        var files: [(url: URL, modified: Date)] = []
        var sorted: [(url: URL, modified: Date)] = []
        /// A kept listing no longer matches what it listed.
        var stale = false
        var reads = 0

        fileprivate init(root: URL, previous: Walk?, now: Double) {
            var changed = previous == nil
            var days: [URL] = []
            let maximumDays = CodexUsageReader.maximumDays
            outer: for year in children(of: root, .root, previous, now, &changed).prefix(3) {
                for month in children(of: year, .numberedDirectories, previous, now, &changed).prefix(3) {
                    for day in children(of: month, .numberedDirectories, previous, now, &changed) {
                        days.append(day)
                        if days.count == maximumDays { break outer }
                    }
                }
            }
            for day in days {
                for url in children(of: day, .rollouts, previous, now, &changed) {
                    let mark = Mark(url)
                    if previous != nil, mark == nil || mark?.hidden == true { stale = true }
                    files.append((url, mark?.modified ?? .distantPast))
                }
            }
            if !changed, let previous, previous.files.count == files.count,
               zip(previous.files, files).allSatisfy({ $0.modified == $1.modified }) {
                sorted = previous.sorted
            } else {
                sorted = files.sorted { $0.modified == $1.modified ? $0.url.path > $1.url.path : $0.modified > $1.modified }
            }
        }

        /// The entries of `directory` the walk uses, from `previous` while the directory is unchanged.
        private mutating func children(of directory: URL, _ kind: Kind, _ previous: Walk?, _ now: Double,
                                       _ changed: inout Bool) -> [URL] {
            // Taken before listing, so a change during the listing shows as a new mark next time.
            let mark = Mark(directory)
            // The parent's kept listing named this as a directory that is not hidden.
            if kind != .root, previous != nil, mark == nil || mark?.hidden == true || mark?.isDirectory == false { stale = true }
            let path = directory.path
            if let mark, let kept = previous?.directories[path], kept.reusable(for: mark),
               kept.hidden.allSatisfy({ Mark($0)?.hidden == true }) {
                directories[path] = kept
                return kept.visible
            }
            changed = true
            reads += 1
            guard let listed = Self.list(directory, kind) else { return [] }
            if let mark { directories[path] = Listed(mark: mark, markedAt: now, visible: listed.visible, hidden: listed.hidden) }
            return listed.visible
        }

        /// `directory` read from disk; nil when it cannot be listed.
        private static func list(_ directory: URL, _ kind: Kind) -> (visible: [URL], hidden: [URL])? {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                              options: []) else { return nil }
            var visible: [URL] = [], hidden: [URL] = []
            for url in entries {
                let values = try? url.resourceValues(forKeys: Set(keys))
                switch kind {
                case .root, .numberedDirectories:
                    guard Int(url.lastPathComponent) != nil, values?.isDirectory == true else { continue }
                case .rollouts:
                    guard url.pathExtension == "jsonl" else { continue }
                }
                if values?.isHidden != true {
                    visible.append(url)
                } else if !url.lastPathComponent.hasPrefix(".") {
                    // A name starting with a dot stays hidden until renamed, which the directory shows.
                    hidden.append(url)
                }
            }
            if kind != .rollouts { visible.sort { $0.lastPathComponent > $1.lastPathComponent } }
            return (visible, hidden)
        }
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        // Invariant for `@unchecked Sendable`: every property is only touched while holding `lock`.
        private let lock = NSLock()
        private var walks: [String: (walk: Walk?, reads: Int, used: UInt64)] = [:]
        private var uses: UInt64 = 0

        func walk(_ key: String) -> Walk? {
            lock.lock(); defer { lock.unlock() }
            return walks[key]?.walk
        }

        /// Keeps `walk` for `key`, or nothing when no directory of it could be kept.
        func store(_ walk: Walk?, reads: Int, for key: String) {
            lock.lock(); defer { lock.unlock() }
            uses += 1
            walks[key] = (walk, (walks[key]?.reads ?? 0) + reads, uses)
            if walks.count > RolloutDays.maximumRoots, let oldest = walks.min(by: { $0.value.used < $1.value.used })?.key {
                walks.removeValue(forKey: oldest)
            }
        }

        func reads(_ key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return walks[key]?.reads ?? 0
        }
    }
}
