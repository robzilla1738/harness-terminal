import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension SurfaceRegistry {
    func searchPaths(surfaceID: String, path: String?, query: String, project: Bool, cancelled: FlagBox) -> IPCResponse {
        guard query.count <= 256 else { return .error("Use a search of 256 characters or fewer.") }
        lock.lock()
        let pty = sessions[surfaceID]
        lock.unlock()
        guard let pty else { return .error("The source pane has closed.") }
        let root = PaneDirectory.root(cwd: pty.currentWorkingDirectory() ?? "/", path: path)
        do {
            let entries: [PaneDirEntry]
            let searchRoot: String
            if project {
                if let gitRoot = try gitPaths(["-C", root, "rev-parse", "--show-toplevel"], cancelled: cancelled) {
                    searchRoot = String(decoding: gitRoot, as: UTF8.self).trimmingCharacters(in: .newlines)
                    guard let files = try gitPaths(["-C", searchRoot, "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cancelled: cancelled) else {
                        return .error("Could not enumerate project files.")
                    }
                    let filesAndPaths = Set(String(decoding: files, as: UTF8.self).split(separator: "\0").map(String.init)).sorted().map {
                        PaneDirEntry(name: $0, path: (searchRoot as NSString).appendingPathComponent($0), directory: false)
                    }
                    var directories: Set<String> = []
                    for entry in filesAndPaths {
                        var parent = (entry.name as NSString).deletingLastPathComponent
                        while !parent.isEmpty, parent != "." {
                            directories.insert(parent)
                            parent = (parent as NSString).deletingLastPathComponent
                        }
                    }
                    entries = filesAndPaths + directories.map {
                        PaneDirEntry(name: $0, path: (searchRoot as NSString).appendingPathComponent($0), directory: true)
                    }
                } else {
                    searchRoot = root
                    entries = try walkPaths(root: root, cancelled: cancelled)
                }
            } else {
                searchRoot = root
                let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [])
                guard urls.count <= 20_000 else { return .error("This folder is too large. Choose a smaller folder.") }
                entries = try urls.map { url in
                    PaneDirEntry(name: url.lastPathComponent, path: url.path, directory: try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
                }
            }
            guard !cancelled.read() else { return .error("Search cancelled") }
            let ranked = PathSearch.ranked(entries, query: query)
            let listing = PaneDirListing(root: searchRoot, entries: Array(ranked.prefix(200)))
            return .text(String(decoding: try JSONEncoder().encode(listing), as: UTF8.self))
        } catch { return .error(error.localizedDescription) }
    }

    private func walkPaths(root: String, cancelled: FlagBox) throws -> [PaneDirEntry] {
        guard root != "/", root != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw SetupError.invalid("Choose a project folder before searching recursively.")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw SetupError.invalid("Could not open this project folder.")
        }
        var entries: [PaneDirEntry] = []
        let started = Date()
        for case let url as URL in walker {
            guard !cancelled.read() else { throw SetupError.invalid("Search cancelled") }
            guard entries.count < 20_000, Date().timeIntervalSince(started) < 5 else {
                throw SetupError.invalid("This folder is too large. Choose a smaller project folder.")
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values.isDirectory == true, ["node_modules", "vendor", "build"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            entries.append(PaneDirEntry(name: String(url.path.dropFirst(root.count + 1)), path: url.path, directory: values.isDirectory == true))
        }
        return entries
    }

    private func gitPaths(_ arguments: [String], cancelled: FlagBox) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let started = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler {
            if process.isRunning, cancelled.read() || Date().timeIntervalSince(started) > 5 {
                process.terminate()
                if Date().timeIntervalSince(started) > 6 { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        defer { timer.cancel() }
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count > 4 * 1024 * 1024 {
                process.terminate()
                process.waitUntilExit()
                throw SetupError.invalid("This project has too many paths. Choose a smaller folder.")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard !cancelled.read() else { throw SetupError.invalid("Search cancelled") }
        guard Date().timeIntervalSince(started) < 5 else { throw SetupError.invalid("Project file lookup timed out.") }
        return process.terminationStatus == 0 ? data : nil
    }
}
