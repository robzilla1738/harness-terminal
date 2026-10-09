import Foundation
import Testing
@testable import HarnessRemoteProtocol

@Test func splitBinaryFramesAndControlPreserveBytesAndSequences() throws {
    let source: [RemoteMessage] = [.request(RemoteRequest(id: "r", method: "snapshot.get")),
        .output(RemoteOutput(surfaceID: "p", sequence: UInt64.max - 4, data: Data([0, 0xff, 0x1b, 0x80]))),
        .input(RemoteInput(surfaceID: "p", data: Data([13, 0, 255]))), .detach]
    let wire = try source.reduce(into: Data()) { $0.append(try RemoteCodec.encode($1)) }
    var buffer = Data(), result: [RemoteMessage] = []
    for byte in wire { buffer.append(byte); result.append(contentsOf: try RemoteCodec.decode(buffer: &buffer)) }
    #expect(result == source)
    #expect(buffer.isEmpty)
}

@Test func rejectOversizedAndInvalidFramesBeforeBufferingPayload() throws {
    var enormous = Data([0x7f, 0xff, 0xff, 0xff])
    #expect(throws: RemoteCodec.Failure.oversizedFrame) { _ = try RemoteCodec.decode(buffer: &enormous) }
    var bad = Data([0, 0, 0, 1, 9])
    #expect(throws: RemoteCodec.Failure.malformedFrame) { _ = try RemoteCodec.decode(buffer: &bad) }
    #expect(throws: RemoteCodec.Failure.invalidSurfaceID) { _ = try RemoteCodec.encode(.input(RemoteInput(surfaceID: "", data: Data()))) }
}

@Test func jsonValuesKeepNumericAndNullTypes() throws {
    let source: JSONValue = .object(["n": .int(7), "hash": .uint(UInt64.max), "d": .double(0.5), "b": .bool(true), "v": .null, "list": .array([.string("日本語")])])
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(source)) == source)
}
