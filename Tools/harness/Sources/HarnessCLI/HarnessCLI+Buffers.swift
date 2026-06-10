import Foundation
import HarnessCore

/// Paste-buffer subcommands (set/list/show/delete/paste/save/load). Mechanically
/// extracted from `HarnessCLI.swift` (PR-32): zero logic change.
extension HarnessCLI {
    static func handleSetBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        let data: Data
        if let inline = flagValue(args, flag: "--data") {
            data = Data(inline.utf8)
        } else if args.contains("--stdin") {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            fputs("Usage: harness-cli set-buffer (--data <text> | --stdin) [--name <name>]\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .setBuffer(name: name, data: data))
        if case let .text(final) = response { print(final) }
    }

    static func handleListBuffers(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .listBuffers)
        guard case let .buffers(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                print("\(item.name)\t\(item.byteCount)B\t\(item.preview)")
            }
        }
    }

    static func handleShowBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        let response = try checkedRequest(client, .getBuffer(name: name))
        guard case let .buffer(summary) = response, let data = summary.data else {
            throw DaemonClientError.unexpectedResponse
        }
        FileHandle.standardOutput.write(data)
    }

    static func handleDeleteBuffer(_ args: [String], client: DaemonClient) throws {
        guard let name = flagValue(args, flag: "--name") else {
            fputs("Usage: harness-cli delete-buffer --name <name>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .deleteBuffer(name: name))
    }

    static func handlePasteBuffer(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli paste-buffer --surface <id> [--name <name>] [-p|--bracketed]\n", harnessStderr)
            exit(1)
        }
        let name = flagValue(args, flag: "--name")
        let bracketed = args.contains("-p") || args.contains("--bracketed")
        _ = try checkedRequest(client, .pasteBuffer(surfaceID: surface, name: name, bracketed: bracketed))
    }

    /// `save-buffer [--name <name>] <path>` — write a paste buffer to a file (file
    /// I/O is client-side; the buffer data comes over IPC).
    static func handleSaveBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        guard let path = flagValue(args, flag: "--file") ?? positionalArgs(args, skippingValuesFor: ["--name", "--file"]).first else {
            fputs("Usage: harness-cli save-buffer [--name <name>] <path>\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .getBuffer(name: name))
        guard case let .buffer(summary) = response, let data = summary.data else {
            throw DaemonClientError.unexpectedResponse
        }
        let expanded = (path as NSString).expandingTildeInPath
        // Canonicalize via URL to resolve symlinks, remove redundant separators, and collapse
        // any '.'/'..' components left after tilde expansion. Reject paths that still contain
        // '..' after standardization — a traversal-by-confusion attempt (e.g. "~/../../../etc").
        // We do NOT restrict to the home directory: users may legitimately save anywhere; we
        // only neutralize confusing relative-prefix tricks.
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard !canonical.components(separatedBy: "/").contains("..") else {
            fputs("harness-cli save-buffer: path contains '..' after expansion — refusing\n", harnessStderr)
            exit(1)
        }
        try data.write(to: URL(fileURLWithPath: canonical))
    }

    /// `load-buffer [--name <name>] <path>` — read a file into a new paste buffer.
    static func handleLoadBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        guard let path = flagValue(args, flag: "--file") ?? positionalArgs(args, skippingValuesFor: ["--name", "--file"]).first else {
            fputs("Usage: harness-cli load-buffer [--name <name>] <path>\n", harnessStderr)
            exit(1)
        }
        let expanded = (path as NSString).expandingTildeInPath
        // Same canonicalization and traversal guard as save-buffer (see comment there).
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard !canonical.components(separatedBy: "/").contains("..") else {
            fputs("harness-cli load-buffer: path contains '..' after expansion — refusing\n", harnessStderr)
            exit(1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: canonical))
        let response = try checkedRequest(client, .setBuffer(name: name, data: data))
        if case let .text(final) = response { print(final) }
    }
}
