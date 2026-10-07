import XCTest

/// The daemon library linked into this test bundle must not contain the Lua runtime.
/// `swift test` builds this bundle from HarnessDaemonCore. The CLI target is the one that links CLua51.
final class DaemonLuaLinkTests: XCTestCase {
    func testDaemonTestBundleDoesNotExportLua() throws {
        let bundle = Bundle(for: DaemonLuaLinkTests.self).bundlePath
        let nm = try Self.symbols(of: Self.machO(in: bundle))
        XCTAssertFalse(nm.contains("luaL_newstate"), nm)
        XCTAssertFalse(nm.contains("lua_pcall"), nm)
        for relative in [
            ".build/debug/HarnessDaemon",
            ".build/out/Products/Debug/HarnessDaemon",
            ".build/out/Products/Release/HarnessDaemon",
        ] {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(relative)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            let symbols = try Self.symbols(of: url.path)
            XCTAssertFalse(symbols.contains("luaL_newstate"), relative)
            XCTAssertFalse(symbols.contains("lua_pcall"), relative)
            let libraries = try Self.output("/usr/bin/otool", ["-L", url.path])
            XCTAssertFalse(libraries.contains("liblua"), libraries)
        }
    }

    private static func machO(in bundle: String) -> String {
        let nested = (bundle as NSString).appendingPathComponent("Contents/MacOS")
        if let name = try? FileManager.default.contentsOfDirectory(atPath: nested).first {
            return (nested as NSString).appendingPathComponent(name)
        }
        return bundle
    }

    private static func symbols(of path: String) throws -> String {
        try output("/usr/bin/nm", ["-g", path])
    }

    private static func output(_ launch: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting. A full pipe otherwise stalls `nm` while we wait for it to exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
