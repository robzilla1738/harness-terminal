import HarnessCore
import HarnessTerminalEngine

/// Display-width-aware measurement + clipping for the attach-window status band.
/// Terminal columns, not scalar counts: a wide (CJK) glyph occupies two cells and a combining
/// mark zero, so counting scalars overflowed the row (between-padding came up one column short
/// per wide glyph) and under-truncated `display-message`/`status-format` text. Mirrors the
/// display-width rule `GridCompositor.paintBorderLabel` already follows.
enum StatusLineWidth {
    /// Display width of `s` in terminal columns.
    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + CharacterWidth.width(of: $1) }
    }

    /// Total display width of styled segments.
    static func displayWidth(of segs: [StyledSegment]) -> Int {
        segs.reduce(0) { $0 + displayWidth($1.text) }
    }

    /// Truncate to `width` display columns; a wide glyph that would straddle the cut is dropped
    /// entirely rather than overflowing the row by its trailing cell.
    static func clip(_ string: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        var used = 0
        var out = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            let w = CharacterWidth.width(of: scalar)
            if used + w > width { break }
            used += w
            out.append(scalar)
        }
        return String(out)
    }

    /// Truncate styled segments to a total display `width`, cutting the last that overflows.
    static func clipSegments(_ segs: [StyledSegment], to width: Int) -> [StyledSegment] {
        var out: [StyledSegment] = []
        var used = 0
        for seg in segs {
            let count = displayWidth(seg.text)
            if used + count <= width { out.append(seg); used += count; continue }
            let remain = width - used
            if remain > 0 {
                var s = seg
                s.text = clip(seg.text, to: remain)
                out.append(s)
            }
            break
        }
        return out
    }
}
