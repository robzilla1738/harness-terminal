import Foundation

/// Finds a remote daemon's control socket over SSH, so adding a host doesn't mean typing a
/// path. Runs one non-interactive `ssh` that prints the first live socket it finds.
public enum RemoteSocketDetector {
    /// Remote script: `harness-cli socket-path` if it's on PATH, then the Linux and macOS
    /// defaults (`HarnessPaths`). Prints the first path that is a live socket; exits 3 if none.
    static let script = """
    for p in "$(harness-cli socket-path 2>/dev/null)" \
      "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/harness/harness.sock}" \
      "${XDG_DATA_HOME:-$HOME/.local/share}/harness/harness.sock" \
      "$HOME/Library/Application Support/Harness/harness.sock"; do
      [ -n "$p" ] && [ -S "$p" ] && { printf '%s\\n' "$p"; exit 0; }
    done
    exit 3
    """

    /// `ssh` argv (without the executable) for the probe. Throws on an unsafe target or args.
    public static func sshArguments(target: String, sshArgs: [String]) throws -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            + (try SSHTunnelManager.validatedUserSSHArgs(sshArgs))
            + [try SSHTunnelManager.validatedSSHTarget(target), "sh -c " + ControlPlane.shellQuote(script)]
    }

    /// The socket path from the probe's stdout: its last absolute-path line.
    public static func parse(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noDaemon
        case ssh(String)

        public var description: String {
            switch self {
            case .noDaemon:
                return "Connected, but no running Harness daemon was found. Start HarnessDaemon there (Scripts/install-linux.sh on Linux) and try again."
            case let .ssh(reason): return reason
            }
        }
    }

    /// Blocking: runs the probe and returns the socket path. Call off the main thread.
    public static func detect(target: String, sshArgs: [String], cancelled: () -> Bool = { false }) throws -> String {
        let result = try ProcessCapture.run(
            URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: try sshArguments(target: target, sshArgs: sshArgs), timeout: 12, maxOutputBytes: 1_048_576, cancelled: cancelled
        )
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        if result.status == 0, let path = parse(stdout) { return path }
        if result.status == 3 { throw Failure.noDaemon }
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        throw Failure.ssh(SSHTunnelManager.diagnose(stderr)
            ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "ssh exited with status \(result.status)")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The Add Remote Host form's fields, before they become a `RemoteHost`.
public struct RemoteHostDraft: Equatable, Sendable {
    public var name: String
    public var target: String
    public var options: String
    public var socket: String

    public init(name: String, target: String, options: String, socket: String) {
        self.name = name
        self.target = target
        self.options = options
        self.socket = socket
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedSocket: String { socket.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var sshArgs: [String] { options.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// A saveable host, or nil when a field is missing or ssh would refuse the target/options.
    public var host: RemoteHost? {
        let host = RemoteHost(name: trimmedName, sshTarget: trimmedTarget, remoteSocketPath: trimmedSocket, sshArgs: sshArgs)
        guard !host.name.isEmpty, host.remoteSocketPath.hasPrefix("/"),
              (try? SSHTunnelManager.sshArguments(for: host, localSocket: URL(fileURLWithPath: "/tmp/check.sock"))) != nil
        else { return nil }
        return host
    }

    /// `me@devbox.local` → `devbox`; an IP address stays whole.
    public static func suggestedName(forTarget target: String) -> String {
        let host = target.trimmingCharacters(in: .whitespaces).split(separator: "@").last.map(String.init) ?? ""
        let isAddress = host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        return isAddress ? host : String(host.split(separator: ".").first ?? "")
    }
}
