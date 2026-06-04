import Foundation

/// Column width of a Unicode scalar, à la POSIX `wcwidth`:
/// `0` = zero-width (combining marks, control, ZWJ/format), `1` = normal, `2` = wide.
///
/// This is a pragmatic implementation covering the ranges that matter for terminal
/// layout (CJK ideographs, Hangul, fullwidth forms, common emoji blocks, combining
/// marks). It is intentionally data-driven and isolated so it can be unit-tested in
/// isolation and refined against a generated corpus without touching the parser.
///
/// NOTE (Phase 1): emoji ZWJ-sequence collapsing and variation-selector presentation
/// are handled at the grapheme layer in the screen model; this function reports the
/// width of a single scalar. Ranges here track Unicode 15-era East Asian Width = W/F.
///
/// ## Lookup strategy (hot path)
/// `width(of:)` is on the per-scalar print path, so it must be O(1), not a linear range scan.
/// Three tiers, fastest first:
/// 1. `scalar < 0x300` — ASCII, Latin-1, and everything below the first combining block: a single
///    range check yields zero-width controls vs. single-width text (covers `é`/`café`/`résumé`).
/// 2. BMP (`≤ 0xFFFF`) — a generated two-stage trie (`CharacterWidthTable`): 256-block index → a
///    deduped 2-bits-per-cell block. ~4 loads + bit ops.
/// 3. Astral — a binary search over the few maximal non-width-1 runs.
///
/// The generated `CharacterWidthTable` is produced by `Scripts/generate-width-table.swift` from the
/// canonical ranges below and proven byte-identical to `referenceWidth` over every scalar by
/// `CharacterWidthTests`. The canonical ranges + `referenceWidth` remain the single source of truth.
public enum CharacterWidth {
    /// Returns 0, 1, or 2 for the given scalar value.
    @inline(__always)
    public static func width(of scalar: UInt32) -> Int {
        // Tier 1 — ASCII / Latin-1 / pre-combining fast path. Below the first zero-width block
        // (0x0300) and the first wide block (0x1100), the only non-single-width scalars are the
        // C0/DEL/C1 controls, which the screen model executes rather than draws.
        if scalar < 0x300 {
            if scalar < 0x20 || (scalar >= 0x7F && scalar < 0xA0) { return 0 }
            return 1
        }
        // Tier 2 — BMP two-stage trie.
        if scalar <= 0xFFFF {
            let hi = Int(scalar >> 8)
            let base = Int(CharacterWidthTable.stage1[hi]) * CharacterWidthTable.blockBytes
            let lo = Int(scalar & 0xFF)
            let packed = CharacterWidthTable.stage2[base + (lo >> 2)]
            return Int((packed >> UInt8((lo & 3) << 1)) & 0x3)
        }
        // Tier 3 — astral binary search.
        return astralWidth(scalar)
    }

    /// Convenience for `Unicode.Scalar`.
    @inline(__always)
    public static func width(of scalar: Unicode.Scalar) -> Int {
        width(of: scalar.value)
    }

    /// Binary search the (sorted, non-overlapping) astral runs where width ≠ 1.
    private static func astralWidth(_ cp: UInt32) -> Int {
        let lo = CharacterWidthTable.astralLo
        let hi = CharacterWidthTable.astralHi
        var low = 0
        var high = lo.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            if cp < lo[mid] {
                high = mid - 1
            } else if cp > hi[mid] {
                low = mid + 1
            } else {
                return Int(CharacterWidthTable.astralCode[mid])
            }
        }
        return 1
    }

    // MARK: - Reference (canonical) implementation — the single source of truth.
    //
    // The fast `width(of:)` above is a generated table proven equivalent to this function for every
    // scalar by `CharacterWidthTests`. Edit the ranges here, then re-run
    // `Scripts/generate-width-table.swift`; the parity test fails until the table is regenerated.

    /// Canonical width via linear range scan — the oracle the generated table is verified against.
    static func referenceWidth(of cp: UInt32) -> Int {
        if cp == 0 { return 0 }
        if cp < 0x20 || (cp >= 0x7F && cp < 0xA0) { return 0 }
        if isZeroWidth(cp) { return 0 }
        if isWide(cp) { return 2 }
        return 1
    }

    private static func isZeroWidth(_ cp: UInt32) -> Bool {
        for range in zeroWidthRanges where range.contains(cp) { return true }
        return false
    }

    private static func isWide(_ cp: UInt32) -> Bool {
        for range in wideRanges where range.contains(cp) { return true }
        return false
    }

    /// Combining marks and zero-width format characters. Sorted, non-overlapping.
    static let zeroWidthRanges: [ClosedRange<UInt32>] = [
        0x0300 ... 0x036F, // Combining Diacritical Marks
        0x0483 ... 0x0489,
        0x0591 ... 0x05BD,
        0x0610 ... 0x061A,
        0x064B ... 0x065F,
        0x0670 ... 0x0670,
        0x06D6 ... 0x06DC,
        0x06DF ... 0x06E4,
        0x0900 ... 0x0902,
        0x093C ... 0x093C,
        0x0941 ... 0x0948,
        0x0E31 ... 0x0E31,
        0x0E34 ... 0x0E3A,
        0x0E47 ... 0x0E4E, // Thai: MAITAIKHU, MAI EK/THO/TRI/CHATTAWA, THANTHAKHAT, NIKHAHIT, YAMAKKAN
        0x1AB0 ... 0x1AFF, // Combining Diacritical Marks Extended
        0x1DC0 ... 0x1DFF, // Combining Diacritical Marks Supplement
        0x200B ... 0x200F, // ZWSP, ZWNJ, ZWJ, LRM/RLM
        0x2028 ... 0x202E, // line/para separators + bidi
        0x2060 ... 0x2064, // word joiner / invisible operators
        0x20D0 ... 0x20FF, // Combining Diacritical Marks for Symbols
        0xFE00 ... 0xFE0F, // Variation Selectors
        0xFE20 ... 0xFE2F, // Combining Half Marks
        0xFEFF ... 0xFEFF, // BOM / zero-width no-break space
        0xE0100 ... 0xE01EF, // Variation Selectors Supplement
    ]

    /// East Asian Wide / Fullwidth ranges. Sorted, non-overlapping.
    static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100 ... 0x115F, // Hangul Jamo
        0x2329 ... 0x232A, // angle brackets
        0x2E80 ... 0x303E, // CJK Radicals … Kangxi … CJK Symbols
        0x3041 ... 0x33FF, // Hiragana … Katakana … CJK Compatibility
        0x3400 ... 0x4DBF, // CJK Ext A
        0x4E00 ... 0x9FFF, // CJK Unified Ideographs
        0xA000 ... 0xA4CF, // Yi
        0xAC00 ... 0xD7A3, // Hangul Syllables
        0xF900 ... 0xFAFF, // CJK Compatibility Ideographs
        0xFE10 ... 0xFE19, // Vertical forms
        0xFE30 ... 0xFE6F, // CJK Compatibility Forms / Small Form Variants
        0xFF00 ... 0xFF60, // Fullwidth Forms
        0xFFE0 ... 0xFFE6, // Fullwidth signs
        0x1F300 ... 0x1F64F, // Misc Symbols and Pictographs + Emoticons
        0x1F900 ... 0x1F9FF, // Supplemental Symbols and Pictographs
        0x20000 ... 0x2FFFD, // CJK Ext B–F
        0x30000 ... 0x3FFFD, // CJK Ext G
    ]
}
