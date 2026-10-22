import Foundation
import HerdlyCore

/// The running processes' ids and command lines, for `CodexCLIProcesses`. Process identity only: no
/// environment, open files, or window contents are read.
enum ProcessList {
    static let limit = 4 * 1024 * 1024

    /// `ps -axo pid=,args=` output written from the kernel's process table (#303), or nil when the table
    /// could not be read or the listing would exceed `limit`.
    static func listing() -> String? {
        guard let records = KernelProcessTable.records(arguments: true) else { return nil }
        let listing = ProcessListing.pidArgs(records)
        return listing.utf8.count <= limit ? listing : nil
    }
}
