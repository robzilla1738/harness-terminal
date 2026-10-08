import Foundation

/// sRGB color used by chrome contrast checks. The app palette and the tests both
/// resolve through this so a pill or a label cannot drift onto a hardcoded hex.
public struct ChromeColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Rec. 709 perceived brightness, matching the chrome dark/light split.
    public var perceivedBrightness: Double {
        red * 0.299 + green * 0.587 + blue * 0.114
    }

    public var relativeLuminance: Double {
        func channel(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public func contrastRatio(against other: ChromeColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public func mixed(toward other: ChromeColor, fraction: Double) -> ChromeColor {
        let amount = min(max(fraction, 0), 1)
        return ChromeColor(
            red: red * (1 - amount) + other.red * amount,
            green: green * (1 - amount) + other.green * amount,
            blue: blue * (1 - amount) + other.blue * amount
        )
    }
}

public enum ChromeContrast {
    public static let textMinimum = 4.5
    public static let pillMinimum = 3.0

    public static func meetsText(_ foreground: ChromeColor, on surface: ChromeColor) -> Bool {
        foreground.contrastRatio(against: surface) >= textMinimum
    }

    public static func meetsPill(_ label: ChromeColor, on fill: ChromeColor) -> Bool {
        label.contrastRatio(against: fill) >= pillMinimum
    }
}

/// Resolved chrome colors for one canvas. Views paint these; they do not invent a second palette.
public struct ChromePaletteSpec: Equatable, Sendable {
    public var isDark: Bool
    public var surface: ChromeColor
    public var textPrimary: ChromeColor
    public var activePillFill: ChromeColor
    public var activePillLabel: ChromeColor

    public static func resolve(backgroundHex: String, foregroundHex: String) -> ChromePaletteSpec {
        let surface = ChromeColor(hex: backgroundHex) ?? ChromeColor(red: 0, green: 0, blue: 0)
        let authored = ChromeColor(hex: foregroundHex) ?? ChromeColor(red: 1, green: 1, blue: 1)
        let isDark = surface.perceivedBrightness < 0.5
        let text = readableText(authored: authored, on: surface, isDark: isDark)
        let pillFill = pillFill(surface: surface, label: text)
        return ChromePaletteSpec(
            isDark: isDark,
            surface: surface,
            textPrimary: text,
            activePillFill: pillFill,
            activePillLabel: text
        )
    }

    /// A visible lift off the surface that still clears the pill contrast floor.
    /// Light surfaces use a lighter lift so a selected row is a quiet pill, not a gray slab.
    private static func pillFill(surface: ChromeColor, label: ChromeColor) -> ChromeColor {
        var fraction = surface.perceivedBrightness >= 0.5 ? 0.07 : 0.14
        var candidate = surface.mixed(toward: label, fraction: fraction)
        if ChromeContrast.meetsPill(label, on: candidate) { return candidate }
        while fraction > 0.02 {
            fraction -= 0.02
            candidate = surface.mixed(toward: label, fraction: fraction)
            if ChromeContrast.meetsPill(label, on: candidate) { return candidate }
        }
        return surface
    }

    private static func readableText(authored: ChromeColor, on surface: ChromeColor, isDark: Bool) -> ChromeColor {
        if ChromeContrast.meetsText(authored, on: surface) { return authored }
        let lightInk = ChromeColor(red: 1, green: 1, blue: 1)
        let darkInk = ChromeColor(hex: "#1D1D1F") ?? ChromeColor(red: 0.11, green: 0.11, blue: 0.12)
        let preferred = isDark ? lightInk : darkInk
        if ChromeContrast.meetsText(preferred, on: surface) { return preferred }
        return lightInk.contrastRatio(against: surface) >= darkInk.contrastRatio(against: surface) ? lightInk : darkInk
    }
}

/// What a single pane is showing, for its header. A lone pane uses the tab's fields; a
/// split pane uses its own leaf (the tab's fields follow whichever pane is focused).
public struct PaneIdentity: Equatable, Sendable {
    public var directory: String
    public var program: String?
    public var agent: AgentKind?

    public static func of(leaf: PaneLeaf, in tab: Tab) -> PaneIdentity {
        let leaves = tab.rootPane.allLeaves()
        let isActive = leaf.id == (tab.activePaneID ?? leaves.first?.id)
        if leaves.count == 1 {
            return PaneIdentity(
                directory: leaf.cwd ?? tab.cwd,
                program: leaf.command ?? tab.currentCommand,
                agent: tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title)
            )
        }
        let program = leaf.command ?? (isActive ? tab.currentCommand : nil)
        let byCommand = program.flatMap { command in
            AgentKind.allCases.first { $0 != .generic && $0.commandToken == command }
        }
        return PaneIdentity(
            directory: leaf.cwd ?? tab.cwd,
            program: program,
            agent: byCommand ?? (isActive ? tab.agent?.kind : nil)
        )
    }

    /// Something other than a shell is running there (an editor, a build, an agent): closing
    /// it should ask first. A shell at its prompt closes without asking.
    public var isBusy: Bool {
        if agent != nil { return true }
        guard let program, !program.isEmpty else { return false }
        return !SurfaceIdentity.isShell(program)
    }
}

/// One identity line for tabs, sidebar rows, pane headers, and the session switcher.
public enum SurfaceIdentity {
    public static func label(directory: String, program: String?, agent: String? = nil) -> String {
        let directoryName = displayDirectory(directory)
        let base = directoryName.isEmpty ? "Terminal" : directoryName
        guard let name = foregroundName(command: program, agent: agent) else { return base }
        return "\(base) › \(name)"
    }

    /// A process title Claude and similar tools publish is often a version (`2.1.291`).
    /// The login shell (`fish`, `zsh`) is the prompt, not a program in that directory.
    /// Prefer a real command, then the agent name.
    public static func foregroundName(command: String?, agent: String?) -> String? {
        if let command = usableProgram(command), !isRuntimeHost(command), !isShell(command) {
            return command
        }
        if let agent = usableProgram(agent), !isShell(agent) { return agent }
        return nil
    }

    public static func usableProgram(_ program: String?) -> String? {
        let trimmed = program?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !isVersionToken(trimmed) else { return nil }
        return trimmed
    }

    /// `~/Code/harness` under the home directory, `~` for home itself, otherwise the last component.
    public static func displayDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed == "/" { return "/" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed == home { return "~" }
        if trimmed.hasPrefix(home + "/") {
            return "~/" + trimmed.dropFirst(home.count + 1)
        }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    private static func isVersionToken(_ value: String) -> Bool {
        var core = value
        if core.first == "v" || core.first == "V" { core.removeFirst() }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy(\.isNumber) }
    }

    private static func isRuntimeHost(_ name: String) -> Bool {
        ["node", "nodejs", "python", "python3", "ruby", "perl", "java", "deno", "bun"]
            .contains(name.lowercased())
    }

    public static func isShell(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent.lowercased()
        return ["fish", "zsh", "bash", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh"]
            .contains(base)
    }
}

/// Paint-time material. Light canvases may firm up opacity so type stays readable.
/// The stored settings opacity and blur are never rewritten here.
public enum ChromeMaterial {
    public static let lightPaintOpacityFloor: Float = 0.94

    public static func paintOpacity(
        stored: Float,
        appearanceMode: HarnessAppearanceMode,
        systemAppearance: HarnessSystemAppearance
    ) -> Float {
        let storedClamped = min(max(stored, 0), 1)
        let firmsUp = appearanceMode == .light
            || (appearanceMode == .macOSSystem && systemAppearance == .light)
        guard firmsUp else { return storedClamped }
        return min(max(storedClamped, lightPaintOpacityFloor), 1)
    }

    /// Alpha of the pane header only. The header has no metal drawable behind it, so it
    /// tints once at the paint opacity. Default 0.63 and the light floor stay a tint.
    public static func headerFillAlpha(
        stored: Float,
        appearanceMode: HarnessAppearanceMode,
        systemAppearance: HarnessSystemAppearance
    ) -> Float {
        paintOpacity(stored: stored, appearanceMode: appearanceMode, systemAppearance: systemAppearance)
    }

    public static func headerFillIsClear(
        stored: Float,
        appearanceMode: HarnessAppearanceMode,
        systemAppearance: HarnessSystemAppearance
    ) -> Bool {
        headerFillAlpha(stored: stored, appearanceMode: appearanceMode, systemAppearance: systemAppearance) <= 0
    }

    /// Alpha of the island layer behind the metal surface. The drawable already
    /// composites the canvas at `paintOpacity`. A second tint at that alpha would
    /// source-over (0.63 becomes ~0.86, 0.94 becomes ~1), so this layer stays clear.
    public static func backdropFillAlpha(
        stored _: Float,
        appearanceMode _: HarnessAppearanceMode,
        systemAppearance _: HarnessSystemAppearance
    ) -> Float {
        0
    }
}

/// Tab and split geometry shared by the chrome views and the tests.
public struct IslandChrome: Equatable, Sendable {
    public var margin: Double
    public var cornerRadius: Double
}

/// Lengths along a split. `first + thickness + second` equals the length passed
/// to `ChromeLayout.tiledSplit` when thickness is non-negative.
public struct TiledSplit: Equatable, Sendable {
    public var first: Double
    public var secondOrigin: Double
    public var second: Double

    public init(first: Double, secondOrigin: Double, second: Double) {
        self.first = first
        self.secondOrigin = secondOrigin
        self.second = second
    }
}

/// The gap around a terminal card. All four edges are the same value, so the
/// space under the tab matches the left, right, and bottom.
public struct CardInsets: Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double
}

public enum ChromeLayout {
    /// A tab hugs its label. It does not stretch out to `max` and leave an empty pill.
    public static func huggedPillWidth(
        labelWidth: Double,
        accessoryWidth: Double,
        min: Double,
        max: Double
    ) -> Double {
        let natural = labelWidth + accessoryWidth
        let lower = Swift.min(min, max)
        let upper = Swift.max(min, max)
        return Swift.min(upper, Swift.max(lower, natural))
    }

    /// Two panes that together cover `length`, with `thickness` between them.
    /// A thickness of 0 still fills the length. The first pane gets `ratio` of
    /// the free length (0...1). A non-finite ratio is half.
    public static func tiledSplit(length: Double, thickness: Double, ratio: Double) -> TiledSplit {
        let gap = max(0, thickness)
        let available = max(0, length - gap)
        let share = ratio.isFinite ? min(1, max(0, ratio)) : 0.5
        let first = available * share
        return TiledSplit(first: first, secondOrigin: first + gap, second: available - first)
    }

    /// Space between two islands, and between an island and the window edge.
    public static let islandGap = 8.0

    /// Comfortable density makes every pane, a lone one included, an inset card. Each
    /// island takes half the gap on every side and the container pads by the other half
    /// (see `containerPadding`), so the edge gap and the gap between panes are the same.
    /// Compact panes stay flush.
    public static func cardInsets(separated: Bool) -> CardInsets {
        let half = separated ? islandGap / 2 : 0
        return CardInsets(top: half, leading: half, bottom: half, trailing: half)
    }

    /// The pane container's own padding. No top padding under the tab row, which already
    /// leaves room; with no tab row above (sidebar mode) the top matches the other sides.
    public static func containerPadding(separated: Bool, padsTop: Bool = false) -> CardInsets {
        let half = separated ? islandGap / 2 : 0
        return CardInsets(top: padsTop ? half : 0, leading: half, bottom: half, trailing: half)
    }

    /// Space from the window top to the tab pill, and from the pill to the card border.
    public static func gapAroundTab(tabBarHeight: Double, pillHeight: Double, cardTopInset: Double) -> (above: Double, below: Double) {
        let pad = max(0, (tabBarHeight - pillHeight) / 2)
        return (pad, pad + cardTopInset)
    }

    public static func island(separated: Bool, splitRadius: Double) -> IslandChrome {
        IslandChrome(
            margin: cardInsets(separated: separated).top,
            cornerRadius: separated ? splitRadius : 0
        )
    }

    /// Indices `i` that get a rule between visible pill `i` and `i + 1`. No rule touches the
    /// active pill (it has a border) or the hovered one (it has a fill).
    public static func dividerSlots(count: Int, activeIndex: Int?, hoveredIndex: Int?) -> [Int] {
        guard count > 1 else { return [] }
        let skip = Set([activeIndex, hoveredIndex].compactMap { $0 })
        return (0 ..< count - 1).filter { !skip.contains($0) && !skip.contains($0 + 1) }
    }

    /// Left edge of a variable-width tab slot, before the bar's own leading inset.
    public static func slotOrigin(index: Int, widths: [Double], spacing: Double) -> Double {
        guard index > 0, !widths.isEmpty else { return 0 }
        let count = min(index, widths.count)
        return widths.prefix(count).reduce(0, +) + spacing * Double(count)
    }

    /// Nearest slot for a drag whose left edge is `leadingX` into variable-width pills.
    public static func dragTargetSlot(leadingX: Double, widths: [Double], spacing: Double) -> Int {
        guard !widths.isEmpty else { return 0 }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for index in widths.indices {
            let distance = abs(leadingX - slotOrigin(index: index, widths: widths, spacing: spacing))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
