/// The animal drawn for every session, on the strip and at the head of each queue row. The user picks
/// one per display profile; each session still keeps its own color. Cases are in picker order, so
/// `allCases` lists Sheep, the default, first.
///
/// Frames are pure data copied cell for cell from the agreed Paper sprite artboards: `#` is the
/// session's body color, `+` its highlight, `.` empty. A cell draws at 2pt, so every kind fits 18 by
/// 10 points and three fit the strip's left wing. Drawing stays in the app target.
public enum SpriteKind: String, CaseIterable, Identifiable, Sendable {
    case sheep
    case critter
    case sheepdog
    case cow
    case blob

    public var id: String { rawValue }

    /// The picker label and the tile's spoken name.
    public var name: String {
        switch self {
        case .sheep: "Sheep"
        case .critter: "Critter"
        case .sheepdog: "Sheepdog"
        case .cow: "Cow"
        case .blob: "Blob"
        }
    }

    /// Two frames: the first is the idle, unlit, and Reduce Motion pose; working alternates them.
    public var frames: [[String]] {
        switch self {
        case .critter: Self.critterFrames
        case .sheep: Self.sheepFrames
        case .sheepdog: Self.sheepdogFrames
        case .cow: Self.cowFrames
        case .blob: Self.blobFrames
        }
    }

    /// Cells across, the same in both frames.
    public var columns: Int { frames[0].first?.count ?? 0 }
    /// Cells down, the same in both frames.
    public var rows: Int { frames[0].count }

    /// The widest kind's columns: the queue row's sprite slot is this many cells wide.
    public static let maximumColumns = allCases.map(\.columns).max() ?? 0
    /// The tallest kind's rows: the queue row's sprite slot is this many cells tall.
    public static let maximumRows = allCases.map(\.rows).max() ?? 0

    // Built once; the strip and every queue row read these on each frame step.
    private static let critterFrames = [[".++.++", "######", "#+##+#", ".#..#."],
                                        [".++.++", "######", "#+##+#", "#....#"]]
    private static let sheepFrames = [[".####....", "######+++", "######+.+", "######++.", ".#..#...."],
                                      [".####....", "######+++", "######+.+", "######++.", "#..#....."]]
    private static let sheepdogFrames = [[".......++", "+.....+++", ".######+.", ".######..", ".#....#.."],
                                         [".......++", "......+++", "+######+.", ".######..", "#....#..."]]
    private static let cowFrames = [["......+.+", "#######++", "##+##+#+.", "#######..", ".#.#..#.#"],
                                    ["......+.+", "#######++", "##+##+#+.", "#######..", "#.#..#.#."]]
    private static let blobFrames = [["..###..", ".#####.", ".#+#+#.", ".#####.", "..#.#.."],
                                     [".......", "..###..", "##+#+##", "#######", ".#...#."]]
}
