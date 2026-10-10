import Foundation
import HarnessCore

extension SurfaceRegistry {
    // Called with the registry lock held, just like the other layout operations.
    func handleLibrary(_ operation: LibraryOperation, capabilities: [String]) -> IPCResponse {
        do {
            let typed = capabilities.contains(DaemonStats.paneContent)
            if !typed {
                let setup: SavedSetup?
                switch operation {
                case let .capture(id, _): setup = editor.snapshot.workspaces.flatMap(\.sessions).first(where: { $0.id == id }).map { SavedSetup(name: $0.name, tabs: $0.tabs.map(SetupTab.init)) }
                case let .save(value, _): setup = editor.snapshot.library.setups.first(where: { $0.id == value.id && $0.containsTypedContent }) ?? value
                case let .open(id, _): setup = editor.snapshot.library.setups.first(where: { $0.id == id })
                case let .restoreClosed(id): setup = editor.snapshot.library.recentlyClosed.first(where: { $0.id == id })?.setup
                default: setup = nil
                }
                if setup?.containsTypedContent == true { throw PreviewError.unsupported }
            }
            switch operation {
            case .list:
                return .text(String(decoding: try JSONEncoder().encode(typed ? editor.snapshot.library : editor.snapshot.library.terminalProjection()), as: UTF8.self))
            case let .capture(sessionID, name):
                guard let session = editor.snapshot.workspaces.flatMap(\.sessions).first(where: { $0.id == sessionID }) else {
                    return .error("Session not found")
                }
                guard editor.snapshot.library.setups.count < 200 else { return .error("The setup library is full (200 setups).") }
                let setup = SavedSetup(name: name, tabs: session.tabs.map(SetupTab.init))
                try setup.validate()
                editor.snapshot.library.setups.append(setup)
                for wi in editor.snapshot.workspaces.indices {
                    if let si = editor.snapshot.workspaces[wi].sessions.firstIndex(where: { $0.id == sessionID }) {
                        editor.snapshot.workspaces[wi].sessions[si].originSetupID = setup.id
                        editor.snapshot.workspaces[wi].sessions[si].lastOpenedAt = Date()
                    }
                }
            case let .save(setup, sourceSessionID):
                try setup.validate()
                if let index = editor.snapshot.library.setups.firstIndex(where: { $0.id == setup.id }) {
                    editor.snapshot.library.setups[index] = setup
                } else {
                    guard editor.snapshot.library.setups.count < 200 else { return .error("The setup library is full (200 setups).") }
                    editor.snapshot.library.setups.append(setup)
                }
                if let sourceSessionID {
                    for wi in editor.snapshot.workspaces.indices {
                        if let si = editor.snapshot.workspaces[wi].sessions.firstIndex(where: { $0.id == sourceSessionID }) {
                            editor.snapshot.workspaces[wi].sessions[si].originSetupID = setup.id
                            editor.snapshot.workspaces[wi].sessions[si].lastOpenedAt = Date()
                        }
                    }
                }
            case let .deleteSetup(id):
                editor.snapshot.library.setups.removeAll { $0.id == id }
            case let .open(id, mode):
                guard let setup = editor.snapshot.library.setups.first(where: { $0.id == id }) else { return .error("Setup not found") }
                if mode == .existing,
                   let session = editor.snapshot.workspaces.flatMap(\.sessions)
                    .filter({ $0.originSetupID == id })
                    .max(by: { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }) {
                    for workspace in editor.snapshot.workspaces where workspace.sessions.contains(where: { $0.id == session.id }) {
                        _ = editor.selectSession(workspaceID: workspace.id, sessionID: session.id)
                        _ = editor.selectWorkspace(workspace.id)
                    }
                    commit()
                    return .sessionID(session.id)
                }
                return try openRecipe(setup, originSetupID: id)
            case let .restoreClosed(id):
                guard let closed = editor.snapshot.library.recentlyClosed.first(where: { $0.id == id }) else { return .error("Closed layout not found") }
                let result = try openRecipe(closed.setup, originSetupID: nil, appendTo: closed.kind == .session ? nil : closed.sessionID)
                // Even a partial launch leaves the restored layout available for repair.
                // Consuming the record prevents retry from duplicating the successful panes.
                editor.snapshot.library.recentlyClosed.removeAll { $0.id == id }
                libraryChanged()
                return result
            case let .deleteClosed(id):
                editor.snapshot.library.recentlyClosed.removeAll { id == nil || $0.id == id }
            }
            libraryChanged()
            return .ok
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func libraryChanged() {
        editor.snapshot.revision += 1
        editor.snapshot.savedAt = Date()
        commit()
    }

    private func openRecipe(_ setup: SavedSetup, originSetupID: UUID?, appendTo: SessionID? = nil) throws -> IPCResponse {
        try setup.validate()
        for pane in setup.tabs.flatMap({ $0.layout.panes }) where (pane.content ?? .terminal).isTerminal {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: pane.directory, isDirectory: &directory), directory.boolValue else {
                throw SetupError.invalid("Directory not found: \(pane.directory). Edit the setup before opening it.")
            }
            if let shell = pane.shell, !FileManager.default.isExecutableFile(atPath: shell) {
                throw SetupError.invalid("Shell is not executable: \(shell). Edit the setup before opening it.")
            }
        }
        let tabs = setup.tabs.enumerated().map { index, tab in
            Tab(title: tab.title, cwd: tab.layout.panes.first!.directory, rootPane: tab.layout.makePaneTree(), sortOrder: index)
        }
        let sessionID: SessionID
        if let appendTo, let wi = editor.snapshot.workspaces.firstIndex(where: { $0.sessions.contains(where: { $0.id == appendTo }) }),
           let si = editor.snapshot.workspaces[wi].sessions.firstIndex(where: { $0.id == appendTo }) {
            sessionID = appendTo
            let offset = editor.snapshot.workspaces[wi].sessions[si].tabs.count
            for (index, var tab) in tabs.enumerated() {
                tab.sortOrder = offset + index
                editor.snapshot.workspaces[wi].sessions[si].tabs.append(tab)
            }
            editor.snapshot.workspaces[wi].sessions[si].setActiveTab(tabs[0].id)
            editor.snapshot.workspaces[wi].activeSessionID = sessionID
            editor.snapshot.activeWorkspaceID = editor.snapshot.workspaces[wi].id
        } else {
            guard let wi = editor.snapshot.workspaces.firstIndex(where: { $0.id == editor.snapshot.activeWorkspaceID }) else {
                throw SetupError.invalid("No workspace is available.")
            }
            var session = SessionGroup(name: setup.name, tabs: tabs, sortOrder: editor.snapshot.workspaces[wi].sessions.count)
            session.originSetupID = originSetupID
            session.lastOpenedAt = Date()
            sessionID = session.id
            editor.snapshot.workspaces[wi].sessions.append(session)
            editor.snapshot.workspaces[wi].activeSessionID = session.id
        }
        if appendTo != nil { for tab in tabs { editor.propagateNewTabToGroup(tab.id) } }
        var failed: [String] = []
        for (tab, definition) in zip(tabs, setup.tabs) {
            for (leaf, pane) in zip(tab.rootPane.allLeaves(), definition.layout.panes) where leaf.paneContent.isTerminal {
                guard createOrEnsureSurface(surfaceID: leaf.surfaceID.uuidString, cwd: pane.directory, shell: pane.shell,
                                            rows: 24, cols: 80, scrollbackBytes: nil, freshlyCreated: true) != nil else {
                    failed.append(pane.directory)
                    continue
                }
            }
        }
        libraryChanged()
        guard failed.isEmpty else {
            return .error("The layout opened, but shells could not start in: \(failed.joined(separator: ", ")). No startup commands ran. Open the existing session to repair it; do not open a new copy.")
        }
        if originSetupID != nil {
            for (tab, definition) in zip(tabs, setup.tabs) {
                for (leaf, pane) in zip(tab.rootPane.allLeaves(), definition.layout.panes) where leaf.paneContent.isTerminal {
                    if let command = pane.startupCommand, !command.isEmpty {
                        sessions[leaf.surfaceID.uuidString]?.write(command + "\n")
                    }
                }
            }
        }
        return .sessionID(sessionID)
    }

    func recordClosed(_ kind: ClosedLayout.Kind, sessionID: SessionID, name: String, tabs: [Tab]) {
        guard !tabs.isEmpty else { return }
        let setup = SavedSetup(name: name.isEmpty ? "Terminal" : name, tabs: tabs.map(SetupTab.init))
        editor.snapshot.library.recentlyClosed.insert(ClosedLayout(kind: kind, sessionID: sessionID, setup: setup), at: 0)
        editor.snapshot.library.recentlyClosed = Array(editor.snapshot.library.recentlyClosed.prefix(20))
    }
}
