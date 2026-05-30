import HarnessTerminalEngine

/// Retroactive `CopyModeGridSource` conformances declared here (the module that owns the
/// protocol) so the engine stays dependency-free. Both surfaces — the GUI's live emulator and
/// the compositor's headless grid terminal — back the *same* reducer.

extension TerminalEmulator: CopyModeGridSource {
    public var totalLines: Int { bufferLineCount }
    public var viewportRows: Int { rows }
    public var columns: Int { cols }
    public func line(_ index: Int) -> [TerminalGridCell] { bufferLine(index) }
}

extension HarnessGridTerminal: CopyModeGridSource {
    public var totalLines: Int { bufferLineCount }
    public var viewportRows: Int { rowCount }
    // `columns` is already a member of HarnessGridTerminal and satisfies the requirement.
    public func line(_ index: Int) -> [TerminalGridCell] { bufferLine(index) }
}
