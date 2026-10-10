import Foundation

public extension SessionSnapshot {
    func projected(for capabilities: [String]) -> SessionSnapshot {
        var result = self
        for wi in result.workspaces.indices {
            for si in result.workspaces[wi].sessions.indices {
                for ti in result.workspaces[wi].sessions[si].tabs.indices {
                    var tab = result.workspaces[wi].sessions[si].tabs[ti]
                    if let kind = tab.agent?.kind { tab.agent?.kind = kind.projected(for: capabilities) }
                    tab.rootPane = tab.rootPane.agentProjection(for: capabilities)
                    if !capabilities.contains(DaemonStats.paneContent) { tab.rootPane = tab.rootPane.terminalProjection() }
                    result.workspaces[wi].sessions[si].tabs[ti] = tab
                }
            }
        }
        if !capabilities.contains(DaemonStats.paneContent) { result.library = result.library.terminalProjection() }
        return result
    }
}
public extension PaneNode {
    func terminalProjection() -> PaneNode {
        switch self {
        case var .leaf(leaf):
            if !leaf.paneContent.isTerminal {
                leaf.content = nil; leaf.shell = nil; leaf.command = "Preview unavailable in this client"
                leaf.activity = nil; leaf.lastAgentRunID = nil; leaf.resumeAutomatically = nil
            }
            return .leaf(leaf)
        case let .branch(direction, ratio, first, second):
            return .branch(direction: direction, ratio: ratio, first: first.terminalProjection(), second: second.terminalProjection())
        }
    }
}
public extension SessionLibrary {
    func terminalProjection() -> SessionLibrary {
        var result = self
        result.setups = setups.map { $0.terminalProjection() }
        for index in result.recentlyClosed.indices { result.recentlyClosed[index].setup = result.recentlyClosed[index].setup.terminalProjection() }
        return result
    }
}
public extension SavedSetup {
    var containsTypedContent: Bool { tabs.contains { $0.layout.panes.contains { !($0.content ?? .terminal).isTerminal } } }
    func terminalProjection() -> SavedSetup {
        var result = self
        for index in result.tabs.indices { result.tabs[index].layout = result.tabs[index].layout.terminalProjection() }
        return result
    }
}
private extension SetupLayout {
    func terminalProjection() -> SetupLayout {
        switch self {
        case var .pane(pane): pane.content = nil; return .pane(pane)
        case let .split(direction, ratio, first, second): return .split(direction: direction, ratio: ratio, first: first.terminalProjection(), second: second.terminalProjection())
        }
    }
}

public extension PaneNode {
    func agentProjection(for capabilities: [String]) -> PaneNode {
        switch self {
        case var .leaf(leaf):
            if let kind = leaf.activity?.agent?.kind { leaf.activity?.agent?.kind = kind.projected(for: capabilities) }
            leaf.workloadProvider = leaf.workloadProvider?.projected(for: capabilities)
            return .leaf(leaf)
        case let .branch(direction, ratio, first, second):
            return .branch(direction: direction, ratio: ratio, first: first.agentProjection(for: capabilities), second: second.agentProjection(for: capabilities))
        }
    }
}
