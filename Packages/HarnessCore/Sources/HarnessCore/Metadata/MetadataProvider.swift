import Foundation

public protocol MetadataProvider: Sendable {
    func refresh(tab: Tab) -> Tab
}

public struct GitMetadataProvider: MetadataProvider {
    public init() {}

    /// Reads the branch in-process via `GitHEADReader` — no `git` subprocess, no
    /// `waitUntilExit()` that can wedge a refresh loop on a hung filesystem.
    public func refresh(tab: Tab) -> Tab {
        var updated = tab
        updated.gitBranch = GitHEADReader.currentBranch(at: tab.cwd)
        return updated
    }
}

public struct CwdMetadataProvider: MetadataProvider {
    public init() {}

    public func refresh(tab: Tab) -> Tab {
        tab
    }
}
