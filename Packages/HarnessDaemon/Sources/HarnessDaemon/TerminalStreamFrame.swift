import Foundation
import HarnessCore

enum TerminalStreamFrame {
    case output(Data, UInt64), resize(ReplaySize)
    var sequence: UInt64 { switch self { case let .output(_, sequence): sequence; case let .resize(size): size.sequence } }
    var cost: Int { switch self { case let .output(data, _): data.count; case .resize: 32 } }
    var wire: Data? {
        switch self {
        case let .output(data, sequence): try? IPCCodec.encodeOutputFrame(data, sequence: sequence)
        case let .resize(size): try? IPCCodec.encode(IPCReply(response: .terminalResize(size)))
        }
    }
}
