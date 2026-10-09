import Foundation

/// Column width of a Unicode scalar, à la POSIX `wcwidth`:
/// `0` = zero-width (combining marks, control, ZWJ/format), `1` = normal, `2` = wide.
///
/// The generated ranges are derived from the Unicode Character Database (18.0.0):
///   wide  = East_Asian_Width ∈ {W, F} (UAX #11), plus the default-Wide unassigned gaps
///           inside the CJK ideograph blocks/planes (3400–4DBF, 4E00–9FFF, F900–FAFF,
///           20000–2FFFD, 30000–3FFFD), so future-assigned ideographs measure correctly.
///   zero  = General_Category ∈ {Mn, Me, Cf, Zl, Zp} for cp ≥ 0x0300.
/// This covers the emoji blocks `wcwidth` callers print constantly (⭐ ⚡ ✨ ❌ ✅ ⌚,
/// U+1F680–6FF transport, U+1F7E0+ colored shapes, U+1FA70+ extended pictographs) and the
/// full combining repertoire (Devanagari virama, Hebrew/Arabic/Syriac/Indic/Lao/Tibetan
/// marks, bidi isolates) — not just the hand-picked subset this table once held.
///
/// Deliberate deviations from raw UCD, chosen to match the engine's cell model:
///   - Everything below U+0300 is fixed by tier 1 (controls zero, the rest narrow) — so the
///     soft hyphen U+00AD stays width 1 (Ghostty/xterm behavior), never zero.
///   - Hangul conjoining jamo V/T (1160–11FF, D7B0–D7FF) stay width 1, NOT zero: the
///     engine's `attachCombining` folds only Grapheme_Extend scalars, so zero-width jamo
///     would be silently dropped (invisible vowels in NFD Korean). Width 1 keeps decomposed
///     Hangul legible until the grapheme layer composes syllables (Phase 3).
///   - Regional indicators (U+1F1E6–FF) are narrow as single scalars; flag pairing is a
///     grapheme-layer concern, matching Ghostty's per-scalar table.
///
/// Regenerate with `Scripts/generate-width-table.py` (see its header for the workflow);
/// `CharacterWidthTests` re-proves table ↔ reference parity over every scalar in CI.
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
/// `Scripts/generate-width-table.py` derives both ranges and packed lookup tables directly from
/// versioned, checksum-pinned Unicode files. Exhaustive tests compare the two lookup strategies.
public enum CharacterWidth {
    public static let unicodeVersion = CharacterWidthTable.unicodeVersion

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

    /// Keep new combining marks even when the host Swift/ICU Unicode database is older.
    static func isGraphemeExtend(_ scalar: UInt32) -> Bool {
        let ranges = CharacterWidthTable.graphemeExtendRanges
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = low + (high - low) / 2
            if scalar < ranges[mid].lowerBound { high = mid }
            else if scalar > ranges[mid].upperBound { low = mid + 1 }
            else { return true }
        }
        return false
    }

    /// Canonical width via linear range scan — the oracle the generated table is verified against.
    static func referenceWidth(of cp: UInt32) -> Int {
        if cp == 0 { return 0 }
        if cp < 0x20 || (cp >= 0x7F && cp < 0xA0) { return 0 }
        if isZeroWidth(cp) { return 0 }
        if isWide(cp) { return 2 }
        return 1
    }

    private static func isZeroWidth(_ cp: UInt32) -> Bool {
        for range in CharacterWidthTable.zeroWidthRanges where range.contains(cp) { return true }
        return false
    }

    private static func isWide(_ cp: UInt32) -> Bool {
        for range in CharacterWidthTable.wideRanges where range.contains(cp) { return true }
        return false
    }

}
