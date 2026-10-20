import Foundation

/// One version of a file, read with a single `stat` and without opening it: device, inode, size and
/// modification time. Readers that rescan every two seconds compare stamps to reuse what they decoded
/// from an unchanged file. An append changes the size and time; an atomic replace changes the inode.
public struct FileStamp: Hashable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    /// Whether the path itself is a regular file (for a stamp taken without following links, a
    /// symbolic link is not).
    public let isRegularFile: Bool

    /// The stamp of `url`, following a final symbolic link when `followingLinks` is true; nil when
    /// the path cannot be stat'ed. Take it before reading, so a change during the read shows up as a
    /// different stamp on the next scan rather than being hidden by the cache.
    public init?(_ url: URL, followingLinks: Bool) {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return followingLinks ? stat(path, &info) : lstat(path, &info)
        }
        guard status == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
        isRegularFile = info.st_mode & S_IFMT == S_IFREG
    }
}
