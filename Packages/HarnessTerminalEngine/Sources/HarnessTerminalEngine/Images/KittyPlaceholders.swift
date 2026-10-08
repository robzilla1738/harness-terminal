import Foundation

/// Kitty graphics Unicode placeholders (`U=1`): instead of the terminal drawing an image at the
/// cursor, the program prints U+10EEEE cells. Each cell's foreground color is the image id, and
/// its first and second combining marks are the row and column of the image cell it shows,
/// taken from Kitty's diacritic table. (A cell keeps two marks, so the optional third one, an
/// id's high byte, is dropped: ids up to 2^24 work.) A cell without marks
/// continues the cell to its left. Because the image is ordinary text, it scrolls, reflows,
/// and survives tmux, editors, and reattaching like any other output.
public enum KittyPlaceholders {
    public static let character: UInt32 = 0x10EEEE

    /// Kitty's `rowcolumn-diacritics.txt`: the n-th mark means row (or column) n.
    static let diacritics: [UInt32] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x0305 ... 0x0305, 0x030D ... 0x030E, 0x0310 ... 0x0310, 0x0312 ... 0x0312, 0x033D ... 0x033F,
            0x0346 ... 0x0346, 0x034A ... 0x034C, 0x0350 ... 0x0352, 0x0357 ... 0x0357, 0x035B ... 0x035B,
            0x0363 ... 0x036F, 0x0483 ... 0x0487, 0x0592 ... 0x0595, 0x0597 ... 0x0599, 0x059C ... 0x05A1,
            0x05A8 ... 0x05A9, 0x05AB ... 0x05AC, 0x05AF ... 0x05AF, 0x05C4 ... 0x05C4, 0x0610 ... 0x0617,
            0x0657 ... 0x065B, 0x065D ... 0x065E, 0x06D6 ... 0x06DC, 0x06DF ... 0x06E2, 0x06E4 ... 0x06E4,
            0x06E7 ... 0x06E8, 0x06EB ... 0x06EC, 0x0730 ... 0x0730, 0x0732 ... 0x0733, 0x0735 ... 0x0736,
            0x073A ... 0x073A, 0x073D ... 0x073D, 0x073F ... 0x0741, 0x0743 ... 0x0743, 0x0745 ... 0x0745,
            0x0747 ... 0x0747, 0x0749 ... 0x074A, 0x07EB ... 0x07F1, 0x07F3 ... 0x07F3, 0x0816 ... 0x0819,
            0x081B ... 0x0823, 0x0825 ... 0x0827, 0x0829 ... 0x082D, 0x0951 ... 0x0951, 0x0953 ... 0x0954,
            0x0F82 ... 0x0F83, 0x0F86 ... 0x0F87, 0x135D ... 0x135F, 0x17DD ... 0x17DD, 0x193A ... 0x193A,
            0x1A17 ... 0x1A17, 0x1A75 ... 0x1A7C, 0x1B6B ... 0x1B6B, 0x1B6D ... 0x1B73, 0x1CD0 ... 0x1CD2,
            0x1CDA ... 0x1CDB, 0x1CE0 ... 0x1CE0, 0x1DC0 ... 0x1DC1, 0x1DC3 ... 0x1DC9, 0x1DCB ... 0x1DCC,
            0x1DD1 ... 0x1DE6, 0x1DFE ... 0x1DFE, 0x20D0 ... 0x20D1, 0x20D4 ... 0x20D7, 0x20DB ... 0x20DC,
            0x20E1 ... 0x20E1, 0x20E7 ... 0x20E7, 0x20E9 ... 0x20E9, 0x20F0 ... 0x20F0, 0x2CEF ... 0x2CF1,
            0x2DE0 ... 0x2DFF, 0xA66F ... 0xA66F, 0xA67C ... 0xA67D, 0xA6F0 ... 0xA6F1, 0xA8E0 ... 0xA8F1,
            0xAAB0 ... 0xAAB0, 0xAAB2 ... 0xAAB3, 0xAAB7 ... 0xAAB8, 0xAABE ... 0xAABF, 0xAAC1 ... 0xAAC1,
            0xFE20 ... 0xFE26, 0x10A0F ... 0x10A0F, 0x10A38 ... 0x10A38, 0x1D185 ... 0x1D189,
            0x1D1AA ... 0x1D1AD, 0x1D242 ... 0x1D244,
        ]
        return ranges.flatMap { Array($0) }
    }()

    private static let diacriticIndex: [UInt32: Int] = Dictionary(uniqueKeysWithValues: diacritics.enumerated().map { ($1, $0) })

    /// A virtual placement (`U=1`): which stored image, and how many cells it spans.
    public struct Virtual: Equatable, Sendable {
        public var textureID: Int
        public var cols: Int
        public var rows: Int
    }

    /// The image quads the placeholder cells of `grid` draw. `virtuals` maps Kitty image ids
    /// to their virtual placements; `textureID` becomes the quad's (negative) image id.
    public static func placements(in grid: TerminalGridSnapshot, virtuals: [Int: Virtual]) -> [ImagePlacementSnapshot] {
        guard !virtuals.isEmpty else { return [] }
        var out: [ImagePlacementSnapshot] = []
        for row in 0 ..< grid.rows {
            var previous: (id: Int, imageRow: Int, imageCol: Int)?
            var run: (start: Int, id: Int, imageRow: Int, firstCol: Int, count: Int)?
            func flush() {
                guard let current = run, let placement = virtuals[current.id] else { run = nil; return }
                let cols = Double(max(placement.cols, 1)), rows = Double(max(placement.rows, 1))
                out.append(ImagePlacementSnapshot(
                    id: -placement.textureID, row: row, col: current.start, cols: current.count, rows: 1, z: 0,
                    sourceX: Double(current.firstCol) / cols, sourceY: Double(current.imageRow) / rows,
                    sourceWidth: Double(current.count) / cols, sourceHeight: 1 / rows
                ))
                run = nil
            }
            for col in 0 ..< grid.cols {
                let cell = grid.cells[row * grid.cols + col]
                guard cell.codepoint == character, let id = imageID(cell.foreground) else {
                    flush(); previous = nil; continue
                }
                let marks = [cell.combining0, cell.combining1].map { $0 == 0 ? nil : diacriticIndex[$0] }
                var imageRow: Int, imageCol: Int
                if let r = marks[0] {
                    imageRow = r
                    imageCol = marks[1] ?? (previous.map { $0.id == id && $0.imageRow == r ? $0.imageCol + 1 : 0 } ?? 0)
                } else if let previous, previous.id == id {
                    (imageRow, imageCol) = (previous.imageRow, previous.imageCol + 1)
                } else {
                    (imageRow, imageCol) = (0, 0)
                }
                if let current = run, current.id == id, current.imageRow == imageRow,
                   current.firstCol + current.count == imageCol, current.start + current.count == col {
                    run?.count += 1
                } else {
                    flush()
                    run = (col, id, imageRow, imageCol, 1)
                }
                previous = (id, imageRow, imageCol)
            }
            flush()
        }
        return out
    }

    /// The image id a placeholder's foreground encodes: 24-bit color, or a 256-color index.
    static func imageID(_ color: TerminalGridColor) -> Int? {
        switch color {
        case let .rgb(r, g, b): return Int(r) << 16 | Int(g) << 8 | Int(b)
        case let .palette(index): return Int(index)
        case .none: return nil
        }
    }
}
