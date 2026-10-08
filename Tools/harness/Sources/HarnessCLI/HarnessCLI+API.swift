import Foundation
import HarnessCore
import HarnessTerminalEngine

extension HarnessCLI {
    /// `api` exits itself. The outer `catch` in `main` turns thrown errors into exit 1,
    /// which would hide exit 2 and exit 3.
    static func handleAPI(_ args: [String]) -> Never {
        let sub = args.count > 1 ? args[1] : ""
        switch sub {
        case "list":
            do {
                print(try HarnessAPI.listJSON())
                exit(0)
            } catch {
                fputs("api list: \(error)\n", harnessStderr)
                exit(1)
            }
        case "describe":
            guard args.count > 2 else {
                fputs("Usage: harness-cli api describe <method>\n", harnessStderr)
                exit(2)
            }
            do {
                print(try HarnessAPI.describeJSON(named: args[2]))
                exit(0)
            } catch let error as APIPlanError {
                fputs("\(error.message)\n", harnessStderr)
                exit(Int32(error.code.rawValue))
            } catch {
                fputs("api describe: \(error)\n", harnessStderr)
                exit(1)
            }
        case "call":
            guard args.count > 2 else {
                fputs("Usage: harness-cli api call <method> --args '{...}'\n", harnessStderr)
                exit(2)
            }
            callAPI(method: args[2], args: args)
        default:
            fputs("Usage: harness-cli api list|describe|call <method> --args '{...}'\n", harnessStderr)
            exit(2)
        }
    }

    private static func callAPI(method name: String, args: [String]) -> Never {
        let parsed: [String: APIArgument]
        switch HarnessAPI.arguments(from: flagValue(args, flag: "--args") ?? "{}") {
        case let .success(value):
            parsed = value
        case let .failure(error):
            fputs("\(error.message)\n", harnessStderr)
            exit(Int32(error.code.rawValue))
        }
        let client: DaemonClient
        do {
            client = try makeClient(args)
        } catch {
            fputs("\(unreachableReason(error) ?? "\(error)")\n", harnessStderr)
            exit(CLIExit.unreachable)
        }
        let result = APIExecutor.call(method: name, arguments: parsed, client: client,
                                      environment: APIEnvironment(environment: callerEnvironment(args) ?? [:]))
        if let json = result.json { print(json) }
        if let message = result.message { fputs(message + "\n", harnessStderr) }
        exit(result.exitCode)
    }
}
