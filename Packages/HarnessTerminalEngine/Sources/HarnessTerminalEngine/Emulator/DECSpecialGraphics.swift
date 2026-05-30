import Foundation

/// The DEC Special Graphics character set (VT100 line-drawing). When `ESC ( 0` designates it
/// into GL, ASCII bytes `0x60`–`0x7E` print as box-drawing / symbol glyphs instead of letters —
/// how `tput`, `ncurses`, and many TUIs draw boxes and rules. The line-drawing codepoints land
/// in `U+2500`–`U+257F`, which the renderer already draws procedurally (seamless, font-
/// independent), so the translation alone makes them render correctly.
enum DECSpecialGraphics {
    /// Map one scalar through the table. Bytes outside `0x60`–`0x7E` pass through unchanged.
    static func map(_ scalar: UInt32) -> UInt32 {
        guard scalar >= 0x60, scalar <= 0x7E else { return scalar }
        return table[Int(scalar - 0x60)]
    }

    // Indexed by (scalar - 0x60), i.e. ``` ` ``` … `~`. Canonical VT100 mapping.
    private static let table: [UInt32] = [
        0x25C6, // ` diamond ◆
        0x2592, // a medium shade ▒
        0x2409, // b HT symbol ␉
        0x240C, // c FF symbol ␌
        0x240D, // d CR symbol ␍
        0x240A, // e LF symbol ␊
        0x00B0, // f degree °
        0x00B1, // g plus-minus ±
        0x2424, // h NL symbol ␤
        0x240B, // i VT symbol ␋
        0x2518, // j ┘
        0x2510, // k ┐
        0x250C, // l ┌
        0x2514, // m └
        0x253C, // n ┼
        0x23BA, // o scan line 1 ⎺
        0x23BB, // p scan line 3 ⎻
        0x2500, // q ─
        0x23BC, // r scan line 7 ⎼
        0x23BD, // s scan line 9 ⎽
        0x251C, // t ├
        0x2524, // u ┤
        0x2534, // v ┴
        0x252C, // w ┬
        0x2502, // x │
        0x2264, // y ≤
        0x2265, // z ≥
        0x03C0, // { pi π
        0x2260, // | not-equal ≠
        0x00A3, // } pound £
        0x00B7, // ~ middle dot ·
    ]
}
