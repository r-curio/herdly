import Foundation

// #303: Herdly reads the process table from the kernel instead of running `/bin/ps`. HerdlyApp makes
// the syscalls and hands over `KernelProcessRecord`s; this file writes them in the exact text shapes
// `ps` printed, so `CodexCLIProcesses`, `ZellijProcessTable.parse`, `TerminalForegroundProcesses.parse`
// and the Claude descendant walk keep their parsing and identity rules unchanged.

/// The scheduler state `ps` shows as `stat`'s first letter.
public enum ProcessRunState: Sendable {
    case running, sleeping, stopped, zombie, unknown

    var letter: Character {
        switch self {
        case .running: "R"
        case .sleeping: "S"
        case .stopped: "T"
        case .zombie: "Z"
        case .unknown: "?"
        }
    }
}

/// One process as the kernel reports it (`KERN_PROC_ALL` plus `KERN_PROCARGS2`). Identity facts only:
/// no environment, open files or window contents.
public struct KernelProcessRecord: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// The effective user id, as `ps -o uid` prints it.
    public let uid: UInt32
    /// The controlling terminal's device name (`ttys003`); nil when it has none.
    public let tty: String?
    public let state: ProcessRunState
    /// Whether it leads its session (`s` in `stat`).
    public let sessionLeader: Bool
    /// Whether it is in its terminal's foreground process group (`+` in `stat`).
    public let foreground: Bool
    /// The kernel's short command name (`p_comm`, at most 16 bytes).
    public let shortName: String
    /// The argument vector, `argv[0]` first; nil when the kernel would not give it (another user's or an
    /// exiting process), or when it was not read.
    public let arguments: [String]?

    public init(pid: Int32, ppid: Int32, uid: UInt32, tty: String?, state: ProcessRunState, sessionLeader: Bool,
                foreground: Bool, shortName: String, arguments: [String]?) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.tty = tty
        self.state = state
        self.sessionLeader = sessionLeader
        self.foreground = foreground
        self.shortName = shortName
        self.arguments = arguments
    }
}

/// `ps` output shapes written from kernel records. Rows are ordered by pid, as `ps` prints them.
public enum ProcessListing {
    /// `ps -axo pid=,args=` for the processes whose argument vector was read; nil once the text would
    /// pass `limit` bytes. A process without one is left out: the kernel withholds other users' vectors,
    /// which `ps` shows, and a row without its arguments could hide what the Codex rules look for (an
    /// `app-server` would read as a CLI). Herdly never targets another user's processes.
    public static func pidArgs(_ records: [KernelProcessRecord], limit: Int) -> String? {
        rows(records.filter { $0.arguments?.isEmpty == false }, limit: limit) { "\(pid($0.pid)) \(args($0))" }
    }

    /// `ps -axo pid=,ppid=,uid=,tty=,comm=`.
    public static func pidPPIDUIDTTYComm(_ records: [KernelProcessRecord]) -> String {
        rows(records) { record in
            let tty = (record.tty ?? "??").padding(toLength: max(8, (record.tty ?? "??").count), withPad: " ", startingAt: 0)
            return "\(pid(record.pid)) \(pid(record.ppid)) \(column(String(record.uid))) \(tty) \(command(record))"
        } ?? ""
    }

    /// `ps -o pid=,stat=,comm= -t <tty>`: only the processes whose controlling terminal is `tty` (`ttys003`);
    /// nil once the text would pass `limit` bytes. Of `stat`, only the `+` flag is sure to match `ps`; the
    /// state letter may differ (see `stat`).
    public static func pidStatComm(_ records: [KernelProcessRecord], tty: String, limit: Int) -> String? {
        rows(records.filter { $0.tty == tty }, limit: limit) { record in
            let stat = stat(record)
            return "\(pid(record.pid)) \(stat.padding(toLength: max(4, stat.count), withPad: " ", startingAt: 0)) \(command(record))"
        }
    }

    /// `ps -axo pid=,ppid=`.
    public static func pidPPID(_ records: [KernelProcessRecord]) -> String {
        rows(records) { "\(pid($0.pid)) \(pid($0.ppid))" } ?? ""
    }

    /// `ps`'s `comm`: `argv[0]`, which a process may rewrite (`npm run dev`) and a login shell starts with
    /// `-`. `ps` reads other users' vectors, which Herdly cannot; for those, and for an empty first entry,
    /// the kernel's short name (`ps` would show a path with the same basename, up to 16 bytes).
    public static func command(_ record: KernelProcessRecord) -> String {
        guard let first = record.arguments?.first, !first.isEmpty else { return visible(record.shortName) }
        return visible(first)
    }

    /// `ps`'s `args`: the vector joined by spaces.
    static func args(_ record: KernelProcessRecord) -> String {
        visible((record.arguments ?? []).joined(separator: " "))
    }

    /// `ps`'s `stat`: the state letter, then `s` for a session leader and `+` for the foreground group.
    /// `ps` takes the letter from Mach thread states (`S`, `I`, `U` for most processes); the kernel's
    /// `p_stat` is `R` for nearly every live process. The parsers read only `+`, which matches `ps`.
    public static func stat(_ record: KernelProcessRecord) -> String {
        var value = String(record.state.letter)
        if record.sessionLeader { value += "s" }
        if record.foreground { value += "+" }
        return value
    }

    /// Control characters escaped as `ps` prints them in a UTF-8 locale (tab and newline in octal, the
    /// rest in caret form), so no argument can start a row or split a column.
    public static func visible(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsEscape) else { return text }
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A: result += "\\0" + String(scalar.value, radix: 8)
            case 0x00..<0x20: result += "^" + String(UnicodeScalar(UInt8(scalar.value + 0x40)))
            case 0x7F: result += "^?"
            case 0x80..<0xA0: result += "M^" + String(UnicodeScalar(UInt8(scalar.value - 0x80 + 0x40)))
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F..<0xA0).contains(scalar.value)
    }

    /// The rows in pid order; nil as soon as they pass `limit` bytes, before the rest are built.
    private static func rows(_ records: [KernelProcessRecord], limit: Int = .max,
                             _ row: (KernelProcessRecord) -> String) -> String? {
        var text = "", bytes = 0
        for record in records.sorted(by: { $0.pid < $1.pid }) {
            let line = row(record) + "\n"
            bytes += line.utf8.count
            guard bytes <= limit else { return nil }
            text += line
        }
        return text
    }

    private static func pid(_ value: Int32) -> String { column(String(value)) }

    private static func column(_ value: String) -> String {
        String(repeating: " ", count: max(0, 5 - value.count)) + value
    }
}

/// The argument vector in a `KERN_PROCARGS2` buffer.
public enum KernelProcessArguments {
    public static let maximumArguments = 4096

    /// `argv` from `bytes`: an `argc` count, the executable path, NUL padding, then `argc` NUL-terminated
    /// arguments (the environment follows and is never read). nil when the count is implausible or the
    /// buffer ends first.
    public static func parse(_ bytes: [UInt8]) -> [String]? {
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= maximumArguments else { return nil }
        var index = header
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? arguments : nil
    }
}
