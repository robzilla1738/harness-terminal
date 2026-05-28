import Foundation

/// Single dispatch point that turns a `Command` into a runtime effect.
///
/// Concrete executors live near the consumer: the macOS app implements a
/// `MainExecutor` that drives `SessionCoordinator`; `harness-cli` implements a
/// CLI-only executor that talks to the daemon over IPC; the daemon executes
/// hook-triggered commands via its own embedded executor.
///
/// The protocol intentionally hands off one command at a time so the
/// implementation can decide how to compose results — concurrent execution,
/// undo, capture, etc. — without baking that policy into Command.
public protocol CommandExecutor: AnyObject {
    /// Execute `command`. May throw if the command is malformed or its
    /// underlying IPC fails. `.sequence` is unwrapped by the executor so each
    /// component sees the full executor context.
    func execute(_ command: Command) throws
}

public extension CommandExecutor {
    /// Execute a textual command. Convenience for callers that already hold a
    /// string (the `:` prompt, `harness-cli run`).
    func executeSource(_ source: String) throws {
        let command = try CommandParser.parse(source)
        try execute(command)
    }
}

/// Errors that the executor surfaces back to the caller (used by `:` prompt
/// and `harness-cli run` to print a clear message).
public enum CommandExecutionError: Error, CustomStringConvertible {
    case daemonError(String)
    case unsupportedInThisContext(String)
    case noActiveSurface

    public var description: String {
        switch self {
        case let .daemonError(message): return "daemon: \(message)"
        case let .unsupportedInThisContext(message): return message
        case .noActiveSurface: return "no active surface"
        }
    }
}
