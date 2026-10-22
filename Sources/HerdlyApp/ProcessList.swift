import Foundation
import HerdlyCore

/// The running processes' ids and command lines, for `CodexCLIProcesses`. Process identity only: no
/// environment, open files, or window contents are read.
enum ProcessList {
    static let limit = 4 * 1024 * 1024

    /// `ps -axo pid=,args=` output written from the kernel's process table (#303), or nil when the table
    /// could not be read or the listing passes `limit` bytes (building stops there). Only the user's own
    /// processes are listed: the kernel gives Herdly no other user's arguments (`ProcessListing.pidArgs`).
    static func listing() -> String? {
        guard let records = KernelProcessTable.records(arguments: .owner(getuid())) else { return nil }
        return ProcessListing.pidArgs(records, limit: limit)
    }
}
