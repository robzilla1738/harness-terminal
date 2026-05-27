import Foundation

public protocol MetadataProvider: Sendable {
    func refresh(tab: Tab) -> Tab
}

public struct GitMetadataProvider: MetadataProvider {
    public init() {}

    public func refresh(tab: Tab) -> Tab {
        var updated = tab
        updated.gitBranch = Self.currentBranch(at: tab.cwd)
        return updated
    }

    private static func currentBranch(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return branch?.isEmpty == false ? branch : nil
        } catch {
            return nil
        }
    }
}

public struct CwdMetadataProvider: MetadataProvider {
    public init() {}

    public func refresh(tab: Tab) -> Tab {
        tab
    }
}
