import Darwin
import Foundation
import HerdlyCore

/// The process table read from the kernel in Herdly's own process (#303), replacing every scheduled
/// `/bin/ps`. `sysctl(KERN_PROC_ALL)` gives each process's ids, tty and state; `KERN_PROCARGS2` gives its
/// argument vector. `ProcessListing` (HerdlyCore) turns the records into the text `ps` printed. Read-only;
/// any failed table read is nil, which every caller treats as unreadable.
enum KernelProcessTable {
    /// Every process, `kinfo_proc` as the kernel fills it; nil when the table could not be read.
    static func kinfo() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        return read(&mib)
    }

    /// Whose argument vectors a read asks the kernel for (`KERN_PROCARGS2`, one call per process). The
    /// kernel gives Herdly only its own user's, so asking for the rest only costs time.
    enum Arguments {
        case none
        case all
        case owner(uid_t)
    }

    /// Every process except the kernel's own (pid 0, which `ps` does not list either), with the argument
    /// vectors `arguments` names; nil when the table could not be read.
    static func records(arguments: Arguments) -> [KernelProcessRecord]? {
        kinfo().map { records($0, arguments: arguments) }
    }

    /// The processes whose controlling terminal is `/dev/<tty>`, with every argument vector the kernel
    /// gives; nil when the device or the table could not be read.
    static func records(onTTY tty: String) -> [KernelProcessRecord]? {
        var info = stat()
        guard tty.allSatisfy({ $0.isLetter || $0.isNumber }), stat("/dev/" + tty, &info) == 0,
              info.st_mode & S_IFMT == S_IFCHR else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(truncatingIfNeeded: info.st_rdev))]
        return read(&mib).map { records($0, arguments: .all) }
    }

    /// `pid`'s argument vector from the kernel (`KERN_PROCARGS2`), nil when it cannot be read.
    static func arguments(of pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size,
              size <= 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return KernelProcessArguments.parse(Array(buffer.prefix(size)))
    }

    /// The kernel's short command name (`p_comm`).
    static func shortName(_ process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func read(_ mib: inout [Int32]) -> [kinfo_proc]? {
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        // Room for processes started between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func records(_ table: [kinfo_proc], arguments: Arguments) -> [KernelProcessRecord] {
        table.filter { $0.kp_proc.p_pid > 0 }.map { process in
            let wanted = switch arguments {
            case .none: false
            case .all: true
            case .owner(let uid): process.kp_eproc.e_ucred.cr_uid == uid
            }
            return record(process, readArguments: wanted)
        }
    }

    private static func record(_ process: kinfo_proc, readArguments: Bool) -> KernelProcessRecord {
        let pid = process.kp_proc.p_pid, eproc = process.kp_eproc
        let controlled = process.kp_proc.p_flag & P_CONTROLT != 0
        let vector = readArguments ? arguments(of: pid) : nil
        return KernelProcessRecord(pid: pid, ppid: eproc.e_ppid, uid: eproc.e_ucred.cr_uid,
                                   tty: ttyName(eproc.e_tdev), state: state(process.kp_proc.p_stat),
                                   sessionLeader: Int32(eproc.e_flag) & EPROC_SLEADER != 0,
                                   foreground: controlled && eproc.e_pgid == eproc.e_tpgid,
                                   shortName: shortName(process), arguments: vector)
    }

    private static func state(_ value: CChar) -> ProcessRunState {
        switch Int32(value) {
        case SRUN, SIDL: .running
        case SSLEEP: .sleeping
        case SSTOP: .stopped
        case SZOMB: .zombie
        default: .unknown
        }
    }

    /// A character device number names the same tty for as long as the system runs, so found names are
    /// kept (#301); a miss is looked up again next time.
    static func ttyName(_ device: dev_t) -> String? {
        guard device != ~dev_t(0) else { return nil }
        if let known = ttyNames.name(device) { return known }
        // `devname_r`: reads run from several tasks at once, and `devname` shares one buffer.
        var buffer = [CChar](repeating: 0, count: 64)
        guard devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let value = text(buffer)
        guard !value.isEmpty, value != "??" else { return nil }
        ttyNames.store(value, for: device)
        return value
    }

    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static let ttyNames = TTYNames()

    private final class TTYNames: @unchecked Sendable {
        // Invariant for `@unchecked Sendable`: `names` is only touched while holding `lock`.
        private let lock = NSLock()
        private var names: [dev_t: String] = [:]

        func name(_ device: dev_t) -> String? {
            lock.lock(); defer { lock.unlock() }
            return names[device]
        }

        func store(_ name: String, for device: dev_t) {
            lock.lock(); defer { lock.unlock() }
            names[device] = name
        }
    }
}
