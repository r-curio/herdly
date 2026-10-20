import Foundation

/// The `.jsonl` files under a Codex rollouts root, in the order `FileManager`'s enumerator visits
/// them with hidden files skipped. The reminder scan used to walk the whole tree every two seconds
/// (#306). Adding, removing or renaming an entry changes its directory's stamp, and a new directory
/// changes its parent's, so while every visited directory keeps its stamp the last walk is reused.
/// Stamps are taken before walking, so a change during the walk shows up on the next call.
public enum RolloutTree {
    /// Past this many entries the tree is not used, as before.
    public static let maximumEntries = 50_000

    public struct Index: Sendable {
        /// Each `.jsonl` file with its lowercased name, in enumeration order.
        public let files: [(url: URL, lowercasedName: String)]
        /// The walk passed `maximumEntries`; `files` is then empty.
        public let tooLarge: Bool
    }

    /// Nil when the root cannot be enumerated.
    public static func index(_ root: URL) -> Index? {
        let key = root.standardizedFileURL.path
        if let cached = cache.entry(key), cached.directories.allSatisfy({ FileStamp(URL(fileURLWithPath: $0.key), followingLinks: false) == $0.value }) {
            return cached.index
        }
        let rootStamp = FileStamp(root, followingLinks: false)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { return nil }
        var directories: [String: FileStamp] = [:]
        if let rootStamp { directories[key] = rootStamp }
        var stampsComplete = rootStamp != nil
        var files: [(url: URL, lowercasedName: String)] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > maximumEntries { return Index(files: [], tooLarge: true) }
            if url.pathExtension == "jsonl" { files.append((url, url.lastPathComponent.lowercased())) }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let stamp = FileStamp(url, followingLinks: false) { directories[url.standardizedFileURL.path] = stamp }
                else { stampsComplete = false }
            }
        }
        let index = Index(files: files, tooLarge: false)
        // A directory that could not be stamped could change unseen, so that walk is not kept.
        if stampsComplete { cache.store(Cache.Entry(directories: directories, index: index), for: key) }
        return index
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        struct Entry {
            let directories: [String: FileStamp]
            let index: Index
        }

        // Invariant for `@unchecked Sendable`: `entries` is only touched while holding `lock`.
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func entry(_ key: String) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ entry: Entry, for key: String) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = entry
        }
    }
}
